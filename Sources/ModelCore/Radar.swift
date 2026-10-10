import Foundation

// MARK: - Model

public struct RadarSettings: Codable, Equatable, Sendable {
    /// Hugging Face accounts whose new uploads are watched.
    public var authors: [String]
    public var useSpicilege: Bool
    /// Uploads older than this are not « nouveau ».
    public var maxAgeDays: Int

    public init(authors: [String], useSpicilege: Bool = true, maxAgeDays: Int = 30) {
        self.authors = authors
        self.useSpicilege = useSpicilege
        self.maxAgeDays = maxAgeDays
    }

    /// The MLX publishers, plus the owners of the models already on this Mac in the engines' folders.
    public static func defaults(models: [LocalModel]) -> RadarSettings {
        var authors = ["mlx-community", "lmstudio-community"]
        for model in models where model.kind == .languageModel && model.store != .huggingFace && !model.isLink {
            if let owner = model.name.split(separator: "/").first.map(String.init), model.name.contains("/"), !authors.contains(owner) {
                authors.append(owner)
            }
        }
        return RadarSettings(authors: authors)
    }
}

/// Why a repository is a candidate: shown to the user as the reason it is listed.
public enum RadarSource: Codable, Hashable, Sendable {
    case trending
    case author(String)
    case spicilege(Date?)
}

/// What the Hub says about one repository.
public struct RadarCandidate: Codable, Hashable, Sendable {
    public var id: String
    public var createdAt: Date?
    public var pipelineTag: String?
    public var libraryName: String?
    public var tags: [String]
    public var likes: Int
    public var downloads: Int
    public var trendingScore: Double
    public var gated: Bool
    public var sizeBytes: Int64?
    public var architectures: [String]
    public var sources: [RadarSource]
    /// Several weight sets in one repository (quantizations side by side): `sizeBytes` is their sum.
    public var multipleVariants = false
    /// The weight files found, to spot adapters (LoRA) that need their base model.
    public var weightFiles: [String] = []

    public init(id: String, createdAt: Date? = nil, pipelineTag: String? = nil, libraryName: String? = nil, tags: [String] = [],
                likes: Int = 0, downloads: Int = 0, trendingScore: Double = 0, gated: Bool = false, sizeBytes: Int64? = nil,
                architectures: [String] = [], sources: [RadarSource] = []) {
        self.id = id
        self.createdAt = createdAt
        self.pipelineTag = pipelineTag
        self.libraryName = libraryName
        self.tags = tags
        self.likes = likes
        self.downloads = downloads
        self.trendingScore = trendingScore
        self.gated = gated
        self.sizeBytes = sizeBytes
        self.architectures = architectures
        self.sources = sources
    }

    public var isMLX: Bool { libraryName == "mlx" || tags.contains("mlx") }
    /// A LoRA adapter: not served as is by the engines, it needs its base model.
    public var isAdapter: Bool {
        tags.contains { $0.hasPrefix("base_model:adapter:") } || weightFiles.contains { ($0 as NSString).lastPathComponent.hasPrefix("adapter") }
    }
    public var isGGUF: Bool { libraryName == "gguf" || tags.contains("gguf") }

    /// `base_model:Qwen/X`, `base_model:quantized:Qwen/X`, `base_model:finetune:Qwen/X` tags.
    public var baseModels: [String] {
        tags.compactMap { tag -> String? in
            guard tag.hasPrefix("base_model:") else { return nil }
            let value = tag.dropFirst("base_model:".count)
            let parts = value.split(separator: ":", maxSplits: 1)
            return String(parts.count == 2 && !parts[0].contains("/") ? parts[1] : value)
        }
    }

    static let languagePipelines: Set<String> = ["text-generation", "image-text-to-text"]

    /// Several GGUF quantizations, or several folders each with its own `config.json`.
    static func hasSeveralVariants(_ files: [String]) -> Bool {
        let ggufs = files.filter { $0.hasSuffix(".gguf") && !$0.contains("mmproj") && !$0.contains("-of-") }
        let configs = files.filter { ($0 as NSString).lastPathComponent == "config.json" }
        return ggufs.count > 1 || configs.count > 1
    }

