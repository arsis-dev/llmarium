import Foundation

public enum HarnessKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case claudeCode, codex, pi, opencode, deepseekHarness

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .pi: "Pi"
        case .opencode: "OpenCode"
        case .deepseekHarness: "DeepSeek Harness"
        }
    }

    /// Command looked up in the user's login shell; DeepSeek Harness is a desktop app.
    public var command: String? {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .pi: "pi"
        case .opencode: "opencode"
        case .deepseekHarness: nil
        }
    }

    /// Claude Code needs room for its own system prompt and tools.
    public var minimumContext: Int? { self == .claudeCode ? 48 * 1024 : nil }

    /// Where its settings for this app live, in French, for the confirmation shown before opening.
    public var configurationSummary: String {
        switch self {
        case .claudeCode: "Variables d'environnement de la fenêtre seulement ; aucun fichier modifié."
        case .codex: "Dossier Codex propre à l'app (CODEX_HOME) : vos réglages, skills et MCP habituels ne sont pas chargés, ce qui allège fortement le prompt."
        case .pi: "Une entrée « local-launcher » dans ~/.pi/agent/models.json (sauvegarde avant écriture) ; les autres fournisseurs restent intacts."
        case .opencode: "Configuration passée à la fenêtre (OPENCODE_CONFIG_CONTENT, serveur privé) ; opencode.json n'est pas modifié."
        case .deepseekHarness: "Un fournisseur « local-launcher » dans la couche de patch du profil desktop (sauvegarde avant écriture) ; le reste du fichier est conservé."
        }
    }
}

/// The running model a harness connects to: an engine endpoint and the identifier it serves.
public struct HarnessTarget: Codable, Hashable, Sendable {
    public var engine: EngineKind
    public var baseURL: String
    public var modelID: String
    public var contextWindow: Int?
    public var modelType: String?

    public init(engine: EngineKind, baseURL: String, modelID: String, contextWindow: Int?, modelType: String?) {
        self.engine = engine
        self.baseURL = baseURL
        self.modelID = modelID
        self.contextWindow = contextWindow
        self.modelType = modelType
    }

    public var openAIBaseURL: String { baseURL + "/v1" }

    /// Targets for the models an engine holds now. oMLX may hold several; MTPLX and mlx-serve hold one.
    /// With the proxy running, harnesses go through it: their settings then survive a model moving to another port.
    public static func targets(in snapshot: InventorySnapshot, via proxy: String? = nil) -> [HarnessTarget] {
        snapshot.running.flatMap { targets(for: $0, in: snapshot, via: proxy) }
    }

    public static func targets(for running: RunningModel, in snapshot: InventorySnapshot, via proxy: String? = nil) -> [HarnessTarget] {
        guard let engine = running.role.engine, let engineURL = running.baseURL else { return [] }
        let url = proxy ?? engineURL
        return running.models.map { id in
                let omlxState = engine == .omlx ? snapshot.engine(.omlx)?.omlx?.models.first { $0.id == id } : nil
                let local = snapshot.models.first { model in
                    engine == .omlx ? OMLXIdentity.matches(id, model) : LaunchPlan.servedName(model) == id && model.store == engine.store
                }
                let launched = LaunchRegistry.shared.servers().first { $0.pid == running.pid }
                return HarnessTarget(engine: engine, baseURL: url, modelID: id,
                                     contextWindow: omlxState?.maxContext ?? launched?.context ?? local?.spec?.maxContext,
                                     modelType: local?.spec?.modelType)
        }
    }
}

/// What to run, with which environment, where; plus the files written for it.
public struct HarnessLaunch: Equatable, Sendable {
    public var kind: HarnessKind
    public var arguments: [String]
    public var environment: [String: String]
    public var directory: String
    public var appToOpen: String?
    public var writtenFiles: [String]
}

public enum HarnessError: Error, CustomStringConvertible, Equatable {
    case notInstalled(HarnessKind)
    case contextTooSmall(HarnessKind, Int)
    case unexpectedFormat(String)
    case noHeadlessMode(HarnessKind)

