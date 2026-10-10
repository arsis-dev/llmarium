import Foundation

public struct Sampling: Codable, Hashable, Sendable {
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var repetitionPenalty: Double?

    public init(temperature: Double? = nil, topP: Double? = nil, topK: Int? = nil, repetitionPenalty: Double? = nil) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.repetitionPenalty = repetitionPenalty
    }

    public var isEmpty: Bool { temperature == nil && topP == nil && topK == nil && repetitionPenalty == nil }

    public var summary: String {
        var parts: [String] = []
        if let temperature { parts.append("température \(temperature.formatted())") }
        if let topP { parts.append("top_p \(topP.formatted())") }
        if let topK { parts.append("top_k \(topK)") }
        if let repetitionPenalty { parts.append("pénalité de répétition \(repetitionPenalty.formatted())") }
        return parts.isEmpty ? "valeurs du moteur" : parts.joined(separator: ", ")
    }
}

public enum RecipeAuthor: String, Codable, Sendable {
    case auto, user = "utilisateur", claude = "Claude"

    public var title: String {
        switch self {
        case .auto: "Déduite des fichiers du modèle"
        case .user: "Écrite par vous"
        case .claude: "Écrite par Claude"
        }
    }
}

/// How to serve one model on one engine on this Mac. Applied when the app starts MTPLX or mlx-serve; informational
/// for oMLX, whose settings live in its own app.
public struct Recipe: Codable, Hashable, Sendable, Identifiable {
    public var engine: EngineKind
    public var model: String
    public var context: Int?
    /// MTPLX's `--reasoning` (`on`, `off`, `auto`); nil keeps the engine default.
    public var reasoning: String?
    public var sampling: Sampling
    /// Extra engine arguments, as an array.
    public var flags: [String]
    public var notes: [String]
    /// Where each value comes from, with dates.
    public var sources: [String]
    public var author: RecipeAuthor
    public var updatedAt: Date

    public var id: String { Self.key(engine: engine, model: model) }

    public static func key(engine: EngineKind, model: String) -> String { "\(engine.rawValue):\(model)" }

    public init(engine: EngineKind, model: String, context: Int? = nil, reasoning: String? = nil, sampling: Sampling = Sampling(),
                flags: [String] = [], notes: [String] = [], sources: [String] = [], author: RecipeAuthor = .auto, updatedAt: Date = Date()) {
        self.engine = engine
        self.model = model
        self.context = context
        self.reasoning = reasoning
        self.sampling = sampling
        self.flags = flags
        self.notes = notes
        self.sources = sources
        self.author = author
        self.updatedAt = updatedAt
    }

    /// Engine arguments this recipe adds, skipping any option the command already carries.
    public func arguments(for engine: EngineKind, existing: [String]) -> [String] {
        var added: [String] = []
        func add(_ option: String, _ value: String?) {
            guard let value, !existing.contains(option), !added.contains(option), !flags.contains(option) else { return }
            added += [option, value]
        }
        func number(_ value: Double?) -> String? { value.map { String($0) } }
        switch engine {
        case .mtplx:
            add("--reasoning", reasoning)
            add("--default-temperature", number(sampling.temperature))
            add("--default-top-p", number(sampling.topP))
            add("--default-top-k", sampling.topK.map(String.init))
        case .mlxServe:
            add("--temp", number(sampling.temperature))
            add("--top-p", number(sampling.topP))
            add("--top-k", sampling.topK.map(String.init))
        case .omlx:
            return []
        }
        // Free flags go last, unless the command already has that option.
        var index = 0
        while index < flags.count {
            let flag = flags[index]
            let takesValue = index + 1 < flags.count && !flags[index + 1].hasPrefix("--")
            if !existing.contains(flag) {
                added.append(flag)
                if takesValue { added.append(flags[index + 1]) }
            }
            index += takesValue ? 2 : 1
        }
        return added
    }
}

public final class RecipeStore: @unchecked Sendable {
    public static let shared = RecipeStore(file: AppPaths.support.appending(path: "recipes.json"))

    private let file: URL
    private let lock = NSLock()

    public init(file: URL) { self.file = file }

    public func all() -> [Recipe] { lock.withLock { read() }.sorted { $0.id < $1.id } }

    public func recipe(engine: EngineKind, model: String) -> Recipe? {
        lock.withLock { read().first { $0.engine == engine && $0.model == model } }
    }

    public func save(_ recipe: Recipe) throws {
        try lock.withLock {
            var recipes = read().filter { $0.id != recipe.id }
            var stored = recipe
            stored.updatedAt = Date()
            recipes.append(stored)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(recipes).write(to: file, options: .atomic)
        }
    }

    public func remove(engine: EngineKind, model: String) throws {
        try lock.withLock {
            let recipes = read().filter { !($0.engine == engine && $0.model == model) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(recipes).write(to: file, options: .atomic)
        }
    }

    private func read() -> [Recipe] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Recipe].self, from: data)) ?? []
    }
}

public enum RecipeDeriver {
    /// The recipe the app uses: the saved one, otherwise one built from the model's files and the known pitfalls.
    public static func effective(model: LocalModel, engine: EngineKind, store: RecipeStore = .shared) -> Recipe {
        if var saved = store.recipe(engine: engine, model: model.name) {
            // Pitfalls stay visible even on a saved recipe.
            for (note, _) in Knowledge.notes(engine: engine) where !saved.notes.contains(note) { saved.notes.append(note) }
            return saved
        }
        return derive(model: model, engine: engine)
    }

