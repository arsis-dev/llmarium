import Foundation
import Network
import Security

/// API keys of remote providers, in the login Keychain. The proxy reads them when it forwards a request.
public enum ProviderKeys {
    static let service = "dev.arsis.localmodellauncher.provider"

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
        item[kSecAttrLabel as String] = "Modèles locaux : clé \(provider)"
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
    private let queue = DispatchQueue(label: "dev.arsis.localmodellauncher.proxy")
    private var listeners: [NWListener] = []
    private let tableProvider: @Sendable () async -> RouteTable
    private let keyProvider: @Sendable (String) -> String?
    private let log: Logger
    private let tableLock = NSLock()
    private var table = RouteTable(aliases: [], servers: [], providers: [])
    private var tableDate = Date.distantPast

    public init(port: Int, tableProvider: @escaping @Sendable () async -> RouteTable,
                keyProvider: @escaping @Sendable (String) -> String? = { ProviderKeys.key(for: $0) }, log: @escaping Logger = { _ in }) {
        self.port = port
        self.tableProvider = tableProvider
        self.keyProvider = keyProvider
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
        await refreshTable()
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
    func refreshTable(ifOlderThan age: TimeInterval = 0) async {
        let fresh = tableLock.withLock { Date().timeIntervalSince(tableDate) < age }
        guard !fresh else { return }
        let built = await tableProvider()
        tableLock.withLock {
            table = built
            tableDate = Date()
        }
    }

    func resolve(model: String, path: String) async -> RouteResult {
        await refreshTable(ifOlderThan: 5)
        let first = currentTable.resolve(model: model, path: path)
        guard case .notFound = first else { return first }
        await refreshTable(ifOlderThan: 1)
        return currentTable.resolve(model: model, path: path)
    }

    private func accept(_ connection: NWConnection) {
        let session = ProxySession(client: connection, server: self, queue: queue)
        session.start()
    }

    func logRequest(_ line: String) { log(line) }
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
                await server.refreshTable(ifOlderThan: 5)
                let list = server.currentTable.modelList()
                queue.async { self.reply(ProxyBody.response(status: 200, reason: "OK", body: list)) }
            }
        case ("GET", "/health"), ("GET", "/"):
            reply(ProxyBody.response(status: 200, reason: "OK", body: Data(#"{"status":"ok","service":"Modèles locaux"}"#.utf8)))
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
                    return reply(ProxyBody.error(status: 503, message: "Clé absente pour « \(provider) » : ajoutez-la avec lml provider set-key \(provider)."))
                }
                authorization = head.path.hasPrefix("/v1/messages") ? [("x-api-key", key)] : [("Authorization", "Bearer \(key)")]
            }
            let rewritten = ProxyBody.rewriting(body, model: upstream.model)
            forward(head.forwarded(to: upstream, bodyLength: rewritten.count, authorization: authorization) + rewritten,
                    to: upstream, label: "\(head.method) \(head.path) \(requested) → \(upstream.label) \(upstream.model)")
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
                    reply(ProxyBody.error(status: 502, message: "\(upstream.label) ne répond pas sur \(upstream.host):\(upstream.port). Moteur arrêté ? Relancez-le dans Modèles locaux ou avec lml start.", type: "upstream_unavailable"))
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Copies the upstream response to the client as it arrives, then closes both.
    private func pipe(from upstream: NWConnection, first: @escaping (Data) -> Void, done: @escaping () -> Void) {
        var sawFirst = false
        func next() {
            upstream.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, complete, error in
                if let data, !data.isEmpty {
                    if !sawFirst { sawFirst = true; first(data) }
                    client.send(content: data, completion: .contentProcessed { sendError in
                        if sendError != nil {
                            // The client went away: stop the upstream request too.
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
