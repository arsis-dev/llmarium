import ModelCore
import SwiftUI

/// The menu bar panel: engines, memory and disk at a glance.
struct MenuPanel: View {
    @EnvironmentObject private var model: InventoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("LLMarium").font(.system(.title3, design: .serif).weight(.semibold))
                Spacer()
                if model.isScanning { ProgressView().controlSize(.small) }
            }
            if let snapshot = model.snapshot {
                if !snapshot.running.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("En mémoire").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(snapshot.running) { running in
                            Button {
                                AppWindows.showMain(model, section: .running)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(running.title).lineLimit(1)
                                        Spacer()
                                        Text(Format.memory(running.footprintBytes)).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    Text((running.launcher.isOrphan ? "Orphelin · " : "") + running.launcher.summary)
                                        .font(.caption).foregroundStyle(running.launcher.isOrphan ? .orange : .secondary).lineLimit(1)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Voir le détail et l'arrêter")
                        }
                    }
                    Divider()
                }
                QuickLaunchSection(snapshot: snapshot)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(snapshot.engines) { engine in
                        HStack(alignment: .firstTextBaseline) {
                            Text(engine.kind.title).frame(width: 82, alignment: .leading)
                            StatePill(text: engine.stateText, color: engine.stateColor)
                            Spacer()
                            if let port = engine.instances.first?.ports.first {
                                Text(":\(port)").font(.callout.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        if let loaded = engine.omlx?.models.filter(\.loaded), !loaded.isEmpty {
                            Text(loaded.map(\.id).joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 82)
                        }
                    }
                }
                ProxyLine()
                Divider()
                MemoryBar(stats: snapshot.memory.stats, ceiling: snapshot.engine(.omlx)?.omlx?.ceilingBytes)
                Divider()
                HStack {
                    Label("\(snapshot.disk.volumeAvailableBytes.map(Format.bytes) ?? "—") libres", systemImage: "internaldrive")
                    Spacer()
                    Text("\(snapshot.models.count) modèles · \(Format.bytes(snapshot.disk.modelBytes))").foregroundStyle(.secondary)
                }
                .font(.callout)
                if !snapshot.disk.brokenLinkIDs.isEmpty || !snapshot.disk.emptyCacheEntries.isEmpty {
                    Button {
                        AppWindows.showMain(model, section: .disk)
                    } label: {
                        Label("\(snapshot.disk.brokenLinkIDs.count) lien(s) cassé(s), \(snapshot.disk.emptyCacheEntries.count) entrée(s) vide(s)",
                              systemImage: "exclamationmark.triangle")
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }
            } else {
                Text("Inventaire en cours…").foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("Ouvrir la fenêtre") { AppWindows.showMain(model) }
                Spacer()
                Button {
                    Task { await model.refresh(full: true) }
                } label: { Image(systemName: "arrow.clockwise") }
                    .help("Actualiser")
                Button {
                    NSApp.terminate(nil)
                } label: { Image(systemName: "power") }
                    .help("Quitter")
            }
        }
        .padding(16)
        .frame(width: 360)
        .task { await model.refresh() }
    }
}

/// The proxy's state in the menu bar panel.
struct ProxyLine: View {
    @ObservedObject private var proxy = ProxyController.shared
    @EnvironmentObject private var model: InventoryModel

