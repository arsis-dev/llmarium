import Foundation

public enum EngineKind: String, Codable, CaseIterable, Sendable {
    case omlx, mtplx, mlxServe

    public var title: String {
        switch self {
        case .omlx: "oMLX"
        case .mtplx: "MTPLX"
        case .mlxServe: "mlx-serve"
        }
    }

    public var store: StoreKind {
        switch self {
        case .omlx: .omlx
        case .mtplx: .mtplx
        case .mlxServe: .mlxServe
        }
    }
}

public struct EngineInstallation: Codable, Hashable, Sendable {
    public var kind: EngineKind
    public var version: String?
    public var location: String?

    public var isInstalled: Bool { location != nil }

    public init(kind: EngineKind, version: String?, location: String?) {
        self.kind = kind
        self.version = version
        self.location = location
    }

    public static func detect(_ kind: EngineKind, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> EngineInstallation {
        let applications = ["/Applications", home.appending(path: "Applications").path]
        func app(_ name: String) -> (String, String?)? {
            for folder in applications {
                let path = "\(folder)/\(name)"
                if FileManager.default.fileExists(atPath: path) {
                    let info = NSDictionary(contentsOfFile: "\(path)/Contents/Info.plist")
                    return (path, info?["CFBundleShortVersionString"] as? String)
                }
            }
            return nil
        }
        switch kind {
        case .omlx:
            if let (path, version) = app("oMLX.app") { return EngineInstallation(kind: kind, version: version, location: path) }
            let cli = home.appending(path: ".omlx/bin/omlx").path
            return EngineInstallation(kind: kind, version: nil, location: FileManager.default.fileExists(atPath: cli) ? cli : nil)
        case .mtplx:
            // The Homebrew CLI is what serves; MTPLX.app is a front end.
            for cellar in ["/opt/homebrew/Cellar/mtplx", "/usr/local/Cellar/mtplx"] {
                let versions = (try? FileManager.default.contentsOfDirectory(atPath: cellar)) ?? []
                if let latest = versions.max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) {
                    return EngineInstallation(kind: kind, version: latest, location: "\(cellar)/\(latest)/bin/mtplx")
                }
            }
            if let (path, version) = app("MTPLX.app") { return EngineInstallation(kind: kind, version: version, location: path) }
            return EngineInstallation(kind: kind, version: nil, location: nil)
        case .mlxServe:
            let (path, version) = app("MLX-Serve.app") ?? (nil, nil)
            return EngineInstallation(kind: kind, version: version, location: path.map { "\($0)/Contents/MacOS/mlx-serve" })
        }
    }
}

public enum APIState: String, Codable, Sendable {
    case ok, authRequired, unreachable, notProbed

    public var title: String {
        switch self {
        case .ok: "Répond"
        case .authRequired: "Répond, clé requise"
        case .unreachable: "Ne répond pas"
        case .notProbed: "Non vérifié"
        }
    }
}

/// One running server of an engine.
public struct EngineInstance: Codable, Hashable, Sendable {
    public var pid: Int32
    public var ports: [Int]
    public var footprintBytes: Int64
    public var api: APIState = .notProbed
    /// Identifiers listed by `/v1/models`.
    public var servedModels: [String] = []

    public var url: String? { ports.first.map { "http://127.0.0.1:\($0)" } }
}

public struct OMLXModelState: Codable, Hashable, Sendable {
    public var id: String
    public var loaded: Bool
    public var isLoading: Bool
    public var estimatedBytes: Int64?
    public var residentBytes: Int64?
    /// Weights size oMLX measured the last time it loaded the model.
    public var actualBytes: Int64?
    /// Only covers the current oMLX server run: nil means "not since oMLX started", not "never".
    public var lastAccess: Date?
    public var maxContext: Int?
}

/// What oMLX says about its memory: the ceiling it enforces and each model it knows.
public struct OMLXState: Codable, Sendable {
    public var ceilingBytes: Int64?
    public var loadedBytes: Int64?
    public var models: [OMLXModelState]

    static func parse(_ data: Data) -> OMLXState? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func int64(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }
        let models = (root["models"] as? [[String: Any]] ?? []).compactMap { item -> OMLXModelState? in
            guard let id = item["id"] as? String else { return nil }
            return OMLXModelState(id: id, loaded: item["loaded"] as? Bool ?? false, isLoading: item["is_loading"] as? Bool ?? false,
                                  estimatedBytes: int64(item["estimated_size"]), residentBytes: int64(item["resident_estimated_size"]),
                                  actualBytes: int64(item["actual_size"]),
                                  lastAccess: (item["last_access"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                                  maxContext: (item["max_context_window"] as? NSNumber)?.intValue)
        }
        return OMLXState(ceilingBytes: int64(root["final_ceiling"]), loadedBytes: int64(root["current_model_memory"]), models: models)
    }
}

public struct EngineStatus: Codable, Sendable, Identifiable {
    public var installation: EngineInstallation
    public var instances: [EngineInstance]
    public var omlx: OMLXState?

