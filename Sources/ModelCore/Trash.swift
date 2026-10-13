import Foundation

/// What « Mettre à la corbeille » would move, and what the user should know first. Nothing is ever deleted:
/// items go to the Finder's Trash, and space comes back when the Trash is emptied.
public struct TrashPlan: Equatable, Sendable {
    public var model: String
    /// Paths moved to the Trash: the model folder, the whole Hugging Face repository, or only a link.
    public var items: [String]
    /// Space returned once the Trash is emptied; 0 for a link.
    public var freedBytes: Int64
    public var warnings: [String]
}

public enum ModelTrash {
    /// Refuses a model in memory; otherwise says what goes, what space comes back, and what else is affected.
    public static func plan(_ model: LocalModel, models: [LocalModel], running: [RunningModel], omlx: OMLXState?) -> Result<TrashPlan, TrashRefusal> {
        let served = LaunchPlan.servedName(model)
        if let server = running.first(where: { $0.models.contains(model.name) || $0.models.contains(served) }) {
            return .failure(TrashRefusal("\(model.name) est en mémoire (\(server.processDescription), PID \(server.pid)) : arrêtez-le ou déchargez-le d'abord."))
        }
        let omlxEntry = omlx?.models.first { OMLXIdentity.matches($0.id, model) }
        if omlxEntry?.loaded == true || omlxEntry?.isLoading == true {
            return .failure(TrashRefusal("oMLX a chargé \(model.name) : déchargez-le d'abord depuis « En cours »."))
        }

        var warnings: [String] = []
        let url = URL(fileURLWithPath: model.path)
        if model.isLink {
            warnings.append(model.isBrokenLink ? "Lien cassé (\(model.brokenReason ?? "cible absente")) : seul le lien part."
                                               : "C'est un lien : seul le lien part, les poids restent dans \(model.linkTarget ?? "sa cible").")
            return .success(TrashPlan(model: model.name, items: [model.path], freedBytes: 0, warnings: warnings))
        }

        var item = url
        // A snapshot holds links into `blobs/`: only the whole `models--owner--name` folder frees the weights.
        if model.store == .huggingFace, url.deletingLastPathComponent().lastPathComponent == "snapshots" {
            item = url.deletingLastPathComponent().deletingLastPathComponent()
            let revisions = StoreScanner.visibleEntries(item.appending(path: "snapshots")).filter(StoreScanner.isDirectory)
            if revisions.count > 1 { warnings.append("Le dépôt contient \(revisions.count) révisions : elles partent toutes ensemble.") }
        }
        var seen = Set<FileIdentity>()
        let freed = FileSizer.allocatedSize(under: item, followingLinks: false, seen: &seen)
        if freed < model.sizeBytes / 2 {
            warnings.append("La plupart de ses fichiers sont des liens : les poids eux-mêmes restent ailleurs et peu de place est libérée.")
        }

        let target = item.resolvingSymlinksInPath().path
        let dependents = models.filter { other in
            guard other.id != model.id, other.linkTarget != nil, !other.isBrokenLink else { return false }
            let resolved = URL(fileURLWithPath: other.path).resolvingSymlinksInPath().path
            return resolved == target || resolved.hasPrefix(target + "/")
        }
        if !dependents.isEmpty {
            warnings.append("Ces entrées pointent vers ce dossier et deviendront des liens cassés : "
                            + dependents.map { "\($0.name) (\($0.store.title))" }.joined(separator: ", ") + ".")
        }
        if omlxEntry != nil { warnings.append("oMLX le liste : il ne le proposera plus après son prochain examen des dossiers.") }
        return .success(TrashPlan(model: model.name, items: [item.path], freedBytes: freed, warnings: warnings))
    }

    /// Moves each item to the Trash; returns where they landed.
    public static func moveToTrash(_ plan: TrashPlan) throws -> [URL] {
        try plan.items.map { path in
            var landed: NSURL?
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &landed)
            return (landed as URL?) ?? URL(fileURLWithPath: path)
        }
    }
}

public struct TrashRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}