    /// Pipeline tag first; repositories without one are judged by their architectures.
    public var isLanguageModel: Bool? {
        if let pipelineTag { return Self.languagePipelines.contains(pipelineTag) }
        if architectures.isEmpty { return nil }
        return architectures.contains { $0.hasSuffix("ForCausalLM") || $0.hasSuffix("ForConditionalGeneration") }
    }
}

public struct RadarItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var createdAt: Date?
    public var sizeBytes: Int64?
    /// Engines that can probably serve it, guessed from the publisher and the name.
    public var engines: [EngineKind]
    public var reasons: [String]
    public var warnings: [String]
    public var relatedLocal: String?
    public var likes: Int
    public var downloads: Int
    public var score: Double
    public var gated = false

    public static let gatedWarning = "Accès soumis à acceptation sur Hugging Face"

    public var url: String { "https://huggingface.co/\(id)" }
    public var author: String { String(id.split(separator: "/").first ?? "") }
    public var name: String { String(id.split(separator: "/").last ?? Substring(id)) }
}

public struct RadarExclusion: Codable, Hashable, Sendable, Error {
    public var id: String
    public var reason: String
}

public struct RadarReport: Codable, Sendable {
    public var fetchedAt: Date
    public var items: [RadarItem]
    public var excluded: [RadarExclusion]
    /// One line per source: what it brought, or why it was unavailable.
    public var sources: [String]

    public var isStale: Bool { Date().timeIntervalSince(fetchedAt) > 24 * 3600 }
}

// MARK: - Filters

public enum RadarFilter {
    /// RAM a model may use on this Mac: total minus what macOS keeps for itself.
    public static func memoryLimit(totalBytes: Int64) -> Int64 { totalBytes - MemoryPlanner.systemReserve(totalBytes: totalBytes) }

    /// Keeps runnable language models in MLX format that fit in memory and are not already here; says why otherwise.
    public static func evaluate(_ candidate: RadarCandidate, memoryLimit: Int64, localIDs: Set<String>,
                                localBases: [String: String], now: Date = Date()) -> Result<RadarItem, RadarExclusion> {
        func exclude(_ reason: String) -> Result<RadarItem, RadarExclusion> { .failure(RadarExclusion(id: candidate.id, reason: reason)) }
        if localIDs.contains(candidate.id.lowercased()) { return exclude("Déjà sur ce Mac") }
        if candidate.isAdapter { return exclude("Adaptateur LoRA : il faut aussi son modèle de base, les moteurs ne le servent pas seul") }
        if !candidate.isMLX {
            return exclude(candidate.isGGUF ? "GGUF : format que ni oMLX, ni MTPLX, ni mlx-serve ne servent" : "Pas au format MLX")
        }
        switch candidate.isLanguageModel {
        case false?: return exclude("Pas un modèle de langage (\(candidate.pipelineTag ?? candidate.architectures.first ?? "?"))")
        case nil: return exclude("Nature du modèle inconnue (ni étiquette ni architecture)")
        default: break
        }
        if let size = candidate.sizeBytes, size > memoryLimit {
            return exclude("Trop gros pour ce Mac (\(Format.bytes(size)) pour \(Format.memory(memoryLimit)) utilisables)")
        }

        var reasons: [String] = []
        var score = 0.0
        for source in candidate.sources {
            switch source {
            case .trending:
                reasons.append("Tendance sur Hugging Face")
                score += 1 + min(candidate.trendingScore / 20, 3)
            case .author(let author):
                let days = candidate.createdAt.map { Int(now.timeIntervalSince($0) / 86_400) }
                reasons.append("Nouveau chez \(author)" + (days.map { $0 <= 1 ? " (aujourd'hui ou hier)" : " (il y a \($0) jours)" } ?? ""))
                score += (days ?? 30) <= 7 ? 2 : 1
            case .spicilege(let saved):
                reasons.append("Dans vos favoris Spicilege" + (saved.map { " (\($0.formatted(date: .abbreviated, time: .omitted)))" } ?? ""))
                score += 3
            }
        }
        let match = candidate.baseModels.lazy.compactMap { base in localBases[base.lowercased()].map { (base, $0) } }.first
        let related = match?.1
        if let (base, local) = match {
            // Derived from a model on this Mac, or built on the same base model as one.
            reasons.append(base.caseInsensitiveCompare(local) == .orderedSame ? "Dérivé de \(local), que vous avez"
                                                                             : "Même modèle de base (\(base)) que \(local), que vous avez")
            score += 2
        }
        score += log10(Double(max(candidate.likes, 1))) * 0.5
        var warnings: [String] = []
        if candidate.gated { warnings.append(RadarItem.gatedWarning) }
        if candidate.sizeBytes == nil { warnings.append("Taille inconnue") }
        if candidate.multipleVariants {
            warnings.append("Plusieurs variantes dans ce dépôt : la taille est celle de l'ensemble, et le téléchargement les prend toutes")
        }
        return .success(RadarItem(id: candidate.id, createdAt: candidate.createdAt, sizeBytes: candidate.sizeBytes,
                                  engines: engines(for: candidate.id), reasons: reasons, warnings: warnings, relatedLocal: related,
                                  likes: candidate.likes, downloads: candidate.downloads, score: score, gated: candidate.gated))
    }

