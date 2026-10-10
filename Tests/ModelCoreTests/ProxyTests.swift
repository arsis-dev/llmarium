import Darwin
import Foundation
import Network
import XCTest
@testable import ModelCore

final class RouteTableTests: XCTestCase {
    private let deepseek = RemoteProvider(id: "deepseek", name: "DeepSeek", openAIBase: "https://api.deepseek.com/v1",
                                          anthropicBase: "https://api.deepseek.com/anthropic", models: ["deepseek-v4-pro", "deepseek-v4-flash"])
    private let cline = RemoteProvider(id: "cline", name: "Cline", openAIBase: "https://api.cline.bot/api/v1", anthropicBase: nil,
                                       models: [], prefix: "cline/")

    private func table() -> RouteTable {
        RouteTable(aliases: [ProxyAlias(alias: "granite-embedding", model: "granite-embedding-311m"),
                             ProxyAlias(alias: "qwen3.6-mtplx", model: "absent-model"),
                             ProxyAlias(alias: "ds4-flash", model: "deepseek-v4-flash"),
                             ProxyAlias(alias: "deepseek-v4-flash-api", model: "deepseek-v4-flash", provider: "deepseek")],
                   servers: [
                    .init(label: "oMLX", port: 8020, models: ["granite-embedding-311m", "Qwen3.5-4B"], owned: false),
                    .init(label: "MTPLX", port: 18_100, models: ["Qwen3.5-4B"], owned: true)
                   ], providers: [deepseek, cline])
    }

    func testPrecedenceAliasThenOwnedThenEnginesThenRemote() {
        guard case .upstream(let alias) = table().resolve(model: "granite-embedding", path: "/v1/embeddings") else { return XCTFail() }
        XCTAssertEqual(alias.port, 8020)
        XCTAssertEqual(alias.model, "granite-embedding-311m", "the alias becomes the engine's own id")
        guard case .upstream(let owned) = table().resolve(model: "Qwen3.5-4B", path: "/v1/chat/completions") else { return XCTFail() }
        XCTAssertEqual(owned.port, 18_100, "a server this app started wins over oMLX listing the same id")
        guard case .upstream(let remote) = table().resolve(model: "deepseek-v4-pro", path: "/v1/chat/completions") else { return XCTFail() }
        XCTAssertEqual(remote.host, "api.deepseek.com")
        XCTAssertEqual(remote.path, "/v1/chat/completions")
        XCTAssertTrue(remote.tls)
        XCTAssertEqual(remote.providerID, "deepseek")
        guard case .upstream(let prefixed) = table().resolve(model: "cline/anthropic/claude-x", path: "/v1/chat/completions") else { return XCTFail() }
        XCTAssertEqual(prefixed.model, "anthropic/claude-x")
        XCTAssertEqual(prefixed.path, "/api/v1/chat/completions")
    }

    func testAnthropicRoutesGoToTheAnthropicRoot() {
        guard case .upstream(let messages) = table().resolve(model: "deepseek-v4-pro", path: "/v1/messages") else { return XCTFail() }
        XCTAssertEqual(messages.path, "/anthropic/v1/messages")
        XCTAssertEqual(table().resolve(model: "cline/x", path: "/v1/messages"),
                       .notFound("« cline/x » n'est servi par aucun moteur en cours ni fournisseur distant. Lancez-le dans LLMarium ou avec : llmarium start cline/x"),
                       "no Anthropic root for Cline: no route rather than a wrong one")
    }

    func testALocalAliasNeverReachesTheCloud() {
        // ds4 is stopped; its id also exists at DeepSeek's API. The local alias must fail, not leave the machine.
        guard case .notFound = table().resolve(model: "ds4-flash", path: "/v1/chat/completions") else {
            return XCTFail("a local alias was routed to a remote API")
        }
        guard case .upstream(let remote) = table().resolve(model: "deepseek-v4-flash-api", path: "/v1/chat/completions") else { return XCTFail() }
        XCTAssertEqual(remote.providerID, "deepseek")
        XCTAssertEqual(remote.model, "deepseek-v4-flash")
    }

    func testAliasToAStoppedModelExplainsItself() {
        guard case .notFound(let message) = table().resolve(model: "qwen3.6-mtplx", path: "/v1/chat/completions") else { return XCTFail() }
        XCTAssertTrue(message.contains("absent-model"))
    }

    func testModelListHasOnlyReachableAliases() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: table().modelList()) as? [String: Any])
        let ids = (object["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        XCTAssertTrue(ids.contains("granite-embedding"))
        XCTAssertFalse(ids.contains("qwen3.6-mtplx"))
        XCTAssertTrue(ids.contains("deepseek-v4-pro"))
        XCTAssertEqual(ids.filter { $0 == "Qwen3.5-4B" }.count, 1)
    }
}

