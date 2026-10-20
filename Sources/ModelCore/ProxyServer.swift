import Foundation
import Network
import Security

/// API keys of remote providers, in the login Keychain. The proxy reads them when it forwards a request.
public enum ProviderKeys {
    static let service = "dev.arsis.llmarium.provider"

    public static func key(for provider: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: provider, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func hasKey(for provider: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: provider, kSecMatchLimit as String: kSecMatchLimitOne]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public static func setKey(_ key: String, for provider: String) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: provider]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrLabel as String] = "LLMarium : clé \(provider)"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public static func removeKey(for provider: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: provider]
        SecItemDelete(query as CFDictionary)
    }

    public struct KeychainError: Error, CustomStringConvertible {
        public var status: OSStatus
        public var description: String { (SecCopyErrorMessageString(status, nil) as String?) ?? "erreur du trousseau \(status)" }
    }
}

/// Local OpenAI / Anthropic-compatible entry point. It relays each request to the engine or provider serving the
/// requested model, rewriting only the request head and the `model` field: responses, streams included, are copied
/// back byte for byte. It listens on 127.0.0.1 and ::1 only.
public final class ProxyServer: @unchecked Sendable {
    public typealias Logger = @Sendable (String) -> Void

    public let port: Int
    private let queue = DispatchQueue(label: "dev.arsis.llmarium.proxy")
    private var listeners: [NWListener] = []
    private let tableProvider: @Sendable () async -> RouteTable
    private let keyProvider: @Sendable (String) -> String?
    /// Runs `claude -p` / `codex exec` for the subscription providers.
    let subscriptions: SubscriptionRunner
    private let log: Logger
    private let tableLock = NSLock()
    private var table = RouteTable(aliases: [], servers: [], providers: [])
    private var tableDate = Date.distantPast
    /// The rebuild in flight, shared by every request that needs a fresh table: never two inventories at once.
    private var refreshing: Task<RouteTable, Never>?
    /// How long a request waits for a fresh table before routing with the previous one.
    let refreshBudget: Duration
    /// An upstream that sends nothing for this long is cut: the client gets a 504 instead of waiting forever.
    let upstreamIdleTimeout: TimeInterval
    private let logFile: URL?

    public init(port: Int, tableProvider: @escaping @Sendable () async -> RouteTable,
                keyProvider: @escaping @Sendable (String) -> String? = { ProviderKeys.key(for: $0) },
                subscriptions: SubscriptionRunner = SubscriptionRunner(),
                refreshBudget: Duration = .seconds(3), upstreamIdleTimeout: TimeInterval = 300,
                logFile: URL? = nil, log: @escaping Logger = { _ in }) {
        self.port = port
        self.tableProvider = tableProvider
        self.keyProvider = keyProvider
        self.subscriptions = subscriptions
        self.refreshBudget = refreshBudget
        self.upstreamIdleTimeout = upstreamIdleTimeout
        self.logFile = logFile
        self.log = log
    }

    public enum StartError: Error, CustomStringConvertible {
        case portUnavailable(Int, String)
        public var description: String {
            switch self {
            case .portUnavailable(let port, let reason): "Le port \(port) n'est pas disponible (\(reason))."
            }
        }
    }