    /// Guessed from who publishes and how the repository is named; the UI says « probable ».
    public static func engines(for id: String) -> [EngineKind] {
        let lower = id.lowercased()
        if lower.contains("mtplx") || lower.hasPrefix("youssofal/") { return [.mtplx] }
        if lower.hasPrefix("jundot/") || lower.contains("-oq") { return [.omlx] }
        if lower.contains("mlx-serve") || lower.hasPrefix("ddalcu/") { return [.mlxServe] }
        return [.omlx, .mlxServe]
    }

    /// Repository ids already on disk, in every layout the stores use.
    public static func localIDs(_ models: [LocalModel]) -> Set<String> {
        Set(models.filter { !$0.isLink }.map { $0.name.lowercased() })
    }

    /// Base model id → local model name, from the `base_model:` of each local model's README, plus each model's own id.
    public static func localBases(_ models: [LocalModel]) -> [String: String] {
        var bases: [String: String] = [:]
        for model in models where model.kind == .languageModel && !model.isBrokenLink {
            if model.name.contains("/") { bases[model.name.lowercased()] = model.name }
            let readme = URL(fileURLWithPath: model.path).resolvingSymlinksInPath().appending(path: "README.md")
            guard let text = try? String(contentsOf: readme, encoding: .utf8) else { continue }
            for base in readmeBaseModels(text) { bases[base.lowercased()] = model.name }
        }
        return bases
    }

    /// `base_model:` of a README's YAML front matter, as a single value or a list.
    static func readmeBaseModels(_ text: String) -> [String] {
        guard text.hasPrefix("---") else { return [] }
        let lines = text.components(separatedBy: "\n").dropFirst()
        guard let end = lines.firstIndex(of: "---") else { return [] }
        var bases: [String] = []
        var inList = false
        for line in lines[..<end] {
            if line.hasPrefix("base_model:") {
                let value = line.dropFirst("base_model:".count).trimmingCharacters(in: .whitespaces)
                if value.isEmpty { inList = true } else { bases.append(value.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))) ; inList = false }
            } else if inList, line.trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                bases.append(line.trimmingCharacters(in: .whitespaces).dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: "'\" ")))
            } else if !line.hasPrefix(" ") {
                inList = false
            }
        }
        return bases
    }
}

// MARK: - Sources

public enum Spicilege {
    /// Hugging Face model ids from the Spicilege library, read-only. Only URLs and save dates are read:
    /// titles, texts and notes are the user's data and untrusted, and the radar does not need them.
    public static func modelLinks(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> (links: [(id: String, saved: Date?)], status: String) {
        let settings = home.appending(path: "Library/Application Support/Spicilege/desktop.json")
        guard let data = try? Data(contentsOf: settings),
              let path = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["databasePath"] as? String,
              FileManager.default.fileExists(atPath: path) else {
            return ([], "Spicilege : bibliothèque introuvable")
        }
        let query = "select url, coalesce(saved_at, '') from items where url like '%huggingface.co/%' order by saved_at desc limit 300"
        guard let output = Command.run("/usr/bin/sqlite3", ["-readonly", "-separator", "\t", "file:\(path)?mode=ro", query]) else {
            return ([], "Spicilege : lecture impossible")
        }
        var seen = Set<String>()
        var links: [(String, Date?)] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let url = fields.first, let id = modelID(fromURL: String(url)), seen.insert(id.lowercased()).inserted else { continue }
            links.append((id, fields.count > 1 ? parseDate(String(fields[1])) : nil))
        }
        return (links, "Spicilege : \(links.count) modèle(s) parmi vos favoris Hugging Face")
    }

