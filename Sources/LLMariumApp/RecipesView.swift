import AppKit
import ModelCore
import SwiftUI

/// Benchmarks side by side, and the recipe of each language model on each engine that can serve it.
struct RecipesView: View {
    var snapshot: InventorySnapshot
    @EnvironmentObject private var model: InventoryModel
    @State private var selection: String?
    @State private var draft: Recipe?
    @State private var community: [CommunityBenchmark] = []
    @State private var message: String?

    struct Pairing: Hashable, Identifiable {
        var model: LocalModel
        var engine: EngineKind
        var id: String { Recipe.key(engine: engine, model: model.name) }
    }

    private var pairings: [Pairing] {
        snapshot.models.filter { $0.kind == .languageModel && !$0.isBrokenLink }.flatMap { local in
            EngineCompatibility.engines(for: local, snapshot: snapshot).map { Pairing(model: local, engine: $0) }
        }
    }

    private var selected: Pairing? { pairings.first { $0.id == selection } ?? pairings.first }

    var body: some View {
        Form {
            BenchmarksSection(results: model.benchmarkResults)
            if let pairing = selected {
                SwiftUI.Section {
                    Picker("Modèle et moteur", selection: Binding(get: { pairing.id }, set: { selection = $0 })) {
                        ForEach(pairings) { item in Text("\(item.model.name) · \(item.engine.title)").tag(item.id) }
                    }
                    if let draft {
                        RecipeEditor(recipe: Binding(get: { draft }, set: { self.draft = $0 }), engine: pairing.engine)
                    }
                } header: {
                    Text("Recette")
                } footer: {
                    Text(pairing.engine == .omlx
                         ? "oMLX applique ses propres réglages (app oMLX → Réglages du modèle) : cette recette sert de référence."
                         : "Appliquée quand l'app lance \(pairing.engine.title) pour ce modèle.")
                }
                if let draft {
                    SwiftUI.Section("Notes et sources") {
                        ForEach(draft.notes, id: \.self) { Text($0).font(.callout) }
                        ForEach(draft.sources, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                        Text(draft.author.title + " · " + draft.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                    }
                }
                if pairing.engine == .omlx {
                    SwiftUI.Section {
                        if community.isEmpty { Text("Aucun résultat publié pour ce modèle sur cette puce.").foregroundStyle(.secondary) }
                        ForEach(community, id: \.id) { reference in
                            LabeledContent {
                                Link("Voir", destination: URL(string: reference.url)!)
                            } label: {
                                Text("\(reference.decodeTokensPerSecond.map { String(format: "%.1f", $0) } ?? "?") tok/s en génération · \(reference.prefillTokensPerSecond.map { String(format: "%.0f", $0) } ?? "?") en lecture")
                                Text("\(reference.quantization ?? "") · Mac \(reference.memoryGB.map { "\($0) Go" } ?? "") · oMLX \(reference.omlxVersion ?? "") · \(reference.settings.count) réglages").font(.caption)
                            }
                        }
                    } header: {
                        Text("Résultats publiés sur omlx.ai")
                    } footer: {
                        Text("Meilleurs résultats de la communauté pour cette puce (contexte de 4K, protocole d'omlx.ai) : un ordre de grandeur, pas une mesure de ce Mac.")
                    }
                }
                SwiftUI.Section {
                    HStack {
                        Button("Enregistrer la recette", action: save).disabled(draft == nil)
                        Button("Demander à Claude…") { ask(pairing) }
                            .help("Ouvre Claude Code dans Ghostty avec le serveur MCP de l'app : il cherche les réglages recommandés, les propose avec leurs sources, et n'enregistre qu'après votre accord.")
                        if pairing.engine == .mtplx {
                            Button("Optimiser avec mtplx tune…") { tune(pairing) }
                                .help("Charge le modèle et mesure la profondeur MTP la plus rapide (plusieurs minutes), dans une fenêtre Ghostty.")
                        }
                    }
                    if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: selected?.id) { load() }
    }

    private func load() {
        guard let pairing = selected else { return }
        draft = RecipeDeriver.effective(model: pairing.model, engine: pairing.engine)
        message = nil
        community = []
        if pairing.engine == .omlx {
            Task {
                let served = LaunchPlan.servedName(pairing.model)
                community = await CommunityBenchmarks.shared.best(model: served, machine: snapshot.machine)
            }
        }
    }

    private func save() {
        guard var recipe = draft else { return }
        recipe.author = .user
        recipe.sources.append("Modifiée dans LLMarium le \(Date().formatted(date: .abbreviated, time: .omitted))")
        do {
            try RecipeStore.shared.save(recipe)
            draft = recipe
            message = "Recette enregistrée."
        } catch {
            message = "Enregistrement impossible : \(error)"
        }
    }

    private func ask(_ pairing: Pairing) {
        let llmarium = Bundle.main.bundleURL.appending(path: "Contents/MacOS/llmarium").path
        do {
            try HarnessOpener.open(ClaudeAsk.launch(model: pairing.model, engine: pairing.engine, llmarium: llmarium))
            message = "Claude Code est ouvert dans Ghostty. La recette apparaîtra ici une fois enregistrée (rouvrez la section)."
        } catch {
            message = "\(error)"
        }
    }

    private func tune(_ pairing: Pairing) {
        do {
            try HarnessOpener.open(ClaudeAsk.mtplxTune(model: pairing.model))
            message = "mtplx tune tourne dans Ghostty ; il garde son résultat pour les prochains lancements de MTPLX."
        } catch {
            message = "\(error)"
        }
    }
}

struct RecipeEditor: View {
    @Binding var recipe: Recipe
    var engine: EngineKind

    var body: some View {
        LabeledContent("Contexte") {
            HStack {
                TextField("", value: $recipe.context, format: .number, prompt: Text("moteur")).labelsHidden().frame(width: 90).multilineTextAlignment(.trailing)
                Text("tokens").foregroundStyle(.secondary)
            }
        }
        if engine == .mtplx {
            Picker("Raisonnement", selection: Binding(get: { recipe.reasoning ?? "auto" }, set: { recipe.reasoning = $0 == "auto" ? nil : $0 })) {
                Text("Valeur du moteur").tag("auto")
                Text("Coupé").tag("off")
                Text("Actif").tag("on")
            }
        }
        LabeledContent("Température") { optionalNumber($recipe.sampling.temperature) }
        LabeledContent("top_p") { optionalNumber($recipe.sampling.topP) }
        LabeledContent("top_k") {
            TextField("", value: $recipe.sampling.topK, format: .number, prompt: Text("moteur")).labelsHidden().frame(width: 90).multilineTextAlignment(.trailing)
        }
        LabeledContent("Options du moteur") {
            TextField("", text: Binding(get: { recipe.flags.joined(separator: " ") },
                                        set: { recipe.flags = $0.split(separator: " ").map(String.init) }), prompt: Text("aucune"))
                .labelsHidden().frame(width: 260).multilineTextAlignment(.trailing).font(.callout.monospaced())
        }
    }

    private func optionalNumber(_ value: Binding<Double?>) -> some View {
        TextField("", value: value, format: .number.precision(.fractionLength(0...3)), prompt: Text("moteur")).labelsHidden().frame(width: 90).multilineTextAlignment(.trailing)
    }
}

/// Every measure side by side; disturbed ones are marked.
struct BenchmarksSection: View {
    var results: [BenchmarkResult]

    var body: some View {
        SwiftUI.Section {
            if results.isEmpty {
                Text("Aucune mesure. « Mesurer » sur une carte de la section En cours, ou llmarium bench <modèle>.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text("Modèle").gridColumnAlignment(.leading)
                        Text("Moteur").gridColumnAlignment(.leading)
                        Text("Génération")
                        Text("Lecture")
                        Text("1er token")
                        Text("Outil")
                        Text("Long")
                        Text("Mémoire")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(results) { result in
                        GridRow {
                            HStack(spacing: 4) {
                                if result.disturbed {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                        .help("Mesure perturbée : " + result.conditions.joined(separator: " ; "))
                                }
                                Text(result.model).lineLimit(1).truncationMode(.middle)
                            }
                            .frame(maxWidth: 260, alignment: .leading)
                            Text("\(result.engine.title) \(result.engineVersion ?? "")").foregroundStyle(.secondary)
                            Text(result.decodeTokensPerSecond.map { String(format: "%.1f", $0) } ?? "—")
                            Text(result.prefillTokensPerSecond.map { String(format: "%.0f", $0) } ?? "—")
                            Text(result.timeToFirstToken.map { String(format: "%.2f s", $0) } ?? "—")
                            Text(result.toolCallSucceeded.map { $0 ? "✓" : "✗" } ?? "—")
                            Text(result.longContextSucceeded.map { $0 ? "✓" : "✗" } ?? "—")
                            Text(result.peakMemoryBytes.map(Format.memory) ?? "—")
                        }
                        .font(.callout.monospacedDigit())
                        .help(result.date.formatted(date: .abbreviated, time: .shortened) + (result.reasoningObserved ? " · raisonnement produit" : ""))
                    }
                }
            }
        } header: {
            Text("Bancs d'essai")
        } footer: {
            Text("Génération et lecture en tokens/s, mesurées directement sur le moteur après un échauffement. Pour oMLX, la mémoire couvre tous ses modèles chargés. ⚠︎ : un autre client utilisait le moteur ou le GPU.")
        }
    }
}