    /// Starts listening on 127.0.0.1 and returns once ready. Not on ::1: Network.framework refuses a second family on
    /// the same port, and clients of `localhost` fall back to IPv4 (LiteLLM in OrbStack listens on 127.0.0.1 only too).
    public func start() async throws {
        await refreshTable(budget: nil)
        guard let port = NWEndpoint.Port(rawValue: UInt16(port)) else { throw StartError.portUnavailable(self.port, "numéro invalide") }
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let failure: String? = await withCheckedContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume(returning: nil) }
                case .failed(let error), .waiting(let error): once.run { continuation.resume(returning: "\(error)") }
                case .cancelled: once.run { continuation.resume(returning: "annulé") }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        if let failure {
            listener.cancel()
            throw StartError.portUnavailable(self.port, failure.contains("48") ? "déjà utilisé" : failure)
        }
        listeners = [listener]
        log("Proxy à l'écoute sur http://127.0.0.1:\(self.port)/v1")
    }

    public func stop() {
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
    }

    public var currentTable: RouteTable { tableLock.withLock { table } }

    /// Rebuilt at most every few seconds, and at once when a model is not found.
    /// Rebuilt at most every few seconds, and at once when a model is not found. A single rebuild runs at a time;
    /// a request waits for it at most `budget`, then routes with the previous table (a slow engine must not freeze
    /// the entry point). The rebuild keeps running and its table serves the next requests.
    func refreshTable(ifOlderThan age: TimeInterval = 0, budget: Duration? = nil) async {
        let task: Task<RouteTable, Never>? = tableLock.withLock {
            guard Date().timeIntervalSince(tableDate) >= age else { return nil }
            if let refreshing { return refreshing }
            let provider = tableProvider
            let started = Task { [weak self] in
                let built = await provider()
                self?.store(built)
                return built
            }
            refreshing = started
            return started
        }
        guard let task else { return }
        guard let budget else {
            _ = await task.value
            return
        }
        let arrived: Bool = await withCheckedContinuation { continuation in
            let once = Once()
            Task {
                _ = await task.value
                once.run { continuation.resume(returning: true) }
            }
            Task {
                try? await Task.sleep(for: budget)
                once.run { continuation.resume(returning: false) }
            }
        }
        if !arrived { logRequest("Table de routage lente (plus de \(budget)) : la précédente sert en attendant.") }
    }

    private func store(_ built: RouteTable) {
        tableLock.withLock {
            table = built
            tableDate = Date()
            refreshing = nil
        }
    }

    func resolve(model: String, path: String) async -> RouteResult {
        await refreshTable(ifOlderThan: 5, budget: refreshBudget)
        let first = currentTable.resolve(model: model, path: path)
        guard case .notFound = first else { return first }
        await refreshTable(ifOlderThan: 1, budget: refreshBudget)
        return currentTable.resolve(model: model, path: path)
    }

    private func accept(_ connection: NWConnection) {
        let session = ProxySession(client: connection, server: self, queue: queue)
        session.start()
    }

    func logRequest(_ line: String) {
        log(line)
        guard let logFile else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        tableLock.withLock {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: logFile)
            }
        }
    }
    func key(for provider: String) -> String? { keyProvider(provider) }
}

/// Runs a closure once (continuations must be resumed exactly once).
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

/// Relay state of one answer; touched only on the session's serial queue.
final class PipeState: @unchecked Sendable {
    var sawFirst = false
    var ended = false
    var watchdog: DispatchWorkItem?
}

/// One client connection: read one request, answer it or relay it, close.
final class ProxySession: @unchecked Sendable {
    static let maxHead = 64 * 1024
    static let maxBody = 64 * 1024 * 1024

    let client: NWConnection
    /// Weak: the proxy may be stopped while a long answer is still streaming; the session then finishes on its own.
    weak var server: ProxyServer?
    let queue: DispatchQueue
    var buffer = Data()
    var parsed: (head: HTTPRequestHead, bodyStart: Int)?
    var sentContinue = false
    let begin = Date()

    init(client: NWConnection, server: ProxyServer, queue: DispatchQueue) {
        self.client = client
        self.server = server
        self.queue = queue
    }

    func start() {
        client.start(queue: queue)
        receive()
    }