    /// `owner/name` for a model page; nil for datasets, collections, Spaces, papers, organisations and files.
    public static func modelID(fromURL url: String) -> String? {
        guard let components = URLComponents(string: url), let host = components.host, host.hasSuffix("huggingface.co") else { return nil }
        let segments = components.path.split(separator: "/").map(String.init)
        guard segments.count >= 2 else { return nil }
        let reserved: Set<String> = ["datasets", "collections", "spaces", "papers", "blog", "docs", "models", "organizations", "settings", "posts", "learn"]
        guard !reserved.contains(segments[0]) else { return nil }
        if segments.count > 2, !["tree", "blob", "resolve", "discussions", "commits"].contains(segments[2]) { return nil }
        return "\(segments[0])/\(segments[1])"
    }

    static func parseDate(_ text: String) -> Date? {
        if let seconds = Double(text), seconds > 1_000_000_000 { return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds) }
        return ISO8601DateFormatter().date(from: text)
            ?? DateFormatter.radarSQLite.date(from: String(text.prefix(19)))
    }
}

extension DateFormatter {
    static let radarSQLite: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

/// Public Hugging Face API, without account. A refusal (429) makes the radar keep its last list.
public enum HubAPI {
    static let fields = ["createdAt", "pipeline_tag", "library_name", "likes", "downloads", "trendingScore", "gated", "tags"]

    struct Unavailable: Error, CustomStringConvertible {
        var status: Int
        var description: String { status == 429 ? "Hugging Face limite les requêtes (429)" : "Hugging Face a répondu \(status)" }
    }

    static func list(_ query: [String: String]) async throws -> [RadarCandidate] {
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            + fields.map { URLQueryItem(name: "expand[]", value: $0) }
        let rows = try await json(components.url!) as? [[String: Any]] ?? []
        return rows.compactMap(candidate)
    }

    /// Repository details with file sizes: the real size of quantized weights.
    public static func detail(_ id: String) async throws -> RadarCandidate? {
        guard let url = URL(string: "https://huggingface.co/api/models/\(id)?blobs=true") else { return nil }
        guard let row = try await json(url) as? [String: Any], var candidate = candidate(row) else { return nil }
        let siblings = row["siblings"] as? [[String: Any]] ?? []
        let weights = siblings.filter { ($0["rfilename"] as? String).map { $0.hasSuffix(".safetensors") || $0.hasSuffix(".gguf") } ?? false }
        let total = weights.compactMap { ($0["size"] as? NSNumber)?.int64Value }.reduce(0, +)
        candidate.sizeBytes = total > 0 ? total : nil
        let names = siblings.compactMap { $0["rfilename"] as? String }
        candidate.weightFiles = weights.compactMap { $0["rfilename"] as? String } + names.filter { $0.hasSuffix("adapter_config.json") }
        candidate.multipleVariants = RadarCandidate.hasSeveralVariants(names)
        candidate.architectures = ((row["config"] as? [String: Any])?["architectures"] as? [String]) ?? []
        return candidate
    }

    static func candidate(_ row: [String: Any]) -> RadarCandidate? {
        guard let id = row["id"] as? String ?? row["modelId"] as? String else { return nil }
        let gated: Bool = (row["gated"] as? Bool) ?? ((row["gated"] as? String).map { $0 != "false" } ?? false)
        return RadarCandidate(id: id, createdAt: (row["createdAt"] as? String).flatMap(isoDate),
                              pipelineTag: row["pipeline_tag"] as? String, libraryName: row["library_name"] as? String,
                              tags: row["tags"] as? [String] ?? [], likes: (row["likes"] as? NSNumber)?.intValue ?? 0,
                              downloads: (row["downloads"] as? NSNumber)?.intValue ?? 0,
                              trendingScore: (row["trendingScore"] as? NSNumber)?.doubleValue ?? 0, gated: gated)
    }

    static func isoDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    static func json(_ url: URL) async throws -> Any {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Modeles-locaux/0.1 (radar)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Unavailable(status: status) }
        return try JSONSerialization.jsonObject(with: data)
    }
}

// MARK: - Radar

