import Foundation

/// A subscription reached through its own command-line tool instead of an HTTP API: `claude -p` (claude.ai plan) or
/// `codex exec` (ChatGPT plan). The proxy runs the tool once per chat completion, isolated from the user's own
/// configuration (no tools, no MCP servers, no CLAUDE.md or AGENTS.md, no saved session), and answers in OpenAI shape.
public enum SubscriptionCLI: String, Codable, Hashable, Sendable, CaseIterable {
    case claude, codex

    public var executableName: String { rawValue }

    public var title: String {
        switch self {
        case .claude: "Claude (abonnement)"
        case .codex: "ChatGPT (abonnement Codex)"
        }
    }

    /// The providers `llmarium provider add-subscriptions` writes to `proxy.json`.
    public var provider: RemoteProvider {
        switch self {
        case .claude: RemoteProvider(id: "claude-cli", name: title, openAIBase: nil, anthropicBase: nil,
                                     models: ["sonnet", "opus", "haiku"], prefix: "claude-cli/", cli: .claude)
        case .codex: RemoteProvider(id: "codex-cli", name: title, openAIBase: nil, anthropicBase: nil,
                                    models: ["gpt-6.1-sol", "gpt-6-luna"], prefix: "codex-cli/", cli: .codex)
        }
    }
}

/// What a chat completion asks, reduced to what the command-line tools can take.
public struct SubscriptionRequest: Equatable, Sendable {
    public var system: String?
    public var prompt: String
    /// JSON Schema from `response_format.json_schema.schema`, serialized.
    public var schema: Data?
    public var stream: Bool
    /// OpenAI's `reasoning_effort`, passed to `--effort` / `model_reasoning_effort`.
    public var effort: String?

    public struct Invalid: Error, CustomStringConvertible {
        public var description: String
    }

    /// Text only: image parts and tools are refused rather than silently dropped. Unknown fields (`temperature`,
    /// `max_tokens`, `chat_template_kwargs`…) are ignored, since neither tool exposes them.
    public static func parse(_ body: Data) throws -> SubscriptionRequest {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let messages = object["messages"] as? [[String: Any]], !messages.isEmpty else {
            throw Invalid(description: "Corps attendu : un objet JSON avec un tableau « messages ».")
        }
        if let tools = object["tools"] as? [Any], !tools.isEmpty {
            throw Invalid(description: "Les outils (« tools ») ne passent pas par un abonnement : texte seulement.")
        }
        var system: [String] = []
        var turns: [(role: String, text: String)] = []
        for message in messages {
            let role = message["role"] as? String ?? "user"
            let text = try Self.text(of: message["content"])
            if role == "system" || role == "developer" { system.append(text) } else { turns.append((role, text)) }
        }
        guard !turns.isEmpty else { throw Invalid(description: "Aucun message « user » à transmettre.") }
        // A single question goes as is; a conversation is written out turn by turn, since `-p` takes one prompt.
        let prompt = turns.count == 1 && turns[0].role == "user" ? turns[0].text
            : turns.map { "\($0.role == "assistant" ? "Assistant" : "User"):\n\($0.text)" }.joined(separator: "\n\n")
        var schema: Data?
        if let format = object["response_format"] as? [String: Any], format["type"] as? String == "json_schema",
           let wrapper = format["json_schema"] as? [String: Any], let raw = wrapper["schema"] as? [String: Any] {
            schema = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        let effort = (object["reasoning_effort"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return SubscriptionRequest(system: system.isEmpty ? nil : system.joined(separator: "\n\n"), prompt: prompt,
                                   schema: schema, stream: object["stream"] as? Bool ?? false, effort: effort)
    }

    static func text(of content: Any?) throws -> String {
        if let text = content as? String { return text }
        guard let parts = content as? [[String: Any]] else { return "" }
        return try parts.map { part in
            switch part["type"] as? String {
            case "text", "input_text": return part["text"] as? String ?? ""
            default: throw Invalid(description: "Images et pièces jointes non prises en charge par le relais d'abonnement : texte seulement.")
            }
        }.joined(separator: "\n")
    }
}

/// OpenAI structured outputs (and so `codex exec --output-schema`) insist on closed objects whose properties are all
/// required. A pydantic schema has neither when a field has a default: close every object, require every property,
/// drop `default`. The answer still validates against the original schema.
public enum StrictSchema {
    public static func make(_ data: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return data }
        return (try? JSONSerialization.data(withJSONObject: strict(object), options: [.sortedKeys, .withoutEscapingSlashes])) ?? data
    }

    static func strict(_ node: Any) -> Any {
        if let list = node as? [Any] { return list.map(strict) }
        guard var object = node as? [String: Any] else { return node }
        object.removeValue(forKey: "default")
        for (key, value) in object { object[key] = strict(value) }
        if let properties = object["properties"] as? [String: Any] {
            object["additionalProperties"] = false
            object["required"] = properties.keys.sorted()
        }
        return object
    }
}

/// One run of a command-line tool: what to start and what came out.
public struct CLIInvocation: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var directory: URL
    public var input: Data
}

public struct CLIOutput: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool

