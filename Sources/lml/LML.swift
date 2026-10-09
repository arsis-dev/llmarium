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
    static let valued: Set<String> = ["engine", "context", "port"]

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
