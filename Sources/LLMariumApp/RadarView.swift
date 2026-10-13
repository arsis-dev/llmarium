import AppKit
import ModelCore
import SwiftUI

/// New language models this Mac can run, with why each one is listed. Downloading is the user's action, after a disk check.
struct RadarView: View {
    var snapshot: InventorySnapshot
    @State private var report = Radar.cached()
    @State private var loading = false
    @State private var settings: RadarSettings?
    @State private var newAuthor = ""
    @State private var pending: RadarDownload?
    @State private var pendingItem: RadarItem?
    @State private var message: String?
    @State private var showExcluded = false
    @State private var usage: ModelUsage?

    private var shownItems: [RadarItem] {
        guard let usage else { return report?.items ?? [] }
        return (report?.items ?? []).filter { $0.usages?.contains { $0.usage == usage } == true }
    }

    var body: some View {
        Form {
            SwiftUI.Section {
                HStack {
                    if let report {
                        Text("Liste du \(report.fetchedAt.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                    Button("Actualiser") { Task { await load(refresh: true) } }.disabled(loading)
                }
                ForEach(report?.sources ?? [], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                if let message { Text(message).font(.callout) }
            } header: {
                Text("Radar")
            } footer: {
                Text("Modèles de langage au format MLX, qui tiennent dans \(Format.memory(RadarFilter.memoryLimit(totalBytes: snapshot.machine.memoryBytes))) de mémoire et ne sont pas encore sur ce Mac. Mis à jour une fois par jour ; les moteurs indiqués sont probables, d'après l'auteur et le nom.")
            }

            if let report {
                SwiftUI.Section {
                    Picker("Usage", selection: $usage) {
                        Text("Tous").tag(ModelUsage?.none)
                        ForEach(ModelUsage.allCases, id: \.self) { Text($0.title).tag(ModelUsage?.some($0)) }
                    }
                    .pickerStyle(.segmented)
                    if shownItems.isEmpty {
                        Text(report.items.isEmpty ? "Aucun modèle retenu." : "Aucun modèle pour cet usage.").foregroundStyle(.secondary)
                    }
                    ForEach(shownItems) { item in
                        RadarRow(item: item, bandwidth: snapshot.machine.bandwidth) { engine in prepare(item, engine: engine) }
                    }
                } footer: {
                    Text("Usages et vitesses sont des indices : l'usage vient du nom et des étiquettes Hugging Face (survolez une étiquette pour voir lequel), la vitesse est la borne fixée par la bande passante de la puce.")
                }
                SwiftUI.Section {
                    DisclosureGroup("Écartés : \(report.excluded.count)", isExpanded: $showExcluded) {
                        ForEach(report.excluded, id: \.id) { exclusion in
                            LabeledContent(exclusion.id) { Text(exclusion.reason).foregroundStyle(.secondary) }.font(.callout)
                        }
                    }
                }
            }

            if let settings {
                SwiftUI.Section("Sources") {
                    ForEach(settings.authors, id: \.self) { author in
                        LabeledContent(author) {
                            Button { update { $0.authors.removeAll { $0 == author } } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("Ne plus suivre")
                        }
                    }
                    HStack {
                        TextField("", text: $newAuthor, prompt: Text("Auteur Hugging Face à suivre")).labelsHidden()
                        Button("Ajouter") {
                            let author = newAuthor.trimmingCharacters(in: .whitespaces)
                            guard !author.isEmpty else { return }
                            update { if !$0.authors.contains(author) { $0.authors.append(author) } }
                            newAuthor = ""
                        }
                    }
                    Toggle("Liens Hugging Face de mes favoris Spicilege", isOn: Binding(get: { settings.useSpicilege },
                                                                                       set: { value in update { $0.useSpicilege = value } }))
                }
            }
        }
        .formStyle(.grouped)
        .task {
            settings = Radar.settings(models: snapshot.models)
            if report == nil || report?.isStale == true { await load(refresh: false) }
        }
        .confirmationDialog("Télécharger \(pendingItem?.id ?? "") ?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            presenting: pending) { download in
            Button("Télécharger") { start(download) }
            Button("Annuler", role: .cancel) {}
        } message: { download in
            Text("Depuis \(pendingItem?.url ?? "")\nTaille : \(download.sizeBytes.map(Format.bytes) ?? "inconnue")\nVers : \(download.destination)\nEspace libre : \(snapshot.disk.volumeAvailableBytes.map(Format.bytes) ?? "?")\n\nLe téléchargement s'ouvre dans Ghostty, où vous pouvez l'interrompre.")
        }
    }

    private func load(refresh: Bool) async {
        loading = true
        defer { loading = false }
        report = await Radar.report(snapshot: snapshot, refresh: refresh)
    }

    private func update(_ change: (inout RadarSettings) -> Void) {
        guard var current = settings else { return }
        change(&current)
        settings = current
        try? Radar.save(current)
        message = "Pris en compte à la prochaine actualisation."
    }

    private func prepare(_ item: RadarItem, engine: EngineKind) {
        if item.gated {
            message = "Ce modèle demande d'accepter ses conditions sur Hugging Face : faites-le sur sa page, connectez-vous avec « hf auth login », puis réessayez."
            return
        }
        if let refusal = RadarDownload.diskRefusal(sizeBytes: item.sizeBytes, freeBytes: snapshot.disk.volumeAvailableBytes) {
            message = refusal
            return
        }
        pendingItem = item
        pending = RadarDownload.plan(repo: item.id, engine: engine, sizeBytes: item.sizeBytes)
    }

    private func start(_ download: RadarDownload) {
        do {
            try HarnessOpener.open(download.command)
            message = download.engine == .omlx
                ? "Téléchargement lancé dans Ghostty. oMLX le proposera après son prochain examen du cache ; la section Modèles le montre dès la fin."
                : "Téléchargement lancé dans Ghostty ; le modèle apparaîtra dans la section Modèles à la fin."
        } catch {
            message = "\(error)"
        }
    }
}

struct RadarRow: View {
    var item: RadarItem
    var bandwidth: Double?
    var download: (EngineKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.id).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(item.sizeBytes.map(Format.bytes) ?? "taille ?").monospacedDigit().foregroundStyle(.secondary)
            }
            Text(item.reasons.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(item.usages ?? [], id: \.self) { tag in
                    StatePill(text: tag.usage.title, color: .blue).help(tag.clue)
                }
                if let speed = item.speedBound(bandwidth: bandwidth) {
                    Text("≤ \(SpeedEstimate.format(speed.tokensPerSecond)) tok/s").font(.caption).foregroundStyle(.secondary)
                        .help("Borne de la bande passante : \(Int(speed.bandwidth ?? 0)) Go/s ÷ \(Format.memory(speed.activeBytes ?? 0)) lus par token (\(speed.activeBasis ?? "dense")).")
                }
            }
            ForEach(item.warnings, id: \.self) { StatePill(text: $0, color: .orange) }
            HStack {
                Text(item.engines.map(\.title).joined(separator: " ou ") + " (probable)" + (item.createdAt.map { " · publié le \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Link("Voir sur Hugging Face", destination: URL(string: item.url)!).font(.callout)
                Menu("Télécharger") {
                    ForEach(item.engines, id: \.self) { engine in
                        Button("Pour \(engine.title)…") { download(engine) }
                    }
                }
                .fixedSize()
            }
        }
        .padding(.vertical, 3)
    }
}