    public init(status: Int32, stdout: Data, stderr: Data, timedOut: Bool = false) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// The answer of one subscription call, before it is shaped as an HTTP response.
public struct SubscriptionAnswer: Equatable, Sendable {
    public var content: String
    public var inputTokens: Int
    public var outputTokens: Int
    /// `claude -p` reports what the call would cost at API prices; Codex reports tokens only.
    public var costUSD: Double?
}

public struct SubscriptionFailure: Error, CustomStringConvertible, Sendable {
    public var status: Int
    public var description: String
    public var type: String
}

/// Runs `claude -p` or `codex exec` for one chat completion. Everything but the process itself is a pure function,
/// and `run` is injectable, so tests drive it with a fake tool.
public struct SubscriptionRunner: Sendable {
    public typealias Run = @Sendable (CLIInvocation, TimeInterval) async -> CLIOutput

    /// Where a tool is looked for when LLMarium is started from the Finder (no shell PATH): the official installers'
    /// folders first, then the PATH it was given.
    public var executable: @Sendable (SubscriptionCLI) -> URL?
    /// Codex's home for these calls: only `auth.json` (a link to the user's), so their AGENTS.md, config, MCP servers
    /// and memories stay out. Codex rewrites `auth.json` in place, through the link: the login stays shared. Not the
    /// harness's `codex-home`, whose Codex reaches the proxy with a key and must not inherit a ChatGPT login.
    public var codexHome: URL
    public var userCodexAuth: URL
    public var timeout: TimeInterval
    public var run: Run

    public init(executable: @escaping @Sendable (SubscriptionCLI) -> URL? = SubscriptionRunner.findExecutable,
                codexHome: URL = AppPaths.support.appending(path: "codex-subscription"),
                userCodexAuth: URL = SubscriptionRunner.defaultCodexAuth,
                timeout: TimeInterval = 900, run: @escaping Run = SubscriptionRunner.runProcess) {
        self.executable = executable
        self.codexHome = codexHome
        self.userCodexAuth = userCodexAuth
        self.timeout = timeout
        self.run = run
    }

    public static let defaultCodexAuth: URL = {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
        return home.appending(path: "auth.json")
    }()