    public var description: String {
        switch self {
        case .notInstalled(let kind): "\(kind.title) n'est pas installé."
        case .contextTooSmall(let kind, let context):
            "\(kind.title) demande au moins \(Format.tokens(kind.minimumContext ?? 0)) de contexte ; ce modèle est servi avec \(Format.tokens(context))."
        case .unexpectedFormat(let file): "Format inattendu dans \(file) : rien n'a été modifié."
        case .noHeadlessMode(let kind): "\(kind.title) n'a pas de mode sans interface."
        }
    }
}

public enum HarnessPlanner {
    public static let providerID = "local-launcher"
    static let apiKeyVariable = "LOCAL_LAUNCHER_API_KEY"
    static let placeholderKey = "local"

    /// Why a harness cannot be used with this target, or nil.
    public static func unavailableReason(_ kind: HarnessKind, target: HarnessTarget, installed: Set<HarnessKind>) -> String? {
        if !installed.contains(kind) { return HarnessError.notInstalled(kind).description }
        if let minimum = kind.minimumContext, let context = target.contextWindow, context < minimum {
            return HarnessError.contextTooSmall(kind, context).description
        }
        return nil
    }

    /// Builds the launch and writes the configuration it needs. `paths` lets tests point the writes at fixtures.
    public static func prepare(_ kind: HarnessKind, target: HarnessTarget, directory: String,
                               paths: HarnessPaths = .standard) throws -> HarnessLaunch {
        if let minimum = kind.minimumContext, let context = target.contextWindow, context < minimum {
            throw HarnessError.contextTooSmall(kind, context)
        }
        var launch = HarnessLaunch(kind: kind, arguments: [], environment: [apiKeyVariable: placeholderKey],
                                   directory: directory, appToOpen: nil, writtenFiles: [])
        switch kind {
        case .claudeCode:
            launch.environment.merge(claudeEnvironment(target)) { _, new in new }
            // Local prefill can outlast the plan-mode classifier; the LSP tool re-prefills the whole prompt when it attaches.
            launch.arguments = ["claude", "--settings", #"{"useAutoModeDuringPlan":false}"#, "--disallowedTools", "LSP"]
        case .codex:
            try FileManager.default.createDirectory(at: paths.codexHome, withIntermediateDirectories: true)
            let config = paths.codexHome.appending(path: "config.toml")
            try Data(codexConfig(target).utf8).write(to: config, options: .atomic)
            launch.environment["CODEX_HOME"] = paths.codexHome.path
            launch.arguments = ["codex"]
            launch.writtenFiles = [config.path]
        case .pi:
            let existing = try? Data(contentsOf: paths.piModels)
            try write(piModels(existing: existing, target: target), to: paths.piModels, backup: existing != nil)
            launch.arguments = ["pi", "--model", "\(providerID)/\(target.modelID)"]
            launch.writtenFiles = [paths.piModels.path]
        case .opencode:
            launch.environment["OPENCODE_CONFIG_CONTENT"] = openCodeConfig(target)
            // The background service would not see this window's configuration: use a private server.
            launch.arguments = ["opencode", "--standalone"]
        case .deepseekHarness:
            let existing = try? String(contentsOf: paths.dshPatch, encoding: .utf8)
            let updated = try dshPatch(existing: existing, target: target)
            try write(Data(updated.utf8), to: paths.dshPatch, backup: existing != nil)
            launch.appToOpen = paths.dshApp
            launch.writtenFiles = [paths.dshPatch.path]
        }
        return launch
    }

    /// The same harness run once without interface, for scripts and for checking a pairing.
    public static func headless(_ launch: HarnessLaunch, prompt: String, target: HarnessTarget) throws -> [String] {
        switch launch.kind {
        case .claudeCode: return launch.arguments + ["-p", prompt]
        case .codex: return ["codex", "exec", "--skip-git-repo-check", "--sandbox", "read-only", prompt]
        case .pi: return launch.arguments + ["-p", "--no-session", prompt]
        case .opencode: return ["opencode", "run", "--standalone", "-m", "\(providerID)/\(target.modelID)", prompt]
        case .deepseekHarness: throw HarnessError.noHeadlessMode(.deepseekHarness)
        }
    }

    // MARK: - Configurations

    static func claudeEnvironment(_ target: HarnessTarget) -> [String: String] {
        var environment = [
            "ANTHROPIC_BASE_URL": target.baseURL,
            "ANTHROPIC_AUTH_TOKEN": placeholderKey,
            // An empty key overrides a real one exported by the user's shell.
            "ANTHROPIC_API_KEY": "",
            "ANTHROPIC_MODEL": target.modelID,
            "ANTHROPIC_DEFAULT_OPUS_MODEL": target.modelID,
            "ANTHROPIC_DEFAULT_SONNET_MODEL": target.modelID,
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": target.modelID,
            "CLAUDE_CODE_SUBAGENT_MODEL": target.modelID,
            "API_TIMEOUT_MS": "3000000",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "CLAUDE_CODE_ATTRIBUTION_HEADER": "0"
        ]
        if let context = target.contextWindow {
            environment["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] = String(context)
            environment["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = String(context)
        }
        return environment
    }

    /// Codex's whole configuration in the app's own CODEX_HOME. Hosted web search is off: local engines refuse it.
    static func codexConfig(_ target: HarnessTarget) -> String {
        var lines = [
            "# Écrit par Modèles locaux à chaque ouverture : ne pas modifier.",
            "model = \(tomlString(target.modelID))",
            "model_provider = \"\(providerID)\"",
            "web_search = \"disabled\""
        ]
        if let context = target.contextWindow { lines.append("model_context_window = \(context)") }
        lines += ["", "[model_providers.\(providerID)]", "name = \"Modèles locaux\"",
                  "base_url = \(tomlString(target.openAIBaseURL))", "env_key = \"\(apiKeyVariable)\"", "wire_api = \"responses\"", ""]
        return lines.joined(separator: "\n")
    }

    static func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func openCodeConfig(_ target: HarnessTarget) -> String {
        var model: [String: Any] = ["name": target.modelID, "tool_call": true]
        if let context = target.contextWindow { model["limit"] = ["context": context, "output": min(context / 4, 32_768)] }
        let config: [String: Any] = [
            "provider": [providerID: [
                "npm": "@ai-sdk/openai-compatible",
                "name": "Modèles locaux",
                "options": ["baseURL": target.openAIBaseURL, "apiKey": placeholderKey, "timeout": false],
                "models": [target.modelID: model]
            ]],
            "model": "\(providerID)/\(target.modelID)"
        ]
        let data = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func piModels(existing: Data?, target: HarnessTarget) throws -> Data {
        try piModels(existing: existing, baseURL: target.baseURL, models: [HarnessModel(target)])
    }

    /// Pi's providers with ours replaced or added. Other providers and top-level keys are kept as they are.
    static func piModels(existing: Data?, baseURL: String, models: [HarnessModel]) throws -> Data {
        var root: [String: Any] = [:]
        if let existing, !existing.isEmpty {
            guard let parsed = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any] else {
                throw HarnessError.unexpectedFormat("models.json")
            }
            root = parsed
        }
        var providers = root["providers"] as? [String: Any] ?? [:]
        var compat: [String: Any] = ["supportsDeveloperRole": false, "supportsReasoningEffort": false,
                                     "maxTokensField": "max_tokens", "requiresToolResultName": true]
        // One compat block per provider: the Qwen thinking format only when every model is a Qwen.
        if !models.isEmpty, models.allSatisfy({ $0.modelType?.hasPrefix("qwen") == true }) { compat["thinkingFormat"] = "qwen" }
        let entries = models.map { item -> [String: Any] in
            var model: [String: Any] = ["id": item.id, "name": item.name, "input": ["text"],
                                        "reasoning": true, "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0]]
            if let context = item.contextWindow {
                model["contextWindow"] = context
                model["maxTokens"] = min(context / 4, 32_768)
            }
            return model
        }
        providers[providerID] = ["api": "openai-completions", "baseUrl": baseURL + "/v1", "apiKey": placeholderKey,
                                 "compat": compat, "models": entries]
        root["providers"] = providers
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static let dshMarker = "# Fournisseur géré par Modèles locaux : réécrit à chaque ouverture."

    static func dshPatch(existing: String?, target: HarnessTarget) throws -> String {
        try dshPatch(existing: existing, baseURL: target.baseURL, models: [HarnessModel(target)])
    }

    /// Our provider inside the `llm-pi-ai` entry of a hand-edited YAML patch layer, changing no other line.
    static func dshPatch(existing: String?, baseURL: String, models: [HarnessModel]) throws -> String {
        func block(indent: Int) -> [String] {
            let pad = String(repeating: " ", count: indent)
            var lines = ["\(pad)\(dshMarker)", "\(pad)\(providerID):", "\(pad)  displayName: Modèles locaux",
                         "\(pad)  api: openai-completions", "\(pad)  baseURL: \(yamlString(baseURL + "/v1"))",
                         "\(pad)  apiKeyEnv: \(apiKeyVariable)", "\(pad)  models:"]
            for model in models {
                lines += ["\(pad)    - id: \(yamlString(model.id))", "\(pad)      name: \(yamlString(model.name))"]
                if let context = model.contextWindow { lines.append("\(pad)      contextWindow: \(context)") }
                lines += ["\(pad)      input:", "\(pad)        - text"]
            }
            return lines
        }
        let header = ["# Your patch layer for this dsh profile, applied after every bundle layer.", ""]
        let entry = ["- id: llm-pi-ai", "  name: \"@deepseek-ai/dsh-llm-pi-ai\"", "  config:", "    providers:"] + block(indent: 6)
        guard let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (header + entry).joined(separator: "\n") + "\n"
        }
        var lines = existing.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "- id: llm-pi-ai" && $0.hasPrefix("-") }) else {
            return (lines + [""] + entry).joined(separator: "\n") + "\n"
        }
        // The entry runs until the next line written at column 0 (next entry or its comment).
        let end = lines[(start + 1)...].firstIndex { !$0.isEmpty && !$0.hasPrefix(" ") } ?? lines.count
        guard let providers = lines[start..<end].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "providers:" }) else {
            throw HarnessError.unexpectedFormat("cordis.patch.yml (pas de « providers » dans llm-pi-ai)")
        }
        let providersIndent = indentation(lines[providers])
        let keyIndent = providersIndent + 2
        let providersEnd = lines[(providers + 1)..<end].firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty && indentation($0) <= providersIndent } ?? end
        // Remove our previous block: its marker, its key and every deeper line under the key.
        if let key = lines[(providers + 1)..<providersEnd].firstIndex(where: { $0 == String(repeating: " ", count: keyIndent) + "\(providerID):" }) {
            var from = key
            if from > providers + 1, lines[from - 1].trimmingCharacters(in: .whitespaces) == dshMarker { from -= 1 }
            let to = lines[(key + 1)..<providersEnd].firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty && indentation($0) <= keyIndent } ?? providersEnd
            lines.removeSubrange(from..<to)
        }
        lines.insert(contentsOf: block(indent: keyIndent), at: providers + 1)
        return lines.joined(separator: "\n") + "\n"
    }

    static func indentation(_ line: String) -> Int { line.prefix { $0 == " " }.count }

    static func yamlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Atomic write, with a dated copy of the previous file next to it.
    static func write(_ data: Data, to url: URL, backup: Bool) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if backup {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let copy = url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent).bak-local-launcher-\(stamp)")
            try? FileManager.default.copyItem(at: url, to: copy)
        }
        try data.write(to: url, options: .atomic)
    }
}

