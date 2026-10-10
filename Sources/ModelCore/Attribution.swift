import Foundation

/// One link in "who started this": an app, an agent session, a project or a tool.
public struct LaunchStep: Codable, Hashable, Sendable {
    public var title: String
    public var detail: String?

    public init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }
}

public enum LaunchCertainty: String, Codable, Sendable {
    /// Read from the live chain of parent processes.
    case certain
    /// Rebuilt from the environment the process inherited, because its launcher is gone.
    case probable
    case unknown
}

public struct LaunchAttribution: Codable, Hashable, Sendable {
    /// Outermost first: app, agent session, project, tool.
    public var steps: [LaunchStep] = []
    public var certainty: LaunchCertainty = .unknown
    /// The launcher has exited and the process was not started by launchd: it lives on by itself.
    public var isOrphan = false
    public var launchdLabel: String?
    /// Working directory at launch (`PWD`), usually the project.
    public var projectPath: String?
    public var claudeSessionID: String?
    public var claudeSessionTitle: String?

    public var summary: String {
        steps.isEmpty ? "Lanceur inconnu" : steps.map { step in step.detail.map { "\(step.title) « \($0) »" } ?? step.title }.joined(separator: " › ")
    }
}

/// Works out who started a process: its live parents first, then what its environment says once they are gone.
public struct LaunchAttributor {
    var processes: [Int32: RunningProcess]
    var appNames: AppNames
    var launched: [LaunchedServer]
    var sessionTitle: (String) -> (title: String?, transcript: String?)

    public init(processes: [RunningProcess], launched: [LaunchedServer] = LaunchRegistry.shared.servers(),
                sessionTitle: @escaping (String) -> (title: String?, transcript: String?) = ClaudeSessions.shared.lookup) {
        self.processes = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        self.appNames = AppNames(processes: processes)
        self.launched = launched
        self.sessionTitle = sessionTitle
    }

    public static let appStep = LaunchStep("LLMarium")

    static let agents = ["claude": "Claude Code", "codex": "Codex", "pi": "Pi", "opencode": "OpenCode", "opencode2": "OpenCode",
                         "dsh": "DeepSeek Harness", "hermes": "Hermes", "mtplx": "MTPLX", "omlx": "oMLX"]
    static let tools: Set<String> = ["tauri", "cargo", "npm", "pnpm", "bun", "yarn", "uv", "uvx", "make", "just", "swift", "xcodebuild", "docker"]
    static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "login", "sudo", "env", "nohup", "timeout", "launchd"]

    public func attribute(_ process: RunningProcess) -> LaunchAttribution {
        var attribution = LaunchAttribution()
        attribution.projectPath = process.environment["PWD"]
        if let session = process.environment["CLAUDE_CODE_SESSION_ID"] {
            attribution.claudeSessionID = session
            attribution.claudeSessionTitle = sessionTitle(session).title
        }

        // Servers this app started stay its own, even after the app restarted and they were reparented to launchd.
        if launched.contains(where: { entry in
            entry.pid == process.pid && process.startedAt.map { abs(entry.startedAt.timeIntervalSince($0)) < 1 } ?? true
        }) {
            attribution.projectPath = nil
            attribution.steps = [Self.appStep]
            attribution.certainty = .certain
            return attribution
        }

        var ancestors: [RunningProcess] = []
        var parent = process.parentPID
        while parent > 1, let next = processes[parent], ancestors.count < 32 {
            ancestors.append(next)
            parent = next.parentPID
        }
        let live = ancestors.compactMap(step(for:))
        if !live.isEmpty {
            attribution.steps = naming(collapse(live.reversed()), sessionTitle: attribution.claudeSessionTitle)
            attribution.certainty = .certain
            return attribution
        }

        if let label = process.environment["XPC_SERVICE_NAME"], !label.isEmpty, label != "0", process.parentPID == 1 {
            attribution.launchdLabel = label
            attribution.steps = [LaunchStep("launchd", detail: label)]
            attribution.certainty = .certain
            return attribution
        }
        if let responsible = process.responsiblePID, responsible != process.pid, let owner = processes[responsible],
           let step = step(for: owner) {
            attribution.steps = [step]
            attribution.certainty = .certain
            return attribution
        }

        attribution.isOrphan = process.parentPID <= 1 && process.appName == nil
        attribution.steps = naming(collapse(environmentSteps(process)), sessionTitle: attribution.claudeSessionTitle)
        attribution.certainty = attribution.steps.isEmpty ? .unknown : .probable
        return attribution
    }

    /// Host app, agent session and last tool, as the environment recorded them at launch.
    func environmentSteps(_ process: RunningProcess) -> [LaunchStep] {
        let environment = process.environment
        var steps: [LaunchStep] = []
        if let bundle = environment["__CFBundleIdentifier"] { steps.append(LaunchStep(appNames.name(for: bundle))) }
        else if let terminal = environment["TERM_PROGRAM"] { steps.append(LaunchStep(Self.terminalName(terminal))) }
        if environment["CLAUDECODE"] == "1" || environment["CLAUDE_CODE_SESSION_ID"] != nil {
            steps.append(LaunchStep("Claude Code"))
        }
        // `_` is the last command the launching shell ran: a hint, kept only when it names a known tool.
        if let last = environment["_"].map({ ($0 as NSString).lastPathComponent }), Self.tools.contains(last) {
            steps.append(LaunchStep(last))
        }
        return steps
    }

    func step(for process: RunningProcess) -> LaunchStep? {
        // Exact executable name first: the Claude app bundles Claude Code as `…/claude.app/…/claude`,
        // while the app itself runs as `Claude`.
        if let agent = Self.agents[process.name] { return LaunchStep(agent) }
        // Node agents often retitle themselves: `node` for macOS, `pi` in argv[0].
        if let first = process.arguments.first.map({ ($0 as NSString).lastPathComponent }), let agent = Self.agents[first] {
            return LaunchStep(agent)
        }
        if let app = process.appName { return LaunchStep(app) }
        let name = process.name.lowercased()
        if Self.shells.contains(name) { return nil }
        if name == "node" || name.hasPrefix("python") || name == "bun" {
            // Agents shipped as scripts: `node …/bin/opencode`, `python -m mtplx …`.
            for argument in process.arguments.dropFirst().prefix(3) {
                let base = (argument as NSString).lastPathComponent.lowercased()
                if let agent = Self.agents[base] { return LaunchStep(agent) }
                if Self.tools.contains(base) { return LaunchStep(base) }
            }
            return nil
        }
        if Self.tools.contains(name) { return LaunchStep(name) }
        return LaunchStep(process.name)
    }

    /// Names the Claude Code session in its step.
    func naming(_ steps: [LaunchStep], sessionTitle: String?) -> [LaunchStep] {
        guard let sessionTitle else { return steps }
        return steps.map { $0.title == "Claude Code" ? LaunchStep($0.title, detail: sessionTitle) : $0 }
    }

    /// Drops consecutive duplicates (an app and its helper, two shells of one terminal).
    func collapse<S: Sequence>(_ steps: S) -> [LaunchStep] where S.Element == LaunchStep {
        steps.reduce(into: []) { result, step in
            if result.last?.title != step.title { result.append(step) }
        }
    }

    static func terminalName(_ value: String) -> String {
        switch value {
        case "ghostty": "Ghostty"
        case "Apple_Terminal": "Terminal"
        case "iTerm.app": "iTerm"
        case "vscode": "VS Code"
        case "WezTerm": "WezTerm"
        default: value
        }
    }
}