    @Sendable public static func findExecutable(_ cli: SubscriptionCLI) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let folders = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] + path
        return folders.lazy.map { URL(fileURLWithPath: $0).appending(path: cli.executableName) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The tool's environment: the app's, minus anything that would bill an API key, reach another endpoint or make
    /// the tool believe it runs inside an agent session.
    static func environment(for cli: SubscriptionCLI, base: [String: String], codexHome: URL, executable: URL) -> [String: String] {
        var environment = base.filter { key, _ in
            !(key == "CLAUDECODE" || key.hasPrefix("CLAUDE_") || key.hasPrefix("ANTHROPIC_") || key.hasPrefix("CODEX_")
              || key.hasPrefix("OPENAI_"))
        }
        let folder = executable.deletingLastPathComponent().path
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = path.split(separator: ":").contains(Substring(folder)) ? path : "\(folder):\(path)"
        if cli == .codex { environment["CODEX_HOME"] = codexHome.path }
        return environment
    }

    static func arguments(for cli: SubscriptionCLI, model: String, request: SubscriptionRequest, directory: URL) -> [String] {
        switch cli {
        case .claude:
            var arguments = ["-p", "--output-format", "json", "--model", model,
                             "--tools", "", "--strict-mcp-config", "--setting-sources", "",
                             "--no-session-persistence", "--disable-slash-commands",
                             "--system-prompt", request.system ?? "You are a helpful assistant."]
            if let schema = request.schema { arguments += ["--json-schema", String(decoding: schema, as: UTF8.self)] }
            if let effort = request.effort { arguments += ["--effort", effort] }
            return arguments
        case .codex:
            var arguments = ["exec", "--ignore-user-config", "--ignore-rules", "--ephemeral", "--sandbox", "read-only",
                             "--skip-git-repo-check", "--model", model,
                             "-c", #"forced_login_method="chatgpt""#,
                             "-c", "features.shell_tool=false", "-c", "features.multi_agent=false",
                             "-c", #"web_search="disabled""#, "-c", "include_environment_context=false",
                             "-c", "include_permissions_instructions=false", "-c", "include_apps_instructions=false"]
            if request.system != nil {
                arguments += ["-c", "model_instructions_file=\(tomlString(directory.appending(path: "instructions.md").path))"]
            }
            if let effort = request.effort { arguments += ["-c", "model_reasoning_effort=\(tomlString(effort))"] }
            if request.schema != nil { arguments += ["--output-schema", directory.appending(path: "schema.json").path] }
            arguments += ["--cd", directory.path, "--output-last-message", directory.appending(path: "answer.txt").path, "--json", "-"]
            return arguments
        }
    }

    static func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Runs one completion in a fresh working folder, removed afterwards.
    public func answer(_ request: SubscriptionRequest, target: SubscriptionTarget) async throws -> SubscriptionAnswer {
        guard let executable = executable(target.cli) else {
            throw SubscriptionFailure(status: 503, description: "« \(target.cli.executableName) » introuvable (cherché dans ~/.local/bin, /opt/homebrew/bin, /usr/local/bin et le PATH).",
                                      type: "upstream_unavailable")
        }
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appending(path: "llmarium-\(target.cli.rawValue)-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        if target.cli == .codex {
            try prepareCodexHome()
            if let system = request.system { try Data(system.utf8).write(to: directory.appending(path: "instructions.md")) }
            if let schema = request.schema { try StrictSchema.make(schema).write(to: directory.appending(path: "schema.json")) }
        }
        let invocation = CLIInvocation(
            executable: executable, arguments: Self.arguments(for: target.cli, model: target.model, request: request, directory: directory),
            environment: Self.environment(for: target.cli, base: ProcessInfo.processInfo.environment, codexHome: codexHome, executable: executable),
            directory: directory, input: Data(request.prompt.utf8))
        let output = await run(invocation, timeout)
        if output.timedOut {
            throw SubscriptionFailure(status: 504, description: "\(target.cli.executableName) n'a pas répondu en \(Int(timeout)) s : arrêté.", type: "upstream_timeout")
        }
        switch target.cli {
        case .claude: return try Self.parseClaude(output)
        case .codex:
            let answer = try? Data(contentsOf: directory.appending(path: "answer.txt"))
            return try Self.parseCodex(output, answer: answer)
        }
    }

    /// `codex-subscription/auth.json` → the user's `auth.json`. Nothing else is created by hand; Codex fills its caches there.
    func prepareCodexHome() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let link = codexHome.appending(path: "auth.json")
        if (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) == userCodexAuth.path { return }
        guard fileManager.fileExists(atPath: userCodexAuth.path) else {
            throw SubscriptionFailure(status: 503, description: "Codex n'est pas connecté (\(userCodexAuth.path) absent) : lancez « codex login » une fois.",
                                      type: "upstream_unavailable")
        }
        try? fileManager.removeItem(at: link)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: userCodexAuth)
    }

    static func failureText(_ output: CLIOutput) -> String {
        let text = String(decoding: output.stderr.isEmpty ? output.stdout : output.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.suffix(600))
    }

    /// `--output-format json`: one object; `structured_output` when a schema was given, `result` otherwise.
    static func parseClaude(_ output: CLIOutput) throws -> SubscriptionAnswer {
        guard let object = (try? JSONSerialization.jsonObject(with: output.stdout)) as? [String: Any] else {
            throw SubscriptionFailure(status: 502, description: "claude a échoué (code \(output.status)) : \(failureText(output))", type: "upstream_error")
        }
        if object["is_error"] as? Bool == true || (object["subtype"] as? String).map({ $0 != "success" }) == true {
            let reason = object["result"] as? String ?? object["subtype"] as? String ?? "erreur"
            throw SubscriptionFailure(status: 502, description: "claude : \(reason)", type: "upstream_error")
        }
        let content: String
        if let structured = object["structured_output"], !(structured is NSNull),
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.withoutEscapingSlashes]) {
            content = String(decoding: data, as: UTF8.self)
        } else {
            content = object["result"] as? String ?? ""
        }
        let usage = object["usage"] as? [String: Any] ?? [:]
        let input = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].reduce(0) { $0 + (usage[$1] as? Int ?? 0) }
        return SubscriptionAnswer(content: content, inputTokens: input, outputTokens: usage["output_tokens"] as? Int ?? 0,
                                  costUSD: object["total_cost_usd"] as? Double)
    }

    /// `--json`: one event per line; the answer itself is in the `--output-last-message` file.
    static func parseCodex(_ output: CLIOutput, answer: Data?) throws -> SubscriptionAnswer {
        var input = 0, outputTokens = 0
        var failure: String?
        for line in String(decoding: output.stdout, as: UTF8.self).split(separator: "\n") {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "turn.completed":
                let usage = event["usage"] as? [String: Any] ?? [:]
                input += usage["input_tokens"] as? Int ?? 0
                outputTokens += usage["output_tokens"] as? Int ?? 0
            case "turn.failed":
                failure = (event["error"] as? [String: Any])?["message"] as? String ?? "échec du tour"
            case "error":
                failure = failure ?? event["message"] as? String
            default: break
            }
        }
        if let failure { throw SubscriptionFailure(status: 502, description: "codex : \(String(failure.prefix(600)))", type: "upstream_error") }
        guard output.status == 0, let answer, !answer.isEmpty else {
            throw SubscriptionFailure(status: 502, description: "codex a échoué (code \(output.status)) : \(failureText(output))", type: "upstream_error")
        }
        return SubscriptionAnswer(content: String(decoding: answer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                                  inputTokens: input, outputTokens: outputTokens, costUSD: nil)
    }

    /// The process, with stdin, stdout and stderr as files in its working folder (no pipe to drain), stopped at the
    /// deadline: SIGTERM, then SIGKILL two seconds later.
    @Sendable public static func runProcess(_ invocation: CLIInvocation, timeout: TimeInterval) async -> CLIOutput {
        let fileManager = FileManager.default
        let stdinURL = invocation.directory.appending(path: ".stdin")
        let stdoutURL = invocation.directory.appending(path: ".stdout")
        let stderrURL = invocation.directory.appending(path: ".stderr")
        do {
            try invocation.input.write(to: stdinURL)
            fileManager.createFile(atPath: stdoutURL.path, contents: nil)
            fileManager.createFile(atPath: stderrURL.path, contents: nil)
            let process = Process()
            process.executableURL = invocation.executable
            process.arguments = invocation.arguments
            process.environment = invocation.environment
            process.currentDirectoryURL = invocation.directory
            let stdin = try FileHandle(forReadingFrom: stdinURL)
            let stdout = try FileHandle(forWritingTo: stdoutURL)
            let stderr = try FileHandle(forWritingTo: stderrURL)
            defer { try? stdin.close(); try? stdout.close(); try? stderr.close() }
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            let timedOut = TimedOut()
            let status: Int32 = await withCheckedContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    try? Data("\(error)".utf8).write(to: stderrURL)
                    continuation.resume(returning: 127)
                    return
                }
                let pid = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }
                    timedOut.set()
                    kill(pid, SIGTERM)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(pid, SIGKILL) } }
                }
            }
            return CLIOutput(status: status, stdout: (try? Data(contentsOf: stdoutURL)) ?? Data(),
                             stderr: (try? Data(contentsOf: stderrURL)) ?? Data(), timedOut: timedOut.value)
        } catch {
            return CLIOutput(status: 127, stdout: Data(), stderr: Data("\(error)".utf8))
        }
    }

    final class TimedOut: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.withLock { flag = true } }
        var value: Bool { lock.withLock { flag } }
    }
}

