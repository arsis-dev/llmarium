import AppKit
import ModelCore
import SwiftUI

/// What is holding a model in memory now, who started it, and the way to free it after a warning.
struct RunningView: View {
    var snapshot: InventorySnapshot
    @EnvironmentObject private var model: InventoryModel
    @State private var pending: PendingAction?
    @State private var harnessRequest: HarnessRequest?

    struct HarnessRequest: Identifiable {
        var target: HarnessTarget
        var kind: HarnessKind
        var id: String { "\(target.modelID)-\(kind.rawValue)" }
    }

    enum PendingAction: Identifiable {
        case unload(RunningModel, String)
        case freeComfyUI(RunningModel)
        case stop(RunningModel)
        case force(RunningModel)

        var id: String {
            switch self {
            case .unload(let running, let name): "unload-\(running.pid)-\(name)"
            case .freeComfyUI(let running): "free-\(running.pid)"
            case .stop(let running): "stop-\(running.pid)"
            case .force(let running): "force-\(running.pid)"
            }
        }

        var running: RunningModel {
            switch self {
            case .unload(let running, _), .freeComfyUI(let running), .stop(let running), .force(let running): running
            }
        }

        var title: String {
            switch self {
            case .unload(_, let name): "Décharger \(name) ?"
            case .freeComfyUI: "Libérer la mémoire de ComfyUI ?"
            case .stop(let running): "Arrêter \(running.title) ?"
            case .force(let running): "Forcer l'arrêt de \(running.title) ?"
            }
        }

        var confirmLabel: String {
            switch self {
            case .unload: "Décharger"
            case .freeComfyUI: "Libérer"
            case .stop: "Arrêter"
            case .force: "Forcer l'arrêt"
            }
        }

        var message: String {
            let running = self.running
            var lines: [String] = []
            switch self {
            case .unload(_, let name):
                let size = running.role == .omlx ? "" : " (\(Format.memory(running.footprintBytes)))"
                lines.append("oMLX libérera la mémoire de \(name)\(size) ; son serveur et ses autres modèles restent actifs.")
            case .freeComfyUI:
                lines.append("ComfyUI déchargera ses modèles et videra son cache. Son serveur reste actif ; il rechargera les modèles à la prochaine génération.")
                if (running.comfyUI?.runningJobs ?? 0) > 0 {
                    lines.append("La génération en cours n'est pas interrompue : la libération a lieu à sa fin.")
                }
                return lines.joined(separator: "\n\n")
            case .stop:
                lines.append("Le processus \(running.pid) recevra une demande d'arrêt et libérera \(Format.memory(running.footprintBytes)).")
            case .force:
                lines.append("Le processus \(running.pid) sera tué sans pouvoir terminer proprement.")
            }
            lines += running.stopWarnings
            return lines.joined(separator: "\n\n")
        }
    }

