import Foundation
import ModelCore

/// Minimal MCP server over stdio: one JSON-RPC message per line. Stdout carries protocol messages only.
struct MCPServer {
    static let protocolVersion = "2025-06-18"

    struct Tool {
        var name: String
        var description: String
        var properties: [String: Any] = [:]
        var required: [String] = []
        var readOnly = true
        var run: ([String: Any]) async -> Encodable
    }

    let tools: [Tool] = [
        Tool(name: "get_status",
             description: "Résumé en lecture seule : moteurs locaux (oMLX, MTPLX, mlx-serve), état, port, modèles chargés, mémoire et disque.") { _ in
            await Inventory.take()
        },
        Tool(name: "list_models",
             description: "Modèles présents sur le disque, avec emplacement, taille, format, architecture, quantification et contexte maximal.",
             properties: ["all": ["type": "boolean", "description": "Inclure embeddings, rerankers et autres modèles. Par défaut : modèles de langage seulement."]]) { arguments in
            let all = arguments["all"] as? Bool ?? false
            return await Inventory.take().models.filter { all || $0.kind == .languageModel || $0.isBrokenLink }
        },
        Tool(name: "list_running_models",
             description: "Modèles en mémoire maintenant (serveurs des moteurs et processus de modèle hors moteur) : mémoire, ports, depuis quand, qui les a lancés (app, session d'agent, projet) et clients connectés. Lecture seule : l'arrêt se fait dans l'app, après confirmation.") { _ in
            await Runtime.current().running
        },
        Tool(name: "estimate_memory",
             description: "Mémoire nécessaire pour charger un modèle sur un moteur (poids mesurés ou taille sur disque, cache de contexte), mémoire disponible maintenant, verdict et quoi libérer. Lecture seule.",
             properties: modelProperties, required: ["model"]) { arguments in
            await withModel(arguments) { model, engine, context, snapshot in
                MemoryPlanner.estimate(model: model, engine: engine, context: context, memory: snapshot.memory,
                                       omlx: snapshot.engine(.omlx)?.omlx, running: snapshot.running)
            }
        },
        Tool(name: "start_model",
             description: "Charge un modèle : dans oMLX (via son API), ou en lançant un serveur MTPLX ou mlx-serve sur 127.0.0.1 (port 18100 à 18199). Ré-estime la mémoire au moment du lancement et refuse si le modèle ne tient pas. Attend qu'il réponde et renvoie l'adresse. L'arrêt ne se fait pas par MCP : il se fait dans l'app, après confirmation.",
             properties: modelProperties, required: ["model"], readOnly: false) { arguments in
            await withModel(arguments) { model, engine, context, snapshot in
                // A large model takes minutes to load; MCP clients give up much sooner. Answer within 25 s,
                // and let the load go on: the server is recorded and shows in list_running_models once ready.
                let box = OutcomeBox()
                Task { box.set(await ModelStarter.start(model, engine: engine, context: context, snapshot: snapshot)) }
                for _ in 0..<25 {
                    if let outcome = box.get() { return StartAnswer(outcome) }
                    try? await Task.sleep(for: .seconds(1))
                }
                return Pending(message: "\(model.name) se charge toujours sur \(engine.title) après 25 s. Il apparaîtra dans list_running_models une fois prêt.")
            }
        },
        Tool(name: "open_in_harness",
             description: "Ouvre pour l'utilisateur, dans une fenêtre Ghostty du dossier donné, un harness (claude, codex, pi, opencode) branché sur un modèle déjà en mémoire ; « dsh » configure DeepSeek Harness et ouvre l'app. Ne lance pas de modèle : utiliser start_model avant si besoin.",
             properties: [
                "harness": ["type": "string", "enum": ["claude", "codex", "pi", "opencode", "dsh"]],
                "model": ["type": "string", "description": "Partie du nom d'un modèle en cours ; par défaut le premier."],
                "directory": ["type": "string", "description": "Dossier du projet (chemin absolu ou ~)."]
             ],
             required: ["harness", "directory"], readOnly: false) { arguments in
            let name = (arguments["harness"] as? String ?? "").lowercased()
            guard let kind = HarnessKind.allCases.first(where: { ($0.command ?? "dsh") == name }) else { return Failure(error: "Harness inconnu.") }
            let snapshot = await Inventory.take()
            let query = arguments["model"] as? String
            guard let target = HarnessTarget.targets(in: snapshot).first(where: { query == nil || $0.modelID.localizedCaseInsensitiveContains(query!) }) else {
                return Failure(error: "Aucun modèle en cours ne correspond ; lancez-le d'abord avec start_model.")
            }
            if let reason = HarnessPlanner.unavailableReason(kind, target: target, installed: HarnessInstallations.detect()) { return Failure(error: reason) }
            let directory = ((arguments["directory"] as? String ?? "~") as NSString).expandingTildeInPath
            do {
                let launch = try HarnessPlanner.prepare(kind, target: target, directory: directory)
                try HarnessOpener.open(launch)
                return Opened(harness: kind.title, model: target.modelID, url: target.baseURL, directory: directory, configuredFiles: launch.writtenFiles)
            } catch {
                return Failure(error: "\(error)")
            }
        },
        Tool(name: "get_model_context",
             description: "Tout ce qu'il faut pour proposer la meilleure configuration d'un modèle sur un moteur de ce Mac : machine, moteur et version, architecture et quantification, valeurs du generation_config.json, recette en vigueur et ses sources, pièges constatés, mesures de mémoire, derniers bancs d'essai, et pour oMLX les meilleurs résultats publiés sur omlx.ai pour cette puce. Indique aussi quels champs de recette s'appliquent à ce moteur. Lecture seule.",
             properties: modelProperties, required: ["model"]) { arguments in
            await withModel(arguments) { model, engine, _, snapshot in
                await ModelContext.build(model: model, engine: engine, snapshot: snapshot)
            }
        },
        Tool(name: "save_recipe",
             description: "Enregistre la recette d'un modèle sur un moteur (signée « Claude »). Appliquée quand l'app lance MTPLX ou mlx-serve ; indicative pour oMLX. Chaque valeur doit venir d'une source citée dans « sources » (page, fiche du modèle, mesure). Ne lance rien.",
             properties: modelProperties.merging([
                "reasoning": ["type": "string", "enum": ["on", "off", "auto"], "description": "MTPLX seulement."],
                "temperature": ["type": "number"], "top_p": ["type": "number"], "top_k": ["type": "integer"],
                "flags": ["type": "array", "items": ["type": "string"], "description": "Options supplémentaires du moteur, une par élément."],
                "notes": ["type": "array", "items": ["type": "string"]],
                "sources": ["type": "array", "items": ["type": "string"], "description": "Obligatoire : d'où vient chaque valeur, avec date."]
             ]) { current, _ in current }, required: ["model", "sources"], readOnly: false) { arguments in
            await withModel(arguments) { model, engine, context, _ in
                guard let sources = arguments["sources"] as? [String], !sources.isEmpty else { return Failure(error: "« sources » est obligatoire.") }
                var recipe = RecipeDeriver.effective(model: model, engine: engine)
                if let context { recipe.context = context }
                if let reasoning = arguments["reasoning"] as? String { recipe.reasoning = reasoning == "auto" ? nil : reasoning }
                if let value = (arguments["temperature"] as? NSNumber)?.doubleValue { recipe.sampling.temperature = value }
                if let value = (arguments["top_p"] as? NSNumber)?.doubleValue { recipe.sampling.topP = value }
                if let value = (arguments["top_k"] as? NSNumber)?.intValue { recipe.sampling.topK = value }
                if let flags = arguments["flags"] as? [String] { recipe.flags = flags }
                for note in arguments["notes"] as? [String] ?? [] where !recipe.notes.contains(note) { recipe.notes.append(note) }
                let stamp = Date().formatted(date: .abbreviated, time: .omitted)
                recipe.sources += sources.map { "\($0) (Claude, \(stamp))" }
                recipe.author = .claude
                do { try RecipeStore.shared.save(recipe) } catch { return Failure(error: "\(error)") }
                return recipe
            }
        },
        Tool(name: "list_recipes", description: "Recettes enregistrées (écrites par l'utilisateur ou par Claude). Lecture seule.") { _ in
            RecipeStore.shared.all()
        },
        Tool(name: "list_benchmarks",
             description: "Résultats des bancs d'essai : délai avant le premier token, vitesses de lecture et de génération, appel d'outil, contexte long, pic mémoire, conditions de mesure. Lecture seule.") { _ in
            BenchmarkStore.shared.all()
        },
        Tool(name: "run_benchmark",
             description: "Mesure un modèle déjà en mémoire (consigne courte, contexte d'environ 13K tokens, appel d'outil) directement sur son moteur. Prend une à trois minutes : répond après 25 s au plus, le résultat arrive ensuite dans list_benchmarks.",
             properties: ["model": ["type": "string", "description": "Partie du nom d'un modèle en cours."]], required: ["model"], readOnly: false) { arguments in
            let query = arguments["model"] as? String ?? ""
            let snapshot = await Inventory.take()
            guard let target = HarnessTarget.targets(in: snapshot).first(where: { $0.modelID.localizedCaseInsensitiveContains(query) }),
                  let running = snapshot.running.first(where: { $0.models.contains(target.modelID) }) else {
                return Failure(error: "« \(query) » n'est pas en mémoire : lancez-le d'abord avec start_model.")
            }
            let box = BenchmarkBox()
            Task {
                let local = snapshot.models.first { target.engine == .omlx ? OMLXIdentity.matches(target.modelID, $0) : LaunchPlan.servedName($0) == target.modelID }
                let result = await Benchmark.run(baseURL: target.baseURL, model: target.modelID, engine: target.engine,
                                                 engineVersion: snapshot.engine(target.engine)?.installation.version, machine: snapshot.machine,
                                                 pid: running.pid, context: target.contextWindow,
                                                 recipeID: local.map { RecipeDeriver.effective(model: $0, engine: target.engine).id },
                                                 loadSeconds: LaunchRegistry.shared.servers().first { $0.pid == running.pid }?.loadSeconds,
                                                 otherClients: running.clients.map(\.title), omlxURL: snapshot.engine(.omlx)?.instances.first?.url)
                try? BenchmarkStore.shared.add(result)
                box.set(result)
            }
            for _ in 0..<25 {
                if let result = box.get() { return result }
                try? await Task.sleep(for: .seconds(1))
            }
            return Pending(message: "Mesure de \(target.modelID) en cours ; le résultat apparaîtra dans list_benchmarks.")
        },
        Tool(name: "get_radar",
             description: "Nouveaux modèles de langage au format MLX qui tiennent dans la mémoire de ce Mac et n'y sont pas encore : tendances Hugging Face, nouveautés des auteurs suivis, favoris Spicilege, autres versions des modèles présents. Chaque modèle donne ses raisons ; les modèles écartés aussi. Liste du jour (mise en cache 24 h). Lecture seule : le téléchargement se fait dans l'app ou avec llmarium radar download.",
             properties: ["refresh": ["type": "boolean", "description": "Forcer une nouvelle recherche."]]) { arguments in
            await Radar.report(snapshot: await Inventory.take(), refresh: arguments["refresh"] as? Bool ?? false)
        },
        Tool(name: "get_disk_report",
             description: "Occupation des dossiers de modèles, architectures présentes en plusieurs exemplaires, liens cassés et entrées vides du cache Hugging Face. Ne supprime rien.") { _ in
            await Inventory.take().disk
        },
        Tool(name: "get_memory_report",
             description: "Mémoire du Mac, pression et plus gros consommateurs (apps, moteurs, processus de modèles hors moteur), plus le plafond mémoire d'oMLX.") { _ in
            let processes = ProcessScanner.all()
            let engines = await EngineDetector.detect(processes: processes)
            return MemoryAnswer(memory: .current(processes: processes), omlx: engines.first { $0.kind == .omlx }?.omlx)
        }
    ]

