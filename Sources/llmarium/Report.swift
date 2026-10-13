import Foundation
import ModelCore

/// Plain-text views of a snapshot for the terminal.
enum Report {
    static func status(_ snapshot: InventorySnapshot) -> String {
        var lines = ["\(snapshot.machine.chip) · \(Format.memory(snapshot.machine.memoryBytes)) · \(snapshot.machine.systemVersion)", ""]
        lines.append("Moteurs")
        for engine in snapshot.engines { lines.append(contentsOf: self.engine(engine)) }
        lines.append("")
        lines.append(running(snapshot.running))
        lines.append("")
        lines.append(memorySummary(snapshot.memory.stats, omlx: snapshot.engine(.omlx)?.omlx))
        let disk = snapshot.disk
        lines.append("Disque : \(disk.volumeAvailableBytes.map(Format.bytes) ?? "—") libres, modèles \(Format.bytes(disk.modelBytes)) · \(snapshot.models.count) modèles, \(disk.architectureGroups.count) architectures en plusieurs exemplaires, \(disk.brokenLinkIDs.count) lien(s) cassé(s), \(disk.emptyCacheEntries.count) entrée(s) vide(s)")
        return lines.joined(separator: "\n")
    }

    static func engine(_ engine: EngineStatus) -> [String] {
        let installation = engine.installation
        let version = installation.version.map { " \($0)" } ?? ""
        guard installation.isInstalled else { return ["  \(engine.kind.title) : non installé"] }
        guard engine.isRunning else { return ["  \(engine.kind.title)\(version) : arrêté"] }
        var lines: [String] = []
        for instance in engine.instances {
            let ports = instance.ports.map(String.init).joined(separator: ", ")
            lines.append("  \(engine.kind.title)\(version) : actif, PID \(instance.pid), port \(ports.isEmpty ? "—" : ports), \(instance.api.title), \(Format.memory(instance.footprintBytes))")
            if let omlx = engine.omlx {
                let loaded = omlx.models.filter { $0.loaded || $0.isLoading }
                lines.append("    chargé : " + (loaded.isEmpty ? "aucun modèle" : loaded.map { "\($0.id)\($0.isLoading ? " (chargement)" : "") \($0.residentBytes.map(Format.memory) ?? "")" }.joined(separator: ", ")))
                lines.append("    exposés par l'API : \(instance.servedModels.count) · plafond mémoire oMLX : \(omlx.ceilingBytes.map(Format.memory) ?? "—")")
            } else if !instance.servedModels.isEmpty {
                lines.append("    servi : " + instance.servedModels.joined(separator: ", "))
            }
        }
        return lines
    }

