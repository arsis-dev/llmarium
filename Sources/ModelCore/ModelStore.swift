import Foundation

public enum StoreKind: String, Codable, CaseIterable, Sendable {
    case omlx, mlxServe, mtplx, huggingFace

    public var title: String {
        switch self {
        case .omlx: "oMLX"
        case .mlxServe: "mlx-serve"
        case .mtplx: "MTPLX"
        case .huggingFace: "Cache Hugging Face"
        }
    }
}

/// A folder where an engine (or the Hugging Face cache) keeps model weights.
public struct ModelStore: Codable, Hashable, Sendable {
    public var kind: StoreKind
    public var path: String

    public init(kind: StoreKind, path: String) {
        self.kind = kind
        self.path = path
    }

    /// Default locations on this Mac. Only the `model` section of the oMLX settings is read: the file also holds an API key.
    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> [ModelStore] {
        var stores = omlxModelDirectories(home: home).map { ModelStore(kind: .omlx, path: $0.path) }
        stores.append(ModelStore(kind: .mlxServe, path: home.appending(path: ".mlx-serve/models").path))
        stores.append(ModelStore(kind: .mtplx, path: home.appending(path: ".mtplx/models").path))
        stores.append(ModelStore(kind: .huggingFace, path: huggingFaceHub(home: home, environment: environment).path))
        return stores
    }

    static func omlxModelDirectories(home: URL) -> [URL] {
        let fallback = [home.appending(path: ".omlx/models")]
        guard let data = try? Data(contentsOf: home.appending(path: ".omlx/settings.json")),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let model = root["model"] as? [String: Any] else { return fallback }
        let dirs = (model["model_dirs"] as? [String]) ?? (model["model_dir"] as? String).map { [$0] } ?? []
        return dirs.isEmpty ? fallback : dirs.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }

    static func huggingFaceHub(home: URL, environment: [String: String]) -> URL {
        if let hub = environment["HF_HUB_CACHE"], !hub.isEmpty { return URL(fileURLWithPath: hub) }
        if let hf = environment["HF_HOME"], !hf.isEmpty { return URL(fileURLWithPath: hf).appending(path: "hub") }
        return home.appending(path: ".cache/huggingface/hub")
    }
}

/// One model as found on disk.
public struct LocalModel: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    /// `owner/name` when the layout gives an owner, otherwise the folder name.
    public var name: String
    public var store: StoreKind
    public var path: String
    /// Set when the store entry is a symbolic link: its weights live elsewhere and are not counted twice.
    public var linkTarget: String?
    /// The link leads nowhere usable: missing target, or a folder without weights (interrupted download).
    public var isBrokenLink = false
    public var brokenReason: String?
    public var sizeBytes: Int64 = 0
    public var format: ModelFormat = .unknown
    public var spec: ModelSpec?

    public init(name: String, store: StoreKind, path: String) {
        self.id = "\(store.rawValue):\(name)"
        self.name = name
        self.store = store
        self.path = path
    }

    public var isLink: Bool { linkTarget != nil || isBrokenLink }
    public var kind: ModelKind { spec?.kind ?? (format == .gguf ? .languageModel : .unknown) }
}

/// A Hugging Face cache entry left without any snapshot, usually after a deletion or an interrupted download.
public struct EmptyCacheEntry: Codable, Hashable, Sendable {
    public var name: String
    public var path: String
    public var sizeBytes: Int64
}

public struct StoreScan: Codable, Sendable {
    public var store: ModelStore
    public var exists: Bool
    /// Bytes this folder really occupies: links are not followed and each file is counted once.
    public var totalBytes: Int64
    public var models: [LocalModel]
    public var emptyEntries: [EmptyCacheEntry]
}

public enum StoreScanner {
    public static func scan(_ store: ModelStore) -> StoreScan {
        let root = URL(fileURLWithPath: store.path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return StoreScan(store: store, exists: false, totalBytes: 0, models: [], emptyEntries: [])
        }
        var models: [LocalModel] = []
        var empty: [EmptyCacheEntry] = []
        switch store.kind {
        case .omlx, .mlxServe:
            models = scanNested(root, kind: store.kind)
        case .mtplx:
            models = scanNested(root, kind: store.kind, rename: { $0.replacingOccurrences(of: "--", with: "/", options: [], range: $0.range(of: "--")) })
        case .huggingFace:
            (models, empty) = scanHuggingFace(root)
        }
        var seen = Set<FileIdentity>()
        let total = FileSizer.allocatedSize(under: root, followingLinks: false, seen: &seen)
        return StoreScan(store: store, exists: true, totalBytes: total,
                         models: models.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                         emptyEntries: empty.sorted { $0.name < $1.name })
    }

    /// `name` or `owner/name` folders, where an entry may also be a link to a folder elsewhere.
    static func scanNested(_ root: URL, kind: StoreKind, rename: (String) -> String = { $0 }) -> [LocalModel] {
        var models: [LocalModel] = []
        for entry in visibleEntries(root) {
            if isSymbolicLink(entry) || looksLikeModel(entry) {
                models.append(model(at: entry, name: rename(entry.lastPathComponent), kind: kind))
            } else if isDirectory(entry) {
                for child in visibleEntries(entry) where isSymbolicLink(child) || looksLikeModel(child) {
                    models.append(model(at: child, name: "\(entry.lastPathComponent)/\(child.lastPathComponent)", kind: kind))
                }
            }
        }
        return models
    }

