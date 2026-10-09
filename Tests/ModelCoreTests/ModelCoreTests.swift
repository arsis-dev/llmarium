import Foundation
import XCTest
@testable import ModelCore

final class ModelSpecTests: XCTestCase {
    func testReadsTextConfigAndCountsFullAttentionLayers() throws {
        let json = """
        {"model_type": "qwen4_exp", "architectures": ["Qwen4ExpForConditionalGeneration"],
         "quantization": {"bits": 4, "group_size": 64, "mode": "affine"},
         "text_config": {"num_hidden_layers": 4, "hidden_size": 2560, "num_key_value_heads": 2, "head_dim": 256,
                         "max_position_embeddings": 262144, "vocab_size": 248320,
                         "layer_types": ["linear_attention", "linear_attention", "linear_attention", "full_attention"]}}
        """
        let spec = try XCTUnwrap(ModelSpec.parse(Data(json.utf8)))
        XCTAssertEqual(spec.layers, 4)
        XCTAssertEqual(spec.kvHeads, 2)
        XCTAssertEqual(spec.headDim, 256)
        XCTAssertEqual(spec.maxContext, 262_144)
        XCTAssertEqual(spec.fullAttentionLayers, 1)
        XCTAssertEqual(spec.quantBits, 4)
        XCTAssertTrue(spec.hasMLXQuantization)
        XCTAssertEqual(spec.kind, .languageModel)
        XCTAssertFalse(spec.isPartial)
        XCTAssertEqual(spec.architectureSignature, "qwen4_exp|4|2560|2|248320")
    }

