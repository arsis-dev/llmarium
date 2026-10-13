import Foundation
import IOKit
import Metal

/// What the GPU of this Mac may hold and how many cores it has. Read once: neither changes while the app runs,
/// except the wired limit, which takes effect for new allocations only.
public struct GPUInfo: Codable, Hashable, Sendable {
    /// Memory macOS lets the GPU use (`recommendedMaxWorkingSetSize`): models beyond it do not load, whatever the free RAM.
    public var limitBytes: Int64?
    /// Where the limit comes from, in French.
    public var limitSource: String?
    public var coreCount: Int?

    public static let current: GPUInfo = {
        let limit = MTLCreateSystemDefaultDevice().map { Int64($0.recommendedMaxWorkingSetSize) }
        let wired = sysctlInt("iogpu.wired_limit_mb") ?? 0
        let source = wired > 0 ? "relevé par iogpu.wired_limit_mb" : "valeur par défaut de macOS"
        return GPUInfo(limitBytes: limit, limitSource: limit == nil ? nil : source, coreCount: coreCount())
    }()

    /// `gpu-core-count` of the Apple GPU in the I/O Registry; `system_profiler` would take seconds.
    static func coreCount() -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? NSNumber)?.intValue
    }
}

/// Memory bandwidth of Apple chips, from Apple's specifications. Max chips come in two GPU sizes with different
/// bandwidths: without the core count, no figure is given rather than a guess.
public enum ChipBandwidth {
    /// GB/s, keyed by « M4 Pro », « M5 Max/40 »…
    static let table: [String: Double] = [
        "M1": 68, "M1 Pro": 200, "M1 Max": 400, "M1 Ultra": 800,
        "M2": 100, "M2 Pro": 200, "M2 Max": 400, "M2 Ultra": 800,
        "M3": 100, "M3 Pro": 150, "M3 Max/30": 300, "M3 Max/40": 400, "M3 Ultra": 819,
        "M4": 120, "M4 Pro": 273, "M4 Max/32": 410, "M4 Max/40": 546,
        "M5": 153, "M5 Pro": 307, "M5 Max/32": 460, "M5 Max/40": 614
    ]

    public static func gigabytesPerSecond(chip: String, gpuCores: Int?) -> Double? {
        guard let match = chip.firstMatch(of: #/M(\d+)(?:\s+(Pro|Max|Ultra))?/#) else { return nil }
        let name = "M\(match.1)" + (match.2.map { " \($0)" } ?? "")
        if let value = table[name] { return value }
        return gpuCores.flatMap { table["\(name)/\($0)"] }
    }
}
