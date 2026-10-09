import Foundation
import ModelCore

@main
struct LML {
    static let usage = """
    lml — moteurs et modèles locaux

    Utilisation :
      lml [status]          Moteurs, mémoire et disque en bref
      lml running           Modèles en mémoire et qui les a lancés
      lml models [--all]    Modèles présents (--all inclut embeddings, rerankers…)
      lml disk              Emplacements, doublons probables, liens cassés, entrées vides
      lml memory            Mémoire et plus gros consommateurs
      lml estimate <modèle> [--engine omlx|mtplx|mlx-serve] [--context N]
                            Mémoire nécessaire, disponible, et quoi libérer
      lml start <modèle> [--engine …] [--context N] [--port N] [--force]
                            Charge le modèle (refusé s'il ne tient pas, sauf --force)
      lml open <harness> [--model …] [--dir dossier] [--headless "consigne"] [--dry-run]
                            Ouvre le modèle dans claude, codex, pi, opencode ou dsh
                            (fenêtre Ghostty ; --headless : une fois, sans interface)
      lml mcp               Serveur MCP sur stdio
    Option : --json pour une sortie JSON.
    L'arrêt et le déchargement se font dans l'app, après confirmation.
    """

    static func main() async {
        let options = Options(Array(CommandLine.arguments.dropFirst()))
        let json = options.flag("json")
        let all = options.flag("all")
        let command = options.positional.first ?? "status"

        switch command {
        case "mcp":
            await MCPServer().run()
        case "memory":
            let report = MemoryReport.current()
            json ? emit(report) : print(Report.memory(report, omlx: nil))
        case "running":
            let runtime = await Runtime.current()
            json ? emit(runtime.running) : print(Report.running(runtime.running))
        case "status", "models", "disk":
            let snapshot = await Inventory.take()
            if json {
                switch command {
                case "models": emit(snapshot.models)
                case "disk": emit(snapshot.disk)
                default: emit(snapshot)
                }
            } else {
                switch command {
                case "models": print(Report.models(snapshot, all: all))
                case "disk": print(Report.disk(snapshot))
                default: print(Report.status(snapshot))
                }
            }
        case "estimate", "start":
            guard let query = options.positional.dropFirst().first else { fail("Précisez un modèle : lml \(command) <modèle>") }
            let snapshot = await Inventory.take()
            let model: LocalModel
            switch ModelResolver.find(query, in: snapshot.models) {
            case .success(let found): model = found
            case .failure(let error): fail(error.description)
            }
            let engines = EngineCompatibility.engines(for: model, snapshot: snapshot)
            let engine: EngineKind
            if let name = options.value("engine") {
                guard let chosen = EngineKind.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased().replacingOccurrences(of: "-", with: "") || $0.title.lowercased() == name.lowercased() }) else {
                    fail("Moteur inconnu : \(name) (omlx, mtplx, mlx-serve)")
                }
                engine = chosen
            } else if let first = engines.first {
                engine = first
            } else {
                fail("Aucun moteur ne peut servir \(model.name) : \(EngineKind.allCases.map { EngineCompatibility.absenceReason($0, model: model, snapshot: snapshot) }.joined(separator: " "))")
            }
            let context = options.value("context").flatMap(Int.init)
            if command == "estimate" {
                let estimate = MemoryPlanner.estimate(model: model, engine: engine, context: context, memory: snapshot.memory,
                                                      omlx: snapshot.engine(.omlx)?.omlx, running: snapshot.running)
                json ? emit(estimate) : print(Report.estimate(estimate, model: model, engine: engine, engines: engines))
            } else {
                if !json { print("Lancement de \(model.name) sur \(engine.title)…") }
                let outcome = await ModelStarter.start(model, engine: engine, context: context, port: options.value("port").flatMap(Int.init),
                                                       snapshot: snapshot, force: options.flag("force"))
                print(Report.start(outcome, model: model, engine: engine))
                if outcome.refusal != nil { exit(1) }
                if case .failed = outcome.result { exit(1) }
            }
        case "open":
            guard let name = options.positional.dropFirst().first,
                  let kind = HarnessKind.allCases.first(where: { [$0.rawValue.lowercased(), $0.command ?? "dsh", $0.title.lowercased()].contains(name.lowercased()) }) else {
                fail("Précisez un harness : claude, codex, pi, opencode ou dsh.")
            }
            var snapshot = await Inventory.take()
            var targets = HarnessTarget.targets(in: snapshot)
            let query = options.value("model")
            var target = targets.first { query == nil || $0.modelID.localizedCaseInsensitiveContains(query!) }
            if target == nil, let query {
                // Not running yet: start it first, with the usual memory check.
                guard case .success(let model) = ModelResolver.find(query, in: snapshot.models),
                      let engine = EngineCompatibility.engines(for: model, snapshot: snapshot).first else {
                    fail("Aucun modèle en cours ni lançable ne correspond à « \(query) ».")
                }
                print("Lancement de \(model.name) sur \(engine.title)…")
                let outcome = await ModelStarter.start(model, engine: engine, context: nil, snapshot: snapshot)
                if let refusal = outcome.refusal { fail("Non lancé : \(refusal)") }
                if case .failed(let reason, _) = outcome.result { fail("Échec : \(reason)") }
                snapshot = await Inventory.take()
                targets = HarnessTarget.targets(in: snapshot)
                target = targets.first { $0.modelID.localizedCaseInsensitiveContains(query) || query.localizedCaseInsensitiveContains($0.modelID) }
            }
            guard let target else {
                fail(targets.isEmpty ? "Aucun modèle en cours : lancez-en un (lml start …) ou précisez --model."
                                     : "Modèles en cours : \(targets.map(\.modelID).joined(separator: ", ")).")
            }
            if let reason = HarnessPlanner.unavailableReason(kind, target: target, installed: HarnessInstallations.detect()) { fail(reason) }
            let directory = options.value("dir").map { ($0 as NSString).expandingTildeInPath } ?? FileManager.default.currentDirectoryPath
            do {
                let launch = try HarnessPlanner.prepare(kind, target: target, directory: directory)
                for file in launch.writtenFiles { print("Configuré : \(file)") }
                if options.flag("dry-run") {
                    print("Commande : \(launch.arguments.joined(separator: " "))\(launch.appToOpen.map { "ouvrir \($0)" } ?? "")")
                    print("Variables : \(launch.environment.keys.sorted().joined(separator: ", "))")
                    exit(0)
                }
                if let prompt = options.value("headless") {
                    let status = HarnessOpener.runHeadless(try HarnessPlanner.headless(launch, prompt: prompt, target: target), launch: launch)
                    exit(status)
                }
                try HarnessOpener.open(launch)
                print("\(kind.title) ouvert avec \(target.modelID) (\(target.engine.title), \(target.baseURL)) dans \(directory).")
                if kind == .deepseekHarness {
                    print("Choisissez « \(target.modelID) (local) » dans le sélecteur de modèle. Si l'app était déjà ouverte, redémarrez-la pour qu'elle relise sa configuration.")
                }
            } catch {
                fail("\(error)")
            }
        case "help", "-h":
            print(usage)
        default:
            FileHandle.standardError.write(Data("Commande inconnue : \(command)\n\n\(usage)\n".utf8))
            exit(64)
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }

    static func emit<T: Encodable>(_ value: T) {
        print(String(decoding: (try? JSONCoding.encoder.encode(value)) ?? Data(), as: UTF8.self))
    }
}

/// `--flag`, `--key value` and positional arguments.
struct Options {
    var positional: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []
    static let valued: Set<String> = ["engine", "context", "port", "model", "dir", "headless"]

    init(_ arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                let key = String(argument.dropFirst(2))
                if Self.valued.contains(key), index + 1 < arguments.count {
                    values[key] = arguments[index + 1]
                    index += 1
                } else {
                    flags.insert(key)
                }
            } else {
                positional.append(argument)
            }
            index += 1
        }
    }

    func flag(_ name: String) -> Bool { flags.contains(name) }
    func value(_ name: String) -> String? { values[name] }
}

enum JSONCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
