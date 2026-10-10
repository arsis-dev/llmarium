import Foundation

/// A remote API reachable through the proxy. Its key lives in the Keychain, never in this file.
public struct RemoteProvider: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// OpenAI-compatible root including `/v1` (e.g. `https://api.deepseek.com/v1`).
    public var openAIBase: String?
    /// Anthropic-compatible root, to which `/v1/messages` is appended (e.g. `https://api.deepseek.com/anthropic`).
    public var anthropicBase: String?
    public var models: [String]
    /// Ids starting with this prefix go to this provider, prefix removed (`cline/` for `cline/*`).
    public var prefix: String?

    public init(id: String, name: String, openAIBase: String?, anthropicBase: String?, models: [String], prefix: String? = nil) {
        self.id = id
        self.name = name
        self.openAIBase = openAIBase
        self.anthropicBase = anthropicBase
        self.models = models
        self.prefix = prefix
    }
}

/// A stable name for a model, kept when the model moves to another engine or port.
public struct ProxyAlias: Codable, Hashable, Sendable {
    public var alias: String
    /// The id an engine or a provider serves.
    public var model: String
    /// Nil: local engines only, never a remote API (a local id can exist at a provider too: ds4's
    /// `deepseek-v4-flash` is also DeepSeek's cloud model). Set: that remote provider only.
    public var provider: String?

    public init(alias: String, model: String, provider: String? = nil) {
        self.alias = alias
        self.model = model
        self.provider = provider
    }
}

public struct ProxyConfig: Codable, Sendable {
    public var port: Int
    public var aliases: [ProxyAlias]
    public var providers: [RemoteProvider]

    public init(port: Int = 18_099, aliases: [ProxyAlias] = [], providers: [RemoteProvider] = []) {
        self.port = port
        self.aliases = aliases
        self.providers = providers
    }

    public static let file = AppPaths.support.appending(path: "proxy.json")

    public static func load(from file: URL = file) -> ProxyConfig {
        guard let data = try? Data(contentsOf: file), let config = try? JSONDecoder().decode(ProxyConfig.self, from: data) else {
            return ProxyConfig()
        }
        return config
    }

    public func save(to file: URL = file) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: file, options: .atomic)
    }
}

/// Where one request goes.
public struct Upstream: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var tls: Bool
    /// Path sent upstream (`/v1/chat/completions` locally, `/v1/chat/completions` or `/anthropic/v1/messages` remotely).
    public var path: String
    public var model: String
    /// Remote provider id: its key is added and the client's authorization dropped.
    public var providerID: String?
    /// For logs: « oMLX », « MTPLX », « deepseek »…
    public var label: String
}

public enum RouteResult: Equatable, Sendable {
    case upstream(Upstream)
    case notFound(String)
}

/// Who serves which model right now. Built from the runtime (and the proxy configuration), rebuilt every few seconds.
public struct RouteTable: Sendable {
    public struct LocalServer: Equatable, Sendable {
        public var label: String
        public var port: Int
        public var models: [String]
        /// Started by this app: wins over another server listing the same id.
        public var owned: Bool
    }

    public var aliases: [String: ProxyAlias]
    public var servers: [LocalServer]
    public var providers: [RemoteProvider]

    public init(aliases: [ProxyAlias], servers: [LocalServer], providers: [RemoteProvider]) {
        self.aliases = Dictionary(aliases.map { ($0.alias, $0) }, uniquingKeysWith: { first, _ in first })
        self.servers = servers
        self.providers = providers
    }

    public static func build(runtime: Runtime, config: ProxyConfig, launched: [LaunchedServer] = LaunchRegistry.shared.servers()) -> RouteTable {
        let ownedPIDs = Set(launched.map(\.pid))
        var servers: [LocalServer] = []
        for engine in runtime.engines {
            for instance in engine.instances where instance.api == .ok {
                guard let port = instance.ports.first else { continue }
                // oMLX loads its models on demand and refuses itself what does not fit: every id it knows is routable.
                let models = engine.omlx.map { $0.models.map(\.id) } ?? instance.servedModels
                servers.append(LocalServer(label: engine.kind.title, port: port, models: models, owned: ownedPIDs.contains(instance.pid)))
            }
        }
        return RouteTable(aliases: config.aliases, servers: servers, providers: config.providers)
    }

    /// Alias first, then a server this app started, then any running engine (MTPLX and mlx-serve before oMLX's
    /// on-demand list), then a remote provider by model list or prefix.
    public func resolve(model requested: String, path: String) -> RouteResult {
        let alias = aliases[requested]
        let model = alias?.model ?? requested
        let ordered = servers.filter(\.owned) + servers.filter { !$0.owned && $0.label != EngineKind.omlx.title }
            + servers.filter { !$0.owned && $0.label == EngineKind.omlx.title }
        if alias?.provider == nil, let server = ordered.first(where: { $0.models.contains(model) }) {
            return .upstream(Upstream(host: "127.0.0.1", port: server.port, tls: false, path: path, model: model, providerID: nil, label: server.label))
        }
        // A local alias never falls back to a remote API.
        let candidates = alias == nil ? providers : providers.filter { $0.id == alias?.provider }
        for provider in candidates {
            var upstreamModel: String?
            if provider.models.contains(model) { upstreamModel = model }
            else if let prefix = provider.prefix, model.hasPrefix(prefix) { upstreamModel = String(model.dropFirst(prefix.count)) }
            guard let upstreamModel, let route = Self.remotePath(provider, path: path) else { continue }
            return .upstream(Upstream(host: route.host, port: route.port, tls: route.tls, path: route.path, model: upstreamModel,
                                      providerID: provider.id, label: provider.id))
        }
        let hint = alias != nil ? "l'alias « \(requested) » vise « \(model) », qui n'est servi par aucun \(alias?.provider == nil ? "moteur local en cours" : "fournisseur joignable")"
                                             : "« \(requested) » n'est servi par aucun moteur en cours ni fournisseur distant"
        return .notFound("\(hint). Lancez-le dans LLMarium ou avec : llmarium start \(model)")
    }