    /// `models--owner--name/snapshots/<revision>`; folders that do not follow this layout (`owner/name`) are read as nested stores.
    static func scanHuggingFace(_ root: URL) -> ([LocalModel], [EmptyCacheEntry]) {
        var models: [LocalModel] = []
        var empty: [EmptyCacheEntry] = []
        for entry in visibleEntries(root) where isDirectory(entry) {
            let folder = entry.lastPathComponent
            if folder.hasPrefix("models--") {
                let name = String(folder.dropFirst("models--".count)).replacingOccurrences(of: "--", with: "/")
                if let snapshot = currentSnapshot(of: entry) {
                    models.append(model(at: snapshot, name: name, kind: .huggingFace))
                } else {
                    var seen = Set<FileIdentity>()
                    empty.append(EmptyCacheEntry(name: name, path: entry.path,
                                                 sizeBytes: FileSizer.allocatedSize(under: entry, followingLinks: false, seen: &seen)))
                }
            } else if !folder.contains("--") && !nonModelFolders.contains(folder) {
                models += scanNested(entry, kind: .huggingFace).map { nested in
                    var model = nested
                    model.name = "\(folder)/\(nested.name)"
                    model.id = "\(StoreKind.huggingFace.rawValue):\(model.name)"
                    return model
                }
                for child in visibleEntries(entry) where isDirectory(child) && !isSymbolicLink(child) && !looksLikeModel(child) {
                    var seen = Set<FileIdentity>()
                    empty.append(EmptyCacheEntry(name: "\(folder)/\(child.lastPathComponent)", path: child.path,
                                                 sizeBytes: FileSizer.allocatedSize(under: child, followingLinks: false, seen: &seen)))
                }
            }
        }
        return (models, empty)
    }

    /// Shared download caches kept at the hub root by some tools; their size still counts in the store total.
    static let nonModelFolders: Set<String> = ["blobs", "xet"]

    /// The revision `refs/main` points to, otherwise the most recent snapshot.
    static func currentSnapshot(of entry: URL) -> URL? {
        let snapshots = entry.appending(path: "snapshots")
        let revisions = visibleEntries(snapshots).filter(isDirectory)
        guard !revisions.isEmpty else { return nil }
        if let main = try? String(contentsOf: entry.appending(path: "refs/main"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let match = revisions.first(where: { $0.lastPathComponent == main }) {
            return match
        }
        return revisions.max { modificationDate($0) < modificationDate($1) }
    }

    static func model(at url: URL, name: String, kind: StoreKind) -> LocalModel {
        var model = LocalModel(name: name, store: kind, path: url.path)
        var target = url
        if isSymbolicLink(url) {
            let resolved = url.resolvingSymlinksInPath()
            model.linkTarget = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? resolved.path
            guard FileManager.default.fileExists(atPath: resolved.path) else {
                model.isBrokenLink = true
                model.brokenReason = "cible absente"
                return model
            }
            guard looksLikeModel(resolved) else {
                model.isBrokenLink = true
                model.brokenReason = "cible sans poids ni config.json"
                return model
            }
            target = resolved
        }
        var seen = Set<FileIdentity>()
        model.sizeBytes = FileSizer.allocatedSize(under: target, followingLinks: true, seen: &seen)
        if let data = try? Data(contentsOf: target.appending(path: "config.json")) { model.spec = ModelSpec.parse(data) }
        model.format = format(of: target, spec: model.spec)
        return model
    }

    static func format(of url: URL, spec: ModelSpec?) -> ModelFormat {
        let files = visibleEntries(url).map(\.pathExtension)
        if files.contains("gguf") { return .gguf }
        if spec?.hasMLXQuantization == true { return .mlx }
        if files.contains("safetensors") { return .safetensors }
        return .unknown
    }

    static func looksLikeModel(_ url: URL) -> Bool {
        guard isDirectory(url) else { return url.pathExtension == "gguf" }
        return visibleEntries(url).contains { ["config.json"].contains($0.lastPathComponent) || ["safetensors", "gguf"].contains($0.pathExtension) }
    }

    static func visibleEntries(_ url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    static func isDirectory(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
    }

    static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

struct FileIdentity: Hashable {
    var device: Int32
    var inode: UInt64
}

enum FileSizer {
    /// Allocated bytes of the regular files under `root`, each file counted once even when several links reach it.
    /// `followingLinks` reads the file a link points to (Hugging Face snapshots are links into `blobs/`).
    static func allocatedSize(under root: URL, followingLinks: Bool, seen: inout Set<FileIdentity>) -> Int64 {
        var total: Int64 = 0
        func add(_ path: String) {
            var info = stat()
            let status = followingLinks ? stat(path, &info) : lstat(path, &info)
            guard status == 0, info.st_mode & S_IFMT == S_IFREG else { return }
            if seen.insert(FileIdentity(device: info.st_dev, inode: info.st_ino)).inserted {
                total += Int64(info.st_blocks) * 512
            }
        }
        add(root.path)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return total }
        for case let url as URL in enumerator { add(url.path) }
        return total
    }
}
