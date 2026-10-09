import Darwin
import Foundation

public struct RunningProcess: Codable, Hashable, Sendable {
    public var pid: Int32
    public var name: String
    public var executablePath: String
    /// Empty for processes of other users: macOS only gives arguments of one's own processes.
    public var arguments: [String]
    public var footprintBytes: Int64
    /// 1 when the launcher is gone or the process was started by launchd.
    public var parentPID: Int32
    public var startedAt: Date?
    /// The process macOS holds responsible for this one (an app for its helpers); itself when started detached.
    public var responsiblePID: Int32?
    /// Only the keys in `EnvironmentKeys.kept`: the environment also holds tokens and account details.
    public var environment: [String: String]

    public init(pid: Int32, name: String, executablePath: String, arguments: [String], footprintBytes: Int64,
                parentPID: Int32 = 0, startedAt: Date? = nil, responsiblePID: Int32? = nil, environment: [String: String] = [:]) {
        self.pid = pid
        self.name = name
        self.executablePath = executablePath
        self.arguments = arguments
        self.footprintBytes = footprintBytes
        self.parentPID = parentPID
        self.startedAt = startedAt
        self.responsiblePID = responsiblePID
        self.environment = environment
    }

    /// Outermost `.app` bundle in the executable path, so helpers count with their app.
    public var appName: String? {
        executablePath.split(separator: "/").first { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
    }

    public var role: ProcessRole {
        let path = executablePath
        let first = arguments.first ?? ""
        if path.contains("/oMLX.app/") || first == "omlx-server" || arguments.contains(where: { $0.hasPrefix("omlx.server") }) {
            return .omlx
        }
        if path.contains("/MTPLX.app/") || arguments.contains(where: { $0.hasPrefix("mtplx.server") })
            || (first.hasSuffix("/mtplx") && arguments.contains { ["serve", "quickstart", "start"].contains($0) }) {
            return .mtplx
        }
        if path.contains("/MLX-Serve.app/") { return .mlxServe }
        let joined = arguments.joined(separator: " ").lowercased()
        let modelHints = [".cache/huggingface", "/models--", ".omlx/models", ".mlx-serve/models", ".mtplx/models", "mlx_lm", "mlx_vlm", ".gguf"]
        if modelHints.contains(where: joined.contains) { return .modelWorker }
        // Homebrew's framework Python runs as `Python`.
        if name.lowercased().hasPrefix("python") && footprintBytes >= 1 << 30 { return .modelWorker }
        return .application
    }

    /// For a model worker: the project its virtual environment belongs to, the script and the model it loads.
    public var workerDescription: String {
        var parts: [String] = []
        let components = executablePath.split(separator: "/").map(String.init)
        if let venv = components.firstIndex(where: { ["venv", ".venv"].contains($0) || $0.hasPrefix("venv-") }), venv > 0 {
            parts.append(components[venv - 1])
        }
        if let script = arguments.dropFirst().first(where: { $0.hasSuffix(".py") }) {
            parts.append((script as NSString).lastPathComponent)
        }
        if let cached = arguments.lazy.compactMap(Self.cachedModelName).first { parts.append(cached) }
        return parts.isEmpty ? name : parts.joined(separator: " · ")
    }

    /// `owner/name` from a Hugging Face cache path (`…/models--owner--name/…`).
    static func cachedModelName(_ argument: String) -> String? {
        guard let range = argument.range(of: "models--") else { return nil }
        let folder = argument[range.upperBound...].prefix { $0 != "/" }
        return folder.replacingOccurrences(of: "--", with: "/")
    }
}

public enum ProcessRole: String, Codable, Sendable {
    case omlx, mtplx, mlxServe, modelWorker, application

    public var title: String {
        switch self {
        case .omlx: "oMLX"
        case .mtplx: "MTPLX"
        case .mlxServe: "mlx-serve"
        case .modelWorker: "Modèle hors moteur"
        case .application: "Application"
        }
    }

    public var engine: EngineKind? {
        switch self {
        case .omlx: .omlx
        case .mtplx: .mtplx
        case .mlxServe: .mlxServe
        case .modelWorker, .application: nil
        }
    }
}

/// Processes counted together, as the user sees them: one app with its helpers, one engine, one model worker.
public struct ProcessGroup: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var role: ProcessRole
    public var detail: String?
    public var pids: [Int32]
    public var footprintBytes: Int64

