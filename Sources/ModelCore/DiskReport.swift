import Foundation

/// Models that share one architecture. Usually several quantizations of the same model,
/// but a base model and its fine-tunes share it too: the UI says "probably".
public struct ArchitectureGroup: Codable, Hashable, Sendable {
    public var signature: String
    public var modelType: String
    public var modelIDs: [String]
    public var totalBytes: Int64
}

public struct StoreUsage: Codable, Hashable, Sendable {
    public var store: ModelStore
    public var exists: Bool
    public var totalBytes: Int64
    public var modelCount: Int
}

public struct DiskReport: Codable, Sendable {
    public var volumeAvailableBytes: Int64?
    public var volumeTotalBytes: Int64?
    public var stores: [StoreUsage]
    public var architectureGroups: [ArchitectureGroup]
    public var brokenLinkIDs: [String]
    public var emptyCacheEntries: [EmptyCacheEntry]

    public var modelBytes: Int64 { stores.reduce(0) { $0 + $1.totalBytes } }
    public var emptyCacheBytes: Int64 { emptyCacheEntries.reduce(0) { $0 + $1.sizeBytes } }

    public static func make(scans: [StoreScan], volume: URL = FileManager.default.homeDirectoryForCurrentUser) -> DiskReport {
        let models = scans.flatMap(\.models)
        let values = try? volume.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
        return DiskReport(
            volumeAvailableBytes: values?.volumeAvailableCapacity.map(Int64.init),
            volumeTotalBytes: values?.volumeTotalCapacity.map(Int64.init),
            stores: scans.map { StoreUsage(store: $0.store, exists: $0.exists, totalBytes: $0.totalBytes, modelCount: $0.models.count) },
            architectureGroups: groups(models),
            brokenLinkIDs: models.filter(\.isBrokenLink).map(\.id),
            emptyCacheEntries: scans.flatMap(\.emptyEntries))
    }

    /// Language models only: small encoders (BERT and the like) share shapes across unrelated models.
    /// Links are left out: they point at weights already listed elsewhere.
    static func groups(_ models: [LocalModel]) -> [ArchitectureGroup] {
        let candidates = models.filter { !$0.isLink && $0.kind == .languageModel && $0.spec?.architectureSignature != nil }
        return Dictionary(grouping: candidates) { $0.spec!.architectureSignature! }
            .filter { $0.value.count > 1 }
            .map { signature, members in
                ArchitectureGroup(signature: signature, modelType: members[0].spec?.modelType ?? "",
                                  modelIDs: members.map(\.id).sorted(),
                                  totalBytes: members.reduce(0) { $0 + $1.sizeBytes })
            }
            .sorted { $0.totalBytes > $1.totalBytes }
    }
}
