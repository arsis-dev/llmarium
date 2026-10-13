import Darwin
import Foundation

/// A server this app started. Kept in `launched.json` so the app still recognises it after a restart,
/// and so it is never mistaken for an orphan.
public struct LaunchedServer: Codable, Hashable, Sendable {
    public var pid: Int32
    public var startedAt: Date
    public var engine: EngineKind
    public var model: String
    public var port: Int
    public var context: Int?
    public var logPath: String
    public var arguments: [String]
    /// Seconds from launch to the first answer of `/v1/models`.
    public var loadSeconds: Int?
    /// Stop the server after this many minutes without activity. Only counted while the app is open.
    public var idleStopAfterMinutes: Int?
    /// Last time the server did something, and its CPU time and log size at the last check.
    public var lastActiveAt: Date?
    public var lastCPUSeconds: Double?
    public var lastLogBytes: Int64?
    public var lastCheckedAt: Date?

    /// When it last did something: its last activity, otherwise the end of its loading.
    public var activeSince: Date { lastActiveAt ?? startedAt.addingTimeInterval(TimeInterval(loadSeconds ?? 0)) }
}

/// When a server started with an idle limit should stop. Three signals, any of which counts as activity: its log
/// grew (MTPLX writes one line per generation), it used CPU beyond its idle level, or a client is connected.
/// Measured on 10 October 2026: mlx-serve idle uses no CPU, MTPLX idle about 0.12 s per minute, and a 5-token
/// request on MTPLX 0.13 s — so CPU alone cannot tell a short request from idling, the log can.
public enum IdlePolicy {
    /// CPU seconds per minute that count as activity: four times MTPLX's idle level; for mlx-serve, which uses
    /// none at rest, anything a request costs.
    public static func activityThreshold(_ engine: EngineKind) -> Double { engine == .mlxServe ? 0.05 : 0.5 }

    public static func check(_ server: LaunchedServer, cpuSeconds: Double?, logBytes: Int64? = nil, hasClients: Bool,
                             now: Date = Date()) -> (server: LaunchedServer, stop: Bool) {
        var updated = server
        // Scaled by the time since the last check: after a sleep of the Mac, an hour of idle CPU is not a request.
        let minutes = max(1, server.lastCheckedAt.map { now.timeIntervalSince($0) / 60 } ?? 1)
        let usedCPU = cpuSeconds.flatMap { current in
            server.lastCPUSeconds.map { current - $0 >= activityThreshold(server.engine) * minutes }
        } ?? false
        let logged = logBytes.flatMap { current in server.lastLogBytes.map { current != $0 } } ?? false
        // No baseline yet (first check): count it as active, the loading itself used the CPU.
        if hasClients || usedCPU || logged || server.lastCPUSeconds == nil { updated.lastActiveAt = now }
        if let cpuSeconds { updated.lastCPUSeconds = cpuSeconds }
        if let logBytes { updated.lastLogBytes = logBytes }
        updated.lastCheckedAt = now
        guard let minutes = server.idleStopAfterMinutes, cpuSeconds != nil else { return (updated, false) }
        return (updated, now.timeIntervalSince(updated.activeSince) >= TimeInterval(minutes * 60))
    }

    /// Size of the server's log, which this app writes to.
    public static func logBytes(_ server: LaunchedServer) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: server.logPath)[.size] as? NSNumber)?.int64Value
    }
}

public final class LaunchRegistry: @unchecked Sendable {
    public static let shared = LaunchRegistry(file: AppPaths.support.appending(path: "launched.json"))

    private let file: URL
    private let lock = NSLock()

    public init(file: URL) { self.file = file }

    public func servers() -> [LaunchedServer] {
        lock.lock()
        defer { lock.unlock() }
        return read()
    }

    public func add(_ server: LaunchedServer) {
        update { $0.removeAll { $0.pid == server.pid }; $0.append(server) }
    }

