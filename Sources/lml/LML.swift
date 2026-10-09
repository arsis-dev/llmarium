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
      lml proxy [--port N]  Point d'entrée local (OpenAI et Anthropic) vers les modèles en cours
      lml proxy import-litellm <fichier>   Reprend les alias et fournisseurs d'une config LiteLLM
      lml proxy port <N>                   Change le port du point d'entrée
      lml provider list | set-key <id> | remove-key <id>   Fournisseurs distants et leurs clés
      lml sync              Inscrit tous les modèles joignables dans Pi et DeepSeek Harness via le point d'entrée
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
            // Through the proxy when it runs: harness settings then survive a model moving to another port.
            let proxyURL = await runningProxy()
            var targets = HarnessTarget.targets(in: snapshot, via: proxyURL)
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
                targets = HarnessTarget.targets(in: snapshot, via: proxyURL)
                target = targets.first { $0.modelID.localizedCaseInsensitiveContains(query) || query.localizedCaseInsensitiveContains($0.modelID) }
            }
            guard let target else {
                fail(targets.isEmpty ? "Aucun modèle en cours : lancez-en un (lml start …) ou précisez --model."
                                     : "Modèles en cours : \(targets.map(\.modelID).joined(separator: ", ")).")
            }
            if let reason = HarnessPlanner.unavailableReason(kind, target: target, installed: HarnessInstallations.detect()) { fail(reason) }
            let directory = options.value("dir").map { ($0 as NSString).expandingTildeInPath } ?? FileManager.default.currentDirectoryPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                fail("Dossier introuvable : \(directory)")
            }
            do {
                let launch = try HarnessPlanner.prepare(kind, target: target, directory: directory)
                for file in launch.writtenFiles { print("Configuré : \(file)") }
                if options.flag("dry-run") {
                    print("Commande : \(launch.arguments.joined(separator: " "))\(launch.appToOpen.map { "ouvrir \($0)" } ?? "")")
                    print("Adresse : \(target.baseURL)\(proxyURL == nil ? " (moteur direct)" : " (point d'entrée)")")
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
        case "proxy" where options.positional.dropFirst().first == "port":
            guard let port = options.positional.dropFirst(2).first.flatMap(Int.init), (1024...65_535).contains(port) else {
                fail("lml proxy port <1024-65535>")
            }
            var config = ProxyConfig.load()
            config.port = port
            do { try config.save() } catch { fail("\(error)") }
            print("Port du point d'entrée : \(port). Redémarrez-le (interrupteur dans l'app) pour l'appliquer.")
        case "proxy" where options.positional.dropFirst().first == "import-litellm":
            guard let path = options.positional.dropFirst(2).first.map({ ($0 as NSString).expandingTildeInPath }),
                  let yaml = try? String(contentsOfFile: path, encoding: .utf8) else { fail("Précisez le fichier : lml proxy import-litellm <litellm-config.yaml>") }
            let imported = LiteLLMImport.parse(yaml)
            let merged = LiteLLMImport.merge(imported, into: ProxyConfig.load())
            do { try merged.save() } catch { fail("Écriture impossible : \(error)") }
            print("Alias : " + imported.aliases.map { "\($0.alias) → \($0.model)" }.joined(separator: ", "))
            print("Fournisseurs : " + imported.providers.map { "\($0.id) (\($0.prefix.map { "\($0)*" } ?? $0.models.joined(separator: ", ")))" }.joined(separator: ", "))
            for skipped in imported.skipped { print("Ignoré : \(skipped)") }
            let missing = imported.providers.filter { !ProviderKeys.hasKey(for: $0.id) }.map(\.id)
            if !missing.isEmpty { print("Clés à ajouter : " + missing.map { "lml provider set-key \($0)" }.joined(separator: " ; ")) }
            print("Enregistré dans \(ProxyConfig.file.path)")
        case "provider":
            let action = options.positional.dropFirst().first ?? "list"
            let config = ProxyConfig.load()
            switch action {
            case "list":
                if config.providers.isEmpty { print("Aucun fournisseur distant. Importez-les avec lml proxy import-litellm <fichier>.") }
                for provider in config.providers {
                    let scope = provider.prefix.map { "\($0)*" } ?? provider.models.joined(separator: ", ")
                    print("\(provider.id) · \(provider.name) · \(scope) · clé \(ProviderKeys.hasKey(for: provider.id) ? "présente" : "absente")")
                }
            case "set-key", "remove-key":
                guard let id = options.positional.dropFirst(2).first, config.providers.contains(where: { $0.id == id }) else {
                    fail("Fournisseurs connus : \(config.providers.map(\.id).joined(separator: ", "))")
                }
                if action == "remove-key" {
                    ProviderKeys.removeKey(for: id)
                    print("Clé \(id) retirée du trousseau.")
                    break
                }
                // Typed without echo; never passed as an argument (it would stay in the shell history).
                var buffer = [CChar](repeating: 0, count: 4096)
                guard let entered = readpassphrase("Clé \(id) (invisible) : ", &buffer, buffer.count, 0),
                      case let key = String(cString: entered).trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
                    fail("Aucune clé saisie.")
                }
                memset(&buffer, 0, buffer.count)
                do { try ProviderKeys.setKey(key, for: id) } catch { fail("\(error)") }
                print("Clé \(id) enregistrée dans le trousseau.")
            default:
                fail("lml provider list | set-key <id> | remove-key <id>")
            }
        case "proxy":
            let config = ProxyConfig.load()
            let port = options.value("port").flatMap(Int.init) ?? config.port
            let server = ProxyServer(port: port, tableProvider: {
                RouteTable.build(runtime: await Runtime.current(), config: ProxyConfig.load())
            }, log: { line in
                let stamp = Date().formatted(date: .omitted, time: .standard)
                print("[\(stamp)] \(line)")
                fflush(stdout)
            })
            do { try await server.start() } catch { fail("\(error)") }
            while true { try? await Task.sleep(for: .seconds(3600)) }
        case "sync":
            guard let proxy = await runningProxy() else { fail("Le point d'entrée ne répond pas : démarrez-le dans l'app ou avec lml proxy.") }
            let snapshot = await Inventory.take()
            let table = RouteTable.build(runtime: await Runtime.current(), config: ProxyConfig.load())
            let models = HarnessSync.catalog(snapshot: snapshot, table: table)
            do {
                let written = try HarnessSync.sync(proxy: proxy, models: models, installed: HarnessInstallations.detect())
                print("\(models.count) modèles via \(proxy)/v1 : " + models.map { "\($0.id) (\($0.origin))" }.joined(separator: ", "))
                for file in written { print("Configuré : \(file)") }
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

    /// The proxy's address when it answers on its configured port.
    static func runningProxy() async -> String? {
        let base = "http://127.0.0.1:\(ProxyConfig.load().port)"
        guard let url = URL(string: base + "/health"),
              let (_, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 1)),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return base
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