public enum Radar {
    public static let file = AppPaths.support.appending(path: "radar.json")
    public static let settingsFile = AppPaths.support.appending(path: "radar-settings.json")
    static let detailLimit = 40

    public static func cached(file: URL = file) -> RadarReport? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RadarReport.self, from: data)
    }

    public static func settings(models: [LocalModel]) -> RadarSettings {
        guard let data = try? Data(contentsOf: settingsFile), let saved = try? JSONDecoder().decode(RadarSettings.self, from: data) else {
            return .defaults(models: models)
        }
        return saved
    }

    public static func save(_ settings: RadarSettings) throws {
        try FileManager.default.createDirectory(at: settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: settingsFile, options: .atomic)
    }

    /// The cached list when it is less than a day old, otherwise a fresh one (the previous list stays if the Hub refuses).
    public static func report(snapshot: InventorySnapshot, refresh: Bool = false) async -> RadarReport {
        if !refresh, let cached = cached(), !cached.isStale { return cached }
        var report = await build(snapshot: snapshot, settings: settings(models: snapshot.models))
        if report.items.isEmpty, let cached = cached() {
            report.items = cached.items
            report.sources.append("Liste précédente du \(cached.fetchedAt.formatted(date: .abbreviated, time: .shortened)) conservée")
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? encoder.encode(report).write(to: file, options: .atomic)
        }
        return report
    }

    public static func build(snapshot: InventorySnapshot, settings: RadarSettings, limit: Int = 20) async -> RadarReport {
        var candidates: [String: RadarCandidate] = [:]
        var sources: [String] = []
        func merge(_ found: [RadarCandidate], source: RadarSource) {
            for var candidate in found {
                if var existing = candidates[candidate.id] {
                    if !existing.sources.contains(source) { existing.sources.append(source) }
                    existing.trendingScore = max(existing.trendingScore, candidate.trendingScore)
                    candidates[candidate.id] = existing
                } else {
                    candidate.sources = [source]
                    candidates[candidate.id] = candidate
                }
            }
        }
        let cutoff = Date().addingTimeInterval(-Double(settings.maxAgeDays) * 86_400)
        do {
            for pipeline in RadarCandidate.languagePipelines.sorted() {
                merge(try await HubAPI.list(["filter": "mlx", "pipeline_tag": pipeline, "sort": "trendingScore", "direction": "-1", "limit": "25"]),
                      source: .trending)
            }
            sources.append("Tendances MLX sur Hugging Face")
            for author in settings.authors {
                let recent = try await HubAPI.list(["author": author, "sort": "createdAt", "direction": "-1", "limit": "30"])
                    .filter { ($0.createdAt ?? .distantPast) >= cutoff }
                merge(recent, source: .author(author))
            }
            sources.append("Nouveautés de \(settings.authors.count) auteurs suivis (\(settings.maxAgeDays) derniers jours)")
        } catch {
            sources.append("Hugging Face indisponible : \(error)")
        }
        if settings.useSpicilege {
            let found = Spicilege.modelLinks()
            sources.append(found.status)
            for link in found.links {
                if candidates[link.id] == nil { candidates[link.id] = RadarCandidate(id: link.id) }
                candidates[link.id]?.sources.append(.spicilege(link.saved))
            }
        }

        let memoryLimit = RadarFilter.memoryLimit(totalBytes: snapshot.machine.memoryBytes)
        let localIDs = RadarFilter.localIDs(snapshot.models)
        let localBases = RadarFilter.localBases(snapshot.models)
        var excluded: [RadarExclusion] = []
        // First pass on what the list says; details (sizes, architectures) only for the survivors.
        var survivors: [RadarCandidate] = []
        for candidate in candidates.values {
            if localIDs.contains(candidate.id.lowercased()) { excluded.append(RadarExclusion(id: candidate.id, reason: "Déjà sur ce Mac")); continue }
            let listed = candidate.libraryName != nil || !candidate.tags.isEmpty
            if listed, !candidate.isMLX {
                excluded.append(RadarExclusion(id: candidate.id, reason: candidate.isGGUF ? "GGUF : format que ni oMLX, ni MTPLX, ni mlx-serve ne servent" : "Pas au format MLX"))
                continue
            }
            if candidate.isLanguageModel == false {
                excluded.append(RadarExclusion(id: candidate.id, reason: "Pas un modèle de langage (\(candidate.pipelineTag ?? "?"))"))
                continue
            }
            survivors.append(candidate)
        }
        survivors.sort { priority($0) > priority($1) }
        if survivors.count > detailLimit {
            excluded += survivors[detailLimit...].map { RadarExclusion(id: $0.id, reason: "Hors des \(detailLimit) premiers candidats examinés") }
            survivors = Array(survivors.prefix(detailLimit))
        }
        let detailed = await withTaskGroup(of: RadarCandidate?.self) { group -> [RadarCandidate] in
            var results: [RadarCandidate] = []
            var iterator = survivors.makeIterator()
            func next() -> Bool {
                guard let candidate = iterator.next() else { return false }
                group.addTask {
                    guard var detail = try? await HubAPI.detail(candidate.id) else { return candidate }
                    detail.sources = candidate.sources
                    detail.trendingScore = max(detail.trendingScore, candidate.trendingScore)
                    return detail
                }
                return true
            }
            for _ in 0..<6 { _ = next() }
            while let result = await group.next() {
                if let result { results.append(result) }
                _ = next()
            }
            return results
        }
        var items: [RadarItem] = []
        for candidate in detailed {
            switch RadarFilter.evaluate(candidate, memoryLimit: memoryLimit, localIDs: localIDs, localBases: localBases) {
            case .success(let item): items.append(item)
            case .failure(let exclusion): excluded.append(exclusion)
            }
        }
        items.sort { $0.score > $1.score }
        if items.count > limit {
            excluded += items[limit...].map { RadarExclusion(id: $0.id, reason: "Au-delà des \(limit) premiers") }
            items = Array(items.prefix(limit))
        }
        return RadarReport(fetchedAt: Date(), items: items, excluded: excluded.sorted { $0.id < $1.id }, sources: sources)
    }

    static func priority(_ candidate: RadarCandidate) -> Double {
        candidate.sources.reduce(0) { total, source in
            switch source {
            case .spicilege: total + 3
            case .trending: total + 1 + min(candidate.trendingScore / 20, 3)
            case .author: total + 1
            }
        } + log10(Double(max(candidate.likes, 1))) * 0.5
    }
}