    public var id: EngineKind { installation.kind }
    public var kind: EngineKind { installation.kind }
    public var isRunning: Bool { !instances.isEmpty }
}

public enum EngineDetector {
    /// Read-only: lists processes and calls `/v1/models` (and `/v1/models/status` on oMLX), never a route that loads a model.
    public static func detect(processes: [RunningProcess], ports: PortTable = .current(),
                              home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> [EngineStatus] {
        let listening = ports.listening
        var statuses: [EngineStatus] = []
        for kind in EngineKind.allCases {
            let servers = processes.filter { $0.role.engine == kind && isServer($0, kind: kind) }
            var instances: [EngineInstance] = []
            for process in servers {
                var ports = listening[process.pid] ?? []
                if ports.isEmpty, kind == .omlx, let port = omlxPort(home: home) { ports = [port] }
                var instance = EngineInstance(pid: process.pid, ports: ports, footprintBytes: process.footprintBytes)
                if let url = instance.url {
                    (instance.api, instance.servedModels) = await probeModels(base: url)
                }
                instances.append(instance)
            }
            var status = EngineStatus(installation: .detect(kind, home: home), instances: instances)
            if kind == .omlx, let url = instances.first(where: { $0.api == .ok })?.url {
                status.omlx = await fetch(url + "/v1/models/status").flatMap(OMLXState.parse)
            }
            statuses.append(status)
        }
        return statuses
    }

    /// The process that answers HTTP, not the app around it (oMLX.app, MTPLX.app, MLXCore).
    static func isServer(_ process: RunningProcess, kind: EngineKind) -> Bool {
        switch kind {
        case .omlx: process.arguments.first == "omlx-server" || process.arguments.contains { $0.hasPrefix("omlx.server") }
        case .mtplx: process.arguments.contains { $0.hasPrefix("mtplx.server") }
        case .mlxServe: process.executablePath.hasSuffix("/mlx-serve")
        }
    }

    static func omlxPort(home: URL) -> Int? {
        guard let data = try? Data(contentsOf: home.appending(path: ".omlx/settings.json")),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let server = root["server"] as? [String: Any] else { return nil }
        return (server["port"] as? NSNumber)?.intValue
    }

    static func probeModels(base: String) async -> (APIState, [String]) {
        guard let url = URL(string: base + "/v1/models") else { return (.unreachable, []) }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "GET"
        // A kept-alive probe would show this app as a client of the engine.
        request.setValue("close", forHTTPHeaderField: "Connection")
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else {
            return (.unreachable, [])
        }
        if http.statusCode == 401 || http.statusCode == 403 { return (.authRequired, []) }
        guard http.statusCode == 200,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (.unreachable, []) }
        let ids = (root["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        return (.ok, ids)
    }

    static func fetch(_ address: String) async -> Data? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.setValue("close", forHTTPHeaderField: "Connection")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()
}

/// Local TCP ports: which process listens on which port, and which processes are connected to it.
public struct PortTable: Sendable {
    public var listening: [Int32: [Int]] = [:]
    /// Port → PIDs of local clients currently connected to it.
    public var clients: [Int: [Int32]] = [:]

    public init(listening: [Int32: [Int]] = [:], clients: [Int: [Int32]] = [:]) {
        self.listening = listening
        self.clients = clients
    }

    public static func current() -> PortTable {
        guard let output = Command.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-FpnT"]) else { return PortTable() }
        return parse(output)
    }

    /// `lsof -F pnT` output: `p<pid>`, then per socket `n<name>` and `TST=<state>`.
    static func parse(_ output: String) -> PortTable {
        var listening: [Int32: Set<Int>] = [:]
        var connections: [(pid: Int32, remotePort: Int)] = []
        var pid: Int32?
        var name: Substring?
        func flush(state: Substring) {
            guard let pid, let name else { return }
            if state == "LISTEN", let port = name.split(separator: ":").last.flatMap({ Int($0) }) {
                listening[pid, default: []].insert(port)
            } else if state == "ESTABLISHED", let arrow = name.range(of: "->") {
                let remote = name[arrow.upperBound...]
                guard let colon = remote.lastIndex(of: ":"), let port = Int(remote[remote.index(after: colon)...]),
                      ["127.0.0.1", "[::1]", "localhost"].contains(String(remote[..<colon])) else { return }
                connections.append((pid, port))
            }
        }
        for line in output.split(separator: "\n") {
            switch line.first {
            case "p": pid = Int32(line.dropFirst()); name = nil
            case "f": name = nil
            case "n": name = line.dropFirst()
            case "T" where line.hasPrefix("TST="): flush(state: line.dropFirst(4))
            default: break
            }
        }
        let owners = listening.reduce(into: [Int: Int32]()) { result, entry in entry.value.forEach { result[$0] = entry.key } }
        var clients: [Int: Set<Int32>] = [:]
        // The server's own side of a connection also points at a loopback port: keep only other processes.
        for connection in connections where owners[connection.remotePort].map({ $0 != connection.pid }) == true {
            clients[connection.remotePort, default: []].insert(connection.pid)
        }
        return PortTable(listening: listening.mapValues { $0.sorted() }, clients: clients.mapValues { $0.sorted() })
    }
}

enum Command {
    static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
