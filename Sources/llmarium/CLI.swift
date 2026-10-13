import Foundation
import ModelCore

@main
struct LLMariumCLI {
    static let usage = """
    llmarium — moteurs et modèles locaux

    Utilisation :
      llmarium [status]          Moteurs, mémoire et disque en bref
      llmarium running           Modèles en mémoire et qui les a lancés
      llmarium models [--all]    Modèles présents (--all inclut embeddings, rerankers…)
      llmarium disk              Emplacements, doublons probables, liens cassés, entrées vides
      llmarium memory            Mémoire et plus gros consommateurs
      llmarium estimate <modèle> [--engine omlx|mtplx|mlx-serve] [--context N]
                            Mémoire nécessaire, disponible, et quoi libérer
      llmarium start <modèle> [--engine …] [--context N] [--port N] [--force] [--idle minutes]
                            Charge le modèle (refusé s'il ne tient pas, sauf --force) ; --idle : arrêt
                            après ce temps sans activité, compté pendant que l'app est ouverte
      llmarium open <harness> [--model …] [--dir dossier] [--headless "consigne"] [--dry-run]
                            Ouvre le modèle dans claude, codex, pi, opencode ou dsh
                            (fenêtre Ghostty ; --headless : une fois, sans interface)
      llmarium proxy [--port N]  Point d'entrée local (OpenAI et Anthropic) vers les modèles en cours
      llmarium proxy import-litellm <fichier>   Reprend les alias et fournisseurs d'une config LiteLLM
      llmarium proxy port <N>                   Change le port du point d'entrée
      llmarium provider list | set-key <id> | remove-key <id>   Fournisseurs distants et leurs clés
      llmarium sync              Inscrit tous les modèles joignables dans Pi et DeepSeek Harness via le point d'entrée
      llmarium recipe [list] | show <modèle> | remove <modèle> | set <modèle> [--context N] [--reasoning on|off|auto]
                 [--temperature x] [--top-p x] [--top-k n] [--note "…"]
                            Recettes : réglages appliqués au lancement, sources et pièges connus
      llmarium bench <modèle> | list
                            Banc d'essai d'un modèle en mémoire, ou comparaison des mesures
      llmarium radar [--refresh] [--all] [--usage code|chat|raisonnement|vision]
                            Nouveaux modèles lançables sur ce Mac, avec leurs raisons (--all : les exclus aussi)
      llmarium radar download <owner/name> [--engine …] [--yes]
                            Télécharge un modèle après contrôle de l'espace disque
      llmarium mcp               Serveur MCP sur stdio
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
            guard let query = options.positional.dropFirst().first else { fail("Précisez un modèle : llmarium \(command) <modèle>") }
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
                let estimate = MemoryPlanner.estimate(model: model, engine: engine, context: context, snapshot: snapshot)
                json ? emit(estimate) : print(Report.estimate(estimate, model: model, engine: engine, engines: engines))
            } else {
                let idle = options.value("idle").flatMap(Int.init)
                if options.value("idle") != nil, idle == nil || idle! < 1 { fail("--idle : un nombre de minutes, au moins 1.") }
                if idle != nil, engine == .omlx { fail("--idle ne s'applique pas à oMLX, qui décharge ses modèles lui-même.") }
                if !json { print("Lancement de \(model.name) sur \(engine.title)…") }
                let outcome = await ModelStarter.start(model, engine: engine, context: context, port: options.value("port").flatMap(Int.init),
                                                       snapshot: snapshot, force: options.flag("force"), idleStopAfterMinutes: idle)
                if let idle, outcome.refusal == nil, !json {
                    print("Arrêt après \(idle) min sans activité, tant que l'app LLMarium est ouverte.")
                }
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
                fail(targets.isEmpty ? "Aucun modèle en cours : lancez-en un (llmarium start …) ou précisez --model."
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
                fail("llmarium proxy port <1024-65535>")
            }
            var config = ProxyConfig.load()
            config.port = port
            do { try config.save() } catch { fail("\(error)") }
            print("Port du point d'entrée : \(port). Redémarrez-le (interrupteur dans l'app) pour l'appliquer.")
        case "proxy" where options.positional.dropFirst().first == "import-litellm":
            guard let path = options.positional.dropFirst(2).first.map({ ($0 as NSString).expandingTildeInPath }),
                  let yaml = try? String(contentsOfFile: path, encoding: .utf8) else { fail("Précisez le fichier : llmarium proxy import-litellm <litellm-config.yaml>") }
            let imported = LiteLLMImport.parse(yaml)
            let merged = LiteLLMImport.merge(imported, into: ProxyConfig.load())
            do { try merged.save() } catch { fail("Écriture impossible : \(error)") }
            print("Alias : " + imported.aliases.map { "\($0.alias) → \($0.model)" }.joined(separator: ", "))
            print("Fournisseurs : " + imported.providers.map { "\($0.id) (\($0.prefix.map { "\($0)*" } ?? $0.models.joined(separator: ", ")))" }.joined(separator: ", "))
            for skipped in imported.skipped { print("Ignoré : \(skipped)") }
            let missing = imported.providers.filter { !ProviderKeys.hasKey(for: $0.id) }.map(\.id)
            if !missing.isEmpty { print("Clés à ajouter : " + missing.map { "llmarium provider set-key \($0)" }.joined(separator: " ; ")) }
            print("Enregistré dans \(ProxyConfig.file.path)")
        case "provider":
            let action = options.positional.dropFirst().first ?? "list"
            let config = ProxyConfig.load()
            switch action {
            case "list":
                if config.providers.isEmpty { print("Aucun fournisseur distant. Importez-les avec llmarium proxy import-litellm <fichier>.") }
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
                fail("llmarium provider list | set-key <id> | remove-key <id>")
            }
        case "proxy":
            let config = ProxyConfig.load()
            let port = options.value("port").flatMap(Int.init) ?? config.port
            let server = ProxyServer(port: port, tableProvider: {
                RouteTable.build(runtime: await Runtime.current(), config: ProxyConfig.load())
            }, logFile: AppPaths.logs.appending(path: "proxy.log"), log: { line in
                let stamp = Date().formatted(date: .omitted, time: .standard)
                print("[\(stamp)] \(line)")
                fflush(stdout)
            })
            do { try await server.start() } catch { fail("\(error)") }
            while true { try? await Task.sleep(for: .seconds(3600)) }
        case "sync":
            guard let proxy = await runningProxy() else { fail("Le point d'entrée ne répond pas : démarrez-le dans l'app ou avec llmarium proxy.") }
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
        case "recipe":
            let action = options.positional.dropFirst().first ?? "list"
            if action == "list" {
                for recipe in RecipeStore.shared.all() {
                    print("\(recipe.engine.title) · \(recipe.model) · \(recipe.author.title) · \(recipe.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                }
                if RecipeStore.shared.all().isEmpty { print("Aucune recette enregistrée : les recettes déduites sont calculées à la volée (llmarium recipe show <modèle>).") }
                break
            }
            guard let query = options.positional.dropFirst(2).first else { fail("llmarium recipe show|set <modèle> [--engine …]") }
            let snapshot = await Inventory.take()
            guard case .success(let model) = ModelResolver.find(query, in: snapshot.models) else { fail("Modèle introuvable : \(query)") }
            let engines = EngineCompatibility.engines(for: model, snapshot: snapshot)
            guard let engine = options.value("engine").flatMap({ name in EngineKind.allCases.first { $0.rawValue.lowercased() == name.lowercased().replacingOccurrences(of: "-", with: "") } }) ?? engines.first ?? EngineKind.allCases.first(where: { $0.store == model.store }) else {
                fail("Aucun moteur pour \(model.name)")
            }
            if action == "remove" {
                do { try RecipeStore.shared.remove(engine: engine, model: model.name) } catch { fail("\(error)") }
                print("Recette enregistrée retirée : \(model.name) sur \(engine.title) revient aux valeurs déduites des fichiers.")
                break
            }
            var recipe = RecipeDeriver.effective(model: model, engine: engine)
            if action == "set" {
                if let context = options.value("context").flatMap(Int.init) { recipe.context = context }
                if let reasoning = options.value("reasoning") { recipe.reasoning = reasoning == "auto" ? nil : reasoning }
                if let value = options.value("temperature").flatMap(Double.init) { recipe.sampling.temperature = value }
                if let value = options.value("top-p").flatMap(Double.init) { recipe.sampling.topP = value }
                if let value = options.value("top-k").flatMap(Int.init) { recipe.sampling.topK = value }
                if let note = options.value("note") { recipe.notes.append(note) }
                recipe.author = .user
                recipe.sources.append("Modifiée par l'utilisateur le \(Date().formatted(date: .abbreviated, time: .omitted))")
                do { try RecipeStore.shared.save(recipe) } catch { fail("\(error)") }
                print("Recette enregistrée.")
            }
            print(Report.recipe(recipe))
            let preview = (try? LaunchPlan.make(model: model, engine: engine, port: 18_100, context: recipe.context,
                                                 installation: snapshot.engine(engine)?.installation ?? EngineInstallation(kind: engine, version: nil, location: nil),
                                                 recipe: recipe))
            if let preview { print("Commande de lancement : \(([preview.executable] + preview.arguments).joined(separator: " "))") }
            if engine == .omlx {
                for reference in await CommunityBenchmarks.shared.best(model: LaunchPlan.servedName(model), machine: snapshot.machine) {
                    print("omlx.ai : \(reference.decodeTokensPerSecond.map { String(format: "%.1f", $0) } ?? "?") tok/s en génération, \(reference.prefillTokensPerSecond.map { String(format: "%.0f", $0) } ?? "?") en lecture · \(reference.quantization ?? "") · \(reference.memoryGB.map { "\($0) Go" } ?? "") · \(reference.url)")
                }
            }
        case "bench":
            if options.positional.dropFirst().first == "list" || options.positional.count == 1 {
                print(Report.benchmarks(BenchmarkStore.shared.all()))
                break
            }
            let query = options.positional.dropFirst().first!
            let snapshot = await Inventory.take()
            // Straight to the engine: the proxy would add a hop to the numbers.
            guard let target = HarnessTarget.targets(in: snapshot).first(where: { $0.modelID.localizedCaseInsensitiveContains(query) }),
                  let running = snapshot.running.first(where: { $0.models.contains(target.modelID) }) else {
                fail("« \(query) » n'est pas en mémoire : lancez-le d'abord (llmarium start).")
            }
            let local = snapshot.models.first { target.engine == .omlx ? OMLXIdentity.matches(target.modelID, $0) : LaunchPlan.servedName($0) == target.modelID }
            let recipe = local.map { RecipeDeriver.effective(model: $0, engine: target.engine) }
            let launched = LaunchRegistry.shared.servers().first { $0.pid == running.pid }
            print("Banc d'essai de \(target.modelID) sur \(target.engine.title)…")
            let result = await Benchmark.run(baseURL: target.baseURL, model: target.modelID, engine: target.engine,
                                             engineVersion: snapshot.engine(target.engine)?.installation.version, machine: snapshot.machine,
                                             pid: running.pid, context: target.contextWindow, recipeID: recipe?.id,
                                             loadSeconds: launched?.loadSeconds,
                                             otherClients: running.clients.map(\.title),
                                             omlxURL: snapshot.engine(.omlx)?.instances.first?.url) { step in print("  \(step)…") }
            do { try BenchmarkStore.shared.add(result) } catch { fail("\(error)") }
            print(Report.benchmark(result))
        case "radar" where options.positional.dropFirst().first == "download":
            guard let repo = options.positional.dropFirst(2).first, repo.contains("/") else { fail("llmarium radar download <owner/name> [--engine omlx|mtplx|mlx-serve] [--yes]") }
            let snapshot = await Inventory.take()
            let item = Radar.cached()?.items.first { $0.id == repo }
            let engine = options.value("engine").flatMap { name in EngineKind.allCases.first { $0.rawValue.lowercased() == name.lowercased().replacingOccurrences(of: "-", with: "") } }
                ?? item?.engines.first ?? RadarFilter.engines(for: repo).first!
            let detail = item == nil ? (try? await HubAPI.detail(repo)) ?? nil : nil
            if item?.gated == true || detail?.gated == true {
                fail("Ce modèle demande d'accepter ses conditions sur Hugging Face : faites-le sur https://huggingface.co/\(repo), puis « hf auth login », et réessayez.")
            }
            if detail?.isAdapter == true { fail("C'est un adaptateur LoRA : les moteurs ne le servent pas seul.") }
            let size = item?.sizeBytes ?? detail?.sizeBytes
            if let refusal = RadarDownload.diskRefusal(sizeBytes: size, freeBytes: snapshot.disk.volumeAvailableBytes) { fail(refusal) }
            let plan = RadarDownload.plan(repo: repo, engine: engine, sizeBytes: size)
            print("Téléchargement de https://huggingface.co/\(repo)")
            print("  taille \(size.map(Format.bytes) ?? "?") · vers \(plan.destination) · \(snapshot.disk.volumeAvailableBytes.map(Format.bytes) ?? "?") libres")
            print("  commande : \(plan.command.arguments.joined(separator: " "))")
            if !options.flag("yes") {
                print("Continuer ? [o/N] ", terminator: "")
                guard let answer = readLine(), ["o", "oui", "y", "yes"].contains(answer.lowercased()) else { fail("Annulé.") }
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: HarnessInstallations.userShell)
            process.arguments = ["-lc", plan.command.arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")]
            do { try process.run() } catch { fail("\(error)") }
            process.waitUntilExit()
            exit(process.terminationStatus)
        case "radar":
            let snapshot = await Inventory.take()
            var report = await Radar.report(snapshot: snapshot, refresh: options.flag("refresh"))
            if let wanted = options.value("usage") {
                guard let usage = ModelUsage.allCases.first(where: { $0.rawValue == wanted || $0.title.lowercased() == wanted.lowercased() }) else {
                    fail("--usage : code, chat, raisonnement ou vision")
                }
                report.items = report.items.filter { $0.usages?.contains { $0.usage == usage } == true }
            }
            json ? emit(report) : print(Report.radar(report, all: all, bandwidth: snapshot.machine.bandwidth))
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
    static let valued: Set<String> = ["engine", "context", "port", "model", "dir", "headless", "reasoning", "temperature", "top-p", "top-k", "note", "idle", "usage"]

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
