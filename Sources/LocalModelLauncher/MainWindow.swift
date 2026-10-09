import AppKit
import ModelCore
import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var model: InventoryModel

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: Binding(get: { model.section }, set: { if let value = $0 { model.section = value } })) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            Group {
                if let snapshot = model.snapshot {
                    switch model.section {
                    case .running: RunningView(snapshot: snapshot)
                    case .engines: EnginesView(snapshot: snapshot)
                    case .models: ModelsView(snapshot: snapshot)
                    case .proxy: ProxyView(snapshot: snapshot)
                    case .recipes: RecipesView(snapshot: snapshot)
                    case .disk: DiskView(snapshot: snapshot)
                    case .memory: MemoryView(snapshot: snapshot)
                    }
                } else {
                    ProgressView("Inventaire en cours…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(model.section.title)
            .alert(model.launchOutcome?.title ?? "", isPresented: Binding(get: { model.launchOutcome != nil }, set: { if !$0 { model.launchOutcome = nil } }),
                   presenting: model.launchOutcome) { _ in
                Button("OK", role: .cancel) {}
            } message: { outcome in
                Text(outcome.message)
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        Task { await model.refresh(full: true) }
                    } label: {
                        Label("Actualiser", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isScanning)
                    .keyboardShortcut("r")
                }
            }
        }
    }
}

struct EnginesView: View {
    var snapshot: InventorySnapshot

