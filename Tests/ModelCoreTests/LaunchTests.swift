import Darwin
import Foundation
import XCTest
@testable import ModelCore

final class MemoryEstimateTests: XCTestCase {
    private func qwenFlashNext(store: StoreKind = .mlxServe, size: Int64 = 100 << 30) -> LocalModel {
        var spec = ModelSpec()
        spec.modelType = "qwen4_exp"
        spec.architectures = ["Qwen4ExpForConditionalGeneration"]
        spec.layers = 48
        spec.fullAttentionLayers = 12
        spec.kvHeads = 2
        spec.headDim = 256
        spec.hiddenSize = 2560
        spec.maxContext = 262_144
        var model = LocalModel(name: "ddalcu/Qwen3.8-Flash-Next", store: store, path: "/m/Qwen3.8 Flash Next")
        model.spec = spec
        model.sizeBytes = size
        return model
    }

    private func memory(total: Int64 = 128 << 30, used: Int64) -> MemoryReport {
        let stats = MemoryStats(totalBytes: total, freeBytes: 0, wiredBytes: 0, compressedBytes: 0, appBytes: used,
                                cachedFilesBytes: 0, freePercent: nil, pressure: .normal)
        return MemoryReport(stats: stats, groups: [
            ProcessGroup(id: "app-OrbStack", title: "OrbStack", role: .application, detail: nil, pids: [9], footprintBytes: 7 << 30),
            ProcessGroup(id: "app-Mail", title: "Mail", role: .application, detail: nil, pids: [8], footprintBytes: 300 << 20)
        ])
    }

    func testKVCacheCountsOnlyFullAttentionLayers() {
        // 2 tensors × 12 layers × 2 heads × 256 dims × 2 bytes. On 6 October oMLX reported « KV+SDPA 3.70 GB »
        // for a ~97K-token prompt on this model: the cache alone is 2.4 GB of it.
        XCTAssertEqual(MemoryPlanner.kvBytesPerToken(qwenFlashNext().spec), 24_576)
        var dense = ModelSpec()
        dense.layers = 32; dense.hiddenSize = 4096; dense.attentionHeads = 32; dense.kvHeads = 8
        XCTAssertEqual(MemoryPlanner.kvBytesPerToken(dense), 2 * 32 * 8 * 128 * 2, "head size falls back to hidden / heads")
        XCTAssertNil(MemoryPlanner.kvBytesPerToken(ModelSpec()))
    }

    func testVerdictAndWhatToFree() {
        let store = MeasurementStore(file: FileManager.default.temporaryDirectory.appending(path: "m-\(UUID()).json"))
        let running = RunningModel(pid: 42, role: .modelWorker, models: ["clef-4bit"], processDescription: "clef_mlx.py", ports: [8732],
                                   footprintBytes: 43 << 30, startedAt: nil, launcher: LaunchAttribution(), clients: [])
        let estimate = MemoryPlanner.estimate(model: qwenFlashNext(), engine: .mlxServe, context: 131_072,
                                              memory: memory(used: 60 << 30), omlx: nil, running: [running], measurements: store)
        XCTAssertEqual(estimate.kvCacheBytes, 24_576 * 131_072)
        XCTAssertEqual(estimate.availableBytes, (128 << 30) - (60 << 30) - (8 << 30), "an eighth of RAM, capped at 8 Go, stays with macOS")
        XCTAssertEqual(estimate.verdict, .tooLarge)
        XCTAssertEqual(estimate.toFree.map(\.title), ["clef-4bit", "OrbStack"], "running models and apps of 2 Go or more, largest first")
        XCTAssertEqual(estimate.toFree.first?.runningPID, 42)

        store.record(70 << 30, engine: .mlxServe, model: "ddalcu/Qwen3.8-Flash-Next", source: "processus")
        let measured = MemoryPlanner.estimate(model: qwenFlashNext(), engine: .mlxServe, context: 32_768,
                                              memory: memory(used: 20 << 30), omlx: nil, running: [], measurements: store)
        XCTAssertEqual(measured.weightsBytes, 70 << 30, "a real measure replaces the folder size")
        XCTAssertEqual(measured.verdict, .fits)
    }

    func testOMLXCeilingIsTheAvailableMemory() {
        let omlx = OMLXState(ceilingBytes: 97 << 30, loadedBytes: 10 << 30, models: [
            OMLXModelState(id: "Qwen3.8-Flash-Next", loaded: false, isLoading: false, estimatedBytes: nil, residentBytes: nil,
                           actualBytes: 73 << 30, lastAccess: nil, maxContext: nil)
        ])
        let estimate = MemoryPlanner.estimate(model: qwenFlashNext(store: .omlx), engine: .omlx, context: nil,
                                              memory: memory(used: 20 << 30), omlx: omlx, running: [])
        XCTAssertEqual(estimate.availableBytes, 87 << 30)
        XCTAssertEqual(estimate.weightsBytes, 73 << 30)
        XCTAssertEqual(estimate.context, 65_536, "default context is capped at 64K")
    }

