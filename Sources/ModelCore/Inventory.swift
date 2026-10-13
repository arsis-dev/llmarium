import Foundation

public struct MachineInfo: Codable, Sendable {
    public var chip: String
    public var memoryBytes: Int64
    public var systemVersion: String
    public var gpu: GPUInfo?

    public static func current() -> MachineInfo {
        MachineInfo(chip: sysctlString("machdep.cpu.brand_string") ?? "Mac",
                    memoryBytes: Int64(sysctlInt("hw.memsize") ?? 0),
                    systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    gpu: .current)
    }

    /// Memory bandwidth in GB/s, when the chip is known.
    public var bandwidth: Double? { ChipBandwidth.gigabytesPerSecond(chip: chip, gpuCores: gpu?.coreCount) }
}

/// Everything the inventory knows at one moment. Read-only: taking it never starts, loads or deletes anything.
public struct InventorySnapshot: Codable, Sendable {
    public var takenAt: Date
    public var machine: MachineInfo
    public var engines: [EngineStatus]
    /// Processes holding a model in memory now, with who started them.
    public var running: [RunningModel]
    public var models: [LocalModel]
    public var disk: DiskReport
    public var memory: MemoryReport

    public func engine(_ kind: EngineKind) -> EngineStatus? { engines.first { $0.kind == kind } }
    public func model(id: String) -> LocalModel? { models.first { $0.id == id } }
}

public enum Inventory {
    public static func take(stores: [ModelStore] = ModelStore.standard()) async -> InventorySnapshot {
        async let scans = Task.detached(priority: .userInitiated) { stores.map(StoreScanner.scan) }.value
        let runtime = await Runtime.current()
        let storeScans = await scans
        return InventorySnapshot(takenAt: Date(), machine: .current(), engines: runtime.engines, running: runtime.running,
                                 models: storeScans.flatMap(\.models), disk: .make(scans: storeScans),
                                 memory: runtime.memory)
    }

    /// Engines and memory only, cheap enough to refresh often.
    public static func refreshRuntime(_ snapshot: InventorySnapshot) async -> InventorySnapshot {
        var updated = snapshot
        let runtime = await Runtime.current()
        updated.engines = runtime.engines
        updated.running = runtime.running
        updated.memory = runtime.memory
        updated.takenAt = Date()
        return updated
    }
}

/// What is running now: engines, models in memory and memory use, from one reading of processes and ports.
public struct Runtime: Sendable {
    public var engines: [EngineStatus]
    public var running: [RunningModel]
    public var memory: MemoryReport

    public static func current() async -> Runtime {
        LaunchRegistry.shared.reconcile()
        let processes = ProcessScanner.all()
        let ports = PortTable.current()
        let engines = await EngineDetector.detect(processes: processes, ports: ports)
        // Model servers outside the engines that answer like ComfyUI say which models their jobs load.
        var comfyUI: [Int32: ComfyUIState] = [:]
        for process in processes where process.role == .modelWorker {
            if let port = ports.listening[process.pid]?.first, let state = await ComfyUIProbe.probe(port: port) {
                comfyUI[process.pid] = state
            }
        }
        recordMeasurements(engines: engines, processes: processes)
        return Runtime(engines: engines,
                       running: RunningModelDetector.detect(processes: processes, engines: engines, ports: ports, comfyUI: comfyUI),
                       memory: .current(processes: processes))
    }

    /// What loaded models really take: oMLX's own measure, and the footprint of servers this app started.
    static func recordMeasurements(engines: [EngineStatus], processes: [RunningProcess], store: MeasurementStore = .shared) {
        let storeModels = engines.first { $0.kind == .omlx }?.omlx?.models ?? []
        for state in storeModels where state.loaded {
            if let actual = state.actualBytes { store.record(actual, engine: .omlx, model: state.id, source: "oMLX") }
        }
        for server in LaunchRegistry.shared.servers() {
            if let process = processes.first(where: { $0.pid == server.pid }) {
                store.record(process.footprintBytes, engine: server.engine, model: server.model, source: "empreinte du serveur, cache compris")
            }
        }
    }
}

public enum Format {
    /// Disk sizes in decimal units, as the Finder shows them: "73,4 Go".
    public static func bytes(_ value: Int64) -> String { scaled(Double(value), base: 1000) }

    /// Memory in binary units, as About This Mac shows it: 128 Go of RAM.
    public static func memory(_ value: Int64) -> String { scaled(Double(value), base: 1024) }

    /// Written in French whatever the process locale: the CLI often runs with `LANG` unset.
    static func scaled(_ value: Double, base: Double) -> String {
        let units = ["octets", "Ko", "Mo", "Go", "To"]
        var amount = value
        var unit = 0
        while amount >= base && unit < units.count - 1 {
            amount /= base
            unit += 1
        }
        let digits = unit == 0 || amount >= 100 ? 0 : 1
        let number = amount.formatted(.number.precision(.fractionLength(0...digits)).locale(Locale(identifier: "fr_FR")))
        return "\(number) \(units[unit])"
    }

    public static func tokens(_ value: Int) -> String {
        value >= 1024 && value % 1024 == 0 ? "\(value / 1024)K" : value.formatted()
    }

    public static func percent(_ part: Int64, of total: Int64) -> String {
        guard total > 0 else { return "—" }
        return (Double(part) / Double(total)).formatted(.percent.precision(.fractionLength(0)))
    }
}
