import Foundation

/// One successful launch, kept so the menu bar can offer it again.
public struct LaunchHistoryEntry: Codable, Hashable, Sendable {
    /// `LocalModel.id`: the store and the name, stable across scans.
    public var modelID: String
    public var engine: EngineKind
    public var context: Int?
    public var launchedAt: Date
}

/// Models pinned to the menu bar and the latest launches, newest first.
public struct QuickLaunchState: Codable, Equatable, Sendable {
    public var pinned: [String] = []
    public var history: [LaunchHistoryEntry] = []

    public init(pinned: [String] = [], history: [LaunchHistoryEntry] = []) {
        self.pinned = pinned
        self.history = history
    }
}

public final class QuickLaunchStore: @unchecked Sendable {
    public static let shared = QuickLaunchStore(file: AppPaths.support.appending(path: "quick-launch.json"))
    static let historyLimit = 50

    private let file: URL
    private let lock = NSLock()

    public init(file: URL) { self.file = file }

    public func state() -> QuickLaunchState { lock.withLock { read() } }

    /// Recorded by every start that succeeds, from the app, the CLI or the MCP server.
    public func record(modelID: String, engine: EngineKind, context: Int?, at date: Date = Date()) {
        update { state in
            state.history.removeAll { $0.modelID == modelID && $0.engine == engine }
            state.history.insert(LaunchHistoryEntry(modelID: modelID, engine: engine, context: context, launchedAt: date), at: 0)
            state.history = Array(state.history.prefix(Self.historyLimit))
        }
    }

    public func setPinned(_ modelID: String, _ pinned: Bool) {
        update { state in
            state.pinned.removeAll { $0 == modelID }
            if pinned { state.pinned.append(modelID) }
        }
    }

    private func update(_ change: (inout QuickLaunchState) -> Void) {
        lock.withLock {
            var state = read()
            change(&state)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try? encoder.encode(state).write(to: file, options: .atomic)
        }
    }

    private func read() -> QuickLaunchState {
        guard let data = try? Data(contentsOf: file) else { return QuickLaunchState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(QuickLaunchState.self, from: data)) ?? QuickLaunchState()
    }
}

/// A model the menu bar offers to launch in one click, with the engine and context of its last launch.
public struct QuickLaunchItem: Hashable, Sendable, Identifiable {
    public var model: LocalModel
    public var engine: EngineKind?
    public var context: Int?
    public var pinned: Bool
    /// Why it cannot be launched now (pinned models stay listed): « oMLX n'est pas lancé »…
    public var unavailable: String?

    public var id: String { model.id }
}

public enum QuickLaunch {
    /// Pinned models first, in the order they were pinned, then the latest launches, up to `limit` (pinned ones
    /// are never cut). Models already in memory are left out: they show under « En mémoire ».
    public static func items(state: QuickLaunchState, snapshot: InventorySnapshot, limit: Int = 5) -> [QuickLaunchItem] {
        var ids: [String] = []
        for id in state.pinned + state.history.map(\.modelID) where !ids.contains(id) { ids.append(id) }
        var items: [QuickLaunchItem] = []
        for id in ids {
            let pinned = state.pinned.contains(id)
            guard pinned || items.count < limit, let model = snapshot.model(id: id), !isInMemory(model, snapshot: snapshot) else { continue }
            let engines = EngineCompatibility.engines(for: model, snapshot: snapshot)
            let last = state.history.first { $0.modelID == id && engines.contains($0.engine) }
            guard let engine = last?.engine ?? engines.first else {
                // A recent launch whose engine is gone is dropped; a pinned model stays, with the reason.
                if pinned {
                    let previous = state.history.first { $0.modelID == id }?.engine ?? defaultEngine(for: model)
                    items.append(QuickLaunchItem(model: model, engine: nil, context: nil, pinned: true,
                                                 unavailable: EngineCompatibility.absenceReason(previous, model: model, snapshot: snapshot)))
                }
                continue
            }
            let context = engine == .omlx ? nil : (last?.context ?? RecipeDeriver.effective(model: model, engine: engine).context)
            items.append(QuickLaunchItem(model: model, engine: engine, context: context, pinned: pinned, unavailable: nil))
        }
        return items
    }

    public static func isInMemory(_ model: LocalModel, snapshot: InventorySnapshot) -> Bool {
        let served = LaunchPlan.servedName(model)
        if snapshot.running.contains(where: { $0.role.engine != .omlx && ($0.models.contains(model.name) || $0.models.contains(served)) }) { return true }
        return snapshot.engine(.omlx)?.omlx?.models.contains { $0.loaded && OMLXIdentity.matches($0.id, model) } ?? false
    }

    static func defaultEngine(for model: LocalModel) -> EngineKind {
        switch model.store {
        case .mtplx: .mtplx
        case .mlxServe: .mlxServe
        case .omlx, .huggingFace: .omlx
        }
    }
}
