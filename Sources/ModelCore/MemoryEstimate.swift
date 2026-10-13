import Foundation

/// Something the user could unload or quit to make room: a running model first, then a large app.
public struct FreeCandidate: Codable, Hashable, Sendable {
    public var title: String
    public var bytes: Int64
    public var detail: String?
    /// Set for a running model: the « En cours » section offers to unload or stop it.
    public var runningPID: Int32?
}

/// How much memory a model would take on an engine, against what that engine can use now. An estimate:
/// the weights come from the disk (or from oMLX's own measure), the cache from the architecture.
public struct MemoryEstimate: Codable, Sendable {
    public enum Verdict: String, Codable, Sendable { case fits, tight, tooLarge }

    public var weightsBytes: Int64
    /// Set when the weights figure is a real measure rather than the folder size.
    public var weightsMeasurement: Measurement?
    /// Nil when the architecture is not described well enough to size the cache.
    public var kvBytesPerToken: Int64?
    public var context: Int
    public var kvCacheBytes: Int64
    public var overheadBytes: Int64
    public var availableBytes: Int64
    /// Where the available figure comes from, in French.
    public var availableBasis: String
    /// What the GPU may still take: macOS's limit for the GPU minus the models already in memory.
    public var gpuAvailableBytes: Int64?
    public var gpuLimitBytes: Int64?
    public var gpuLimitSource: String?
    public var verdict: Verdict
    public var toFree: [FreeCandidate]
    public var notes: [String]
    /// Generation speed, measured or bounded; set by the snapshot-based estimate.
    public var speed: SpeedEstimate?

    public var totalBytes: Int64 { weightsBytes + kvCacheBytes + overheadBytes }
    public var shortfallBytes: Int64 { max(0, totalBytes - availableBytes, gpuAvailableBytes.map { totalBytes - $0 } ?? 0) }
    /// The GPU limit, not the free memory, is what stops this model.
    public var limitedByGPU: Bool { gpuAvailableBytes.map { totalBytes > $0 && $0 < availableBytes } ?? false }
}

public enum MemoryPlanner {
    /// Bytes of K and V cache per token: two tensors per attention layer, fp16. Hybrid models keep a full cache
    /// only in their full-attention layers. Checked against oMLX on 6 October: for Qwen3.8-Flash-Next it reported
    /// « KV+SDPA 3.70 GB » for a ~97K-token prompt; this formula gives 2.4 GB, the rest being attention scratch.
    public static func kvBytesPerToken(_ spec: ModelSpec?) -> Int64? {
        guard let spec, let layers = spec.fullAttentionLayers ?? spec.layers, let kvHeads = spec.kvHeads else { return nil }
        // Without `head_dim`, the usual split of the hidden size across attention heads.
        guard let headDim = spec.headDim ?? spec.hiddenSize.flatMap({ hidden in spec.attentionHeads.map { hidden / max($0, 1) } }) else { return nil }
        return Int64(2 * layers * kvHeads * headDim * 2)
    }

    /// The free room macOS keeps for itself, as mlx-serve sizes it: an eighth of RAM, between 2 and 8 Go.
    public static func systemReserve(totalBytes: Int64) -> Int64 {
        min(max(totalBytes / 8, 2 << 30), 8 << 30)
    }

    /// Memory and speed from an inventory snapshot, as the app, the CLI and the MCP server show them.
    public static func estimate(model: LocalModel, engine: EngineKind, context: Int?, snapshot: InventorySnapshot,
                                benchmarks: [BenchmarkResult] = BenchmarkStore.shared.all()) -> MemoryEstimate {
        var estimate = estimate(model: model, engine: engine, context: context, memory: snapshot.memory,
                                omlx: snapshot.engine(.omlx)?.omlx, running: snapshot.running, gpu: snapshot.machine.gpu)
        estimate.speed = SpeedPlanner.estimate(model: model, engine: engine, weightsBytes: estimate.weightsBytes, machine: snapshot.machine,
                                               models: snapshot.models, benchmarks: benchmarks)
        return estimate
    }

