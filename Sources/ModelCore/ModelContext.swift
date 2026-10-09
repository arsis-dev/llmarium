import Foundation

/// Everything known about one model on one engine of this Mac, gathered for « Demander à Claude ».
public struct ModelContext: Encodable, Sendable {
    public var machine: MachineInfo
    public var engine: EngineKind
    public var engineVersion: String?
    public var engineRunning: Bool
    public var model: LocalModel
    public var generationConfig: Sampling?
    public var recipe: Recipe
    /// Which recipe fields this engine applies, in French.
    public var recipeApplies: String
    public var knownPitfalls: [String]
    public var measuredMemory: Measurement?
    public var benchmarks: [BenchmarkResult]
    public var community: [CommunityBenchmark]
    public var launchCommand: [String]?

    public static func build(model: LocalModel, engine: EngineKind, snapshot: InventorySnapshot) async -> ModelContext {
        let installation = snapshot.engine(engine)?.installation ?? EngineInstallation(kind: engine, version: nil, location: nil)
        let recipe = RecipeDeriver.effective(model: model, engine: engine)
        let served = LaunchPlan.servedName(model)
        let generation = (try? Data(contentsOf: URL(fileURLWithPath: model.path).resolvingSymlinksInPath().appending(path: "generation_config.json")))
            .flatMap(RecipeDeriver.sampling(from:))
        let applies: String = switch engine {
        case .mtplx: "context → --context-window ; reasoning → --reasoning ; temperature, top_p, top_k → --default-* ; flags ajoutés tels quels."
        case .mlxServe: "context → --ctx-size ; temperature, top_p, top_k → --temp, --top-p, --top-k ; flags ajoutés tels quels."
        case .omlx: "Rien n'est appliqué automatiquement : oMLX garde ses réglages dans son app (Réglages du modèle). La recette sert de référence."
        }
        let plan = try? LaunchPlan.make(model: model, engine: engine, port: 18_100, context: recipe.context, installation: installation, recipe: recipe)
        return ModelContext(machine: snapshot.machine, engine: engine, engineVersion: installation.version,
                            engineRunning: snapshot.engine(engine)?.isRunning ?? false, model: model, generationConfig: generation,
                            recipe: recipe, recipeApplies: applies, knownPitfalls: Knowledge.notes(engine: engine).map(\.note),
                            measuredMemory: MeasurementStore.shared.measurement(engine: engine, model: engine == .omlx ? served : model.name),
                            benchmarks: BenchmarkStore.shared.all().filter { $0.model == served || $0.model == model.name },
                            community: engine == .omlx ? await CommunityBenchmarks.shared.best(model: served, machine: snapshot.machine) : [],
                            launchCommand: plan.map { [$0.executable] + $0.arguments })
    }
}