    func testOMLXMeasureIsFoundAfterUnloadUnderOMLXName() {
        let store = MeasurementStore(file: FileManager.default.temporaryDirectory.appending(path: "m-\(UUID()).json"))
        store.record(73 << 30, engine: .omlx, model: "Qwen3.8-Flash-Next", source: "oMLX")
        let unloaded = OMLXState(ceilingBytes: 97 << 30, loadedBytes: 0, models: [
            OMLXModelState(id: "Qwen3.8-Flash-Next", loaded: false, isLoading: false, estimatedBytes: 111 << 30, residentBytes: 111 << 30,
                           actualBytes: nil, lastAccess: nil, maxContext: nil)
        ])
        var model = qwenFlashNext(store: .omlx, size: 104 << 30)
        model.name = "Jundot/Qwen3.8-Flash-Next"
        let estimate = MemoryPlanner.estimate(model: model, engine: .omlx, context: nil, memory: memory(used: 20 << 30),
                                              omlx: unloaded, running: [], measurements: store)
        XCTAssertEqual(estimate.weightsBytes, 73 << 30)
        XCTAssertNotNil(estimate.weightsMeasurement)
    }
}

final class LaunchPlanTests: XCTestCase {
    private func model(_ name: String, store: StoreKind, path: String) -> LocalModel {
        LocalModel(name: name, store: store, path: path)
    }

    func testMTPLXCommandListensOnLocalhostOnly() throws {
        let plan = try LaunchPlan.make(model: model("Youssofal/Qwen3.5-4B", store: .mtplx, path: "/x"), engine: .mtplx, port: 18_100,
                                       context: 65_536, installation: EngineInstallation(kind: .mtplx, version: "2.11.3", location: "/bin/mtplx"))
        XCTAssertEqual(plan.arguments, ["serve", "--model", "Youssofal/Qwen3.5-4B", "--host", "127.0.0.1", "--port", "18100", "--no-auth",
                                        "--model-id", "Qwen3.5-4B", "--yes", "--context-window", "65536"])
    }

    func testMLXServePathWithSpacesStaysOneArgument() throws {
        let path = "/Users/me/My Models/Qwen 3"
        let plan = try LaunchPlan.make(model: model("ddalcu/Qwen 3", store: .mlxServe, path: path), engine: .mlxServe, port: 18_101,
                                       context: nil, installation: EngineInstallation(kind: .mlxServe, version: nil, location: "/a/mlx-serve"))
        XCTAssertEqual(plan.arguments, ["--model", path, "--serve", "--host", "127.0.0.1", "--port", "18101"])
    }

    func testRefusesOtherStoresAndBrokenLinks() {
        let installation = EngineInstallation(kind: .mtplx, version: nil, location: "/bin/mtplx")
        XCTAssertThrowsError(try LaunchPlan.make(model: model("a/b", store: .huggingFace, path: "/x"), engine: .mtplx, port: 1,
                                                 context: nil, installation: installation))
        var broken = model("a/b", store: .mtplx, path: "/x")
        broken.isBrokenLink = true
        XCTAssertThrowsError(try LaunchPlan.make(model: broken, engine: .mtplx, port: 1, context: nil, installation: installation))
        XCTAssertThrowsError(try LaunchPlan.make(model: model("a/b", store: .mtplx, path: "/x"), engine: .mtplx, port: 1, context: nil,
                                                 installation: EngineInstallation(kind: .mtplx, version: nil, location: nil)))
    }

    func testFreePortSkipsUsedAndBoundPorts() throws {
        let holder = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(holder) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let first = try XCTUnwrap(ModelLauncher.freePort())
        address.sin_port = in_port_t(UInt16(first).bigEndian)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(holder, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        let next = try XCTUnwrap(ModelLauncher.freePort(excluding: [first + 1]))
        XCTAssertNotEqual(next, first)
        XCTAssertNotEqual(next, first + 1)
        XCTAssertTrue(ModelLauncher.portRange.contains(next))
    }

    func testSpawnedServerStopsOnARequestEvenFromAConcurrencyThread() async throws {
        // On 8 October an MTPLX server started this way ignored SIGTERM: it inherited the spawning thread's signal state.
        let log = FileManager.default.temporaryDirectory.appending(path: "spawn-\(UUID()).log").path
        let pid = try await Task.detached { try ModelLauncher.spawn("/bin/sleep", ["30"], log: log) }.value
        try await Task.sleep(for: .milliseconds(200))
        kill(pid, SIGTERM)
        var exited = false
        for _ in 0..<20 where !exited {
            try await Task.sleep(for: .milliseconds(100))
            exited = waitpid(pid, nil, WNOHANG) == pid
        }
        if !exited { kill(pid, SIGKILL); waitpid(pid, nil, 0) }
        XCTAssertTrue(exited)
    }

    func testRegistryForgetsServersThatAreGone() {
        let registry = LaunchRegistry(file: FileManager.default.temporaryDirectory.appending(path: "r-\(UUID()).json"))
        let alive = LaunchedServer(pid: 1, startedAt: Date(), engine: .mtplx, model: "a", port: 18_100, context: nil, logPath: "/l", arguments: [])
        var gone = alive
        gone.pid = 2
        registry.add(alive)
        registry.add(gone)
        registry.reconcile { $0.pid == 1 }
        XCTAssertEqual(registry.servers().map(\.pid), [1])
    }

    func testResolverPrefersExactThenUniquePartial() {
        let models = [model("Youssofal/Qwen3.5-4B-MTPLX", store: .mtplx, path: "/a"), model("Youssofal/Qwen3.8-27B-MTPLX", store: .mtplx, path: "/b")]
        XCTAssertEqual(try ModelResolver.find("Qwen3.8-27B-MTPLX", in: models).get().path, "/b")
        XCTAssertEqual(try ModelResolver.find("3.5-4b", in: models).get().path, "/a")
        XCTAssertThrowsError(try ModelResolver.find("MTPLX", in: models).get())
        XCTAssertThrowsError(try ModelResolver.find("gemma", in: models).get())
    }
}