    var body: some View {
        Form {
            ForEach(snapshot.engines) { engine in
                SwiftUI.Section(engine.kind.title) {
                    LabeledContent("État") { StatePill(text: engine.stateText, color: engine.stateColor) }
                    LabeledContent("Version", value: engine.installation.version ?? "—")
                    if let location = engine.installation.location {
                        LabeledContent("Emplacement") { Text(location).font(.callout.monospaced()).textSelection(.enabled) }
                    }
                    ForEach(engine.instances, id: \.pid) { instance in
                        LabeledContent("Serveur") {
                            Text("\(instance.url ?? "port inconnu") · PID \(String(instance.pid))").font(.callout.monospaced()).textSelection(.enabled)
                        }
                        LabeledContent("API", value: instance.api.title)
                        LabeledContent("Mémoire du processus", value: Format.memory(instance.footprintBytes))
                        if engine.omlx == nil && !instance.servedModels.isEmpty {
                            LabeledContent("Modèle servi", value: instance.servedModels.joined(separator: ", "))
                        }
                    }
                    if let omlx = engine.omlx {
                        LabeledContent("Plafond mémoire", value: omlx.ceilingBytes.map(Format.memory) ?? "—")
                        ForEach(omlx.models, id: \.id) { state in
                            LabeledContent(state.id) {
                                if state.loaded {
                                    StatePill(text: "Chargé · \(state.residentBytes.map(Format.memory) ?? "")", color: .green)
                                } else if state.isLoading {
                                    StatePill(text: "Chargement", color: .orange)
                                } else {
                                    StatePill(text: state.lastAccess.map { "Déchargé · utilisé \($0.formatted(.relative(presentation: .named)))" } ?? "Déchargé · pas utilisé depuis le démarrage d'oMLX",
                                              color: .secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ModelsView: View {
    var snapshot: InventorySnapshot
    @EnvironmentObject private var model: InventoryModel
    @State private var showAll = false
    @State private var query = ""
    @State private var sortOrder = [KeyPathComparator(\LocalModel.sizeBytes, order: .reverse)]
    @State private var selection: LocalModel.ID?
    @State private var launchTarget: LocalModel?

    private var rows: [LocalModel] {
        snapshot.models
            .filter { showAll || $0.kind == .languageModel || $0.isBrokenLink }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Nom", value: \.name) { item in
                HStack(spacing: 6) {
                    if item.isBrokenLink {
                        Image(systemName: "link.badge.plus").foregroundStyle(.red).help("Lien cassé")
                    } else if item.linkTarget != nil {
                        Image(systemName: "link").foregroundStyle(.secondary).help("Lien vers \(item.linkTarget ?? "")")
                    }
                    Text(item.name).lineLimit(1)
                    if model.isLoadedInOMLX(item) { StatePill(text: "chargé", color: .green) }
                }
            }
            .width(min: 260, ideal: 380)
            TableColumn("Emplacement", value: \.store.title) { Text($0.store.title) }
                .width(min: 90, ideal: 130)
            TableColumn("Taille", value: \.sizeBytes) { item in
                Text(item.isLink ? "—" : Format.bytes(item.sizeBytes)).monospacedDigit()
            }
            .width(min: 70, ideal: 80)
            TableColumn("Détails", value: \.summary) { Text($0.summary).foregroundStyle(.secondary).lineLimit(1) }
        }
        .contextMenu(forSelectionType: LocalModel.ID.self) { ids in
            if let id = ids.first, let item = snapshot.model(id: id) {
                Button("Lancer…") { launchTarget = item }
                    .disabled(EngineCompatibility.engines(for: item, snapshot: snapshot).isEmpty)
                Divider()
                Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
                Button("Copier le chemin") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.path, forType: .string)
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, let item = snapshot.model(id: id) { launchTarget = item }
        }
        .sheet(item: $launchTarget) { item in
            LaunchSheet(item: item)
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Rechercher un modèle")
        .toolbar {
            ToolbarItem {
                Button {
                    launchTarget = selection.flatMap { snapshot.model(id: $0) }
                } label: {
                    Label("Lancer…", systemImage: "play.fill")
                }
                .disabled(selection.flatMap { snapshot.model(id: $0) }.map { EngineCompatibility.engines(for: $0, snapshot: snapshot).isEmpty } ?? true)
                .help("Charger le modèle sélectionné (double-clic sur une ligne)")
            }
            ToolbarItem {
                Toggle("Tous les modèles", isOn: $showAll)
                    .help("Inclure embeddings, rerankers et autres modèles")
            }
        }
    }
}

struct DiskView: View {
    var snapshot: InventorySnapshot

    var body: some View {
        let disk = snapshot.disk
        Form {
            SwiftUI.Section("Volume") {
                LabeledContent("Espace libre", value: disk.volumeAvailableBytes.map(Format.bytes) ?? "—")
                LabeledContent("Capacité", value: disk.volumeTotalBytes.map(Format.bytes) ?? "—")
                LabeledContent("Modèles, tous emplacements", value: Format.bytes(disk.modelBytes))
            }
            SwiftUI.Section("Emplacements") {
                ForEach(disk.stores, id: \.store) { usage in
                    LabeledContent {
                        HStack {
                            Text(usage.exists ? "\(Format.bytes(usage.totalBytes)) · \(usage.modelCount) modèles" : "Absent")
                            if usage.exists {
                                Button { reveal(usage.store.path) } label: { Image(systemName: "folder") }
                                    .buttonStyle(.borderless).help("Afficher dans le Finder")
                            }
                        }
                    } label: {
                        Text(usage.store.kind.title)
                        Text(usage.store.path).font(.caption.monospaced())
                    }
                }
            }
            SwiftUI.Section {
                if disk.architectureGroups.isEmpty { Text("Aucune").foregroundStyle(.secondary) }
                ForEach(disk.architectureGroups, id: \.signature) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(group.modelType) · \(Format.bytes(group.totalBytes))").font(.headline)
                        ForEach(group.modelIDs, id: \.self) { id in
                            if let item = snapshot.model(id: id) {
                                Text("\(Format.bytes(item.sizeBytes)) · \(item.store.title) · \(item.name)").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Même architecture")
            } footer: {
                Text("Probablement le même modèle de base, en plusieurs quantifications ou versions affinées. Rien n'est supprimé d'ici.")
            }
            SwiftUI.Section("Liens cassés") {
                if disk.brokenLinkIDs.isEmpty { Text("Aucun").foregroundStyle(.secondary) }
                ForEach(disk.brokenLinkIDs, id: \.self) { id in
                    if let item = snapshot.model(id: id) {
                        LabeledContent {
                            Text(item.brokenReason ?? "").foregroundStyle(.red)
                        } label: {
                            Text("\(item.store.title) · \(item.name)")
                            Text("→ \(item.linkTarget ?? "")").font(.caption.monospaced())
                        }
                    }
                }
            }
            SwiftUI.Section {
                if disk.emptyCacheEntries.isEmpty { Text("Aucune").foregroundStyle(.secondary) }
                ForEach(disk.emptyCacheEntries, id: \.path) { entry in
                    LabeledContent(entry.name, value: Format.bytes(entry.sizeBytes))
                }
            } header: {
                Text("Entrées vides du cache Hugging Face")
            } footer: {
                Text("Restes de modèles supprimés ou de téléchargements interrompus : aucun poids à l'intérieur.")
            }
        }
        .formStyle(.grouped)
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

struct MemoryView: View {
    var snapshot: InventorySnapshot

    var body: some View {
        let stats = snapshot.memory.stats
        let omlx = snapshot.engine(.omlx)?.omlx
        Form {
            SwiftUI.Section {
                MemoryBar(stats: stats, ceiling: omlx?.ceilingBytes).padding(.vertical, 4)
                LabeledContent("Applications", value: Format.memory(stats.appBytes))
                LabeledContent("Mémoire réservée", value: Format.memory(stats.wiredBytes))
                LabeledContent("Compressée", value: Format.memory(stats.compressedBytes))
                LabeledContent("Fichiers en cache", value: Format.memory(stats.cachedFilesBytes))
                LabeledContent("Marge selon macOS", value: stats.freePercent.map { "\($0) %" } ?? "—")
                    .help("Indicateur de macOS (memory_pressure) : il compte comme disponible la mémoire inactive, qu'il peut compresser ou récupérer.")
            } header: {
                Text("\(snapshot.machine.chip) · \(Format.memory(snapshot.machine.memoryBytes))")
            } footer: {
                Text("Selon le moteur, les poids d'un modèle chargé comptent dans la mémoire des applications ou dans la mémoire réservée. La marge de macOS inclut la mémoire inactive : pour charger un modèle, le plafond d'oMLX est un meilleur repère.")
            }
            if let omlx {
                SwiftUI.Section("oMLX") {
                    LabeledContent("Plafond appliqué par oMLX", value: omlx.ceilingBytes.map(Format.memory) ?? "—")
                    LabeledContent("Modèles chargés", value: omlx.loadedBytes.map(Format.memory) ?? "—")
                }
            }
            SwiftUI.Section {
                ForEach(snapshot.memory.groups) { group in
                    LabeledContent {
                        Text(Format.memory(group.footprintBytes)).monospacedDigit()
                    } label: {
                        HStack(spacing: 8) {
                            Text(group.title)
                            if group.role == .modelWorker {
                                StatePill(text: group.role.title, color: .orange)
                            } else if group.role.engine != nil {
                                StatePill(text: "Moteur", color: .accentColor)
                            }
                        }
                        if group.pids.count > 1 || group.detail != nil {
                            Text(group.detail ?? "\(group.pids.count) processus").font(.caption)
                        }
                    }
                }
            } header: {
                Text("Plus gros consommateurs")
            } footer: {
                Text("Empreinte mémoire par app (avec ses processus auxiliaires), par moteur et par processus de modèle lancé hors des moteurs.")
            }
        }
        .formStyle(.grouped)
    }
}