/// One model as a harness lists it.
public struct HarnessModel: Hashable, Sendable {
    public var id: String
    public var contextWindow: Int?
    public var modelType: String?
    /// Where it runs, for the label (« oMLX », « deepseek »…).
    public var origin: String

    public init(id: String, contextWindow: Int?, modelType: String?, origin: String) {
        self.id = id
        self.contextWindow = contextWindow
        self.modelType = modelType
        self.origin = origin
    }

    init(_ target: HarnessTarget) {
        self.init(id: target.modelID, contextWindow: target.contextWindow, modelType: target.modelType, origin: "local")
    }

    var name: String { origin == "local" ? "\(id) (local)" : "\(id) (\(origin))" }
}

/// « Synchroniser » : every model the proxy can reach, written once into Pi and DeepSeek Harness with the proxy's
/// stable address. Choosing a model then happens in the harness itself.
public enum HarnessSync {
    public static func catalog(snapshot: InventorySnapshot, table: RouteTable) -> [HarnessModel] {
        var models: [HarnessModel] = []
        var seen = Set<String>()
        func add(_ model: HarnessModel) { if seen.insert(model.id).inserted { models.append(model) } }
        // Harnesses chat: embedding and other non-language models stay out of their pickers.
        func isLanguageModel(_ id: String) -> Bool {
            snapshot.models.first { OMLXIdentity.matches(id, $0) || LaunchPlan.servedName($0) == id }.map { $0.kind != .other } ?? true
        }
        let targets = HarnessTarget.targets(in: snapshot).filter { isLanguageModel($0.modelID) }
        for target in targets {
            add(HarnessModel(id: target.modelID, contextWindow: target.contextWindow, modelType: target.modelType, origin: target.engine.title))
        }
        for alias in table.aliases.values.sorted(by: { $0.alias < $1.alias }) {
            guard case .upstream(let upstream) = table.resolve(model: alias.alias, path: "/v1/chat/completions") else { continue }
            if let provider = upstream.providerID, !ProviderKeys.hasKey(for: provider) { continue }
            if upstream.providerID == nil, !isLanguageModel(alias.model) { continue }
            let target = targets.first { $0.modelID == alias.model }
            add(HarnessModel(id: alias.alias, contextWindow: target?.contextWindow, modelType: target?.modelType, origin: upstream.label))
        }
        for provider in table.providers where ProviderKeys.hasKey(for: provider.id) {
            provider.models.forEach { add(HarnessModel(id: $0, contextWindow: nil, modelType: nil, origin: provider.id)) }
        }
        return models
    }

