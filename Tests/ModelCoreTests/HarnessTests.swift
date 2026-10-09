import Foundation
import XCTest
@testable import ModelCore

final class HarnessTests: XCTestCase {
    private let target = HarnessTarget(engine: .omlx, baseURL: "http://127.0.0.1:8020", modelID: "Qwen3.8-27B",
                                       contextWindow: 262_144, modelType: "qwen3_5")

    /// The real desktop patch layer of 8 October: hand-edited, with comments and a Daymon insert at the end.
    static let realPatch = """
    # Your patch layer for this dsh profile, applied after every bundle layer:
    # a top-level YAML array of loader patch entries.
    - id: ui-settings-general
      name: "@deepseek-ai/dsh-client-ui-settings-general"
      config:
        welcomeNoticeVersion: 2026-08-13.1
    - id: llm-pi-ai
      name: "@deepseek-ai/dsh-llm-pi-ai"
      config:
        providers:
          dwarfstar:
            displayName: DwarfStar (local)
            apiKeyEnv: DWARFSTAR_API_KEY
            api: openai-completions
            baseURL: http://127.0.0.1:8000/v1
            models:
              - id: glm-5.3-flash
                name: GLM 5.3 Flash (local)
    - id: agent-default-model
      name: "@deepseek-ai/dsh-agent-default-model"
      config:
        provider: deepseek-account
        model: deepseek-flash

    # Daily Monitor: declares dsh sessions to the local Daymon service.
    - insert:
        - id: daymon
          name: '/Users/me/daymon.mjs'

    """

    func testDSHPatchAddsOnlyOurProviderAndIsIdempotent() throws {
        let once = try HarnessPlanner.dshPatch(existing: Self.realPatch, target: target)
        let twice = try HarnessPlanner.dshPatch(existing: once, target: target)
        XCTAssertEqual(once, twice, "opening again rewrites the same block, nothing more")
        var updated = once.components(separatedBy: "\n")
        let marker = try XCTUnwrap(updated.firstIndex { $0.contains("géré par Modèles locaux") })
        let blockEnd = try XCTUnwrap(updated[marker...].firstIndex { $0.trimmingCharacters(in: .whitespaces) == "- text" })
        XCTAssertTrue(updated[marker...blockEnd].allSatisfy { $0.hasPrefix("      ") }, "the whole block sits inside providers")
        var withoutBlock = updated
        withoutBlock.removeSubrange(marker...blockEnd)
        XCTAssertEqual(withoutBlock.joined(separator: "\n"), Self.realPatch, "every other line is kept as it was")
        updated = once.components(separatedBy: "\n")
        let providers = try XCTUnwrap(updated.firstIndex(of: "    providers:"))
        XCTAssertEqual(updated[providers + 2], "      local-launcher:")
        XCTAssertTrue(once.contains("      dwarfstar:\n        displayName: DwarfStar (local)"))
        XCTAssertTrue(once.contains("contextWindow: 262144"))

        var moved = target
        moved.baseURL = "http://127.0.0.1:18100"
        let switched = try HarnessPlanner.dshPatch(existing: once, target: moved)
        XCTAssertFalse(switched.contains("8020/v1\""))
        XCTAssertEqual(switched.components(separatedBy: "local-launcher:").count, 2, "one block only")
    }

    func testDSHPatchCreatesOrAppendsTheEntry() throws {
        let fresh = try HarnessPlanner.dshPatch(existing: nil, target: target)
        XCTAssertTrue(fresh.contains("- id: llm-pi-ai\n  name: \"@deepseek-ai/dsh-llm-pi-ai\"\n  config:\n    providers:\n"))
        let other = "- id: ui-chat\n  config:\n    transcriptView: standard\n"
        let appended = try HarnessPlanner.dshPatch(existing: other, target: target)
        XCTAssertTrue(appended.hasPrefix(other))
        XCTAssertThrowsError(try HarnessPlanner.dshPatch(existing: "- id: llm-pi-ai\n  config:\n    enabled: true\n", target: target))
    }

