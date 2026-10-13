import Foundation
import XCTest
@testable import ModelCore

/// GPU limit, speed bound, radar usages and the trash plan.
final class Step7Tests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "llmarium-step7-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - GPU limit

    func testGPULimitStopsAModelThatFreeMemoryWouldAllow() {
        let store = MeasurementStore(file: root.appending(path: "m.json"))
        var model = LocalModel(name: "acme/big", store: .mlxServe, path: "/x")
        model.sizeBytes = 40 << 30
        let running = RunningModel(pid: 7, role: .modelWorker, models: ["other"], processDescription: "other", ports: [],
                                   footprintBytes: 30 << 30, startedAt: nil, launcher: LaunchAttribution(), clients: [])
        let gpu = GPUInfo(limitBytes: 64 << 30, limitSource: "valeur par défaut de macOS", coreCount: 40)
        let estimate = MemoryPlanner.estimate(model: model, engine: .mlxServe, context: nil, memory: memory(used: 30 << 30),
                                              omlx: nil, running: [running], gpu: gpu, measurements: store)
        XCTAssertGreaterThan(estimate.availableBytes, estimate.totalBytes, "free RAM alone would allow it")
        XCTAssertEqual(estimate.gpuAvailableBytes, 34 << 30, "the GPU limit minus the models already in memory")
        XCTAssertEqual(estimate.verdict, .tooLarge)
        XCTAssertTrue(estimate.limitedByGPU)
        XCTAssertEqual(estimate.shortfallBytes, estimate.totalBytes - (34 << 30))
        XCTAssertTrue(estimate.notes.contains { $0.contains("GPU") })
    }

    // MARK: - Speed

    func testBandwidthNeedsTheGPUSizeForMaxChips() {
        XCTAssertEqual(ChipBandwidth.gigabytesPerSecond(chip: "Apple M5 Max", gpuCores: 40), 614)
        XCTAssertEqual(ChipBandwidth.gigabytesPerSecond(chip: "Apple M5 Max", gpuCores: 32), 460)
        XCTAssertNil(ChipBandwidth.gigabytesPerSecond(chip: "Apple M5 Max", gpuCores: nil), "no guess between two sizes")
        XCTAssertEqual(ChipBandwidth.gigabytesPerSecond(chip: "Apple M4 Pro", gpuCores: nil), 273)
        XCTAssertEqual(ChipBandwidth.gigabytesPerSecond(chip: "Apple M2", gpuCores: 10), 100)
        XCTAssertNil(ChipBandwidth.gigabytesPerSecond(chip: "Intel Core i9", gpuCores: nil))
    }

    func testActiveShareOfAMixtureOfExpertsFromItsConfig() throws {
        // Qwen3.8-Flash-Next as found on this Mac on 10 October 2026.
        let config = #"""
        {"model_type": "qwen3_next", "architectures": ["Qwen3NextForCausalLM"], "num_hidden_layers": 48, "hidden_size": 2560,
         "num_attention_heads": 16, "num_key_value_heads": 2, "head_dim": 256, "vocab_size": 248320,
         "num_experts": 512, "num_experts_per_tok": 10, "moe_intermediate_size": 640,
         "shared_expert_intermediate_size": 640, "tie_word_embeddings": false}
        """#
        let spec = try XCTUnwrap(ModelSpec.parse(Data(config.utf8)))
        XCTAssertEqual(spec.experts, 512)
        XCTAssertEqual(spec.expertsPerToken, 10)
        let (share, basis) = SpeedPlanner.activeShare(spec: spec, name: "Qwen3.8-Flash-Next")
        XCTAssertEqual(share, 0.04, accuracy: 0.015, "about 5B of about 125B parameters")
        XCTAssertEqual(basis, "10 experts sur 512 par token")
    }

    func testActiveShareFromTheNameOrDense() {
        XCTAssertEqual(SpeedPlanner.activeShare(spec: nil, name: "mlx-community/Qwen3-30B-A3B-4bit").share, 0.1, accuracy: 1e-9)
        XCTAssertEqual(SpeedPlanner.activeShare(spec: nil, name: "acme/Dense-27B").basis, "dense supposé")
        var spec = ModelSpec()
        spec.layers = 64
        XCTAssertEqual(SpeedPlanner.activeShare(spec: spec, name: "acme/Dense-27B").basis, "dense")
    }

    func testMeasureReplacesTheBoundAndUndisturbedRunsCalibrateIt() {
        let bound = SpeedPlanner.estimate(name: "acme/Dense", weightsBytes: 20_000_000_000, spec: nil, bandwidth: 600, measured: nil)
        XCTAssertEqual(bound?.kind, .bound)
        XCTAssertEqual(bound?.tokensPerSecond ?? 0, 30, accuracy: 1e-9)
        XCTAssertNil(bound?.expectedTokensPerSecond)

        let calibrated = SpeedPlanner.estimate(name: "acme/Dense", weightsBytes: 20_000_000_000, spec: nil, bandwidth: 600, measured: nil,
                                               calibration: [(measured: 40, bound: 80), (measured: 30, bound: 50), (measured: 10, bound: 50)])
        XCTAssertEqual(calibrated?.expectedTokensPerSecond ?? 0, 15, accuracy: 1e-9, "median share of the bound reached here (0.5)")

        let run = BenchmarkRun(kind: "court", promptTokens: 24, completionTokens: 100, tokensEstimated: false, timeToFirstToken: 0.2,
                               prefillTokensPerSecond: nil, decodeTokensPerSecond: 21.5, totalSeconds: 5, reasoningObserved: false,
                               succeeded: true, note: nil)
        let result = BenchmarkResult(id: "1", date: Date(), engine: .mtplx, engineVersion: nil, model: "Dense", machine: "Apple M5 Max · 128 Go",
                                     context: nil, recipeID: nil, peakMemoryBytes: nil, loadSeconds: nil, runs: [run],
                                     conditions: ["oMLX traitait 1 requête"])
        let measured = SpeedPlanner.estimate(name: "acme/Dense", weightsBytes: 20_000_000_000, spec: nil, bandwidth: 600, measured: result)
        XCTAssertEqual(measured?.kind, .measured)
        XCTAssertEqual(measured?.tokensPerSecond, 21.5)
        XCTAssertEqual(measured?.disturbed, true)
        XCTAssertTrue(measured?.summary.contains("perturbée") == true)
    }

    // MARK: - Radar usages

    func testUsagesComeWithTheirClue() {
        let coder = ModelUsage.classify(name: "Qwen3-Coder-30B-A3B-Instruct-4bit", tags: [], pipelineTag: "text-generation")
        XCTAssertEqual(coder.map(\.usage), [.code, .chat])
        XCTAssertEqual(coder.first?.clue, "d'après le nom (« coder »)")

        let vision = ModelUsage.classify(name: "Qwen3.8-27B-4bit", tags: [], pipelineTag: "image-text-to-text")
        XCTAssertEqual(vision.map(\.usage), [.vision])
        XCTAssertEqual(vision.first?.clue, "étiquette Hugging Face image-text-to-text")

        XCTAssertEqual(ModelUsage.classify(name: "DeepSeek-R1-Distill-8B", tags: [], pipelineTag: nil).map(\.usage), [.reasoning])
        XCTAssertEqual(ModelUsage.classify(name: "gemma-3-12b-it-4bit", tags: [], pipelineTag: nil).map(\.usage), [.chat])
        XCTAssertEqual(ModelUsage.classify(name: "Qwen3.5-4B-Base", tags: [], pipelineTag: nil), [], "a base model is not for chat")
        XCTAssertTrue(ModelUsage.classify(name: "unicode-tools-7B", tags: [], pipelineTag: nil).allSatisfy { $0.usage != .code },
                      "words, not substrings")
    }

    func testOldModelsLoseScoreAndSayWhy() throws {
        let now = Date()
        var fresh = RadarCandidate(id: "acme/Fresh-4bit", createdAt: now.addingTimeInterval(-10 * 86_400), pipelineTag: "text-generation",
                                   libraryName: "mlx", sizeBytes: 1 << 30, sources: [.trending])
        fresh.trendingScore = 0
        var old = fresh
        old.id = "acme/Old-4bit"
        old.createdAt = now.addingTimeInterval(-18 * 30 * 86_400)
        func evaluate(_ candidate: RadarCandidate) throws -> RadarItem {
            try RadarFilter.evaluate(candidate, memoryLimit: 64 << 30, localIDs: [], localBases: [:], now: now).get()
        }
        let freshItem = try evaluate(fresh)
        let oldItem = try evaluate(old)
        XCTAssertEqual(freshItem.score - oldItem.score, 2, accuracy: 1e-9, "one point per six months past the first six")
        XCTAssertTrue(oldItem.warnings.contains { $0.hasPrefix("Publié il y a 18 mois") })
        XCTAssertEqual(freshItem.usages?.map(\.usage), [.chat])
    }

    // MARK: - Trash

    func testHuggingFaceModelGoesWithItsWholeRepository() throws {
        let repo = root.appending(path: "hub/models--acme--tiny")
        try write(String(repeating: "x", count: 200_000), to: repo.appending(path: "blobs/abc"))
        try write("{}", to: repo.appending(path: "blobs/cfg"))
        for revision in ["r1", "r2"] {
            let snapshot = repo.appending(path: "snapshots/\(revision)")
            try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
            try link(snapshot.appending(path: "model.safetensors"), to: "../../blobs/abc")
            try link(snapshot.appending(path: "config.json"), to: "../../blobs/cfg")
        }
        let elsewhere = root.appending(path: "omlx/tiny")
        try link(elsewhere, to: repo.appending(path: "snapshots/r1").path)

        var model = LocalModel(name: "acme/tiny", store: .huggingFace, path: repo.appending(path: "snapshots/r1").path)
        model.sizeBytes = 200_000
        var linked = LocalModel(name: "tiny", store: .omlx, path: elsewhere.path)
        linked.linkTarget = repo.appending(path: "snapshots/r1").path

        let plan = try ModelTrash.plan(model, models: [model, linked], running: [], omlx: nil).get()
        XCTAssertEqual(plan.items, [repo.path], "the snapshot alone would free nothing")
        XCTAssertGreaterThanOrEqual(plan.freedBytes, 200_000)
        XCTAssertTrue(plan.warnings.contains { $0.contains("2 révisions") })
        XCTAssertTrue(plan.warnings.contains { $0.contains("liens cassés") && $0.contains("tiny (oMLX)") })
    }

    func testALinkOnlyRemovesTheLink() throws {
        var model = LocalModel(name: "tiny", store: .omlx, path: root.appending(path: "link").path)
        model.linkTarget = "/elsewhere/tiny"
        let plan = try ModelTrash.plan(model, models: [model], running: [], omlx: nil).get()
        XCTAssertEqual(plan.items, [model.path])
        XCTAssertEqual(plan.freedBytes, 0)
        XCTAssertTrue(plan.warnings.first?.contains("seul le lien part") == true)
    }

    func testAModelInMemoryIsRefused() throws {
        let folder = root.appending(path: "mtplx/acme--tiny")
        try write("{}", to: folder.appending(path: "config.json"))
        let model = LocalModel(name: "acme/tiny", store: .mtplx, path: folder.path)
        let running = RunningModel(pid: 9, role: .mtplx, models: [LaunchPlan.servedName(model)], processDescription: "MTPLX", ports: [18100],
                                   footprintBytes: 1 << 30, startedAt: nil, launcher: LaunchAttribution(), clients: [])
        guard case .failure(let refusal) = ModelTrash.plan(model, models: [model], running: [running], omlx: nil) else {
            return XCTFail("a served model must not be trashed")
        }
        XCTAssertTrue(refusal.description.contains("PID 9"))

        let omlx = OMLXState(ceilingBytes: nil, loadedBytes: nil, models: [
            OMLXModelState(id: "acme--tiny", loaded: true, isLoading: false, actualBytes: nil)
        ])
        XCTAssertThrowsError(try ModelTrash.plan(model, models: [model], running: [], omlx: omlx).get())
    }

    // MARK: - Idle stop

    func testIdleServerStopsAfterItsLimitAndActivityResetsTheClock() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var server = LaunchedServer(pid: 5, startedAt: start, engine: .mtplx, model: "acme/tiny", port: 18100, context: nil,
                                    logPath: "/dev/null", arguments: [], loadSeconds: 10, idleStopAfterMinutes: 30)
        func check(_ cpu: Double?, clients: Bool = false, at minutes: Double) -> Bool {
            let result = IdlePolicy.check(server, cpuSeconds: cpu, hasClients: clients, now: start.addingTimeInterval(minutes * 60))
            server = result.server
            return result.stop
        }
        XCTAssertFalse(check(12, at: 1), "first check sets the baseline")
        XCTAssertFalse(check(12.12, at: 20), "MTPLX's idle CPU is not activity")
        XCTAssertTrue(check(12.24, at: 31))
        XCTAssertFalse(check(14, at: 32), "a request resets the clock")
        XCTAssertFalse(check(14, clients: true, at: 70), "a connected client counts as activity")
        XCTAssertTrue(check(14, at: 101))

        var logged = server
        logged.lastLogBytes = 1_000
        let short = IdlePolicy.check(logged, cpuSeconds: 14.13, logBytes: 1_400, hasClients: false, now: start.addingTimeInterval(200 * 60))
        XCTAssertFalse(short.stop, "a short request uses little CPU but writes to the log")
        XCTAssertEqual(short.server.lastLogBytes, 1_400)

        var slept = server
        slept.lastCheckedAt = start.addingTimeInterval(200 * 60)
        slept.lastCPUSeconds = 14
        let afterSleep = IdlePolicy.check(slept, cpuSeconds: 14 + 0.12 * 60, hasClients: false, now: start.addingTimeInterval(260 * 60))
        XCTAssertEqual(afterSleep.server.lastActiveAt, slept.lastActiveAt, "an hour of idle CPU after a sleep is not activity")

        var mlxServe = server
        mlxServe.engine = .mlxServe
        mlxServe.lastCheckedAt = start.addingTimeInterval(300 * 60)
        mlxServe.lastCPUSeconds = 20
        let request = IdlePolicy.check(mlxServe, cpuSeconds: 20.1, hasClients: false, now: start.addingTimeInterval(301 * 60))
        XCTAssertEqual(request.server.lastActiveAt, start.addingTimeInterval(301 * 60), "mlx-serve idles at zero CPU: a small request counts")

        var unlimited = server
        unlimited.idleStopAfterMinutes = nil
        XCTAssertFalse(IdlePolicy.check(unlimited, cpuSeconds: 14, hasClients: false, now: start.addingTimeInterval(86_400)).stop)
        XCTAssertFalse(IdlePolicy.check(server, cpuSeconds: nil, hasClients: false, now: start.addingTimeInterval(86_400)).stop,
                       "a process that cannot be read is never stopped")
    }

    // MARK: - Helpers

    private func memory(used: Int64) -> MemoryReport {
        MemoryReport(stats: MemoryStats(totalBytes: 128 << 30, freeBytes: 0, wiredBytes: 0, compressedBytes: 0, appBytes: used,
                                        cachedFilesBytes: 0, freePercent: nil, pressure: .normal), groups: [])
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func link(_ url: URL, to destination: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
    }
}