    /// Writes our provider into Pi and DeepSeek Harness (when installed), each with a dated backup.
    public static func sync(proxy: String, models: [HarnessModel], installed: Set<HarnessKind>, paths: HarnessPaths = .standard) throws -> [String] {
        var written: [String] = []
        if installed.contains(.pi) {
            let existing = try? Data(contentsOf: paths.piModels)
            try HarnessPlanner.write(HarnessPlanner.piModels(existing: existing, baseURL: proxy, models: models), to: paths.piModels, backup: existing != nil)
            written.append(paths.piModels.path)
        }
        if installed.contains(.deepseekHarness) {
            let existing = try? String(contentsOf: paths.dshPatch, encoding: .utf8)
            let updated = try HarnessPlanner.dshPatch(existing: existing, baseURL: proxy, models: models)
            try HarnessPlanner.write(Data(updated.utf8), to: paths.dshPatch, backup: existing != nil)
            written.append(paths.dshPatch.path)
        }
        return written
    }
}

public struct HarnessPaths: Sendable {
    public var codexHome: URL
    public var piModels: URL
    public var dshPatch: URL
    public var dshApp: String

    public static let standard: HarnessPaths = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        // DSH_HOME is DeepSeek Harness's own override of ~/.dsh.
        let dshHome = environment["DSH_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appending(path: ".dsh")
        return HarnessPaths(codexHome: AppPaths.support.appending(path: "codex-home"),
                            piModels: URL(fileURLWithPath: ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"] ?? home.appending(path: ".pi/agent").path)
                                .appending(path: "models.json"),
                            dshPatch: dshHome.appending(path: "profiles/desktop/cordis.patch.yml"),
                            dshApp: "/Applications/DeepSeek Harness.app")
    }()
}

public enum HarnessInstallations {
    /// Harnesses found in the user's login shell (where fnm and the like set PATH up), plus the DeepSeek Harness app.
    public static func detect() -> Set<HarnessKind> {
        var found = Set<HarnessKind>()
        let commands = HarnessKind.allCases.compactMap(\.command)
        let script = commands.map { "command -v \($0) >/dev/null 2>&1 && echo \($0)" }.joined(separator: "; ")
        let output = Command.run(userShell, ["-lic", script]) ?? ""
        let present = Set(output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) })
        for kind in HarnessKind.allCases where kind.command.map(present.contains) == true { found.insert(kind) }
        if FileManager.default.fileExists(atPath: HarnessPaths.standard.dshApp) { found.insert(.deepseekHarness) }
        return found
    }

    public static var userShell: String { ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh" }
}