/// Bundle identifiers to app names: known ones, then the bundles of running apps.
struct AppNames {
    static let known = [
        "com.anthropic.claudefordesktop": "Claude",
        "com.mitchellh.ghostty": "Ghostty",
        "com.apple.Terminal": "Terminal",
        "com.googlecode.iterm2": "iTerm",
        "com.openai.codex": "Codex",
        "com.openai.chat": "ChatGPT",
        "com.microsoft.VSCode": "VS Code",
        "dev.zed.Zed": "Zed",
        "com.6gardens.watslog": "Watslog",
        "com.deepseek.dsh": "DeepSeek Harness"
    ]

    var byBundleID: [String: String] = known

    init(processes: [RunningProcess]) {
        var seen = Set<String>()
        for process in processes {
            guard let range = process.executablePath.range(of: ".app/") else { continue }
            let bundle = String(process.executablePath[..<range.lowerBound]) + ".app"
            guard seen.insert(bundle).inserted,
                  let info = NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist"),
                  let identifier = info["CFBundleIdentifier"] as? String, byBundleID[identifier] == nil else { continue }
            byBundleID[identifier] = info["CFBundleName"] as? String ?? (bundle as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        }
    }

    func name(for identifier: String) -> String { byBundleID[identifier] ?? identifier }
}

/// Titles of Claude Code sessions, read from their transcripts (`~/.claude/projects/*/<id>.jsonl`), cached by modification date.
public final class ClaudeSessions: @unchecked Sendable {
    public static let shared = ClaudeSessions()

    private let lock = NSLock()
    private var paths: [String: String] = [:]
    private var titles: [String: (modified: Date, title: String?)] = [:]
    private let projects: URL

    public init(projects: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")) {
        self.projects = projects
    }

    public func lookup(_ sessionID: String) -> (title: String?, transcript: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard let path = paths[sessionID] ?? find(sessionID) else { return (nil, nil) }
        paths[sessionID] = path
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
        if let cached = titles[path], cached.modified == modified { return (cached.title, path) }
        let title = Self.lastTitle(in: path)
        titles[path] = (modified, title)
        return (title, path)
    }

    private func find(_ sessionID: String) -> String? {
        guard sessionID.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []
        return folders.lazy.map { "\(self.projects.path)/\($0)/\(sessionID).jsonl" }.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// The last title the session was given: a custom title, or a summary for older transcripts.
    static func lastTitle(in path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n").reversed() where line.contains("\"custom-title\"") || line.contains("\"type\":\"summary\"") {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            if let title = object["customTitle"] as? String ?? object["summary"] as? String, !title.isEmpty { return title }
        }
        return nil
    }
}