    var body: some View {
        Group {
            if snapshot.running.isEmpty && model.launches.isEmpty {
                ContentUnavailableView("Aucun modèle en mémoire", systemImage: "moon.zzz",
                                       description: Text("Ni les moteurs ni un autre processus ne gardent de modèle chargé."))
            } else {
                Form {
                    ForEach(Array(model.launches.values), id: \.id) { job in
                        SwiftUI.Section(job.modelName) {
                            HStack {
                                ProgressView().controlSize(.small)
                                TimelineView(.periodic(from: job.startedAt, by: 1)) { context in
                                    Text("Chargement sur \(job.engine.title)… \(Int(context.date.timeIntervalSince(job.startedAt))) s")
                                }
                            }
                        }
                    }
                    ForEach(snapshot.running) { running in
                        RunningCard(running: running, busy: model.busyPID == running.pid,
                                    targets: HarnessTarget.targets(in: snapshot).filter { $0.baseURL == running.baseURL },
                                    installed: model.installedHarnesses,
                                    openHarness: { target, kind in harnessRequest = HarnessRequest(target: target, kind: kind) }) { pending = $0 }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .confirmationDialog(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            presenting: pending) { action in
            Button(action.confirmLabel, role: .destructive) {
                Task {
                    switch action {
                    case .unload(let running, let name): await model.unload(name, from: running)
                    case .freeComfyUI(let running): await model.freeComfyUI(running)
                    case .stop(let running): await model.stop(running)
                    case .force(let running): await model.stop(running, force: true)
                    }
                }
            }
            Button("Annuler", role: .cancel) {}
        } message: { action in
            Text(action.message)
        }
        .sheet(item: $harnessRequest) { request in
            HarnessSheet(target: request.target, initial: request.kind)
        }
        .alert(model.outcome?.title ?? "", isPresented: Binding(get: { model.outcome != nil }, set: { if !$0 { model.outcome = nil } }),
               presenting: model.outcome) { outcome in
            if let candidate = outcome.forceCandidate {
                Button("Forcer l'arrêt…", role: .destructive) { pending = .force(candidate) }
            }
            Button("OK", role: .cancel) {}
        } message: { outcome in
            Text(outcome.message)
        }
    }
}

struct RunningCard: View {
    var running: RunningModel
    var busy: Bool
    var targets: [HarnessTarget] = []
    var installed: Set<HarnessKind> = []
    var openHarness: (HarnessTarget, HarnessKind) -> Void = { _, _ in }
    var ask: (RunningView.PendingAction) -> Void

    var body: some View {
        SwiftUI.Section {
            LabeledContent("Mémoire", value: Format.memory(running.footprintBytes))
            LabeledContent("Processus") {
                Text("PID \(String(running.pid))\(running.startedAt.map { " · depuis \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")")
                    .textSelection(.enabled)
            }
            if let url = running.baseURL {
                LabeledContent("Adresse") {
                    Text(running.role == .modelWorker ? url : url + "/v1").font(.callout.monospaced()).textSelection(.enabled)
                }
            }
            if let comfyUI = running.comfyUI {
                LabeledContent("Activité") {
                    StatePill(text: comfyUI.activity, color: comfyUI.runningJobs > 0 ? .green : .secondary)
                }
                if !comfyUI.models.isEmpty {
                    LabeledContent(comfyUI.modelsFromHistory ? "Modèles (dernière génération)" : "Modèles de la génération") {
                        Text(comfyUI.models.joined(separator: "\n")).multilineTextAlignment(.trailing).textSelection(.enabled)
                    }
                }
            }
            LabeledContent {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(running.launcher.summary).multilineTextAlignment(.trailing)
                    if running.launcher.certainty == .probable {
                        StatePill(text: "Probable, d'après son environnement", color: .orange)
                    }
                    if running.launcher.isOrphan {
                        StatePill(text: "Orphelin : son lanceur n'est plus actif", color: .orange)
                    }
                }
            } label: {
                Text("Lancé par")
            }
            if let project = running.launcher.projectPath {
                LabeledContent("Projet") {
                    HStack {
                        Text((project as NSString).abbreviatingWithTildeInPath).font(.callout.monospaced())
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project)])
                        } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless).help("Afficher dans le Finder")
                    }
                }
            }
            LabeledContent("Clients connectés",
                           value: running.clients.isEmpty ? "Aucun à cet instant" : running.clients.map(\.title).joined(separator: ", "))
            HStack {
                if !targets.isEmpty {
                    Menu("Ouvrir dans…") {
                        ForEach(targets, id: \.modelID) { target in
                            SwiftUI.Section(targets.count > 1 ? target.modelID : "") {
                                ForEach(HarnessKind.allCases) { kind in
                                    let reason = HarnessPlanner.unavailableReason(kind, target: target, installed: installed)
                                    Button(kind.title) { openHarness(target, kind) }
                                        .disabled(reason != nil)
                                        .help(reason ?? "")
                                }
                            }
                        }
                    }
                    .fixedSize()
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if running.comfyUI != nil {
                    Button("Libérer la mémoire de ComfyUI…") { ask(.freeComfyUI(running)) }
                } else if running.canUnloadInEngine {
                    ForEach(running.models, id: \.self) { name in
                        Button(running.models.count > 1 ? "Décharger \(name)…" : "Décharger le modèle…") {
                            ask(.unload(running, name))
                        }
                    }
                }
                if running.canStopProcess {
                    Button("Arrêter le processus…", role: .destructive) { ask(.stop(running)) }
                }
            }
            .disabled(busy)
        } header: {
            HStack(spacing: 8) {
                Text(running.title)
                StatePill(text: running.role.title, color: running.role == .modelWorker ? .orange : .accentColor)
            }
        } footer: {
            if running.role == .modelWorker {
                Text(running.processDescription)
            }
        }
    }
}
