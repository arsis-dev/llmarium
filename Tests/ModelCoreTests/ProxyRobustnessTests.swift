import Darwin
import Foundation
import Network
import XCTest
@testable import ModelCore

/// The entry point stays responsive when the inventory is slow or an upstream goes silent.
final class ProxyRobustnessTests: XCTestCase {
    /// Counts table rebuilds; after the first one, each rebuild takes `delay`.
    final class SlowTable: @unchecked Sendable {
        let lock = NSLock()
        var calls = 0
        var inFlight = 0
        var maxInFlight = 0
        let delay: Duration
        let table: RouteTable
        init(delay: Duration, table: RouteTable) { self.delay = delay; self.table = table }

        func build() async -> RouteTable {
            let first = lock.withLock {
                calls += 1
                inFlight += 1
                maxInFlight = max(maxInFlight, inFlight)
                return calls == 1
            }
            if !first { try? await Task.sleep(for: delay) }
            lock.withLock { inFlight -= 1 }
            return table
        }
    }

    /// Accepts connections and never answers.
    final class SilentUpstream: @unchecked Sendable {
        let queue = DispatchQueue(label: "silent-upstream")
        var listener: NWListener?
        var connections: [NWConnection] = []

        func start() throws -> Int {
            let listener = try NWListener(using: .tcp, on: .any)
            self.listener = listener
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
            listener.newConnectionHandler = { [self] connection in
                connections.append(connection)
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in }
            }
            listener.start(queue: queue)
            _ = ready.wait(timeout: .now() + 3)
            return Int(listener.port?.rawValue ?? 0)
        }
    }

    static func get(port: Int, path: String) throws -> (seconds: Double, text: String) {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var timeout = timeval(tv_sec: 20, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        let request = "GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n"
        _ = request.withCString { send(socket, $0, strlen($0), 0) }
        let start = Date()
        var text = ""
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(socket, &buffer, buffer.count, 0)
            if count <= 0 { break }
            text += String(decoding: buffer[..<count], as: UTF8.self)
        }
        return (Date().timeIntervalSince(start), text)
    }

    func testASlowInventoryNeitherFreezesNorPilesUp() async throws {
        let table = RouteTable(aliases: [], servers: [.init(label: "Faux", port: 1, models: ["m"], owned: true)], providers: [])
        let slow = SlowTable(delay: .seconds(4), table: table)
        let port = try XCTUnwrap(ModelLauncher.freePort())
        let proxy = ProxyServer(port: port, tableProvider: { await slow.build() }, refreshBudget: .milliseconds(300))
        try await proxy.start()
        defer { proxy.stop() }
        // Let the first table age past the refresh interval, then ask three times at once.
        try await Task.sleep(for: .seconds(5.2))
        async let a = Task.detached { try Self.get(port: port, path: "/v1/models") }.value
        async let b = Task.detached { try Self.get(port: port, path: "/v1/models") }.value
        async let c = Task.detached { try Self.get(port: port, path: "/v1/models") }.value
        let answers = try await [a, b, c]
        for answer in answers {
            XCTAssertTrue(answer.text.hasPrefix("HTTP/1.1 200"), answer.text)
            XCTAssertTrue(answer.text.contains("\"m\""), "the previous table still serves")
            XCTAssertLessThan(answer.seconds, 2, "the request does not wait for the slow rebuild")
        }
        XCTAssertEqual(slow.lock.withLock { slow.maxInFlight }, 1, "one rebuild at a time")
    }

    func testASilentUpstreamEndsWithA504() async throws {
        let upstream = SilentUpstream()
        let upstreamPort = try upstream.start()
        let port = try XCTUnwrap(ModelLauncher.freePort())
        let table = RouteTable(aliases: [], servers: [.init(label: "Muet", port: upstreamPort, models: ["m"], owned: true)], providers: [])
        let log = FileManager.default.temporaryDirectory.appending(path: "proxy-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let proxy = ProxyServer(port: port, tableProvider: { table }, upstreamIdleTimeout: 1, logFile: log)
        try await proxy.start()
        defer { proxy.stop() }
        let start = Date()
        let arrivals = try await Task.detached { try ProxyStreamingTests.request(port: port, body: #"{"model":"m"}"#) }.value
        let text = arrivals.map(\.text).joined()
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 504"), text)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        let written = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        XCTAssertTrue(written.contains("Muet"), "the request is in the log file: \(written)")
    }
}
