import Foundation
import ModelCore
import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case running, engines, models, radar, recipes, proxy, disk, memory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .running: "En cours"
        case .engines: "Moteurs"
        case .models: "Modèles"
        case .proxy: "Point d'entrée"
        case .recipes: "Recettes"
        case .radar: "Radar"
        case .disk: "Disque"
        case .memory: "Mémoire"
        }
    }

    var symbol: String {
        switch self {
        case .running: "bolt.circle"
        case .engines: "server.rack"
        case .models: "shippingbox"
        case .proxy: "arrow.triangle.branch"
        case .recipes: "gauge.with.dots.needle.67percent"
        case .radar: "dot.radiowaves.left.and.right"
        case .disk: "internaldrive"
        case .memory: "memorychip"
        }
    }
}

@MainActor
final class InventoryModel: ObservableObject {
    static let shared = InventoryModel()

    @Published private(set) var snapshot: InventorySnapshot?
    @Published private(set) var isScanning = false
    /// The window reopens on the last section viewed.
    @Published var section = Section(rawValue: UserDefaults.standard.string(forKey: "section") ?? "") ?? .running {
        didSet { UserDefaults.standard.set(section.rawValue, forKey: "section") }
    }

    private var lastFullScan: Date?
    /// Harnesses found in the login shell; looked up again on each full scan (it runs the shell once).
    @Published private(set) var installedHarnesses: Set<HarnessKind> = []

