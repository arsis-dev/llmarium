import Darwin
import Foundation

public enum MemoryPressure: String, Codable, Sendable {
    case normal, warning, critical, unknown

    public var title: String {
        switch self {
        case .normal: "Normale"
        case .warning: "Élevée"
        case .critical: "Critique"
        case .unknown: "Inconnue"
        }
    }
}

public struct MemoryStats: Codable, Sendable {
    public var totalBytes: Int64
    public var freeBytes: Int64
    public var wiredBytes: Int64
    public var compressedBytes: Int64
    /// Anonymous memory of processes, without what they marked purgeable (Activity Monitor's "App Memory").
    public var appBytes: Int64
    /// File-backed pages macOS can drop when needed.
    public var cachedFilesBytes: Int64
    /// Percentage macOS reports as free (`memory_pressure`, `kern.memorystatus_level`).
    public var freePercent: Int?
    public var pressure: MemoryPressure

    public var usedBytes: Int64 { appBytes + wiredBytes + compressedBytes }

    public static func current() -> MemoryStats {
        let total = Int64(sysctlInt("hw.memsize") ?? 0)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let page = Int64(vm_kernel_page_size)
        func bytes(_ pages: UInt32) -> Int64 { status == KERN_SUCCESS ? Int64(pages) * page : 0 }
        let pressure: MemoryPressure = switch sysctlInt("kern.memorystatus_vm_pressure_level") {
        case 1: .normal
        case 2: .warning
        case 4: .critical
        default: .unknown
        }
        return MemoryStats(totalBytes: total,
                           freeBytes: bytes(stats.free_count),
                           wiredBytes: bytes(stats.wire_count),
                           compressedBytes: bytes(stats.compressor_page_count),
                           appBytes: max(0, bytes(stats.internal_page_count) - bytes(stats.purgeable_count)),
                           cachedFilesBytes: bytes(stats.external_page_count),
                           freePercent: sysctlInt("kern.memorystatus_level"),
                           pressure: pressure)
    }
}

public struct MemoryReport: Codable, Sendable {
    public var stats: MemoryStats
    /// Largest consumers first, from 256 Mo up.
    public var groups: [ProcessGroup]

    public static func current(processes: [RunningProcess] = ProcessScanner.all()) -> MemoryReport {
        MemoryReport(stats: .current(), groups: ProcessGroup.group(processes).filter { $0.footprintBytes >= 256 << 20 })
    }
}

func sysctlInt(_ name: String) -> Int? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
    if size == MemoryLayout<Int32>.size {
        var value: Int32 = 0
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }
    var value: Int64 = 0
    return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
}

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    return sysctlbyname(name, &buffer, &size, nil, 0) == 0 ? String(cString: buffer) : nil
}