    func testUnknownLayoutGivesPartialSpecWithoutSignature() throws {
        let spec = try XCTUnwrap(ModelSpec.parse(Data(#"{"model_type": "minimax_h3", "quantization_config": {"bits": 8}}"#.utf8)))
        XCTAssertTrue(spec.isPartial)
        XCTAssertNil(spec.architectureSignature)
        XCTAssertEqual(spec.quantBits, 8)
        XCTAssertFalse(spec.hasMLXQuantization)
        XCTAssertEqual(spec.kind, .other)
        XCTAssertNil(ModelSpec.parse(Data("not json".utf8)))
    }
}

final class ProcessTests: XCTestCase {
    private func process(_ path: String, _ arguments: [String], name: String = "python3.13", footprint: Int64 = 100 << 20) -> RunningProcess {
        RunningProcess(pid: 42, name: name, executablePath: path, arguments: arguments, footprintBytes: footprint)
    }

    func testRolesOfEnginesWorkersAndApps() {
        XCTAssertEqual(process("/opt/python3.11", ["omlx-server"], name: "python3.11").role, .omlx)
        XCTAssertEqual(process("/Applications/oMLX.app/Contents/MacOS/oMLX", []).role, .omlx)
        XCTAssertEqual(process("/opt/homebrew/Python", ["Python", "-P", "-m", "mtplx.server.openai", "--"]).role, .mtplx)
        XCTAssertEqual(process("/Applications/MLX-Serve.app/Contents/MacOS/mlx-serve", ["mlx-serve", "--serve"]).role, .mlxServe)
        let worker = process("/Users/me/Library/Application Support/watslog-lab/venv-mlx/bin/python",
                             ["python", "/Users/me/.cache/huggingface/hub/models--mlx-community--clef-4bit/snapshots/d0/clef_mlx.py", "serve"])
        XCTAssertEqual(worker.role, .modelWorker)
        XCTAssertEqual(worker.workerDescription, "watslog-lab · clef_mlx.py · mlx-community/clef-4bit")
        XCTAssertEqual(process("/x/.venv/bin/python", ["python", "server.py"], footprint: 3 << 30).role, .modelWorker)
        let helper = process("/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper", [])
        XCTAssertEqual(helper.role, .application)
        XCTAssertEqual(helper.appName, "Claude")
    }

    func testGroupsAppsAndEnginesButKeepsWorkersApart() {
        var app1 = process("/Applications/Brave Browser.app/Contents/MacOS/Brave", [], footprint: 300)
        app1.pid = 1
        var app2 = process("/Applications/Brave Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper", [], footprint: 200)
        app2.pid = 2
        var worker1 = process("/w/.venv/bin/python", ["python", "/m/models--a--b/x.py"], footprint: 50)
        worker1.pid = 3
        var worker2 = worker1
        worker2.pid = 4
        let groups = ProcessGroup.group([app1, app2, worker1, worker2])
        XCTAssertEqual(groups.first?.title, "Brave Browser")
        XCTAssertEqual(groups.first?.footprintBytes, 500)
        XCTAssertEqual(groups.filter { $0.role == .modelWorker }.count, 2)
    }

    func testParsesKernProcArgsAndKeepsOnlyHarmlessEnvironment() {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(2).littleEndian) { bytes += $0 }
        bytes += Array("/usr/bin/python3".utf8) + [0, 0, 0]
        for text in ["omlx-server", "--port", "PWD=/Users/me/project", "CLAUDE_CODE_MESSAGING_TOKEN=secret",
                     "CLAUDE_CODE_USER_EMAIL=me@example.com", "CLAUDE_CODE_SESSION_ID=abc", "executable_path=/usr/bin/python3"] {
            bytes += Array(text.utf8) + [0]
        }
        let parsed = ArgumentReader.parse(bytes[...])
        XCTAssertEqual(parsed.arguments, ["omlx-server", "--port"])
        XCTAssertEqual(parsed.environment, ["PWD": "/Users/me/project", "CLAUDE_CODE_SESSION_ID": "abc"])
    }

    func testPortTableSeparatesListenersFromClients() {
        let output = """
        p16221
        f6
        n127.0.0.1:8020
        TST=LISTEN
        f7
        n127.0.0.1:8020->127.0.0.1:52000
        TST=ESTABLISHED
        p700
        f9
        n127.0.0.1:52000->127.0.0.1:8020
        TST=ESTABLISHED
        f10
        n192.168.1.4:52001->17.1.1.1:443
        TST=ESTABLISHED
        p900
        f3
        n*:4000
        TST=LISTEN
        f4
        n[::1]:4000
        TST=LISTEN
        """
        let table = PortTable.parse(output)
        XCTAssertEqual(table.listening, [16221: [8020], 900: [4000]])
        XCTAssertEqual(table.clients, [8020: [700]])
    }
}

final class FormatTests: XCTestCase {
    func testFrenchUnits() {
        XCTAssertEqual(Format.bytes(106_000_000_000), "106 Go")
        XCTAssertEqual(Format.bytes(2_600_000_000), "2,6 Go")
        XCTAssertEqual(Format.memory(128 << 30), "128 Go")
        XCTAssertEqual(Format.memory(512 << 20), "512 Mo")
        XCTAssertEqual(Format.tokens(262_144), "256K")
        XCTAssertEqual(Format.tokens(40_960), "40K")
    }

    func testOMLXStatusParsing() throws {
        let json = """
        {"final_ceiling": 100, "current_model_memory": 78,
         "models": [{"id": "q", "loaded": true, "is_loading": false, "estimated_size": 111, "resident_estimated_size": 78,
                     "last_access": 1791281870.45, "max_context_window": 262144},
                    {"id": "e", "loaded": false, "last_access": null}]}
        """
        let state = try XCTUnwrap(OMLXState.parse(Data(json.utf8)))
        XCTAssertEqual(state.ceilingBytes, 100)
        XCTAssertEqual(state.models.map(\.id), ["q", "e"])
        XCTAssertEqual(state.models[0].residentBytes, 78)
        XCTAssertNotNil(state.models[0].lastAccess)
        XCTAssertNil(state.models[1].lastAccess)
    }
}