    static let modelProperties: [String: Any] = [
        "model": ["type": "string", "description": "Nom du modèle (owner/name, nom du dossier ou partie unique du nom)."],
        "engine": ["type": "string", "enum": ["omlx", "mtplx", "mlx-serve"], "description": "Moteur ; par défaut le premier compatible."],
        "context": ["type": "integer", "description": "Contexte en tokens ; par défaut le maximum du modèle, plafonné à 64K."]
    ]

    struct Failure: Encodable { var error: String }

    struct Opened: Encodable {
        var harness: String
        var model: String
        var url: String
        var directory: String
        var configuredFiles: [String]
    }

    struct Pending: Encodable {
        var started = false
        var loading = true
        var message: String
    }

    final class BenchmarkBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: BenchmarkResult?
        func set(_ value: BenchmarkResult) { lock.withLock { result = value } }
        func get() -> BenchmarkResult? { lock.withLock { result } }
    }

    final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: StartOutcome?
        func set(_ value: StartOutcome) { lock.lock(); outcome = value; lock.unlock() }
        func get() -> StartOutcome? { lock.lock(); defer { lock.unlock() }; return outcome }
    }

    /// Resolves `model` and `engine` from the call, then runs `body` with a fresh inventory.
    static func withModel(_ arguments: [String: Any],
                          _ body: (LocalModel, EngineKind, Int?, InventorySnapshot) async -> Encodable) async -> Encodable {
        let snapshot = await Inventory.take()
        guard let query = arguments["model"] as? String else { return Failure(error: "Paramètre « model » manquant.") }
        let model: LocalModel
        switch ModelResolver.find(query, in: snapshot.models) {
        case .success(let found): model = found
        case .failure(let error): return Failure(error: error.description)
        }
        let engines = EngineCompatibility.engines(for: model, snapshot: snapshot)
        let requested = (arguments["engine"] as? String).flatMap { name in
            EngineKind.allCases.first { $0.rawValue.lowercased() == name.lowercased().replacingOccurrences(of: "-", with: "") }
        }
        guard let engine = requested ?? engines.first else {
            return Failure(error: "Aucun moteur ne peut servir \(model.name).")
        }
        return await body(model, engine, (arguments["context"] as? NSNumber)?.intValue, snapshot)
    }

    struct StartAnswer: Encodable {
        var started: Bool
        var message: String
        var url: String?
        var servedModels: [String]?
        var pid: Int32?
        var logPath: String?
        var estimate: MemoryEstimate

        init(_ outcome: StartOutcome) {
            estimate = outcome.estimate
            started = false
            switch outcome.result {
            case .ready(let server, let served, let seconds):
                started = true
                message = "Prêt en \(seconds) s."
                url = "http://127.0.0.1:\(server.port)/v1"
                servedModels = served
                pid = server.pid
                logPath = server.logPath
            case .loadedInOMLX(let id, let seconds):
                started = true
                message = "\(id) chargé dans oMLX en \(seconds) s."
                servedModels = [id]
            case .failed(let reason, let log):
                message = reason + (log.map { "\n\($0)" } ?? "")
            case nil:
                message = outcome.refusal ?? "Rien n'a été lancé."
            }
        }
    }

    struct MemoryAnswer: Encodable {
        var memory: MemoryReport
        var omlx: OMLXState?
    }

    func run() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                  let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
                if !line.isEmpty { send(error: -32700, message: "Parse error", id: NSNull()) }
                continue
            }
            await handle(message)
        }
    }

    func handle(_ message: [String: Any]) async {
        let method = message["method"] as? String ?? ""
        // Notifications carry no id and get no answer.
        guard let id = message["id"] else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            send(result: [
                "protocolVersion": requested ?? Self.protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "llmarium", "version": "0.1.0"],
                "instructions": "Moteurs et modèles locaux de ce Mac. Tous les outils sont en lecture seule sauf start_model, qui charge un modèle après un contrôle de mémoire, et open_in_harness, qui ouvre un harness pour l'utilisateur. Aucun outil n'arrête, ne décharge ni ne supprime : cela se fait dans l'app, après confirmation."
            ], id: id)
        case "ping":
            send(result: [:], id: id)
        case "tools/list":
            send(result: ["tools": tools.map { tool in
                ["name": tool.name, "description": tool.description,
                 "inputSchema": ["type": "object", "properties": tool.properties, "required": tool.required, "additionalProperties": false],
                 "annotations": ["readOnlyHint": tool.readOnly, "destructiveHint": false, "openWorldHint": false]]
            }], id: id)
        case "tools/call":
            guard let name = params["name"] as? String, let tool = tools.first(where: { $0.name == name }) else {
                send(error: -32602, message: "Unknown tool", id: id)
                return
            }
            let value = await tool.run(params["arguments"] as? [String: Any] ?? [:])
            let text = (try? JSONCoding.encoder.encode(AnyEncodable(value))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            send(result: ["content": [["type": "text", "text": text]], "isError": false], id: id)
        default:
            send(error: -32601, message: "Method not found", id: id)
        }
    }

    func send(result: Any, id: Any) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func send(error code: Int, message: String, id: Any) {
        write(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}

struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