    func testPiKeepsOtherProvidersAndReplacesOurs() throws {
        let existing = #"{"providers": {"mtplx": {"api": "openai-completions", "models": [{"id": "a"}]}, "local-launcher": {"old": true}}, "extra": 1}"#
        let data = try HarnessPlanner.piModels(existing: Data(existing.utf8), target: target)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let providers = try XCTUnwrap(root["providers"] as? [String: Any])
        XCTAssertNotNil(providers["mtplx"])
        let ours = try XCTUnwrap(providers["local-launcher"] as? [String: Any])
        XCTAssertNil(ours["old"])
        XCTAssertEqual(ours["baseUrl"] as? String, "http://127.0.0.1:8020/v1")
        XCTAssertEqual((ours["compat"] as? [String: Any])?["thinkingFormat"] as? String, "qwen")
        XCTAssertEqual(root["extra"] as? Int, 1)
        XCTAssertThrowsError(try HarnessPlanner.piModels(existing: Data("{oops".utf8), target: target))
    }

    func testCodexConfigTurnsOffHostedSearch() {
        let config = HarnessPlanner.codexConfig(target)
        XCTAssertTrue(config.contains("web_search = \"disabled\""))
        XCTAssertTrue(config.contains("wire_api = \"responses\""))
        XCTAssertTrue(config.contains("base_url = \"http://127.0.0.1:8020/v1\""))
        XCTAssertTrue(config.contains("model_context_window = 262144"))
    }

    func testOpenCodeConfigSelectsOurModel() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(HarnessPlanner.openCodeConfig(target).utf8)) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "local-launcher/Qwen3.8-27B")
    }

    func testClaudeCodeEnvironmentAndContextGate() throws {
        let environment = HarnessPlanner.claudeEnvironment(target)
        XCTAssertEqual(environment["ANTHROPIC_BASE_URL"], "http://127.0.0.1:8020")
        XCTAssertEqual(environment["ANTHROPIC_API_KEY"], "")
        XCTAssertEqual(environment["CLAUDE_CODE_MAX_CONTEXT_TOKENS"], "262144")
        var small = target
        small.contextWindow = 32_768
        XCTAssertNotNil(HarnessPlanner.unavailableReason(.claudeCode, target: small, installed: [.claudeCode]))
        XCTAssertNil(HarnessPlanner.unavailableReason(.codex, target: small, installed: [.codex]))
        XCTAssertNotNil(HarnessPlanner.unavailableReason(.pi, target: target, installed: []))
    }

    /// Splits a shell command the way /bin/sh does, without running it.
    private func shellWords(_ command: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", #"eval "set -- $1"; for word in "$@"; do printf '%s\0' "$word"; done"#, "sh", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    func testWindowCommandSurvivesTheShell() throws {
        let arguments = ["claude", "--settings", #"{"useAutoModeDuringPlan":false}"#, "dossier avec espaces", "it's", "$HOME"]
        let outer = try shellWords(HarnessOpener.windowCommand(arguments, keep: ["ANTHROPIC_BASE_URL"]))
        XCTAssertEqual(outer.count, 3)
        XCTAssertEqual(outer[1], "-lic")
        let inner = try XCTUnwrap(outer.last)
        let harness = try XCTUnwrap(inner.components(separatedBy: "; ").first { $0.hasPrefix("'claude'") })
        XCTAssertEqual(try shellWords(harness), arguments, "every argument reaches the harness unchanged, unexpanded")
        XCTAssertTrue(inner.contains(#"case " ANTHROPIC_BASE_URL " in"#))
    }

    func testWindowCommandQuotesSpacesAndQuotes() {
        let command = HarnessOpener.windowCommand(["claude", "--settings", #"{"a":false}"#, "it's"])
        XCTAssertTrue(command.contains(#"'\''"#), "single quotes inside the inner command are escaped")
        XCTAssertTrue(command.hasSuffix("'"))
        XCTAssertEqual(HarnessOpener.appleScriptString(#"a "b" \c"#), #""a \"b\" \\c""#)
    }
}
