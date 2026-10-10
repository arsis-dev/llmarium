import Foundation
import XCTest
@testable import ModelCore

final class RadarFilterTests: XCTestCase {
    private let limit = RadarFilter.memoryLimit(totalBytes: 128 << 30)

    private func evaluate(_ candidate: RadarCandidate, local: Set<String> = [], bases: [String: String] = [:]) -> Result<RadarItem, RadarExclusion> {
        RadarFilter.evaluate(candidate, memoryLimit: limit, localIDs: local, localBases: bases, now: Date(timeIntervalSince1970: 2_000_000_000))
    }

    private func reason(_ result: Result<RadarItem, RadarExclusion>) -> String? {
        if case .failure(let exclusion) = result { return exclusion.reason }
        return nil
    }

    func testEachExclusionSaysWhy() {
        let mlx = RadarCandidate(id: "a/llm", pipelineTag: "text-generation", libraryName: "mlx", sizeBytes: 10 << 30)
        XCTAssertEqual(reason(evaluate(mlx, local: ["a/llm"])), "Déjà sur ce Mac")
        XCTAssertTrue(reason(evaluate(RadarCandidate(id: "a/q", pipelineTag: "text-generation", libraryName: "gguf", tags: ["gguf"])))?.hasPrefix("GGUF") == true)
        XCTAssertEqual(reason(evaluate(RadarCandidate(id: "a/t", pipelineTag: "text-generation", libraryName: "transformers"))), "Pas au format MLX")
        XCTAssertEqual(reason(evaluate(RadarCandidate(id: "a/tts", pipelineTag: "text-to-speech", libraryName: "mlx"))), "Pas un modèle de langage (text-to-speech)")
        XCTAssertTrue(reason(evaluate(RadarCandidate(id: "a/big", pipelineTag: "text-generation", libraryName: "mlx", sizeBytes: 125 << 30)))?.hasPrefix("Trop gros") == true)
        XCTAssertNil(reason(evaluate(mlx)))
    }

    func testRepositoriesWithoutPipelineAreJudgedByArchitecture() {
        let causal = RadarCandidate(id: "a/x", libraryName: "mlx", sizeBytes: 1 << 30, architectures: ["Qwen3ForCausalLM"])
        let classifier = RadarCandidate(id: "a/y", libraryName: "mlx", sizeBytes: 1 << 30, architectures: ["Qwen3ForSequenceClassification"])
        XCTAssertNil(reason(evaluate(causal)))
        XCTAssertNotNil(reason(evaluate(classifier)))
        XCTAssertEqual(reason(evaluate(RadarCandidate(id: "a/z", libraryName: "mlx"))), "Nature du modèle inconnue (ni étiquette ni architecture)")
    }

    func testReasonsAndRelatedLocalModel() throws {
        var candidate = RadarCandidate(id: "mlx-community/Qwen3.8-27B-4bit", createdAt: Date(timeIntervalSince1970: 2_000_000_000 - 3 * 86_400),
                                       pipelineTag: "image-text-to-text", libraryName: "mlx",
                                       tags: ["mlx", "base_model:quantized:Qwen/Qwen3.8-27B"], gated: true, sizeBytes: 16 << 30)
        candidate.sources = [.author("mlx-community"), .spicilege(nil)]
        let item = try evaluate(candidate, bases: ["qwen/qwen3.8-27b": "Youssofal/Qwen3.8-27B-MTPLX"]).get()
        XCTAssertEqual(item.reasons, ["Nouveau chez mlx-community (il y a 3 jours)", "Dans vos favoris Spicilege",
                                      "Même modèle de base (Qwen/Qwen3.8-27B) que Youssofal/Qwen3.8-27B-MTPLX, que vous avez"])
        XCTAssertEqual(item.warnings, ["Accès soumis à acceptation sur Hugging Face"])
        XCTAssertEqual(candidate.baseModels, ["Qwen/Qwen3.8-27B"])
    }

    func testAdaptersAreExcludedAndVariantsFlagged() throws {
        var adapter = RadarCandidate(id: "mohit67890/imajev-4b", libraryName: "mlx", tags: ["mlx", "base_model:adapter:Qwen/Qwen3.5-4B"],
                                     sizeBytes: 487_648_432, architectures: [])
        XCTAssertTrue(reason(evaluate(adapter))?.hasPrefix("Adaptateur LoRA") == true)
        adapter.tags = ["mlx"]
        adapter.weightFiles = ["mlx/adapters.safetensors", "adapter_config.json"]
        XCTAssertTrue(reason(evaluate(adapter))?.hasPrefix("Adaptateur LoRA") == true, "seen from the files too")

        XCTAssertTrue(RadarCandidate.hasSeveralVariants(["m-Q4_K_M.gguf", "m-Q8_0.gguf", "mmproj-F16.gguf"]))
        XCTAssertFalse(RadarCandidate.hasSeveralVariants(["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors", "config.json"]))
        XCTAssertTrue(RadarCandidate.hasSeveralVariants(["4bit/config.json", "8bit/config.json"]))
        var several = RadarCandidate(id: "a/b", pipelineTag: "text-generation", libraryName: "mlx", sizeBytes: 1 << 30)
        several.multipleVariants = true
        XCTAssertTrue(try evaluate(several).get().warnings.contains { $0.hasPrefix("Plusieurs variantes") })
    }