    var body: some View {
        Button {
            AppWindows.showMain(model, section: .proxy)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text("Point d'entrée").frame(width: 82, alignment: .leading)
                switch proxy.state {
                case .running(let port):
                    StatePill(text: "Actif", color: .green)
                    Spacer()
                    Text(":\(port)").font(.callout.monospaced()).foregroundStyle(.secondary)
                case .failed: StatePill(text: "Erreur", color: .red); Spacer()
                case .starting: StatePill(text: "Démarrage…", color: .orange); Spacer()
                case .off: StatePill(text: "Arrêté", color: .secondary); Spacer()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Pinned models, then the latest launches: one click loads a model with its last settings.
struct QuickLaunchSection: View {
    var snapshot: InventorySnapshot
    @EnvironmentObject private var model: InventoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Lancer").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Picker("Arrêt après inactivité", selection: $model.quickIdleMinutes) {
                        Text("Jamais").tag(0)
                        ForEach([15, 30, 60, 120], id: \.self) { Text($0 < 60 ? "\($0) min" : "\($0 / 60) h").tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(model.quickIdleMinutes == 0 ? "sans arrêt auto" : "arrêt après \(model.quickIdleMinutes) min")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Les modèles lancés d'ici s'arrêtent seuls après ce temps sans activité, tant que l'app est ouverte (MTPLX et mlx-serve ; oMLX gère les siens).")
            }
            let items = model.quickItems
            if items.isEmpty {
                Text("Vos derniers modèles lancés apparaîtront ici ; épinglez-en depuis « Modèles » (clic droit).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(items) { item in
                QuickLaunchRow(item: item, snapshot: snapshot)
            }
            Button("Autre modèle…") { AppWindows.showMain(model, section: .models) }
                .buttonStyle(.link).font(.callout)
        }
        Divider()
    }
}

struct QuickLaunchRow: View {
    var item: QuickLaunchItem
    var snapshot: InventorySnapshot
    @EnvironmentObject private var model: InventoryModel

    private var estimate: MemoryEstimate? {
        item.engine.map { MemoryPlanner.estimate(model: item.model, engine: $0, context: item.context, snapshot: snapshot) }
    }

    private var title: String { item.model.name.split(separator: "/").last.map(String.init) ?? item.model.name }

    var body: some View {
        let estimate = self.estimate
        HStack(spacing: 8) {
            Button {
                Task { await model.quickLaunch(item) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if item.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                        Text(title).lineLimit(1).truncationMode(.middle)
                    }
                    Text(detail(estimate)).font(.caption).foregroundStyle(item.unavailable == nil ? Color.secondary : Color.orange).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(item.unavailable != nil || model.launches[item.id] != nil)
            .help(help(estimate))

            if model.launches[item.id] != nil {
                ProgressView().controlSize(.small)
            } else if let estimate {
                Circle().fill(color(estimate.verdict)).frame(width: 8, height: 8)
                    .help(estimate.verdict == .tooLarge ? "Ne tient pas maintenant : le clic ouvre la fenêtre de lancement" : "Tient en mémoire")
            }
            Menu {
                if let engine = item.engine {
                    SwiftUI.Section("Lancer et ouvrir dans") {
                        ForEach(HarnessKind.allCases) { kind in
                            let probe = HarnessTarget(engine: engine, baseURL: "", modelID: title, contextWindow: item.context ?? item.model.spec?.maxContext,
                                                      modelType: item.model.spec?.modelType)
                            let reason = HarnessPlanner.unavailableReason(kind, target: probe, installed: model.installedHarnesses)
                            Button(kind.title) { Task { await model.quickLaunch(item, harness: kind) } }
                                .disabled(reason != nil || item.unavailable != nil)
                        }
                    }
                    Button("Choisir le contexte et le moteur…") {
                        model.pendingLaunch = item.model
                        AppWindows.showMain(model, section: .models)
                    }
                }
                Divider()
                Button(item.pinned ? "Retirer de la barre de menus" : "Épingler") { model.setPinned(item.model, !item.pinned) }
            } label: {
                Image(systemName: "chevron.right.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.launches[item.id] != nil)
        }
    }

    private func detail(_ estimate: MemoryEstimate?) -> String {
        if let reason = item.unavailable { return reason }
        guard let engine = item.engine, let estimate else { return "" }
        var parts = [engine.title, Format.memory(estimate.totalBytes)]
        if let context = item.context { parts.append("\(Format.tokens(context)) tokens") }
        if let speed = estimate.speed {
            parts.append(speed.kind == .measured ? "\(SpeedEstimate.format(speed.tokensPerSecond)) tok/s" : "≤ \(SpeedEstimate.format(speed.tokensPerSecond)) tok/s")
        }
        return parts.joined(separator: " · ")
    }

    private func help(_ estimate: MemoryEstimate?) -> String {
        guard let engine = item.engine, let estimate else { return item.unavailable ?? "" }
        let idle = engine == .omlx || model.quickIdleMinutes == 0 ? "" : " Arrêt après \(model.quickIdleMinutes) min sans activité."
        return estimate.verdict == .tooLarge
            ? "Il manque \(Format.memory(estimate.shortfallBytes)) : le clic ouvre la fenêtre de lancement, avec ce qu'il faudrait libérer."
            : "Lancer sur \(engine.title) avec les réglages du dernier lancement.\(idle)"
    }

    private func color(_ verdict: MemoryEstimate.Verdict) -> Color {
        switch verdict {
        case .fits: .green
        case .tight: .orange
        case .tooLarge: .red
        }
    }
}