final class HTTPHeadTests: XCTestCase {
    func testParsesCaseInsensitiveHeadersAndForwardsACleanHead() throws {
        let raw = "POST /v1/chat/completions?x=1 HTTP/1.1\r\nhost: localhost:4000\r\nCONTENT-LENGTH: 12\r\nAuthorization: Bearer litellm:local\r\n"
            + "Expect: 100-continue\r\nAccept: text/event-stream\r\n\r\n{\"model\":1}"
        let (head, bodyStart) = try XCTUnwrap(HTTPRequestHead.parse(Data(raw.utf8)))
        XCTAssertEqual(head.path, "/v1/chat/completions")
        XCTAssertEqual(head.contentLength, 12)
        XCTAssertTrue(head.expectsContinue)
        XCTAssertEqual(bodyStart, raw.utf8.count - 11)
        let upstream = Upstream(host: "api.deepseek.com", port: 443, tls: true, path: "/v1/chat/completions", model: "m", providerID: "d", label: "d")
        let forwarded = String(decoding: head.forwarded(to: upstream, bodyLength: 40, authorization: [("Authorization", "Bearer secret")]), as: UTF8.self)
        XCTAssertTrue(forwarded.hasPrefix("POST /v1/chat/completions HTTP/1.1\r\nHost: api.deepseek.com\r\n"))
        XCTAssertFalse(forwarded.contains("litellm:local"), "the client's key never goes upstream")
        XCTAssertFalse(forwarded.lowercased().contains("expect"))
        XCTAssertTrue(forwarded.contains("Accept: text/event-stream"))
        XCTAssertTrue(forwarded.contains("Content-Length: 40\r\nConnection: close\r\n\r\n"))
        XCTAssertTrue(forwarded.contains("Authorization: Bearer secret"))
        XCTAssertNil(HTTPRequestHead.parse(Data("POST / HTTP/1.1\r\nHost: x\r\n".utf8)), "incomplete head")
    }

    func testBodyRewriteKeepsEveryOtherField() throws {
        let body = Data(#"{"model":"granite-embedding","input":["a","b"],"stream":true,"temperature":0.2}"#.utf8)
        XCTAssertEqual(ProxyBody.model(in: body), "granite-embedding")
        let rewritten = try XCTUnwrap(JSONSerialization.jsonObject(with: ProxyBody.rewriting(body, model: "granite-embedding-311m")) as? [String: Any])
        XCTAssertEqual(rewritten["model"] as? String, "granite-embedding-311m")
        XCTAssertEqual(rewritten["input"] as? [String], ["a", "b"])
        XCTAssertEqual(rewritten["stream"] as? Bool, true)
        XCTAssertEqual(ProxyBody.rewriting(body, model: "granite-embedding"), body, "unchanged bytes when the id is already right")
    }
}

final class ProxyStreamingTests: XCTestCase {
    /// A fake engine: answers one request with three server-sent events, 300 ms apart, then closes.
    final class FakeUpstream: @unchecked Sendable {
        let listener: NWListener
        let queue = DispatchQueue(label: "fake-upstream")
        var received = Data()
        let lock = NSLock()

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
        }

        func start() throws -> Int {
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
            listener.newConnectionHandler = { [self] connection in
                connection.start(queue: queue)
                read(connection)
            }
            listener.start(queue: queue)
            _ = ready.wait(timeout: .now() + 3)
            return Int(listener.port?.rawValue ?? 0)
        }