    /// A full scan walks every model folder (under a second here); engines and memory alone are cheaper.
    func refresh(full: Bool = false) async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        if let snapshot, !full, let lastFullScan, Date().timeIntervalSince(lastFullScan) < 60 {
            self.snapshot = await Inventory.refreshRuntime(snapshot)
        } else {
            snapshot = await Inventory.take()
            lastFullScan = Date()
            installedHarnesses = await Task.detached { HarnessInstallations.detect() }.value
        }
    }

    /// Models being loaded, by model ID: the sheet can be closed meanwhile.
    @Published private(set) var launches: [String: LaunchJob] = [:]
    @Published var launchOutcome: ActionOutcome?

    /// Returns true once the model serves. `quiet` skips the « est prêt » message (launches from the menu bar).
    @discardableResult
    func launch(_ item: LocalModel, engine: EngineKind, context: Int?, force: Bool, idleStopAfterMinutes: Int? = nil,
                quiet: Bool = false) async -> Bool {
        guard launches[item.id] == nil, let snapshot else { return false }
        launches[item.id] = LaunchJob(modelID: item.id, modelName: item.name, engine: engine, startedAt: Date())
        defer { launches[item.id] = nil }
        let outcome = await ModelStarter.start(item, engine: engine, context: context, snapshot: snapshot, force: force,
                                               idleStopAfterMinutes: idleStopAfterMinutes)
        var ready = false
        if let refusal = outcome.refusal {
            launchOutcome = ActionOutcome(title: "\(item.name) n'a pas été lancé", message: refusal)
        } else {
            switch outcome.result {
            case .ready(let server, let served, let seconds):
                ready = true
                if !quiet {
                    launchOutcome = ActionOutcome(title: "\(served.first ?? item.name) est prêt",
                                                  message: "Chargé en \(seconds) s sur \(engine.title) : http://127.0.0.1:\(server.port)/v1")
                }
            case .loadedInOMLX(let id, let seconds):
                ready = true
                if !quiet { launchOutcome = ActionOutcome(title: "\(id) est chargé", message: "oMLX l'a chargé en \(seconds) s.") }
            case .failed(let reason, let log):
                launchOutcome = ActionOutcome(title: "Échec du lancement de \(item.name)", message: reason + (log.map { "\n\n\($0)" } ?? ""))
            case nil:
                break
            }
        }
        // From the menu bar, a failure has nowhere to show but the window.
        if quiet, launchOutcome != nil { AppWindows.showMain(self) }
        await refresh()
        quickLaunch = QuickLaunchStore.shared.state()
        return ready
    }

    // MARK: - Quick launch (menu bar)

    @Published private(set) var quickLaunch = QuickLaunchStore.shared.state()
    /// A model whose launch sheet the main window should open (the menu bar's « Lancer » when it does not fit).
    @Published var pendingLaunch: LocalModel?

    /// Minutes of inactivity before a model launched from the menu bar stops; 0 turns it off.
    @Published var quickIdleMinutes = UserDefaults.standard.object(forKey: "quickIdleMinutes") as? Int ?? 30 {
        didSet { UserDefaults.standard.set(quickIdleMinutes, forKey: "quickIdleMinutes") }
    }

    var quickItems: [QuickLaunchItem] {
        snapshot.map { QuickLaunch.items(state: quickLaunch, snapshot: $0) } ?? []
    }

    func isPinned(_ item: LocalModel) -> Bool { quickLaunch.pinned.contains(item.id) }

    func setPinned(_ item: LocalModel, _ pinned: Bool) {
        QuickLaunchStore.shared.setPinned(item.id, pinned)
        quickLaunch = QuickLaunchStore.shared.state()
    }

    /// One click from the menu bar: launch with the last engine and context; open the launch sheet instead when the
    /// model does not fit; then, if asked, open it in a harness in the last project folder.
    func quickLaunch(_ item: QuickLaunchItem, harness: HarnessKind? = nil) async {
        guard let engine = item.engine, let snapshot else { return }
        let estimate = MemoryPlanner.estimate(model: item.model, engine: engine, context: item.context, snapshot: snapshot)
        if estimate.verdict == .tooLarge && engine != .omlx {
            pendingLaunch = item.model
            AppWindows.showMain(self, section: .models)
            return
        }
        let idle = engine == .omlx || quickIdleMinutes == 0 ? nil : quickIdleMinutes
        guard await launch(item.model, engine: engine, context: item.context, force: false, idleStopAfterMinutes: idle, quiet: true),
              let harness, let current = self.snapshot else { return }
        let served = LaunchPlan.servedName(item.model)
        let targets = HarnessTarget.targets(in: current, via: ProxyController.shared.url).filter { $0.engine == engine }
        guard let target = targets.first(where: { engine == .omlx ? OMLXIdentity.matches($0.modelID, item.model) : $0.modelID == served }) else {
            launchOutcome = ActionOutcome(title: "\(item.model.name) est prêt", message: "Mais il n'apparaît pas encore dans « En cours » : ouvrez \(harness.title) depuis sa carte.")
            AppWindows.showMain(self, section: .running)
            return
        }
        if let reason = HarnessPlanner.unavailableReason(harness, target: target, installed: installedHarnesses) {
            launchOutcome = ActionOutcome(title: "\(harness.title) ne peut pas s'ouvrir", message: reason)
            AppWindows.showMain(self, section: .running)
            return
        }
        let directory = UserDefaults.standard.string(forKey: "lastProjectFolder") ?? NSHomeDirectory()
        do {
            try HarnessOpener.open(try HarnessPlanner.prepare(harness, target: target, directory: directory))
            if harness == .deepseekHarness {
                launchOutcome = ActionOutcome(title: "DeepSeek Harness configuré",
                                              message: "Choisissez « \(target.modelID) (local) » dans son sélecteur de modèle.")
                AppWindows.showMain(self, section: .running)
            }
        } catch {
            launchOutcome = ActionOutcome(title: "\(harness.title) ne s'est pas ouvert", message: "\(error)")
            AppWindows.showMain(self, section: .running)
        }
    }

    /// Benchmarks in progress, by model id served.
    @Published private(set) var benchmarking: [String: String] = [:]

    func benchmark(_ target: HarnessTarget, running: RunningModel) async {
        guard benchmarking[target.modelID] == nil, let snapshot else { return }
        benchmarking[target.modelID] = "Échauffement"
        defer { benchmarking[target.modelID] = nil }
        let local = snapshot.models.first { target.engine == .omlx ? OMLXIdentity.matches(target.modelID, $0) : LaunchPlan.servedName($0) == target.modelID }
        let id = target.modelID
        // Straight to the engine, even when harnesses go through the proxy.
        let result = await Benchmark.run(baseURL: running.baseURL ?? target.baseURL, model: target.modelID, engine: target.engine,
                                         engineVersion: snapshot.engine(target.engine)?.installation.version, machine: snapshot.machine,
                                         pid: running.pid, context: target.contextWindow,
                                         recipeID: local.map { RecipeDeriver.effective(model: $0, engine: target.engine).id },
                                         loadSeconds: LaunchRegistry.shared.servers().first { $0.pid == running.pid }?.loadSeconds,
                                         otherClients: running.clients.map(\.title),
                                         omlxURL: snapshot.engine(.omlx)?.instances.first?.url) { step in
            Task { @MainActor in InventoryModel.shared.benchmarking[id] = step }
        }
        try? BenchmarkStore.shared.add(result)
        benchmarkResults = BenchmarkStore.shared.all()
        let decode = result.decodeTokensPerSecond.map { String(format: "%.1f", $0) } ?? "—"
        launchOutcome = ActionOutcome(title: "Mesure de \(target.modelID) terminée",
                                      message: "Génération \(decode) tokens/s, outil \(result.toolCallSucceeded == true ? "réussi" : "échoué")."
                                        + (result.disturbed ? "\n\nMesure perturbée : \(result.conditions.joined(separator: " ; "))." : ""))
    }

    @Published var benchmarkResults = BenchmarkStore.shared.all()

    /// Servers stopped for inactivity, newest first, until the user clears them.
    @Published var idleStops: [String] = []

    /// Stops the servers started with an idle limit once they have done nothing for that long. Runs every minute
    /// while the app is open; nothing is checked when it is closed.
    func checkIdleServers() async {
        let registry = LaunchRegistry.shared
        registry.reconcile()
        let watched = registry.servers().filter { $0.idleStopAfterMinutes != nil }
        guard !watched.isEmpty else { return }
        let running = await Runtime.current().running
        var stopped = false
        for server in watched {
            let clients = running.first { $0.pid == server.pid }?.clients ?? []
            let (updated, stop) = IdlePolicy.check(server, cpuSeconds: ProcessScanner.cpuSeconds(of: server.pid),
                                                   logBytes: IdlePolicy.logBytes(server), hasClients: !clients.isEmpty)
            registry.add(updated)
            guard stop else { continue }
            let minutes = server.idleStopAfterMinutes ?? 0
            switch await ModelActions.stop(pid: server.pid, startedAt: server.startedAt) {
            case .stopped:
                idleStops.insert("\(server.model) (\(server.engine.title)) arrêté à \(Date().formatted(date: .omitted, time: .shortened)) après \(minutes) min sans activité.", at: 0)
                stopped = true
            case .stillRunning:
                // One attempt only: the user decides on a forced stop from its card.
                var kept = updated
                kept.idleStopAfterMinutes = nil
                registry.add(kept)
                idleStops.insert("\(server.model) n'a pas répondu à la demande d'arrêt après \(minutes) min d'inactivité : arrêtez-le depuis sa carte.", at: 0)
            case .processChanged, .failed:
                break
            }
        }
        registry.reconcile()
        if stopped { await refresh() }
    }

    /// What « Mettre à la corbeille » would do, re-read against what runs now; a refusal is shown as an outcome.
    func trashPlan(for item: LocalModel) async -> TrashPlan? {
        await refresh()
        guard let snapshot else { return nil }
        switch ModelTrash.plan(item, models: snapshot.models, running: snapshot.running, omlx: snapshot.engine(.omlx)?.omlx) {
        case .success(let plan): return plan
        case .failure(let refusal):
            launchOutcome = ActionOutcome(title: "\(item.name) reste en place", message: refusal.description)
            return nil
        }
    }

    func moveToTrash(_ plan: TrashPlan) async {
        do {
            let landed = try ModelTrash.moveToTrash(plan)
            launchOutcome = ActionOutcome(title: "\(plan.model) est dans la corbeille",
                                    message: (plan.freedBytes > 0 ? "\(Format.bytes(plan.freedBytes)) seront libérés quand vous viderez la corbeille. " : "")
                                        + "Pour l'annuler, remettez « \(landed.first?.lastPathComponent ?? "") » à sa place depuis la corbeille.")
        } catch {
            launchOutcome = ActionOutcome(title: "Mise à la corbeille impossible", message: error.localizedDescription)
        }
        await refresh(full: true)
    }

    /// Result of the last unload or stop, shown until dismissed.
    @Published var outcome: ActionOutcome?
    @Published private(set) var busyPID: Int32?

    func unload(_ modelID: String, from running: RunningModel) async {
        guard let url = snapshot?.engine(.omlx)?.instances.first(where: { $0.pid == running.pid })?.url else { return }
        busyPID = running.pid
        defer { busyPID = nil }
        switch await ModelActions.unloadOMLX(model: modelID, baseURL: url) {
        case .unloaded:
            outcome = ActionOutcome(title: "\(modelID) déchargé", message: "oMLX a libéré sa mémoire. Il le rechargera à la prochaine demande.")
        case .authenticationRequired:
            outcome = ActionOutcome(title: "oMLX demande une clé", message: "Déchargez ce modèle depuis l'app oMLX.")
        case .failed(let reason):
            outcome = ActionOutcome(title: "Déchargement impossible", message: reason)
        }
        await refresh()
    }

    func freeComfyUI(_ running: RunningModel) async {
        guard let url = running.baseURL else { return }
        busyPID = running.pid
        defer { busyPID = nil }
        switch await ModelActions.freeComfyUI(baseURL: url) {
        case .unloaded:
            let wait = (running.comfyUI?.runningJobs ?? 0) > 0 ? " dès la fin de la génération en cours" : ""
            outcome = ActionOutcome(title: "Libération demandée à ComfyUI", message: "ComfyUI décharge ses modèles\(wait). Ils seront rechargés à la prochaine génération.")
        case .authenticationRequired, .failed:
            outcome = ActionOutcome(title: "ComfyUI n'a pas accepté la demande", message: "Vous pouvez arrêter son processus à la place.")
        }
        await refresh()
    }

    func stop(_ running: RunningModel, force: Bool = false) async {
        busyPID = running.pid
        defer { busyPID = nil }
        switch await ModelActions.stop(pid: running.pid, startedAt: running.startedAt, force: force) {
        case .stopped:
            outcome = ActionOutcome(title: "\(running.title) arrêté", message: "\(Format.memory(running.footprintBytes)) libérés (PID \(running.pid)).")
        case .stillRunning:
            outcome = ActionOutcome(title: "\(running.title) ne s'est pas arrêté",
                                    message: force ? "Le processus résiste même à l'arrêt forcé."
                                        : "Il n'a pas répondu à la demande d'arrêt après 10 secondes. Vous pouvez forcer l'arrêt : il n'aura pas le temps de terminer proprement.",
                                    forceCandidate: force ? nil : running)
        case .processChanged:
            outcome = ActionOutcome(title: "Rien n'a été arrêté", message: "Le PID \(running.pid) n'appartient plus au même processus. La liste a été actualisée.")
        case .failed(let reason):
            outcome = ActionOutcome(title: "Arrêt impossible", message: reason)
        }
        await refresh()
    }

    var menuBarSymbol: String {
        switch snapshot?.memory.stats.pressure {
        case .warning: "memorychip.fill"
        case .critical: "exclamationmark.triangle.fill"
        default: "memorychip"
        }
    }

    /// Model IDs oMLX reports as loaded, matched to the folders found on disk by their name.
    func isLoadedInOMLX(_ model: LocalModel) -> Bool {
        guard model.store == .omlx, let omlx = snapshot?.engine(.omlx)?.omlx else { return false }
        let leaf = model.name.split(separator: "/").last.map(String.init) ?? model.name
        return omlx.models.contains { $0.loaded && ($0.id == leaf || $0.id == model.name) }
    }
}

struct LaunchJob: Identifiable {
    var id: String { modelID }
    var modelID: String
    var modelName: String
    var engine: EngineKind
    var startedAt: Date
}

struct ActionOutcome: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    /// Set when a polite stop failed: the result offers to force it.
    var forceCandidate: RunningModel?
}
