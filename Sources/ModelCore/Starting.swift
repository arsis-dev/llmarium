import Foundation

public enum ModelResolver {
    /// Exact name or identifier first, then folder name, then a unique partial match.
    public static func find(_ query: String, in models: [LocalModel]) -> Result<LocalModel, ResolveError> {
        let usable = models.filter { !$0.isBrokenLink }
        if let exact = usable.first(where: { $0.name == query || $0.id == query }) { return .success(exact) }
        let byLeaf = usable.filter { LaunchPlan.servedName($0) == query }
        if byLeaf.count == 1 { return .success(byLeaf[0]) }
        let partial = usable.filter { $0.name.localizedCaseInsensitiveContains(query) }
        switch partial.count {
        case 1: return .success(partial[0])
        case 0: return .failure(.notFound(query))
        default: return .failure(.ambiguous(query, partial.map(\.name)))
        }
    }

    public enum ResolveError: Error, CustomStringConvertible {
        case notFound(String)
        case ambiguous(String, [String])

        public var description: String {
            switch self {
            case .notFound(let query): "Aucun modèle ne correspond à « \(query) »."
            case .ambiguous(let query, let names): "« \(query) » correspond à plusieurs modèles : \(names.joined(separator: ", "))."
            }
        }
    }
}

public enum EngineCompatibility {
    /// V1 is strict: MTPLX and mlx-serve serve their own folder; oMLX serves what it lists itself.
    public static func engines(for model: LocalModel, snapshot: InventorySnapshot) -> [EngineKind] {
        guard !model.isBrokenLink else { return [] }
        var engines: [EngineKind] = []
        if omlxID(for: model, snapshot: snapshot) != nil { engines.append(.omlx) }
        if model.store == .mtplx, snapshot.engine(.mtplx)?.installation.isInstalled == true { engines.append(.mtplx) }
        if model.store == .mlxServe, snapshot.engine(.mlxServe)?.installation.isInstalled == true { engines.append(.mlxServe) }
        return engines
    }

    public static func omlxID(for model: LocalModel, snapshot: InventorySnapshot) -> String? {
        snapshot.engine(.omlx)?.omlx?.models.first { OMLXIdentity.matches($0.id, model) }?.id
    }

    /// Why an engine is not offered for this model, in French.
    public static func absenceReason(_ engine: EngineKind, model: LocalModel, snapshot: InventorySnapshot) -> String {
        guard snapshot.engine(engine)?.installation.isInstalled == true else { return "\(engine.title) n'est pas installé." }
        switch engine {
        case .omlx:
            return snapshot.engine(.omlx)?.isRunning == true ? "oMLX ne liste pas ce modèle." : "oMLX n'est pas lancé."
        case .mtplx, .mlxServe:
            return "\(engine.title) ne sert que les modèles de son dossier."
        }
    }
}

public struct StartOutcome: Sendable {
    public var estimate: MemoryEstimate
    /// Nil when the start was refused before anything ran.
    public var result: ModelLauncher.StartResult?
    public var refusal: String?
}

public enum ModelStarter {
    /// A launch that worked goes to the menu bar's recent list.
    static func remember(_ result: ModelLauncher.StartResult, model: LocalModel, engine: EngineKind, context: Int?) {
        switch result {
        case .ready, .loadedInOMLX: QuickLaunchStore.shared.record(modelID: model.id, engine: engine, context: context)
        case .failed: break
        }
    }

    /// Re-reads memory now (not the snapshot the user looked at), refuses a model that does not fit unless `force`,
    /// then loads it in oMLX or starts an MTPLX / mlx-serve server for it.
    public static func start(_ model: LocalModel, engine: EngineKind, context: Int?, port: Int? = nil,
                             snapshot: InventorySnapshot, force: Bool = false, idleStopAfterMinutes: Int? = nil) async -> StartOutcome {
        let runtime = await Runtime.current()
        let omlx = runtime.engines.first { $0.kind == .omlx }
        let recipe = RecipeDeriver.effective(model: model, engine: engine)
        let context = context ?? recipe.context
        let estimate = MemoryPlanner.estimate(model: model, engine: engine, context: context, memory: runtime.memory,
                                              omlx: omlx?.omlx, running: runtime.running)
        func refuse(_ reason: String) -> StartOutcome { StartOutcome(estimate: estimate, result: nil, refusal: reason) }

        guard EngineCompatibility.engines(for: model, snapshot: snapshot).contains(engine) else {
            return refuse(EngineCompatibility.absenceReason(engine, model: model, snapshot: snapshot))
        }
        // oMLX checks memory itself and answers 507 when a model does not fit: it decides, the estimate only warns.
        if estimate.verdict == .tooLarge && !force && engine != .omlx {
            return refuse("Il manque environ \(Format.memory(estimate.shortfallBytes)) : \(Format.memory(estimate.totalBytes)) nécessaires, \(Format.memory(max(0, estimate.availableBytes))) disponibles.")
        }
        switch engine {
        case .omlx:
            guard let id = EngineCompatibility.omlxID(for: model, snapshot: snapshot),
                  let url = omlx?.instances.first(where: { $0.api == .ok })?.url else { return refuse("oMLX ne répond pas.") }
            if omlx?.omlx?.models.first(where: { $0.id == id })?.loaded == true { return refuse("\(id) est déjà chargé dans oMLX.") }
            let result = await ModelLauncher.loadInOMLX(id, baseURL: url)
            remember(result, model: model, engine: engine, context: nil)
            return StartOutcome(estimate: estimate, result: result, refusal: nil)
        case .mtplx, .mlxServe:
            if let serving = runtime.running.first(where: { $0.role.engine == engine && $0.models.contains(LaunchPlan.servedName(model)) }) {
                return refuse("\(engine.title) sert déjà ce modèle (PID \(serving.pid), port \(serving.ports.map(String.init).joined(separator: ", "))).")
            }
            let used = Set(PortTable.current().listening.values.flatMap { $0 })
            guard let port = port ?? ModelLauncher.freePort(excluding: used) else { return refuse("Aucun port libre entre 18100 et 18199.") }
            guard let installation = runtime.engines.first(where: { $0.kind == engine })?.installation else { return refuse("\(engine.title) introuvable.") }
            do {
                let plan = try LaunchPlan.make(model: model, engine: engine, port: port,
                                               context: context ?? estimate.context, installation: installation, recipe: recipe)
                let result = await ModelLauncher.start(plan, model: model, idleStopAfterMinutes: idleStopAfterMinutes)
                remember(result, model: model, engine: engine, context: plan.context)
                return StartOutcome(estimate: estimate, result: result, refusal: nil)
            } catch {
                return refuse("\(error)")
            }
        }
    }
}