        private func read(_ connection: NWConnection) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, _, _ in
                lock.withLock { received.append(data ?? Data()) }
                let text = lock.withLock { String(decoding: received, as: UTF8.self) }
                guard let headEnd = text.range(of: "\r\n\r\n"),
                      let length = text.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") })
                        .flatMap({ Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) }),
                      text[headEnd.upperBound...].utf8.count >= length else { return read(connection) }
                connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n".utf8), completion: .idempotent)
                for index in 0..<3 {
                    queue.asyncAfter(deadline: .now() + .milliseconds(300 * (index + 1))) {
                        connection.send(content: Data("data: {\"n\":\(index)}\n\n".utf8), completion: .contentProcessed { _ in
                            if index == 2 { connection.cancel() }
                        })
                    }
                }
            }
        }
    }

    func testEventsReachTheClientAsTheyArriveAndTheModelIsRewritten() async throws {
        let upstream = try FakeUpstream()
        let upstreamPort = try upstream.start()
        let proxyPort = try XCTUnwrap(ModelLauncher.freePort())
        let table = RouteTable(aliases: [ProxyAlias(alias: "mon-alias", model: "vrai-modele")],
                               servers: [.init(label: "Faux", port: upstreamPort, models: ["vrai-modele"], owned: true)], providers: [])
        let proxy = ProxyServer(port: proxyPort, tableProvider: { table })
        try await proxy.start()
        defer { proxy.stop() }

        let arrivals = try await Task.detached { try Self.request(port: proxyPort, body: #"{"model":"mon-alias","stream":true}"#) }.value
        let events = arrivals.filter { $0.text.contains("data:") }
        XCTAssertEqual(events.flatMap { $0.text.components(separatedBy: "data:").dropFirst() }.count, 3)
        let first = try XCTUnwrap(events.first?.time)
        let last = try XCTUnwrap(events.last?.time)
        XCTAssertGreaterThan(last - first, 0.4, "events arrive spread over time, not buffered until the end")

        let request = upstream.lock.withLock { String(decoding: upstream.received, as: UTF8.self) }
        XCTAssertTrue(request.contains(#""model":"vrai-modele""#))
        XCTAssertTrue(request.contains("Connection: close"))
    }

    func testStoppingTheProxyMidStreamLetsTheAnswerFinish() async throws {
        let upstream = try FakeUpstream()
        let upstreamPort = try upstream.start()
        let proxyPort = try XCTUnwrap(ModelLauncher.freePort())
        let table = RouteTable(aliases: [], servers: [.init(label: "Faux", port: upstreamPort, models: ["m"], owned: true)], providers: [])
        var proxy: ProxyServer? = ProxyServer(port: proxyPort, tableProvider: { table })
        try await proxy?.start()
        let request = Task.detached { try Self.request(port: proxyPort, body: #"{"model":"m","stream":true}"#) }
        try await Task.sleep(for: .milliseconds(450))
        // The user turns the proxy off while the answer is streaming: the server object goes away.
        proxy?.stop()
        proxy = nil
        let arrivals = try await request.value
        XCTAssertEqual(arrivals.map(\.text).joined().components(separatedBy: "data:").count - 1, 3, "the open answer still completes")
    }

    /// Blocking client on a plain socket: records when each piece of the response arrives.
    static func request(port: Int, body: String) throws -> [(time: Double, text: String)] {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        let request = "POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        _ = request.withCString { send(socket, $0, strlen($0), 0) }
        let start = Date()
        var arrivals: [(Double, String)] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(socket, &buffer, buffer.count, 0)
            if count <= 0 { break }
            arrivals.append((Date().timeIntervalSince(start), String(decoding: buffer[..<count], as: UTF8.self)))
        }
        return arrivals
    }
}

final class LiteLLMImportTests: XCTestCase {
    static let config = """
    model_list:
      - model_name: ds4-flash
        litellm_params:
          model: openai/deepseek-v4-flash
          api_base: http://host.docker.internal:8000/v1
          api_key: dummy
      - model_name: granite-embedding
        litellm_params:
          model: openai/granite-embedding-311m   # oMLX
          api_base: http://host.docker.internal:8020/v1
        model_info:
          mode: embedding
      # - model_name: claude-haiku
      #   litellm_params:
      #     model: anthropic/claude-haiku-4-5
      - model_name: deepseek-v4-pro
        litellm_params:
          model: deepseek/deepseek-v4-pro
          api_key: os.environ/DEEPSEEK_API_KEY
      - model_name: deepseek-v4-flash-api
        litellm_params:
          model: deepseek/deepseek-v4-flash
      - model_name: cline/*
        litellm_params:
          model: openai/*
          api_base: https://api.cline.bot/api/v1
      - model_name: bedrock-thing
        litellm_params:
          model: bedrock/titan
    """

    func testLocalEntriesBecomeAliasesAndCloudEntriesProviders() {
        let result = LiteLLMImport.parse(Self.config)
        XCTAssertEqual(result.aliases, [
            ProxyAlias(alias: "ds4-flash", model: "deepseek-v4-flash"),
            ProxyAlias(alias: "granite-embedding", model: "granite-embedding-311m"),
            ProxyAlias(alias: "deepseek-v4-flash-api", model: "deepseek-v4-flash", provider: "deepseek")
        ])
        XCTAssertEqual(result.providers.map(\.id), ["deepseek", "cline"])
        XCTAssertEqual(result.providers[0].models, ["deepseek-v4-pro", "deepseek-v4-flash"])
        XCTAssertEqual(result.providers[1].prefix, "cline/")
        XCTAssertEqual(result.providers[1].openAIBase, "https://api.cline.bot/api/v1")
        XCTAssertEqual(result.skipped.count, 1, "unsupported providers are reported, commented entries ignored")
    }

    func testMergeReplacesAliasesAndKeepsExistingProviders() {
        let existing = ProxyConfig(port: 4000, aliases: [ProxyAlias(alias: "granite-embedding", model: "old")],
                                   providers: [RemoteProvider(id: "deepseek", name: "DeepSeek", openAIBase: "x", anthropicBase: nil, models: ["custom"])])
        let merged = LiteLLMImport.merge(LiteLLMImport.parse(Self.config), into: existing)
        XCTAssertEqual(merged.port, 4000)
        XCTAssertEqual(merged.aliases.first { $0.alias == "granite-embedding" }?.model, "granite-embedding-311m")
        XCTAssertEqual(merged.providers.first?.models, ["custom", "deepseek-v4-pro", "deepseek-v4-flash"])
        XCTAssertEqual(merged.providers.first?.openAIBase, "x", "a provider already configured keeps its endpoints")
    }
}