    /// Drops servers that have exited, or whose PID now belongs to another process.
    public func reconcile(isAlive: (LaunchedServer) -> Bool = { ModelActions.isSameProcess(pid: $0.pid, startedAt: $0.startedAt) }) {
        update { $0.removeAll { !isAlive($0) } }
    }

    public func server(pid: Int32, startedAt: Date?) -> LaunchedServer? {
        servers().first { $0.pid == pid && (startedAt == nil || abs($0.startedAt.timeIntervalSince(startedAt!)) < 1) }
    }

    private func update(_ change: (inout [LaunchedServer]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var servers = read()
        let before = servers
        change(&servers)
        guard servers != before else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(servers).write(to: file, options: .atomic)
    }

    private func read() -> [LaunchedServer] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([LaunchedServer].self, from: data)) ?? []
    }
}

public enum AppPaths {
    public static let support: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        let current = base.appending(path: "LLMarium")
        // Data written before the app was named LLMarium moves once, for the app and the CLI alike.
        let legacy = base.appending(path: "LocalModelLauncher")
        if !FileManager.default.fileExists(atPath: current.path), FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: current)
        }
        return current
    }()
    public static let logs = support.appending(path: "Logs")
}

/// The command that serves one model on one engine. Arguments stay an array: paths with spaces remain one argument.
public struct LaunchPlan: Equatable, Sendable {
    public var engine: EngineKind
    public var executable: String
    public var arguments: [String]
    public var port: Int
    public var context: Int?

    public enum PlanError: Error, Equatable, CustomStringConvertible {
        case notInstalled(EngineKind)
        case wrongStore(EngineKind)
        case brokenModel

        public var description: String {
            switch self {
            case .notInstalled(let engine): "\(engine.title) n'est pas installé."
            case .wrongStore(let engine): "\(engine.title) ne sert que les modèles de son propre dossier."
            case .brokenModel: "Ce modèle est un lien cassé."
            }
        }
    }

    /// MTPLX and mlx-serve serve the models of their own folder; both always listen on localhost only.
    public static func make(model: LocalModel, engine: EngineKind, port: Int, context: Int?, installation: EngineInstallation,
                            recipe: Recipe? = nil) throws -> LaunchPlan {
        guard !model.isBrokenLink else { throw PlanError.brokenModel }
        guard let executable = installation.location else { throw PlanError.notInstalled(engine) }
        guard model.store == engine.store else { throw PlanError.wrongStore(engine) }
        var arguments: [String]
        switch engine {
        case .mtplx:
            arguments = ["serve", "--model", model.name, "--host", "127.0.0.1", "--port", String(port), "--no-auth",
                         "--model-id", servedName(model), "--yes"]
            if let context { arguments += ["--context-window", String(context)] }
        case .mlxServe:
            arguments = ["--model", model.path, "--serve", "--host", "127.0.0.1", "--port", String(port)]
            if let context { arguments += ["--ctx-size", String(context)] }
        case .omlx:
            throw PlanError.wrongStore(.omlx)
        }
        arguments += recipe?.arguments(for: engine, existing: arguments) ?? []
        return LaunchPlan(engine: engine, executable: executable, arguments: arguments, port: port, context: context)
    }

    /// The identifier harnesses will use: the model folder name, without owner.
    public static func servedName(_ model: LocalModel) -> String {
        model.name.split(separator: "/").last.map(String.init) ?? model.name
    }
}

public enum ModelLauncher {
    public enum StartResult: Sendable {
        case ready(LaunchedServer, servedModels: [String], seconds: Int)
        case loadedInOMLX(String, seconds: Int)
        case failed(String, logTail: String?)
    }

    /// Ports the app hands out to engines it starts. The usual engine ports (8000, 8010, 8020, 11234, 4000)
    /// stay with the setups that already expect them.
    public static let portRange = 18_100..<18_200

    public static func freePort(excluding used: Set<Int> = []) -> Int? {
        portRange.first { !used.contains($0) && canBind($0) }
    }