/// The OpenAI-shaped answer: a `chat.completion`, or the same content as a two-event stream when `stream` was asked.
public enum SubscriptionResponse {
    public static func body(_ answer: SubscriptionAnswer, model: String, stream: Bool, now: Date = Date()) -> (data: Data, contentType: String) {
        let id = "chatcmpl-llmarium-\(UUID().uuidString.lowercased())"
        let created = Int(now.timeIntervalSince1970)
        let usage: [String: Any] = ["prompt_tokens": answer.inputTokens, "completion_tokens": answer.outputTokens,
                                    "total_tokens": answer.inputTokens + answer.outputTokens]
        func json(_ object: [String: Any]) -> Data {
            (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
        }
        guard stream else {
            var object: [String: Any] = ["id": id, "object": "chat.completion", "created": created, "model": model, "usage": usage,
                                         "choices": [["index": 0, "message": ["role": "assistant", "content": answer.content],
                                                      "finish_reason": "stop"]]]
            if let cost = answer.costUSD { object["llmarium"] = ["cost_usd_api_equivalent": cost] }
            return (json(object), "application/json")
        }
        let base: [String: Any] = ["id": id, "object": "chat.completion.chunk", "created": created, "model": model]
        let first = base.merging(["choices": [["index": 0, "delta": ["role": "assistant", "content": answer.content], "finish_reason": NSNull()]]]) { $1 }
        let last = base.merging(["choices": [["index": 0, "delta": [String: Any](), "finish_reason": "stop"]], "usage": usage]) { $1 }
        var data = Data()
        for event in [first, last] { data += Data("data: ".utf8) + json(event) + Data("\n\n".utf8) }
        data += Data("data: [DONE]\n\n".utf8)
        return (data, "text/event-stream")
    }
}