    /// Only what files and this project's own findings say: nothing is guessed about the model.
    public static func derive(model: LocalModel, engine: EngineKind) -> Recipe {
        var recipe = Recipe(engine: engine, model: model.name)
        if let data = try? Data(contentsOf: URL(fileURLWithPath: model.path).resolvingSymlinksInPath().appending(path: "generation_config.json")),
           let sampling = sampling(from: data), !sampling.isEmpty {
            recipe.sampling = sampling
            recipe.sources.append("generation_config.json du modèle (valeurs du fichier ; certains modèles en publient d'autres selon le mode de raisonnement)")
        } else {
            recipe.sources.append("Aucune valeur d'échantillonnage publiée dans le dossier du modèle")
        }
        if let max = model.spec?.maxContext {
            recipe.context = min(max, 65_536)
            recipe.sources.append("Contexte : maximum du modèle (\(Format.tokens(max))), plafonné à 64K par défaut")
        }
        for (note, source) in Knowledge.notes(engine: engine) {
            recipe.notes.append(note)
            recipe.sources.append(source)
        }
        return recipe
    }

    static func sampling(from data: Data) -> Sampling? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func double(_ key: String) -> Double? { (root[key] as? NSNumber)?.doubleValue }
        return Sampling(temperature: double("temperature"), topP: double("top_p"), topK: (root["top_k"] as? NSNumber)?.intValue,
                        repetitionPenalty: double("repetition_penalty"))
    }
}

/// Pitfalls this project ran into, with when and where. Nothing here comes from general knowledge about models.
public enum Knowledge {
    public static func notes(engine: EngineKind) -> [(note: String, source: String)] {
        switch engine {
        case .mtplx:
            return [
                ("Raisonnement actif par défaut : il consomme les tokens de sortie et peut laisser une réponse vide. « --reasoning off » pour les clients qui attendent du texte ou du JSON.",
                 "Essai Modèles locaux du 8 oct. 2026"),
                ("MTPLX ignore « enable_thinking » envoyé dans la requête : seul le lancement décide.",
                 "Note de la configuration LiteLLM du 7 juil. 2026"),
                ("« mtplx tune » mesure la profondeur MTP la plus rapide sur ce Mac (plusieurs minutes, charge le modèle).",
                 "Aide de MTPLX 2.11.3")
            ]
        case .omlx:
            return [
                ("Réglages à appliquer dans l'app oMLX (Réglages du modèle → Optimal) ; omlx.ai liste les meilleurs résultats pour cette puce.",
                 "API d'administration d'oMLX 0.7.0"),
                ("Son garde-fou mémoire refuse une requête ou décharge le modèle sous pression ; il ne mesure la taille réelle qu'une fois chargé.",
                 "Essais Modèles locaux des 6 et 8 oct. 2026")
            ]
        case .mlxServe:
            return [
                ("Écoute par défaut sur 0.0.0.0 (réseau local) : l'app impose 127.0.0.1.", "Aide de mlx-serve 26.10.1")
            ]
        }
    }
}

/// « Demander à Claude » : a Claude Code session in Ghostty with only this app's MCP server, asked to research
/// the best known settings, propose them with sources, and save the recipe once the user agrees.
public enum ClaudeAsk {
    public static func launch(model: LocalModel, engine: EngineKind, lml: String) -> HarnessLaunch {
        let config = #"{"mcpServers":{"local-models":{"command":"\#(lml.replacingOccurrences(of: "\"", with: "\\\""))","args":["mcp"]}}}"#
        let prompt = """
        Trouve la meilleure configuration connue pour le modèle « \(model.name) » sur le moteur \(engine.title), sur ce Mac.
        1. Appelle get_model_context (model: « \(model.name) », engine: « \(engine.rawValue) ») : machine, versions, architecture, valeurs du fichier, recette actuelle, mesures, pièges déjà constatés et, pour oMLX, les résultats publiés sur omlx.ai.
        2. Cherche sur le web les réglages recommandés pour ce modèle (fiche du modèle, éditeur, quantificateur, documentation du moteur, retours de la communauté), en distinguant les modes avec et sans raisonnement.
        3. Propose-moi une recette (contexte, raisonnement, température, top_p, top_k, options du moteur, notes) en citant une source datée pour chaque valeur, et ce qui reste incertain.
        4. Seulement si je confirme : enregistre-la avec save_recipe. Ne modifie rien d'autre.
        """
        return HarnessLaunch(kind: .claudeCode,
                             arguments: ["claude", "--mcp-config", config,
                                         "--allowedTools", "mcp__local-models__get_model_context", "WebSearch", "WebFetch", "--", prompt],
                             environment: [:], directory: AppPaths.support.path, appToOpen: nil, writtenFiles: [])
    }

    /// `mtplx tune` for one model, in a window the user watches: it loads the model and runs for minutes.
    public static func mtplxTune(model: LocalModel) -> TerminalCommand {
        TerminalCommand(arguments: ["mtplx", "tune", "--model", model.name], directory: FileManager.default.homeDirectoryForCurrentUser.path)
    }
}