    public static func group(_ processes: [RunningProcess]) -> [ProcessGroup] {
        var groups: [String: ProcessGroup] = [:]
        for process in processes {
            let role = process.role
            let key: String
            let title: String
            var detail: String?
            switch role {
            case .omlx, .mtplx, .mlxServe:
                key = role.rawValue
                title = role.title
            case .modelWorker:
                key = "worker-\(process.pid)"
                title = process.workerDescription
                detail = "PID \(process.pid)"
            case .application:
                let app = process.appName ?? process.name
                key = "app-\(app)"
                title = app
            }
            var group = groups[key] ?? ProcessGroup(id: key, title: title, role: role, detail: detail, pids: [], footprintBytes: 0)
            group.pids.append(process.pid)
            group.footprintBytes += process.footprintBytes
            groups[key] = group
        }
        return groups.values.sorted { $0.footprintBytes > $1.footprintBytes }
    }
}

public enum ProcessScanner {
    public static func all() -> [RunningProcess] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        var reader = ArgumentReader()
        return pids.prefix(Int(filled)).compactMap { pid in
            guard pid > 0, let footprint = footprint(of: pid) else { return nil }
            let launch = reader.read(pid)
            let info = bsdInfo(of: pid)
            return RunningProcess(pid: pid, name: name(of: pid), executablePath: path(of: pid),
                                  arguments: launch.arguments, footprintBytes: footprint,
                                  parentPID: info?.parentPID ?? 0, startedAt: info?.startedAt,
                                  responsiblePID: responsible(for: pid), environment: launch.environment)
        }
    }

    static func bsdInfo(of pid: pid_t) -> (parentPID: Int32, startedAt: Date)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let start = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
        return (Int32(info.pbi_ppid), Date(timeIntervalSince1970: start))
    }

    /// Private libsystem function also used by Activity Monitor; looked up at run time and optional.
    private static let responsibleFunction: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    static func responsible(for pid: pid_t) -> Int32? {
        guard let function = responsibleFunction else { return nil }
        let value = function(pid)
        return value > 0 ? value : nil
    }

    static func footprint(of pid: pid_t) -> Int64? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? Int64(info.ri_phys_footprint) : nil
    }

    static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        return String(cString: buffer)
    }

    static func path(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
    }
}

/// Environment variables worth keeping to explain who started a process. Everything else is dropped when read:
/// the environment of an agent session carries tokens, account identifiers and e-mail addresses.
public enum EnvironmentKeys {
    public static let kept: Set<String> = [
        "__CFBundleIdentifier", "XPC_SERVICE_NAME", "TERM_PROGRAM", "PWD", "_",
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID"
    ]
}

struct LaunchStrings: Equatable {
    var arguments: [String]
    var environment: [String: String]
}

/// Reads `KERN_PROCARGS2` into one reused buffer: argc, executable path, padding, argv, then the environment
/// (followed by a few `key=value` strings of Apple's own, which the key list filters out too).
struct ArgumentReader {
    private var buffer: [UInt8]

    init() {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var maximum: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctl(&mib, 2, &maximum, &size, nil, 0)
        buffer = [UInt8](repeating: 0, count: max(Int(maximum), 4096))
    }

    mutating func read(_ pid: pid_t) -> LaunchStrings {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return LaunchStrings(arguments: [], environment: [:]) }
        return Self.parse(buffer[..<size])
    }

    static func parse(_ bytes: ArraySlice<UInt8>) -> LaunchStrings {
        let data = Array(bytes)
        guard data.count > 4 else { return LaunchStrings(arguments: [], environment: [:]) }
        let argc = Int(data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = 4
        while index < data.count && data[index] != 0 { index += 1 }
        while index < data.count && data[index] == 0 { index += 1 }
        var arguments: [String] = []
        var environment: [String: String] = [:]
        while index < data.count {
            let start = index
            while index < data.count && data[index] != 0 { index += 1 }
            let text = String(decoding: data[start..<index], as: UTF8.self)
            index += 1
            if arguments.count < argc {
                arguments.append(text)
            } else if let equal = text.firstIndex(of: "=") {
                let key = String(text[..<equal])
                if EnvironmentKeys.kept.contains(key) { environment[key] = String(text[text.index(after: equal)...]) }
            }
        }
        return LaunchStrings(arguments: arguments, environment: environment)
    }
}