// MARK: - Download

public struct RadarDownload: Equatable, Sendable {
    public var engine: EngineKind
    public var command: TerminalCommand
    public var destination: String
    public var sizeBytes: Int64?

    /// One command per engine: oMLX reads the Hugging Face cache, MTPLX keeps `owner--name` folders, mlx-serve pulls itself.
    public static func plan(repo: String, engine: EngineKind, sizeBytes: Int64?,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            mlxServe: String = "/Applications/MLX-Serve.app/Contents/MacOS/mlx-serve") -> RadarDownload {
        switch engine {
        case .omlx:
            return RadarDownload(engine: engine, command: TerminalCommand(arguments: ["hf", "download", repo], directory: home.path),
                                 destination: "Cache Hugging Face (lu par oMLX)", sizeBytes: sizeBytes)
        case .mtplx:
            let folder = home.appending(path: ".mtplx/models/\(repo.replacingOccurrences(of: "/", with: "--"))").path
            return RadarDownload(engine: engine, command: TerminalCommand(arguments: ["hf", "download", repo, "--local-dir", folder], directory: home.path),
                                 destination: folder, sizeBytes: sizeBytes)
        case .mlxServe:
            return RadarDownload(engine: engine, command: TerminalCommand(arguments: [mlxServe, "pull", repo], directory: home.path),
                                 destination: home.appending(path: ".mlx-serve/models/\(repo)").path, sizeBytes: sizeBytes)
        }
    }

    /// Refusal message when the disk cannot take the model with a 10 % margin; nil when it fits.
    public static func diskRefusal(sizeBytes: Int64?, freeBytes: Int64?) -> String? {
        guard let sizeBytes else { return "Taille inconnue : vérifiez l'espace disque avant de télécharger." }
        guard let freeBytes else { return nil }
        let needed = sizeBytes + sizeBytes / 10
        guard needed > freeBytes else { return nil }
        return "Pas assez d'espace : \(Format.bytes(needed)) nécessaires (marge de 10 % comprise), \(Format.bytes(freeBytes)) libres. Libérez \(Format.bytes(needed - freeBytes)) (voir la section Disque)."
    }
}
