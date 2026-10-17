import Foundation
import XCTest
@testable import ModelCore

final class QuickLaunchTests: XCTestCase {
    func testPinnedFirstThenRecentWithoutModelsInMemory() {
        let pinned = model("acme/pinned-mtplx", .mtplx)
        let recent = model("acme/recent-serve", .mlxServe)
        let running = model("acme/running-mtplx", .mtplx)
        let omlxOnly = model("acme/omlx-model", .omlx)
        let start = Date(timeIntervalSince1970: 1_000_000)
        let state = QuickLaunchState(pinned: [pinned.id], history: [
            LaunchHistoryEntry(modelID: running.id, engine: .mtplx, context: 32_768, launchedAt: start.addingTimeInterval(300)),
            LaunchHistoryEntry(modelID: omlxOnly.id, engine: .omlx, context: nil, launchedAt: start.addingTimeInterval(200)),
            LaunchHistoryEntry(modelID: recent.id, engine: .mlxServe, context: 16_384, launchedAt: start.addingTimeInterval(100)),
            LaunchHistoryEntry(modelID: "mtplx:acme/deleted", engine: .mtplx, context: nil, launchedAt: start)
        ])
        let server = RunningModel(pid: 3, role: .mtplx, models: [LaunchPlan.servedName(running)], processDescription: "MTPLX", ports: [18100],
                                  footprintBytes: 1 << 30, startedAt: nil, launcher: LaunchAttribution(), clients: [])
        let items = QuickLaunch.items(state: state, snapshot: snapshot([pinned, recent, running, omlxOnly], running: [server]))

        XCTAssertEqual(items.map(\.model.name), ["acme/pinned-mtplx", "acme/recent-serve"],
                       "pinned first; in memory, oMLX not running and deleted models left out")
        XCTAssertTrue(items[0].pinned)
        XCTAssertEqual(items[0].engine, .mtplx)
        XCTAssertEqual(items[1].engine, .mlxServe)
        XCTAssertEqual(items[1].context, 16_384, "the context of the last launch")
    }

    func testPinnedModelWithoutEngineStaysWithItsReason() {
        let omlxOnly = model("acme/omlx-model", .omlx)
        let items = QuickLaunch.items(state: QuickLaunchState(pinned: [omlxOnly.id]), snapshot: snapshot([omlxOnly], running: []))
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items[0].engine)
        XCTAssertEqual(items[0].unavailable, "oMLX n'est pas lancé.")
    }

    func testRecentListIsCappedButPinnedAreNot() {
        let models = (0..<8).map { model("acme/m\($0)", .mtplx) }
        let history = models.enumerated().map { index, item in
            LaunchHistoryEntry(modelID: item.id, engine: .mtplx, context: nil, launchedAt: Date(timeIntervalSince1970: Double(1_000 - index)))
        }
        let pinned = models.suffix(6).map(\.id)
        let items = QuickLaunch.items(state: QuickLaunchState(pinned: pinned, history: history), snapshot: snapshot(models, running: []))
        XCTAssertEqual(items.count, 6, "six pinned models all stay, the recent ones fill no extra place")
        XCTAssertEqual(items.map(\.model.name), models.suffix(6).map(\.name))
    }

    func testStoreKeepsOneEntryPerModelAndEngineNewestFirst() {
        let store = QuickLaunchStore(file: FileManager.default.temporaryDirectory.appending(path: "quick-\(UUID()).json"))
        store.record(modelID: "mtplx:a", engine: .mtplx, context: 8_192, at: Date(timeIntervalSince1970: 1))
        store.record(modelID: "mtplx:b", engine: .mtplx, context: nil, at: Date(timeIntervalSince1970: 2))
        store.record(modelID: "mtplx:a", engine: .mtplx, context: 65_536, at: Date(timeIntervalSince1970: 3))
        store.setPinned("mtplx:b", true)
        store.setPinned("mtplx:b", true)
        let state = store.state()
        XCTAssertEqual(state.history.map(\.modelID), ["mtplx:a", "mtplx:b"])
        XCTAssertEqual(state.history.first?.context, 65_536)
        XCTAssertEqual(state.pinned, ["mtplx:b"])
        store.setPinned("mtplx:b", false)
        XCTAssertEqual(store.state().pinned, [])
    }

    // MARK: - Helpers

    private func model(_ name: String, _ store: StoreKind) -> LocalModel {
        var model = LocalModel(name: name, store: store, path: "/nonexistent/\(name)")
        model.sizeBytes = 2 << 30
        return model
    }

    private func snapshot(_ models: [LocalModel], running: [RunningModel]) -> InventorySnapshot {
        let engines = [EngineKind.omlx, .mtplx, .mlxServe].map {
            EngineStatus(installation: EngineInstallation(kind: $0, version: "1", location: "/usr/local/bin/x"), instances: [], omlx: nil)
        }
        return InventorySnapshot(takenAt: Date(), machine: MachineInfo(chip: "Apple M5 Max", memoryBytes: 128 << 30, systemVersion: "26", gpu: nil),
                                 engines: engines, running: running, models: models,
                                 disk: DiskReport(volumeAvailableBytes: nil, volumeTotalBytes: nil, stores: [], architectureGroups: [],
                                                  brokenLinkIDs: [], emptyCacheEntries: []),
                                 memory: MemoryReport(stats: MemoryStats(totalBytes: 128 << 30, freeBytes: 0, wiredBytes: 0, compressedBytes: 0,
                                                                         appBytes: 0, cachedFilesBytes: 0, freePercent: nil, pressure: .normal),
                                                      groups: []))
    }
}