    func testEngineGuesses() {
        XCTAssertEqual(RadarFilter.engines(for: "Youssofal/X-MTPLX-Optimized-Speed"), [.mtplx])
        XCTAssertEqual(RadarFilter.engines(for: "Jundot/clef-oQ4e"), [.omlx])
        XCTAssertEqual(RadarFilter.engines(for: "ddalcu/Qwen-MLX-Serve-8bit"), [.mlxServe])
        XCTAssertEqual(RadarFilter.engines(for: "mlx-community/Qwen3.8-27B-4bit"), [.omlx, .mlxServe])
    }

    func testReadmeBaseModels() {
        XCTAssertEqual(RadarFilter.readmeBaseModels("---\nlicense: mit\nbase_model: Qwen/Qwen3.5-4B\ntags: [mlx]\n---\n# x"), ["Qwen/Qwen3.5-4B"])
        XCTAssertEqual(RadarFilter.readmeBaseModels("---\nbase_model:\n- Qwen/A\n- 'Qwen/B'\npipeline_tag: x\n---"), ["Qwen/A", "Qwen/B"])
        XCTAssertEqual(RadarFilter.readmeBaseModels("# no front matter\nbase_model: x"), [])
    }
}

final class RadarSourceTests: XCTestCase {
    func testSpicilegeLinksKeepOnlyModelPages() {
        XCTAssertEqual(Spicilege.modelID(fromURL: "https://huggingface.co/ukisai/Swift1.5-Qwen3.8-Flash-Next"), "ukisai/Swift1.5-Qwen3.8-Flash-Next")
        XCTAssertEqual(Spicilege.modelID(fromURL: "https://huggingface.co/a/b/tree/main"), "a/b")
        XCTAssertNil(Spicilege.modelID(fromURL: "https://huggingface.co/datasets/XiaomiMiMo/MiMo-V2.6-RL-oss"))
        XCTAssertNil(Spicilege.modelID(fromURL: "https://huggingface.co/collections/JetBrains/qwen38-36-27b-blend"))
        XCTAssertNil(Spicilege.modelID(fromURL: "https://huggingface.co/FluidInference"), "an organisation page")
        XCTAssertNil(Spicilege.modelID(fromURL: "https://huggingface.co/spaces/a/b"))
        XCTAssertNil(Spicilege.modelID(fromURL: "https://example.com/a/b"))
    }

    func testCandidateFromHubRow() throws {
        let row: [String: Any] = ["id": "mlx-community/X", "createdAt": "2026-10-07T12:00:00.000Z", "pipeline_tag": "text-generation",
                                  "library_name": "mlx", "likes": 5, "downloads": 10, "trendingScore": 3, "gated": "auto", "tags": ["mlx"]]
        let candidate = try XCTUnwrap(HubAPI.candidate(row))
        XCTAssertTrue(candidate.gated)
        XCTAssertNotNil(candidate.createdAt)
        XCTAssertTrue(candidate.isMLX)
    }

    func testReportStaleness() {
        XCTAssertFalse(RadarReport(fetchedAt: Date(), items: [], excluded: [], sources: []).isStale)
        XCTAssertTrue(RadarReport(fetchedAt: Date().addingTimeInterval(-25 * 3600), items: [], excluded: [], sources: []).isStale)
    }
}

final class RadarDownloadTests: XCTestCase {
    func testOneCommandPerEngine() {
        let home = URL(fileURLWithPath: "/Users/me test")
        XCTAssertEqual(RadarDownload.plan(repo: "a/b", engine: .omlx, sizeBytes: 1, home: home).command.arguments, ["hf", "download", "a/b"])
        let mtplx = RadarDownload.plan(repo: "Youssofal/X", engine: .mtplx, sizeBytes: 1, home: home)
        XCTAssertEqual(mtplx.command.arguments, ["hf", "download", "Youssofal/X", "--local-dir", "/Users/me test/.mtplx/models/Youssofal--X"])
        XCTAssertEqual(RadarDownload.plan(repo: "a/b", engine: .mlxServe, sizeBytes: 1, home: home, mlxServe: "/m").command.arguments, ["/m", "pull", "a/b"])
    }

    func testDiskCheckKeepsATenPercentMargin() {
        XCTAssertNil(RadarDownload.diskRefusal(sizeBytes: 10_000_000_000, freeBytes: 11_000_000_000))
        XCTAssertNotNil(RadarDownload.diskRefusal(sizeBytes: 10_000_000_000, freeBytes: 10_500_000_000))
        XCTAssertNotNil(RadarDownload.diskRefusal(sizeBytes: nil, freeBytes: 1))
    }
}