    /// `/v1/messages` goes to the Anthropic-compatible root, every other `/v1/…` route to the OpenAI-compatible one.
    static func remotePath(_ provider: RemoteProvider, path: String) -> (host: String, port: Int, tls: Bool, path: String)? {
        let anthropic = path.hasPrefix("/v1/messages")
        guard let base = anthropic ? provider.anthropicBase : provider.openAIBase,
              let url = URLComponents(string: base), let host = url.host else { return nil }
        let basePath = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
        let suffix = anthropic ? path : String(path.dropFirst("/v1".count))
        let tls = url.scheme == "https"
        return (host, url.port ?? (tls ? 443 : 80), tls, basePath + suffix)
    }

    /// `GET /v1/models` in OpenAI shape: aliases, models served now, remote models.
    public func modelList(now: Date = Date()) -> Data {
        var seen = Set<String>()
        var entries: [[String: Any]] = []
        func add(_ id: String, owner: String) {
            guard seen.insert(id).inserted else { return }
            entries.append(["id": id, "object": "model", "created": Int(now.timeIntervalSince1970), "owned_by": owner])
        }
        for alias in aliases.keys.sorted() {
            if case .upstream(let upstream) = resolve(model: alias, path: "/v1/chat/completions") { add(alias, owner: upstream.label) }
        }
        for server in servers { server.models.forEach { add($0, owner: server.label) } }
        for provider in providers { provider.models.forEach { add($0, owner: provider.id) } }
        let body: [String: Any] = ["object": "list", "data": entries]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])) ?? Data()
    }
}

/// An HTTP/1.1 request head as received: kept as written except the headers the proxy must change.
public struct HTTPRequestHead: Equatable, Sendable {
    public var method: String
    public var target: String
    public var version: String
    public var headers: [(name: String, value: String)]

    public static func == (lhs: HTTPRequestHead, rhs: HTTPRequestHead) -> Bool {
        lhs.method == rhs.method && lhs.target == rhs.target && lhs.version == rhs.version
            && lhs.headers.map { "\($0.name):\($0.value)" } == rhs.headers.map { "\($0.name):\($0.value)" }
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public var contentLength: Int? { header("content-length").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
    public var isChunked: Bool { header("transfer-encoding")?.lowercased().contains("chunked") == true }
    public var expectsContinue: Bool { header("expect")?.lowercased() == "100-continue" }
    /// Path without the query string.
    public var path: String { String(target.split(separator: "?", maxSplits: 1).first ?? "") }

    /// Head and the offset where the body starts, once `\r\n\r\n` has arrived.
    public static func parse(_ data: Data) -> (head: HTTPRequestHead, bodyStart: Int)? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let text = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        let request = lines.removeFirst().split(separator: " ", maxSplits: 2).map(String.init)
        guard request.count == 3 else { return nil }
        let headers = lines.compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]), String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
        return (HTTPRequestHead(method: request[0], target: request[1], version: request[2], headers: headers),
                end.upperBound - data.startIndex)
    }

    /// The head sent upstream: same method and headers, except host, length, connection and authorization.
    public func forwarded(to upstream: Upstream, bodyLength: Int, authorization: [(String, String)]) -> Data {
        let dropped: Set<String> = ["host", "content-length", "connection", "keep-alive", "authorization", "x-api-key",
                                    "expect", "transfer-encoding", "proxy-connection"]
        var lines = ["\(method) \(upstream.path) HTTP/1.1"]
        let defaultPort = upstream.tls ? 443 : 80
        lines.append("Host: \(upstream.host)\(upstream.port == defaultPort ? "" : ":\(upstream.port)")")
        lines += headers.filter { !dropped.contains($0.name.lowercased()) }.map { "\($0.name): \($0.value)" }
        lines += authorization.map { "\($0.0): \($0.1)" }
        lines.append("Content-Length: \(bodyLength)")
        // One request per upstream connection: the response ends when the upstream closes it.
        lines.append("Connection: close")
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }
}

public enum ProxyBody {
    /// The requested model, read from a JSON body.
    public static func model(in body: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["model"] as? String
    }

    /// The same JSON with `model` replaced; the body is left untouched when it already names the upstream model.
    public static func rewriting(_ body: Data, model: String) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return body }
        if object["model"] as? String == model { return body }
        object["model"] = model
        return (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? body
    }

    public static func error(status: Int, message: String, type: String = "invalid_request_error") -> Data {
        let reason = [400: "Bad Request", 404: "Not Found", 411: "Length Required", 413: "Payload Too Large",
                      502: "Bad Gateway", 503: "Service Unavailable"][status] ?? "Error"
        let body = (try? JSONSerialization.data(withJSONObject: ["error": ["message": message, "type": type, "code": status]],
                                                options: [.withoutEscapingSlashes])) ?? Data()
        return response(status: status, reason: reason, body: body)
    }

    public static func response(status: Int, reason: String, body: Data, contentType: String = "application/json") -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        if status == 200 { head = head.replacingOccurrences(of: "200 \(reason)", with: "200 OK") }
        return Data(head.utf8) + body
    }
}