/// A command to run in a terminal window, outside any harness.
public struct TerminalCommand: Equatable, Sendable {
    public var arguments: [String]
    public var directory: String

    public init(arguments: [String], directory: String) {
        self.arguments = arguments
        self.directory = directory
    }
}

public enum HarnessOpener {
    /// Opens a Ghostty window in the project folder, running the harness in the user's login shell
    /// (so PATH and version managers are set up as in their terminal), then leaves a shell open.
    public static func open(_ launch: HarnessLaunch) throws {
        if let app = launch.appToOpen {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [app]
            // A shell started inside a dsh session exports its profile: it would open the wrong one.
            process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DSH_") }
            try process.run()
            process.waitUntilExit()
            return
        }
        var source = "tell application \"Ghostty\"\n"
        source += "set cfg to new surface configuration\n"
        source += "set initial working directory of cfg to \(appleScriptString(launch.directory))\n"
        let environment = launch.environment.sorted { $0.key < $1.key }.map { appleScriptString("\($0.key)=\($0.value)") }
        source += "set environment variables of cfg to {\(environment.joined(separator: ", "))}\n"
        source += "set command of cfg to \(appleScriptString(windowCommand(launch.arguments, keep: Set(launch.environment.keys))))\n"
        source += "new window with configuration cfg\nactivate\nend tell"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            throw OpenError(message: (error[NSAppleScript.errorMessage] as? String) ?? "Ghostty n'a pas pu ouvrir la fenêtre.")
        }
    }

    /// A plain command in a Ghostty window (a download, `mtplx tune`): the user watches it and can interrupt it.
    public static func open(_ command: TerminalCommand) throws {
        try open(HarnessLaunch(kind: .claudeCode, arguments: command.arguments, environment: [:], directory: command.directory,
                               appToOpen: nil, writtenFiles: []))
    }

    public struct OpenError: Error, CustomStringConvertible {
        public var message: String
        public var description: String { message }
    }

    /// `zsh -lic '<clean>; <harness>; exec zsh -l'`: the window stays usable after the harness exits.
    /// Ghostty passes its own environment to every window; when Ghostty was started from an agent session, that
    /// includes its markers (`CLAUDE_CODE_CHILD_SESSION` turns transcripts off) and possibly an `ANTHROPIC_BASE_URL`
    /// that would send « Demander à Claude » elsewhere than the user's login. They are cleared, except ours.
    static func windowCommand(_ arguments: [String], keep: Set<String> = []) -> String {
        let shell = HarnessInstallations.userShell
        let kept = keep.sorted().joined(separator: " ")
        let clean = #"for v in $(env | sed -En 's/^(CLAUDECODE|CLAUDE_[A-Z0-9_]+|ANTHROPIC_[A-Z0-9_]+|CODEX_COMPANION_[A-Z0-9_]+|__CFBundleIdentifier)=.*/\1/p'); do case " "# + kept + #" " in *" $v "*) ;; *) unset "$v" ;; esac; done"#
        let inner = clean + "; " + arguments.map(shellQuote).joined(separator: " ") + "; exec \(shellQuote(shell)) -l"
        return "\(shellQuote(shell)) -lic \(shellQuote(inner))"
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Runs a harness once without interface in the login shell, with the launch's environment and folder.
    public static func runHeadless(_ arguments: [String], launch: HarnessLaunch) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: HarnessInstallations.userShell)
        process.arguments = ["-lic", arguments.map(shellQuote).joined(separator: " ")]
        process.environment = ProcessInfo.processInfo.environment.merging(launch.environment) { _, new in new }
            .filter { !$0.key.hasPrefix("CLAUDE_CODE_") || launch.environment[$0.key] != nil }
            .filter { $0.key != "CLAUDECODE" }
        process.currentDirectoryURL = URL(fileURLWithPath: launch.directory)
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return 127 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
