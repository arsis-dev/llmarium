import Foundation
import XCTest
@testable import ModelCore

/// Claude and ChatGPT reached through `claude -p` and `codex exec` instead of an API key.
final class SubscriptionTests: XCTestCase {
    private let table = RouteTable(aliases: [ProxyAlias(alias: "moments", model: "claude-cli/sonnet", provider: "claude-cli")],
                                   servers: [.init(label: "oMLX", port: 8020, models: ["sonnet"], owned: false)],
                                   providers: [SubscriptionCLI.claude.provider, SubscriptionCLI.codex.provider])

    func testRoutedByPrefixOnlyAndForChatCompletionsOnly() {
        XCTAssertEqual(table.resolve(model: "claude-cli/sonnet", path: "/v1/chat/completions"),
                       .subscription(SubscriptionTarget(cli: .claude, model: "sonnet", providerID: "claude-cli")))
        XCTAssertEqual(table.resolve(model: "codex-cli/gpt-6-luna", path: "/v1/chat/completions"),
                       .subscription(SubscriptionTarget(cli: .codex, model: "gpt-6-luna", providerID: "codex-cli")))
        XCTAssertEqual(table.resolve(model: "moments", path: "/v1/chat/completions"),
                       .subscription(SubscriptionTarget(cli: .claude, model: "sonnet", providerID: "claude-cli")))
        guard case .upstream(let local) = table.resolve(model: "sonnet", path: "/v1/chat/completions") else {
            return XCTFail("a bare suggested name must not start a process")
        }
        XCTAssertEqual(local.port, 8020)
        guard case .notFound = table.resolve(model: "claude-cli/sonnet", path: "/v1/messages") else { return XCTFail() }
        guard case .notFound = table.resolve(model: "claude-cli/", path: "/v1/chat/completions") else { return XCTFail() }
    }