    private func receive() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, complete, error in
            if let data { buffer.append(data) }
            if error != nil { client.cancel(); return }
            process(clientClosed: complete)
        }
    }

    private func process(clientClosed: Bool) {
        if parsed == nil {
            guard let found = HTTPRequestHead.parse(buffer) else {
                if buffer.count > Self.maxHead { return reply(ProxyBody.error(status: 413, message: "En-tête trop long.")) }
                return clientClosed ? client.cancel() : receive()
            }
            parsed = found
        }
        guard let (head, bodyStart) = parsed else { return }
        if head.isChunked && head.contentLength == nil {
            return reply(ProxyBody.error(status: 411, message: "Corps fragmenté non pris en charge : envoyez un Content-Length."))
        }
        let length = head.contentLength ?? 0
        if length > Self.maxBody { return reply(ProxyBody.error(status: 413, message: "Corps trop volumineux.")) }
        if head.expectsContinue && !sentContinue {
            sentContinue = true
            client.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
        }
        if buffer.count - bodyStart < length {
            return clientClosed ? client.cancel() : receive()
        }
        let body = buffer.subdata(in: (buffer.startIndex + bodyStart)..<(buffer.startIndex + bodyStart + length))
        handle(head, body: body)
    }

    private func handle(_ head: HTTPRequestHead, body: Data) {
        switch (head.method, head.path) {
        case ("GET", "/v1/models"), ("GET", "/models"):
            guard let server else { return reply(ProxyBody.error(status: 503, message: "Point d'entrée arrêté.")) }
            Task { [self] in
                await server.refreshTable(ifOlderThan: 5, budget: server.refreshBudget)
                let list = server.currentTable.modelList()
                queue.async { self.reply(ProxyBody.response(status: 200, reason: "OK", body: list)) }
            }
        case ("GET", "/health"), ("GET", "/"):
            reply(ProxyBody.response(status: 200, reason: "OK", body: Data(#"{"status":"ok","service":"LLMarium"}"#.utf8)))
        case ("POST", let path) where path.hasPrefix("/v1/"):
            guard let model = ProxyBody.model(in: body) else {
                return reply(ProxyBody.error(status: 400, message: "Champ « model » absent du corps JSON."))
            }
            guard let server else { return reply(ProxyBody.error(status: 503, message: "Point d'entrée arrêté.")) }
            Task { [self] in
                let route = await server.resolve(model: model, path: path)
                queue.async { self.route(route, head: head, body: body, requested: model) }
            }
        default:
            reply(ProxyBody.error(status: 404, message: "Route inconnue : \(head.method) \(head.path)."))
        }
    }

    private func route(_ route: RouteResult, head: HTTPRequestHead, body: Data, requested: String) {
        switch route {
        case .notFound(let message):
            server?.logRequest("\(head.method) \(head.path) \(requested) → introuvable")
            reply(ProxyBody.error(status: 404, message: message, type: "model_not_found"))
        case .upstream(let upstream):
            var authorization: [(String, String)] = []
            if let provider = upstream.providerID {
                guard let key = server?.key(for: provider) else {
                    return reply(ProxyBody.error(status: 503, message: "Clé absente pour « \(provider) » : ajoutez-la avec llmarium provider set-key \(provider)."))
                }
                authorization = head.path.hasPrefix("/v1/messages") ? [("x-api-key", key)] : [("Authorization", "Bearer \(key)")]
            }
            let rewritten = ProxyBody.rewriting(body, model: upstream.model)
            forward(head.forwarded(to: upstream, bodyLength: rewritten.count, authorization: authorization) + rewritten,
                    to: upstream, label: "\(head.method) \(head.path) \(requested) → \(upstream.label) \(upstream.model)")
        case .subscription(let target):
            answer(target, body: body, label: "\(head.method) \(head.path) \(requested) → \(target.cli.executableName) \(target.model)",
                   requested: requested)
        }
    }

    /// Runs the subscription's tool off the session queue (a call takes seconds to minutes), then answers at once.
    private func answer(_ target: SubscriptionTarget, body: Data, label: String, requested: String) {
        guard let runner = server?.subscriptions else { return reply(ProxyBody.error(status: 503, message: "Point d'entrée arrêté.")) }
        let request: SubscriptionRequest
        do { request = try SubscriptionRequest.parse(body) } catch {
            server?.logRequest("\(label) → 400 (\(error))")
            return reply(ProxyBody.error(status: 400, message: "\(error)"))
        }
        Task { [self] in
            let response: Data
            var line: String
            do {
                let answer = try await runner.answer(request, target: target)
                let shaped = SubscriptionResponse.body(answer, model: requested, stream: request.stream)
                response = ProxyBody.response(status: 200, reason: "OK", body: shaped.data, contentType: shaped.contentType)
                line = "200 en \(String(format: "%.1f", Date().timeIntervalSince(begin))) s · \(answer.inputTokens) → \(answer.outputTokens) tokens"
                if let cost = answer.costUSD { line += String(format: " · %.4f $ équivalent API", cost) }
            } catch let failure as SubscriptionFailure {
                response = ProxyBody.error(status: failure.status, message: failure.description, type: failure.type)
                line = "\(failure.status) en \(String(format: "%.1f", Date().timeIntervalSince(begin))) s (\(failure.description.prefix(200)))"
            } catch {
                response = ProxyBody.error(status: 502, message: "\(error)", type: "upstream_error")
                line = "502 (\(error))"
            }
            let logged = line
            queue.async {
                self.server?.logRequest("\(label) → \(logged)")
                self.reply(response)
            }
        }
    }

    private func forward(_ request: Data, to upstream: Upstream, label: String) {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 5
        let parameters = upstream.tls ? NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp) : NWParameters(tls: nil, tcp: tcp)
        guard let port = NWEndpoint.Port(rawValue: UInt16(upstream.port)) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(upstream.host), port: port, using: parameters)
        let once = Once()
        var status = "?"
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                once.run {
                    connection.send(content: request, completion: .contentProcessed { error in
                        if error != nil { connection.cancel() }
                    })
                    pipe(from: connection) { first in
                        status = String(decoding: first.prefix(12), as: UTF8.self).split(separator: " ").dropFirst().first.map(String.init) ?? "?"
                    } done: {
                        self.server?.logRequest("\(label) → \(status) en \(String(format: "%.1f", Date().timeIntervalSince(self.begin))) s")
                    }
                }
            case .waiting(let error), .failed(let error):
                once.run {
                    connection.cancel()
                    server?.logRequest("\(label) → injoignable (\(error.localizedDescription))")
                    reply(ProxyBody.error(status: 502, message: "\(upstream.label) ne répond pas sur \(upstream.host):\(upstream.port). Moteur arrêté ? Relancez-le dans LLMarium ou avec llmarium start.", type: "upstream_unavailable"))
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Copies the upstream response to the client as it arrives, then closes both.
    private func pipe(from upstream: NWConnection, first: @escaping (Data) -> Void, done: @escaping () -> Void) {
        let state = PipeState()
        let idle = server?.upstreamIdleTimeout ?? 300
        // Re-armed on every chunk: a stream that keeps flowing is never cut, a silent upstream is.
        func arm() {
            state.watchdog?.cancel()
            let item = DispatchWorkItem { [self] in
                guard !state.ended else { return }
                state.ended = true
                upstream.cancel()
                done()
                if state.sawFirst {
                    client.cancel()
                } else {
                    reply(ProxyBody.error(status: 504, message: "Le fournisseur n'a rien envoyé en \(Int(idle)) s : requête abandonnée.", type: "upstream_timeout"))
                }
            }
            state.watchdog = item
            queue.asyncAfter(deadline: .now() + idle, execute: item)
        }
        arm()
        func next() {
            upstream.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, complete, error in
                guard !state.ended else { return }
                arm()
                if let data, !data.isEmpty {
                    if !state.sawFirst { state.sawFirst = true; first(data) }
                    client.send(content: data, completion: .contentProcessed { sendError in
                        if sendError != nil {
                            // The client went away: stop the upstream request too.
                            state.ended = true
                            state.watchdog?.cancel()
                            upstream.cancel()
                            self.client.cancel()
                            done()
                        } else if complete || error != nil {
                            finish()
                        } else {
                            next()
                        }
                    })
                } else if complete || error != nil {
                    finish()
                } else {
                    next()
                }
            }
        }
        func finish() {
            guard !state.ended else { return }
            state.ended = true
            state.watchdog?.cancel()
            upstream.cancel()
            client.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [self] _ in
                client.cancel()
            })
            done()
        }
        next()
    }

    private func reply(_ response: Data) {
        client.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [self] _ in
            client.cancel()
        })
    }
}