    static func running(_ running: [RunningModel]) -> String {
        guard !running.isEmpty else { return "En mémoire : aucun modèle" }
        var lines = ["En mémoire"]
        for model in running {
            let ports = model.ports.isEmpty ? "" : ", port \(model.ports.map(String.init).joined(separator: ", "))"
            let since = model.startedAt.map { ", depuis \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
            lines.append("  \(pad(Format.memory(model.footprintBytes), 9)) \(model.title) [\(model.role.title)] · PID \(model.pid)\(ports)\(since)")
            if let comfyUI = model.comfyUI {
                lines.append("            activité : \(comfyUI.activity)")
                if !comfyUI.models.isEmpty {
                    lines.append("            modèles\(comfyUI.modelsFromHistory ? " (dernière génération)" : "") : \(comfyUI.models.joined(separator: ", "))")
                }
            }
            let certainty = model.launcher.certainty == .probable ? " (probable, d'après son environnement)" : ""
            lines.append("            lancé par : \(model.launcher.summary)\(certainty)")
            if let project = model.launcher.projectPath { lines.append("            projet : \(project)") }
            if model.launcher.isOrphan { lines.append("            orphelin : son lanceur n'est plus actif") }
            lines.append("            clients connectés : " + (model.clients.isEmpty ? "aucun à cet instant" : model.clients.map { "\($0.title) (\($0.pid))" }.joined(separator: ", ")))
        }
        return lines.joined(separator: "\n")
    }

    static func estimate(_ estimate: MemoryEstimate, model: LocalModel, engine: EngineKind, engines: [EngineKind]) -> String {
        var lines = ["\(model.name) sur \(engine.title)" + (engines.count > 1 ? " (aussi possible : \(engines.filter { $0 != engine }.map(\.title).joined(separator: ", ")))" : "")]
        let weightsSource = estimate.weightsMeasurement.map { "  mesuré (\($0.source), \($0.measuredAt.formatted(date: .abbreviated, time: .omitted)))" } ?? "  taille sur disque"
        lines.append("  poids        \(pad(Format.memory(estimate.weightsBytes), 9))\(weightsSource)")
        let perToken = estimate.kvBytesPerToken.map { " (\(Format.memory($0 * 1024)) pour 1K tokens)" } ?? ""
        lines.append("  contexte     \(pad(Format.memory(estimate.kvCacheBytes), 9))  \(Format.tokens(estimate.context)) tokens\(perToken)")
        lines.append("  marge        \(pad(Format.memory(estimate.overheadBytes), 9))  exécution")
        lines.append("  total        \(pad(Format.memory(estimate.totalBytes), 9))")
        lines.append("  disponible   \(pad(Format.memory(max(0, estimate.availableBytes)), 9))  \(estimate.availableBasis)")
        if let gpu = estimate.gpuAvailableBytes {
            lines.append("  GPU          \(pad(Format.memory(max(0, gpu)), 9))  plafond du GPU de \(Format.memory(estimate.gpuLimitBytes ?? 0)) (\(estimate.gpuLimitSource ?? "macOS")) moins les modèles en mémoire")
        }
        switch estimate.verdict {
        case .fits: lines.append("→ Tient en mémoire.")
        case .tight: lines.append("→ Tient, mais de justesse.")
        case .tooLarge: lines.append("→ Ne tient pas : il manque \(Format.memory(estimate.shortfallBytes)).")
        }
        if estimate.verdict != .fits, !estimate.toFree.isEmpty {
            lines.append("Pour libérer de la place :")
            for candidate in estimate.toFree.prefix(6) {
                lines.append("  \(pad(Format.memory(candidate.bytes), 9)) \(candidate.title)\(candidate.detail.map { " · \($0)" } ?? "")")
            }
        }
        if let speed = estimate.speed {
            lines.append("Vitesse : \(speed.summary)" + (speed.activeBasis.map { " ; poids lus par token : \(Format.memory(speed.activeBytes ?? 0)), \($0)" } ?? ""))
        }
        lines += estimate.notes.map { "Note : \($0)" }
        return lines.joined(separator: "\n")
    }

    static func start(_ outcome: StartOutcome, model: LocalModel, engine: EngineKind) -> String {
        if let refusal = outcome.refusal {
            return "Non lancé : \(refusal)\n\n" + estimate(outcome.estimate, model: model, engine: engine, engines: [engine])
        }
        switch outcome.result {
        case .ready(let server, let served, let seconds):
            return "Prêt en \(seconds) s : \(served.joined(separator: ", ")) sur http://127.0.0.1:\(server.port)/v1 (PID \(server.pid))\nJournal : \(server.logPath)"
        case .loadedInOMLX(let id, let seconds):
            return "\(id) chargé dans oMLX en \(seconds) s."
        case .failed(let reason, let log):
            return "Échec : \(reason)" + (log.map { "\n--- fin du journal ---\n\($0)" } ?? "")
        case nil:
            return "Rien n'a été lancé."
        }
    }

    static func recipe(_ recipe: Recipe) -> String {
        var lines = ["\(recipe.model) sur \(recipe.engine.title) — \(recipe.author.title)"]
        lines.append("  contexte       \(recipe.context.map { "\(Format.tokens($0)) tokens" } ?? "valeur du moteur")")
        if recipe.engine == .mtplx { lines.append("  raisonnement   \(recipe.reasoning ?? "valeur du moteur (actif)")") }
        lines.append("  échantillonnage \(recipe.sampling.summary)")
        if !recipe.flags.isEmpty { lines.append("  options        \(recipe.flags.joined(separator: " "))") }
        if !recipe.notes.isEmpty { lines.append("Notes :"); lines += recipe.notes.map { "  - \($0)" } }
        if !recipe.sources.isEmpty { lines.append("Sources :"); lines += recipe.sources.map { "  - \($0)" } }
        return lines.joined(separator: "\n")
    }

    static func benchmark(_ result: BenchmarkResult) -> String {
        var lines = ["\(result.model) · \(result.engine.title) \(result.engineVersion ?? "") · \(result.date.formatted(date: .abbreviated, time: .shortened))"]
        for run in result.runs {
            let ttft = run.timeToFirstToken.map { String(format: "%.2f s", $0) } ?? "—"
            let prefill = run.prefillTokensPerSecond.map { String(format: "%.0f", $0) } ?? "—"
            let decode = run.decodeTokensPerSecond.map { String(format: "%.1f", $0) } ?? "—"
            let tokens = "\(run.promptTokens.map(String.init) ?? "?") → \(run.completionTokens.map(String.init) ?? "?")\(run.tokensEstimated ? " (estimé)" : "")"
            lines.append("  \(pad(run.title, 28)) \(run.succeeded ? "✓" : "✗")  1er token \(ttft), lecture \(prefill) tok/s, génération \(decode) tok/s, tokens \(tokens)\(run.reasoningObserved ? ", raisonnement présent" : "")\(run.note.map { " · \($0)" } ?? "")")
        }
        for condition in result.conditions { lines.append("  ⚠︎ \(condition) : mesure perturbée, à refaire au calme") }
        lines.append("  pic mémoire du processus : \(result.peakMemoryBytes.map(Format.memory) ?? "—")\(result.engine == .omlx ? " (tous les modèles chargés dans oMLX)" : "")\(result.loadSeconds.map { " · chargement \($0) s" } ?? "")")
        return lines.joined(separator: "\n")
    }

    static func benchmarks(_ results: [BenchmarkResult]) -> String {
        guard !results.isEmpty else { return "Aucune mesure. Lancez llmarium bench <modèle> sur un modèle en mémoire." }
        var lines = ["\(pad("modèle", 44)) \(pad("moteur", 10)) \(pad("génér.", 8)) \(pad("lecture", 8)) \(pad("1er tok", 8))  outil  long  pensée  mémoire"]
        for result in results {
            let decode = result.decodeTokensPerSecond.map { String(format: "%.1f", $0) } ?? "—"
            let prefill = result.prefillTokensPerSecond.map { String(format: "%.0f", $0) } ?? "—"
            let ttft = result.timeToFirstToken.map { String(format: "%.2f s", $0) } ?? "—"
            let tool = result.toolCallSucceeded.map { $0 ? "✓" : "✗" } ?? "—"
            let long = result.longContextSucceeded.map { $0 ? "✓" : "✗" } ?? "—"
            lines.append("\(pad(String(result.model.prefix(44)), 44))\(result.disturbed ? "⚠︎" : " ")\(pad(result.engine.title, 10)) \(pad(decode, 8)) \(pad(prefill, 8)) \(pad(ttft, 8))    \(tool)     \(long)     \(result.reasoningObserved ? "oui" : "non")   \(result.peakMemoryBytes.map(Format.memory) ?? "—")")
        }
        lines.append("génér. et lecture en tokens/s ; « pensée » : raisonnement produit malgré la demande de le couper ; ⚠︎ : mesure perturbée par d'autres clients.")
        return lines.joined(separator: "\n")
    }

    static func radar(_ report: RadarReport, all: Bool, bandwidth: Double?) -> String {
        var lines = ["Radar du \(report.fetchedAt.formatted(date: .abbreviated, time: .shortened))"]
        lines += report.sources.map { "  · \($0)" }
        lines.append("")
        if report.items.isEmpty { lines.append("Aucun modèle retenu.") }
        for item in report.items {
            let size = item.sizeBytes.map(Format.bytes) ?? "taille ?"
            let engines = item.engines.map(\.title).joined(separator: " ou ")
            lines.append("\(item.id)  \(size) · \(engines) (probable)\(item.createdAt.map { " · \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "")")
            lines.append("    " + item.reasons.joined(separator: " · "))
            var traits = item.usages.map { $0.isEmpty ? "usage non déterminé" : $0.map(\.usage.title).joined(separator: ", ") } ?? "usage non classé (liste à actualiser)"
            if let speed = item.speedBound(bandwidth: bandwidth) { traits += " · " + speed.summary }
            lines.append("    " + traits)
            for warning in item.warnings { lines.append("    ⚠︎ \(warning)") }
        }
        let counts = Dictionary(grouping: report.excluded, by: \.reason).mapValues(\.count).sorted { $0.value > $1.value }
        lines.append("")
        lines.append("Écartés : \(report.excluded.count) — " + counts.prefix(6).map { "\($0.key) (\($0.value))" }.joined(separator: " ; "))
        if all { lines += report.excluded.map { "  \($0.id) : \($0.reason)" } }
        return lines.joined(separator: "\n")
    }

    static func memorySummary(_ stats: MemoryStats, omlx: OMLXState?) -> String {
        "Mémoire : \(Format.memory(stats.usedBytes)) utilisés sur \(Format.memory(stats.totalBytes)), pression \(stats.pressure.title.lowercased()), marge macOS \(stats.freePercent.map { "\($0) %" } ?? "—") (mémoire inactive comprise)"
    }

    static func memory(_ report: MemoryReport, omlx: OMLXState?) -> String {
        let stats = report.stats
        var lines = [memorySummary(stats, omlx: omlx),
                     "  applications \(Format.memory(stats.appBytes)) · réservée \(Format.memory(stats.wiredBytes)) · compressée \(Format.memory(stats.compressedBytes)) · fichiers en cache \(Format.memory(stats.cachedFilesBytes))",
                     "", "Plus gros consommateurs"]
        for group in report.groups.prefix(15) {
            let marker = group.role == .application ? "" : " [\(group.role.title)]"
            lines.append("  \(pad(Format.memory(group.footprintBytes), 9)) \(group.title)\(marker)\(group.detail.map { " · \($0)" } ?? "")")
        }
        return lines.joined(separator: "\n")
    }

    static func models(_ snapshot: InventorySnapshot, all: Bool) -> String {
        let models = snapshot.models.filter { all || $0.kind == .languageModel || $0.isBrokenLink }
        var lines: [String] = []
        for store in StoreKind.allCases {
            let inStore = models.filter { $0.store == store }
            guard !inStore.isEmpty else { continue }
            lines.append("\(store.title) (\(inStore.count))")
            for model in inStore {
                lines.append("  \(pad(model.isLink ? "lien" : Format.bytes(model.sizeBytes), 9)) \(model.name)  \(describe(model))")
            }
            lines.append("")
        }
        if !all { lines.append("Modèles de langage uniquement ; --all pour tout afficher.") }
        return lines.joined(separator: "\n")
    }

    static func describe(_ model: LocalModel) -> String {
        if model.isBrokenLink { return "LIEN CASSÉ (\(model.brokenReason ?? "?")) → \(model.linkTarget ?? "?")" }
        var parts = [model.format.title]
        if let spec = model.spec {
            if let type = spec.modelType { parts.append(type) }
            if let bits = spec.quantBits { parts.append("\(bits) bits") }
            if let context = spec.maxContext { parts.append("contexte \(Format.tokens(context))") }
            if spec.isPartial { parts.append("métadonnées partielles") }
        }
        if let target = model.linkTarget { parts.append("→ \(target)") }
        return parts.joined(separator: " · ")
    }

    static func disk(_ snapshot: InventorySnapshot) -> String {
        let disk = snapshot.disk
        var lines = ["Volume : \(disk.volumeAvailableBytes.map(Format.bytes) ?? "—") libres sur \(disk.volumeTotalBytes.map(Format.bytes) ?? "—")", "", "Emplacements"]
        for usage in disk.stores {
            let state = usage.exists ? "\(Format.bytes(usage.totalBytes)) · \(usage.modelCount) modèles" : "absent"
            lines.append("  \(pad(usage.store.kind.title, 20)) \(state)  \(usage.store.path)")
        }
        lines += ["", "Même architecture, probablement le même modèle de base"]
        if disk.architectureGroups.isEmpty { lines.append("  aucune") }
        for group in disk.architectureGroups {
            lines.append("  \(Format.bytes(group.totalBytes)) · \(group.modelType)")
            for id in group.modelIDs {
                let model = snapshot.model(id: id)
                lines.append("    \(pad(model.map { Format.bytes($0.sizeBytes) } ?? "", 9)) \(model.map { "\($0.store.title) · \($0.name)" } ?? id)")
            }
        }
        lines += ["", "Liens cassés"]
        if disk.brokenLinkIDs.isEmpty { lines.append("  aucun") }
        for id in disk.brokenLinkIDs {
            let model = snapshot.model(id: id)
            lines.append("  \(model?.path ?? id) → \(model?.linkTarget ?? "?") (\(model?.brokenReason ?? "?"))")
        }
        lines += ["", "Entrées vides du cache Hugging Face (\(Format.bytes(disk.emptyCacheBytes)))"]
        if disk.emptyCacheEntries.isEmpty { lines.append("  aucune") }
        for entry in disk.emptyCacheEntries { lines.append("  \(entry.name)") }
        return lines.joined(separator: "\n")
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }
}