    func testModelListShowsThePrefixedNames() throws {
        let list = try XCTUnwrap(JSONSerialization.jsonObject(with: table.modelList()) as? [String: Any])
        let ids = (list["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        XCTAssertTrue(ids.contains("claude-cli/sonnet"))
        XCTAssertTrue(ids.contains("codex-cli/gpt-6-luna"))
        XCTAssertTrue(ids.contains("moments"))
    }

    func testOldConfigurationsStillDecode() throws {
        let json = #"{"port":18099,"aliases":[],"providers":[{"id":"deepseek","name":"DeepSeek","openAIBase":"https://api.deepseek.com/v1","models":["m"]}]}"#
        let config = try JSONDecoder().decode(ProxyConfig.self, from: Data(json.utf8))
        XCTAssertNil(config.providers[0].cli)
    }

    func testRequestKeepsSystemPromptAndSchema() throws {
        let body = #"""
        {"model":"claude-cli/sonnet","temperature":0.2,"max_tokens":8192,"chat_template_kwargs":{"enable_thinking":false},
         "reasoning_effort":"low",
         "messages":[{"role":"system","content":"JSON only."},{"role":"user","content":[{"type":"text","text":"Pick moments."}]}],
         "response_format":{"type":"json_schema","json_schema":{"name":"r","schema":{"type":"object","properties":{"a":{"type":"string"}}}}}}
        """#
        let request = try SubscriptionRequest.parse(Data(body.utf8))
        XCTAssertEqual(request.system, "JSON only.")
        XCTAssertEqual(request.prompt, "Pick moments.")
        XCTAssertEqual(request.effort, "low")
        XCTAssertFalse(request.stream)
        let schema = try XCTUnwrap(request.schema.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(schema["type"] as? String, "object")
    }

    func testAConversationIsWrittenOutTurnByTurn() throws {
        let body = #"{"model":"x","messages":[{"role":"user","content":"Hi"},{"role":"assistant","content":"Hello"},{"role":"user","content":"More"}]}"#
        let request = try SubscriptionRequest.parse(Data(body.utf8))
        XCTAssertNil(request.system)
        XCTAssertEqual(request.prompt, "User:\nHi\n\nAssistant:\nHello\n\nUser:\nMore")
    }

    func testImagesAndToolsAreRefused() {
        let image = #"{"model":"x","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,AA"}}]}]}"#
        XCTAssertThrowsError(try SubscriptionRequest.parse(Data(image.utf8)))
        let tools = #"{"model":"x","tools":[{"type":"function"}],"messages":[{"role":"user","content":"Hi"}]}"#
        XCTAssertThrowsError(try SubscriptionRequest.parse(Data(tools.utf8)))
        XCTAssertThrowsError(try SubscriptionRequest.parse(Data(#"{"model":"x"}"#.utf8)))
    }

    func testStrictSchemaClosesObjectsAndRequiresEveryField() throws {
        // The shape pydantic gives OpenShorts' DetailResponse: a $defs item with a defaulted field.
        let pydantic = #"""
        {"$defs":{"Clip":{"properties":{"start":{"type":"number"},"why":{"default":"","type":"string"}},"required":["start"],"type":"object"}},
         "properties":{"shorts":{"items":{"$ref":"#/$defs/Clip"},"type":"array"}},"required":["shorts"],"type":"object"}
        """#
        let strict = try XCTUnwrap(JSONSerialization.jsonObject(with: StrictSchema.make(Data(pydantic.utf8))) as? [String: Any])
        XCTAssertEqual(strict["additionalProperties"] as? Bool, false)
        let clip = try XCTUnwrap((strict["$defs"] as? [String: Any])?["Clip"] as? [String: Any])
        XCTAssertEqual(clip["additionalProperties"] as? Bool, false)
        XCTAssertEqual(clip["required"] as? [String], ["start", "why"])
        XCTAssertNil((clip["properties"] as? [String: Any])?["why"].flatMap { ($0 as? [String: Any])?["default"] })
    }

    func testArgumentsIsolateEachTool() {
        let request = SubscriptionRequest(system: "JSON only.", prompt: "p", schema: Data("{}".utf8), stream: false, effort: "low")
        let directory = URL(fileURLWithPath: "/tmp/job")
        let claude = SubscriptionRunner.arguments(for: .claude, model: "sonnet", request: request, directory: directory)
        for flag in ["-p", "--strict-mcp-config", "--no-session-persistence", "--disable-slash-commands"] { XCTAssertTrue(claude.contains(flag), flag) }
        XCTAssertFalse(claude.contains("--bare"), "--bare only takes ANTHROPIC_API_KEY: it would leave the subscription")
        XCTAssertEqual(claude[claude.firstIndex(of: "--tools")! + 1], "")
        XCTAssertEqual(claude[claude.firstIndex(of: "--setting-sources")! + 1], "")
        XCTAssertEqual(claude[claude.firstIndex(of: "--system-prompt")! + 1], "JSON only.")
        XCTAssertEqual(claude[claude.firstIndex(of: "--json-schema")! + 1], "{}")
        XCTAssertEqual(claude[claude.firstIndex(of: "--effort")! + 1], "low")

        let codex = SubscriptionRunner.arguments(for: .codex, model: "gpt-6-luna", request: request, directory: directory)
        for flag in ["--ignore-user-config", "--ephemeral", "--skip-git-repo-check", "--json", #"forced_login_method="chatgpt""#,
                     "features.shell_tool=false", #"model_reasoning_effort="low""#, #"model_instructions_file="/tmp/job/instructions.md""#] {
            XCTAssertTrue(codex.contains(flag), flag)
        }
        XCTAssertEqual(codex[codex.firstIndex(of: "--sandbox")! + 1], "read-only")
        XCTAssertEqual(codex[codex.firstIndex(of: "--output-schema")! + 1], "/tmp/job/schema.json")
        XCTAssertEqual(codex.last, "-", "the prompt comes on stdin")
    }

    func testEnvironmentDropsKeysAndAgentMarkers() {
        let base = ["PATH": "/usr/bin:/bin", "HOME": "/Users/x", "ANTHROPIC_API_KEY": "k", "ANTHROPIC_BASE_URL": "http://elsewhere",
                    "OPENAI_API_KEY": "k", "CODEX_API_KEY": "k", "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "sdk"]
        let home = URL(fileURLWithPath: "/tmp/codex-home")
        let claude = SubscriptionRunner.environment(for: .claude, base: base, codexHome: home, executable: URL(fileURLWithPath: "/Users/x/.local/bin/claude"))
        XCTAssertEqual(Set(claude.keys), ["PATH", "HOME"])
        XCTAssertEqual(claude["PATH"], "/Users/x/.local/bin:/usr/bin:/bin")
        let codex = SubscriptionRunner.environment(for: .codex, base: base, codexHome: home, executable: URL(fileURLWithPath: "/usr/bin/codex"))
        XCTAssertEqual(codex["CODEX_HOME"], "/tmp/codex-home")
        XCTAssertEqual(codex["PATH"], "/usr/bin:/bin")
        XCTAssertNil(codex["OPENAI_API_KEY"])
    }

    func testClaudeOutputPrefersStructuredOutput() throws {
        let stdout = #"{"type":"result","subtype":"success","is_error":false,"result":"ignored","structured_output":{"a":"b"},"total_cost_usd":0.0123,"usage":{"input_tokens":3,"cache_creation_input_tokens":1000,"cache_read_input_tokens":20,"output_tokens":80}}"#
        let answer = try SubscriptionRunner.parseClaude(CLIOutput(status: 0, stdout: Data(stdout.utf8), stderr: Data()))
        XCTAssertEqual(answer, SubscriptionAnswer(content: #"{"a":"b"}"#, inputTokens: 1023, outputTokens: 80, costUSD: 0.0123))
        let failed = #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in"}"#
        XCTAssertThrowsError(try SubscriptionRunner.parseClaude(CLIOutput(status: 1, stdout: Data(failed.utf8), stderr: Data()))) {
            XCTAssertTrue("\($0)".contains("Not logged in"))
        }
        XCTAssertThrowsError(try SubscriptionRunner.parseClaude(CLIOutput(status: 127, stdout: Data(), stderr: Data("boom".utf8)))) {
            XCTAssertTrue("\($0)".contains("boom"))
        }
    }

    func testCodexOutputReadsTheLastMessageAndUsage() throws {
        let events = """
        {"type":"thread.started","thread_id":"t"}
        {"type":"turn.started"}
        {"type":"turn.completed","usage":{"input_tokens":9309,"cached_input_tokens":0,"output_tokens":217,"reasoning_output_tokens":65}}
        """
        let answer = try SubscriptionRunner.parseCodex(CLIOutput(status: 0, stdout: Data(events.utf8), stderr: Data()), answer: Data("{\"a\":1}\n".utf8))
        XCTAssertEqual(answer, SubscriptionAnswer(content: #"{"a":1}"#, inputTokens: 9309, outputTokens: 217, costUSD: nil))
        let failed = #"{"type":"turn.failed","error":{"message":"Invalid schema"}}"#
        XCTAssertThrowsError(try SubscriptionRunner.parseCodex(CLIOutput(status: 1, stdout: Data(failed.utf8), stderr: Data()), answer: nil)) {
            XCTAssertTrue("\($0)".contains("Invalid schema"))
        }
    }

    func testStreamedAnswerIsTwoEventsAndDone() throws {
        let shaped = SubscriptionResponse.body(SubscriptionAnswer(content: "hi", inputTokens: 1, outputTokens: 2, costUSD: nil), model: "m", stream: true)
        XCTAssertEqual(shaped.contentType, "text/event-stream")
        let text = String(decoding: shaped.data, as: UTF8.self)
        XCTAssertEqual(text.components(separatedBy: "data: ").count - 1, 3)
        XCTAssertTrue(text.hasSuffix("data: [DONE]\n\n"))
    }

    /// A real process (a shell script standing in for the tool): stdin reaches it, its output comes back.
    func testRunProcessFeedsStdinAndStopsAtTheDeadline() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "llmarium-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let echo = CLIInvocation(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "tr a-z A-Z; echo oops >&2; exit 3"],
                                 environment: ["PATH": "/usr/bin:/bin"], directory: directory, input: Data("hello".utf8))
        let output = await SubscriptionRunner.runProcess(echo, timeout: 10)
        XCTAssertEqual(output.status, 3)
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "HELLO")
        XCTAssertEqual(String(decoding: output.stderr, as: UTF8.self), "oops\n")
        XCTAssertFalse(output.timedOut)

        let start = Date()
        let slow = CLIInvocation(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:], directory: directory, input: Data())
        let stopped = await SubscriptionRunner.runProcess(slow, timeout: 0.5)
        XCTAssertTrue(stopped.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    /// Through the proxy: an OpenAI chat completion in, the tool run with the translated request, a chat completion out.
    func testProxyAnswersAChatCompletionThroughTheTool() async throws {
        final class Seen: @unchecked Sendable {
            let lock = NSLock()
            var invocation: CLIInvocation?
        }
        let seen = Seen()
        let runner = SubscriptionRunner(executable: { _ in URL(fileURLWithPath: "/usr/local/bin/claude") }, run: { invocation, _ in
            seen.lock.withLock { seen.invocation = invocation }
            let stdout = #"{"subtype":"success","is_error":false,"structured_output":{"windows":[]},"total_cost_usd":0.02,"usage":{"input_tokens":10,"output_tokens":5}}"#
            return CLIOutput(status: 0, stdout: Data(stdout.utf8), stderr: Data())
        })
        let port = try XCTUnwrap(ModelLauncher.freePort())
        let routes = table
        let proxy = ProxyServer(port: port, tableProvider: { routes }, subscriptions: runner)
        try await proxy.start()
        defer { proxy.stop() }
        let body = #"{"model":"claude-cli/sonnet","stream":false,"messages":[{"role":"system","content":"JSON only."},{"role":"user","content":"Score."}],"response_format":{"type":"json_schema","json_schema":{"name":"s","schema":{"type":"object"}}}}"#
        let text = try await Task.detached { try ProxyStreamingTests.request(port: port, body: body) }.value.map(\.text).joined()
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200"), text)
        let json = try XCTUnwrap(text.components(separatedBy: "\r\n\r\n").last)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let message = ((object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        XCTAssertEqual(message, #"{"windows":[]}"#)
        XCTAssertEqual((object["usage"] as? [String: Any])?["prompt_tokens"] as? Int, 10)
        XCTAssertEqual(object["model"] as? String, "claude-cli/sonnet")
        let invocation = try XCTUnwrap(seen.lock.withLock { seen.invocation })
        XCTAssertEqual(String(decoding: invocation.input, as: UTF8.self), "Score.")
        XCTAssertEqual(invocation.arguments[invocation.arguments.firstIndex(of: "--model")! + 1], "sonnet")
        XCTAssertEqual(invocation.arguments[invocation.arguments.firstIndex(of: "--json-schema")! + 1], #"{"type":"object"}"#)

        let image = #"{"model":"claude-cli/sonnet","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"x"}}]}]}"#
        let refused = try await Task.detached { try ProxyStreamingTests.request(port: port, body: image) }.value.map(\.text).joined()
        XCTAssertTrue(refused.hasPrefix("HTTP/1.1 400"), refused)
    }
}