    public static func estimate(model: LocalModel, engine: EngineKind, context requested: Int?,
                                memory: MemoryReport, omlx: OMLXState?, running: [RunningModel],
                                gpu: GPUInfo? = .current, measurements: MeasurementStore = .shared) -> MemoryEstimate {
        var notes: [String] = []
        var weights = model.sizeBytes
        var measurement: Measurement?
        // oMLX names models by folder (`Qwen3.8-Flash-Next-oQ4e-mtp`, `owner--name`): its measures are kept under that name.
        let omlxState = engine == .omlx ? omlx?.models.first(where: { OMLXIdentity.matches($0.id, model) }) : nil
        if let actual = omlxState?.actualBytes, actual > 0 {
            measurement = Measurement(bytes: actual, measuredAt: Date(), source: "oMLX")
        } else {
            measurement = measurements.measurement(engine: engine, model: omlxState?.id ?? model.name)
        }
        if let measurement { weights = measurement.bytes }
        else { notes.append("Taille sur disque : la mémoire réellement prise est souvent plus faible. Elle sera mesurée au premier chargement.") }
        let maxContext = model.spec?.maxContext ?? 32_768
        let context = min(requested ?? min(maxContext, 65_536), maxContext)
        let perToken = kvBytesPerToken(model.spec)
        if perToken == nil { notes.append("Architecture incomplète : le cache de contexte n'est pas estimé.") }
        let kv = (perToken ?? 0) * Int64(context)
        let overhead = Int64(1 << 30) + weights / 20

        let stats = memory.stats
        let available: Int64
        let basis: String
        if engine == .omlx, let ceiling = omlx?.ceilingBytes {
            available = ceiling - (omlx?.loadedBytes ?? 0)
            basis = "Plafond actuel d'oMLX (\(Format.memory(ceiling))) moins ses modèles chargés"
            notes.append("oMLX réserve le cache au fil des requêtes : le contexte complet est un maximum.")
        } else {
            let reserve = systemReserve(totalBytes: stats.totalBytes)
            available = stats.totalBytes - stats.usedBytes - reserve
            basis = "Mémoire non utilisée par les apps, moins \(Format.memory(reserve)) laissés à macOS"
        }
        let total = weights + kv + overhead
        // Every model in memory counts against the GPU limit, whichever engine holds it.
        let gpuAvailable = gpu?.limitBytes.map { $0 - running.reduce(0) { $0 + $1.footprintBytes } }
        let room = min(available, gpuAvailable ?? available)
        let verdict: MemoryEstimate.Verdict = total > room ? .tooLarge : (room - total < total / 10 ? .tight : .fits)
        if let gpuAvailable, total > gpuAvailable, gpuAvailable < available {
            notes.append("macOS ne laisse au GPU que \(Format.memory(gpu?.limitBytes ?? 0)) (\(gpu?.limitSource ?? "plafond de macOS")) : avec les modèles déjà en mémoire, il reste \(Format.memory(max(0, gpuAvailable))).")
        }

        var candidates = running.map { item in
            FreeCandidate(title: item.title, bytes: item.footprintBytes,
                          detail: "\(item.role.title) · lancé par \(item.launcher.summary)", runningPID: item.pid)
        }
        let runningPIDs = Set(running.map(\.pid))
        candidates += memory.groups
            .filter { $0.role == .application && $0.footprintBytes >= 2 << 30 && runningPIDs.isDisjoint(with: $0.pids) }
            .map { FreeCandidate(title: $0.title, bytes: $0.footprintBytes, detail: "Application", runningPID: nil) }

        return MemoryEstimate(weightsBytes: weights, weightsMeasurement: measurement, kvBytesPerToken: perToken, context: context,
                              kvCacheBytes: kv, overheadBytes: overhead, availableBytes: available, availableBasis: basis,
                              gpuAvailableBytes: gpuAvailable, gpuLimitBytes: gpu?.limitBytes, gpuLimitSource: gpu?.limitSource,
                              verdict: verdict, toFree: candidates.sorted { $0.bytes > $1.bytes }, notes: notes)
    }
}

/// oMLX names a model after its folder: the leaf for nested ones, `owner--name` for the Hugging Face cache.
public enum OMLXIdentity {
    public static func matches(_ id: String, _ model: LocalModel) -> Bool {
        let leaf = model.name.split(separator: "/").last.map(String.init) ?? model.name
        return id == model.name || id == leaf || id == model.name.replacingOccurrences(of: "/", with: "--")
    }
}

/// Memory a model really took once loaded, kept between runs: oMLX forgets its measure when it unloads a model,
/// and a folder on disk can be much larger than what an engine keeps in memory.
public struct Measurement: Codable, Hashable, Sendable {
    public var bytes: Int64
    public var measuredAt: Date
    /// « oMLX » or « processus » (footprint of a server this app started).
    public var source: String
}

public final class MeasurementStore: @unchecked Sendable {
    public static let shared = MeasurementStore(file: AppPaths.support.appending(path: "measurements.json"))

    private let file: URL
    private let lock = NSLock()

    public init(file: URL) { self.file = file }

    public static func key(engine: EngineKind, model: String) -> String { "\(engine.rawValue):\(model)" }

    public func measurement(engine: EngineKind, model: String) -> Measurement? {
        lock.lock()
        defer { lock.unlock() }
        return read()[Self.key(engine: engine, model: model)]
    }

    /// Keeps the latest value; ignores tiny ones (a server that has not loaded its weights yet).
    public func record(_ bytes: Int64, engine: EngineKind, model: String, source: String) {
        guard bytes > 256 << 20 else { return }
        lock.lock()
        defer { lock.unlock() }
        var all = read()
        let key = Self.key(engine: engine, model: model)
        if let existing = all[key], abs(existing.bytes - bytes) < existing.bytes / 50,
           Date().timeIntervalSince(existing.measuredAt) < 86_400 { return }
        all[key] = Measurement(bytes: bytes, measuredAt: Date(), source: source)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(all).write(to: file, options: .atomic)
    }

    private func read() -> [String: Measurement] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Measurement].self, from: data)) ?? [:]
    }
}