    static func canBind(_ port: Int) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    /// Starts the server in its own session (a Ctrl-C in the terminal that ran `llmarium start` does not reach it),
    /// logs to a file, waits until it serves, and records it as launched by this app.
    public static func start(_ plan: LaunchPlan, model: LocalModel, idleStopAfterMinutes: Int? = nil, registry: LaunchRegistry = .shared,
                             timeout: TimeInterval = 900) async -> StartResult {
        try? FileManager.default.createDirectory(at: AppPaths.logs, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let log = AppPaths.logs.appending(path: "\(plan.engine.rawValue)-\(LaunchPlan.servedName(model))-\(stamp).log")
        let begin = Date()
        let pid: pid_t
        do { pid = try spawn(plan.executable, plan.arguments, log: log.path) } catch {
            return .failed("Lancement impossible : \(error)", logTail: nil)
        }
        let startedAt = ProcessScanner.bsdInfo(of: pid)?.startedAt ?? begin
        let server = LaunchedServer(pid: pid, startedAt: startedAt, engine: plan.engine, model: model.name, port: plan.port,
                                    context: plan.context, logPath: log.path, arguments: [plan.executable] + plan.arguments,
                                    idleStopAfterMinutes: idleStopAfterMinutes)
        registry.add(server)

        let deadline = begin.addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(1))
            // The child is ours until this process exits: reap it, or it would linger as a zombie that looks alive.
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid {
                registry.reconcile()
                return .failed("\(plan.engine.title) s'est arrêté pendant le chargement.", logTail: tail(of: log.path))
            }
            let (state, served) = await EngineDetector.probeModels(base: "http://127.0.0.1:\(plan.port)")
            if state == .ok, !served.isEmpty {
                Thread.detachNewThread { waitpid(pid, nil, 0) }
                var ready = server
                ready.loadSeconds = Int(Date().timeIntervalSince(begin))
                registry.add(ready)
                return .ready(ready, servedModels: served, seconds: ready.loadSeconds ?? 0)
            }
        }
        Thread.detachNewThread { waitpid(pid, nil, 0) }
        return .failed("Le modèle ne répond toujours pas après \(Int(timeout / 60)) minutes. Il continue de charger : surveillez « En cours ».",
                       logTail: tail(of: log.path))
    }

    /// Asks oMLX to load one of its models. The call returns once loading is done, or with oMLX's refusal (507 when it does not fit).
    public static func loadInOMLX(_ id: String, baseURL: String) async -> StartResult {
        let begin = Date()
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
        guard let url = URL(string: "\(baseURL)/v1/models/\(escaped)/load") else { return .failed("adresse invalide", logTail: nil) }
        var request = URLRequest(url: url, timeoutInterval: 1800)
        request.httpMethod = "POST"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return .loadedInOMLX(id, seconds: Int(Date().timeIntervalSince(begin))) }
            let detail = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["detail"] as? String
            return .failed(code == 401 || code == 403 ? "oMLX demande une clé : chargez ce modèle depuis l'app oMLX." : (detail ?? "réponse \(code) d'oMLX"),
                           logTail: nil)
        } catch {
            return .failed(error.localizedDescription, logTail: nil)
        }
    }

    static func spawn(_ executable: String, _ arguments: [String], log: String) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        posix_spawn_file_actions_addchdir(&actions, FileManager.default.homeDirectoryForCurrentUser.path)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Default signal handling and an empty mask: a spawn from a Swift concurrency thread would otherwise pass on
        // that thread's blocked signals, and the server would ignore the stop request (seen with MTPLX on 8 October).
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // A plain environment, not the one of the app or of an agent session.
        let environment = ["HOME=\(home)", "USER=\(NSUserName())", "LANG=fr_FR.UTF-8",
                           "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                           "TMPDIR=\(NSTemporaryDirectory())"]
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard status == 0 else { throw SpawnError(code: status) }
        return pid
    }

    struct SpawnError: Error, CustomStringConvertible {
        var code: Int32
        var description: String { String(cString: strerror(code)) }
    }

    public static func tail(of path: String, lines: Int = 20) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let text = String(decoding: data.suffix(16_384), as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}
