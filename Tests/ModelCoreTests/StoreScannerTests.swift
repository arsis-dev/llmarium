import Foundation
import XCTest
@testable import ModelCore

final class StoreScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "lml-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testHuggingFaceSnapshotCountsSharedBlobOnce() throws {
        let entry = root.appending(path: "hub/models--acme--tiny-4bit")
        try write(String(repeating: "x", count: 100_000), to: entry.appending(path: "blobs/abc"))
        try write(config(layers: 2), to: entry.appending(path: "blobs/cfg"))
        try write("rev1", to: entry.appending(path: "refs/main"))
        let snapshot = entry.appending(path: "snapshots/rev1")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try link(snapshot.appending(path: "a.safetensors"), to: "../../blobs/abc")
        try link(snapshot.appending(path: "b.safetensors"), to: "../../blobs/abc")
        try link(snapshot.appending(path: "config.json"), to: "../../blobs/cfg")

        let scan = StoreScanner.scan(ModelStore(kind: .huggingFace, path: root.appending(path: "hub").path))
        let model = try XCTUnwrap(scan.models.first)
        XCTAssertEqual(model.name, "acme/tiny-4bit")
        XCTAssertEqual(model.format, .mlx)
        XCTAssertEqual(model.spec?.layers, 2)
        let blobs = allocated(entry.appending(path: "blobs/abc")) + allocated(entry.appending(path: "blobs/cfg"))
        XCTAssertEqual(model.sizeBytes, blobs)
    }

    func testHuggingFaceEntryWithoutSnapshotIsEmptyAndRootBlobsAreIgnored() throws {
        try FileManager.default.createDirectory(at: root.appending(path: "hub/models--acme--gone/refs"), withIntermediateDirectories: true)
        try write("chunk", to: root.appending(path: "hub/blobs/06/chunk"))
        try FileManager.default.createDirectory(at: root.appending(path: "hub/owner/partial/.cache"), withIntermediateDirectories: true)

        let scan = StoreScanner.scan(ModelStore(kind: .huggingFace, path: root.appending(path: "hub").path))
        XCTAssertTrue(scan.models.isEmpty)
        XCTAssertEqual(scan.emptyEntries.map(\.name), ["acme/gone", "owner/partial"])
        XCTAssertGreaterThan(scan.totalBytes, 0, "the shared blobs still count in the folder total")
    }

    func testNestedStoreWithLinks() throws {
        let store = root.appending(path: "omlx")
        try write(config(layers: 4), to: store.appending(path: "Owner/Model/config.json"))
        try write(config(layers: 4), to: root.appending(path: "elsewhere/Real/config.json"))
        try FileManager.default.createDirectory(at: root.appending(path: "elsewhere/Empty"), withIntermediateDirectories: true)
        try link(store.appending(path: "linked"), to: root.appending(path: "elsewhere/Real").path)
        try link(store.appending(path: "missing"), to: root.appending(path: "elsewhere/Nothing").path)
        try link(store.appending(path: "hollow"), to: root.appending(path: "elsewhere/Empty").path)

        let scan = StoreScanner.scan(ModelStore(kind: .omlx, path: store.path))
        let byName = Dictionary(uniqueKeysWithValues: scan.models.map { ($0.name, $0) })
        XCTAssertEqual(Set(byName.keys), ["Owner/Model", "linked", "missing", "hollow"])
        XCTAssertFalse(byName["Owner/Model"]!.isLink)
        XCTAssertEqual(byName["linked"]?.isBrokenLink, false)
        XCTAssertNotNil(byName["linked"]?.linkTarget)
        XCTAssertEqual(byName["missing"]?.brokenReason, "cible absente")
        XCTAssertEqual(byName["hollow"]?.brokenReason, "cible sans poids ni config.json")
        XCTAssertLessThan(scan.totalBytes, byName["Owner/Model"]!.sizeBytes + byName["linked"]!.sizeBytes,
                          "links are not followed for the folder total")
    }

    func testMTPLXFolderNamesBecomeOwnerAndName() throws {
        try write(config(layers: 2), to: root.appending(path: "mtplx/Youssofal--Qwen3.5-4B--Speed/config.json"))
        let scan = StoreScanner.scan(ModelStore(kind: .mtplx, path: root.appending(path: "mtplx").path))
        XCTAssertEqual(scan.models.map(\.name), ["Youssofal/Qwen3.5-4B--Speed"])
    }

    func testMissingStore() {
        let scan = StoreScanner.scan(ModelStore(kind: .mlxServe, path: root.appending(path: "absent").path))
        XCTAssertFalse(scan.exists)
        XCTAssertTrue(scan.models.isEmpty)
    }

    func testArchitectureGroupsSkipLinksPartialSpecsAndEncoders() throws {
        func model(_ name: String, _ spec: ModelSpec?, link: String? = nil) -> LocalModel {
            var model = LocalModel(name: name, store: .huggingFace, path: "/\(name)")
            model.spec = spec
            model.linkTarget = link
            model.sizeBytes = 10
            return model
        }
        var llm = ModelSpec()
        llm.modelType = "qwen4_exp"
        llm.architectures = ["Qwen4ExpForConditionalGeneration"]
        llm.layers = 48; llm.hiddenSize = 2560; llm.vocabSize = 248_320; llm.kvHeads = 2
        var encoder = ModelSpec()
        encoder.modelType = "bert"
        encoder.architectures = ["BertModel"]
        encoder.layers = 6; encoder.hiddenSize = 384; encoder.vocabSize = 30_522
        var partial = ModelSpec()
        partial.modelType = "minimax_h3"
        partial.architectures = ["MiniMaxForCausalLM"]

        let groups = DiskReport.groups([
            model("a", llm), model("b", llm), model("link", llm, link: "/a"),
            model("e1", encoder), model("e2", encoder), model("p1", partial), model("p2", partial)
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].modelIDs, ["huggingFace:a", "huggingFace:b"])
        XCTAssertEqual(groups[0].totalBytes, 20)
    }

    // MARK: - Helpers

    private func config(layers: Int) -> String {
        """
        {"model_type": "qwen3_5", "architectures": ["Qwen3_5ForConditionalGeneration"],
         "quantization": {"bits": 4, "group_size": 64},
         "text_config": {"num_hidden_layers": \(layers), "hidden_size": 256, "vocab_size": 1000, "max_position_embeddings": 4096}}
        """
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func link(_ url: URL, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
    }

    private func allocated(_ url: URL) -> Int64 {
        var info = stat()
        stat(url.path, &info)
        return Int64(info.st_blocks) * 512
    }
}
