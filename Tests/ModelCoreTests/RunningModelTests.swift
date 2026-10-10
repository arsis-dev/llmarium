import Foundation
import XCTest
@testable import ModelCore

final class AttributionTests: XCTestCase {
    private func process(_ pid: Int32, _ name: String, _ path: String, parent: Int32, arguments: [String] = [],
                         environment: [String: String] = [:], responsible: Int32? = nil) -> RunningProcess {
        RunningProcess(pid: pid, name: name, executablePath: path, arguments: arguments, footprintBytes: 1,
                       parentPID: parent, responsiblePID: responsible ?? pid, environment: environment)
    }

    private func attributor(_ processes: [RunningProcess]) -> LaunchAttributor {
        LaunchAttributor(processes: processes, launched: []) { id in (id == "s1" ? "Révision du design" : nil, nil) }
    }

    func testLiveChainFromClaudeApp() {
        let worker = process(40, "python3.12", "/w/.venv/bin/python", parent: 30, arguments: ["python", "/m/models--a--b/x.py"],
                             environment: ["CLAUDE_CODE_SESSION_ID": "s1", "PWD": "/Users/me/Dev/watslog"])
        let processes = [
            process(10, "Claude", "/Applications/Claude.app/Contents/MacOS/Claude", parent: 1),
            process(20, "disclaimer", "/Applications/Claude.app/Contents/Helpers/disclaimer", parent: 10),
            process(25, "claude", "/Users/me/Library/Application Support/Claude/claude-code/2.1/claude.app/Contents/MacOS/claude", parent: 20),
            process(30, "zsh", "/bin/zsh", parent: 25),
            worker
        ]
        let attribution = attributor(processes).attribute(worker)
        XCTAssertEqual(attribution.steps, [LaunchStep("Claude"), LaunchStep("Claude Code", detail: "Révision du design")])
        XCTAssertEqual(attribution.certainty, .certain)
        XCTAssertFalse(attribution.isOrphan)
        XCTAssertEqual(attribution.projectPath, "/Users/me/Dev/watslog")
        XCTAssertEqual(attribution.summary, "Claude › Claude Code « Révision du design »")
    }

    func testOrphanIsRebuiltFromItsEnvironment() {
        // The clef server of 6 October: its `tauri dev` parent exited and it was reparented to launchd.
        let worker = process(80606, "python3.12", "/u/.local/share/uv/python/bin/python3.12", parent: 1,
                             arguments: ["python", "/h/models--mlx-community--clef-4bit/snapshots/d0/clef_mlx.py", "serve"],
                             environment: ["__CFBundleIdentifier": "com.anthropic.claudefordesktop", "CLAUDECODE": "1",
                                           "CLAUDE_CODE_SESSION_ID": "s1", "PWD": "/Users/me/Dev/watslog",
                                           "_": "/Users/me/Dev/watslog/node_modules/.bin/tauri", "XPC_SERVICE_NAME": "0"])
        let attribution = attributor([worker]).attribute(worker)
        XCTAssertEqual(attribution.summary, "Claude › Claude Code « Révision du design » › tauri")
        XCTAssertEqual(attribution.certainty, .probable)
        XCTAssertTrue(attribution.isOrphan)
    }

    func testLaunchdJobIsNotAnOrphan() {
        let job = process(5, "python3", "/opt/python3", parent: 1, environment: ["XPC_SERVICE_NAME": "dev.me.embeddings"])
        let attribution = attributor([job]).attribute(job)
        XCTAssertEqual(attribution.launchdLabel, "dev.me.embeddings")
        XCTAssertFalse(attribution.isOrphan)
        XCTAssertEqual(attribution.certainty, .certain)
    }

    func testResponsibleAppWhenParentIsGone() {
        let app = process(9, "MLXCore", "/Applications/MLX-Serve.app/Contents/MacOS/MLXCore", parent: 1)
        let server = process(12, "mlx-serve", "/Applications/MLX-Serve.app/Contents/MacOS/mlx-serve", parent: 1, responsible: 9)
        XCTAssertEqual(attributor([app, server]).attribute(server).summary, "MLX-Serve")
    }

    func testServersThisAppStartedStayItsOwn() {
        let start = Date(timeIntervalSince1970: 1_000)
        let server = RunningProcess(pid: 77, name: "Python", executablePath: "/p", arguments: ["Python", "-m", "mtplx.server.openai"],
                                    footprintBytes: 1, parentPID: 1, startedAt: start, responsiblePID: 77)
        let entry = LaunchedServer(pid: 77, startedAt: start, engine: .mtplx, model: "a/b", port: 18100, context: nil, logPath: "/l", arguments: [])
        let attribution = LaunchAttributor(processes: [server], launched: [entry]) { _ in (nil, nil) }.attribute(server)
        XCTAssertEqual(attribution.summary, "LLMarium")
        XCTAssertFalse(attribution.isOrphan)
        var reused = server
        reused.startedAt = Date(timeIntervalSince1970: 9_000)
        XCTAssertNotEqual(LaunchAttributor(processes: [reused], launched: [entry]) { _ in (nil, nil) }.attribute(reused).summary, "LLMarium",
                          "a reused PID is not this app's server")
    }

    func testAgentsThatRetitleThemselves() {
        let pi = process(5, "node", "/fnm/bin/node", parent: 1, arguments: ["pi"])
        XCTAssertEqual(attributor([pi]).step(for: pi)?.title, "Pi")
    }

    func testModelHints() {
        func hint(_ arguments: [String]) -> String? {
            RunningProcess(pid: 1, name: "python", executablePath: "/p", arguments: arguments, footprintBytes: 0).modelHint
        }
        XCTAssertEqual(hint(["python", "/h/models--mlx-community--clef-4bit/snapshots/x/run.py"]), "mlx-community/clef-4bit")
        XCTAssertEqual(hint(["mlx-serve", "--model", "/Users/me/.mlx-serve/models/ddalcu/Qwen"]), "ddalcu/Qwen")
        XCTAssertEqual(hint(["llama-server", "-m", "/models/Winnow-12B-Q8_0.gguf"]), "Winnow-12B-Q8_0.gguf")
        XCTAssertEqual(hint(["server", "--model", "qwen3"]), "qwen3")
        XCTAssertNil(hint(["python", "server.py"]))
    }
}

final class ComfyUITests: XCTestCase {
    func testModelFilesOfAWanWorkflow() {
        let workflow: [String: Any] = [
            "37": ["class_type": "UNETLoader", "inputs": ["unet_name": "wan2.2_ti2v_5B_fp16.safetensors", "weight_dtype": "default"]],
            "38": ["class_type": "CLIPLoader", "inputs": ["clip_name": "umt5_xxl_fp16.safetensors", "type": "wan"]],
            "39": ["class_type": "VAELoader", "inputs": ["vae_name": "wan2.2_vae.safetensors"]],
            "6": ["class_type": "CLIPTextEncode", "inputs": ["text": "a cat", "clip": ["38", 0]]],
            "40": ["class_type": "LoraLoader", "inputs": ["lora_name": "styles/ink.safetensors"]],
            "41": ["class_type": "UNETLoader", "inputs": ["unet_name": "wan2.2_ti2v_5B_fp16.safetensors"]]
        ]
        XCTAssertEqual(ComfyUIProbe.modelFiles(in: workflow),
                       ["wan2.2_ti2v_5B_fp16.safetensors", "umt5_xxl_fp16.safetensors", "wan2.2_vae.safetensors", "ink.safetensors"])
        XCTAssertEqual(ComfyUIProbe.modelFiles(in: "not a workflow"), [])
    }

    func testActivity() {
        XCTAssertEqual(ComfyUIState(runningJobs: 0, pendingJobs: 0, models: [], modelsFromHistory: false).activity, "Inactif")
        XCTAssertEqual(ComfyUIState(runningJobs: 1, pendingJobs: 2, models: [], modelsFromHistory: false).activity,
                       "Génération en cours · 2 en attente")
    }

    func testHomebrewPythonServerIsAModelWorker() {
        let server = RunningProcess(pid: 10549, name: "Python", executablePath: "/opt/homebrew/Cellar/python@3.12/Python",
                                    arguments: ["Python", "main.py", "--port", "8188"], footprintBytes: 35 << 30)
        XCTAssertEqual(server.role, .modelWorker)
    }
}

final class StopTests: XCTestCase {
    private func spawn(_ script: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()
        Thread.sleep(forTimeInterval: 0.3)
        return process
    }

    func testStopsAProcessThatAcceptsTheRequest() async throws {
        let child = try spawn("exec sleep 30")
        let started = ProcessScanner.bsdInfo(of: child.processIdentifier)?.startedAt
        let result = await ModelActions.stop(pid: child.processIdentifier, startedAt: started)
        XCTAssertEqual(result, .stopped)
    }

    func testRefusesWhenThePIDNoLongerMatches() async throws {
        let child = try spawn("exec sleep 30")
        defer { child.terminate() }
        let result = await ModelActions.stop(pid: child.processIdentifier, startedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(result, .processChanged)
        XCTAssertTrue(child.isRunning, "nothing may be sent to a process that is not the one the user chose")
    }

    func testOffersForceWhenTheRequestIsIgnored() async throws {
        let child = try spawn("trap '' TERM; while true; do sleep 0.1; done")
        let pid = child.processIdentifier
        let started = ProcessScanner.bsdInfo(of: pid)?.startedAt
        let polite = await ModelActions.stop(pid: pid, startedAt: started, timeout: 1)
        XCTAssertEqual(polite, .stillRunning)
        let forced = await ModelActions.stop(pid: pid, startedAt: started, force: true)
        XCTAssertEqual(forced, .stopped)
    }
}
