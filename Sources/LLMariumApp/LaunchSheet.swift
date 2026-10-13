import ModelCore
import SwiftUI

/// Choose an engine and a context, see whether the model fits, then load it.
struct LaunchSheet: View {
    var item: LocalModel
    @EnvironmentObject private var model: InventoryModel
    @Environment(\.dismiss) private var dismiss
    @State private var engine: EngineKind?
    @State private var context = 65_536
    @State private var confirmForce = false
    @State private var stopWhenIdle = false
    @State private var idleMinutes = 30

    private var snapshot: InventorySnapshot? { model.snapshot }
    private var engines: [EngineKind] { snapshot.map { EngineCompatibility.engines(for: item, snapshot: $0) } ?? [] }
    private var maxContext: Int { item.spec?.maxContext ?? 32_768 }
    private var contexts: [Int] {
        let steps = [8_192, 16_384, 32_768, 65_536, 131_072, 262_144, 524_288, 1_048_576].filter { $0 < maxContext }
        return steps + [maxContext]
    }

    private var estimate: MemoryEstimate? {
        guard let snapshot, let engine else { return nil }
        return MemoryPlanner.estimate(model: item, engine: engine, context: context, snapshot: snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                SwiftUI.Section {
                    if engines.isEmpty {
                        Text("Aucun moteur ne peut servir ce modèle.").foregroundStyle(.secondary)
                    } else {
                        Picker("Moteur", selection: $engine) {
                            ForEach(engines, id: \.self) { Text($0.title).tag(EngineKind?.some($0)) }
                        }
                    }
                    if let snapshot {
                        ForEach(EngineKind.allCases.filter { !engines.contains($0) }, id: \.self) { absent in
                            LabeledContent(absent.title) {
                                Text(EngineCompatibility.absenceReason(absent, model: item, snapshot: snapshot)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if engine != .omlx {
                        Picker("Contexte", selection: $context) {
                            ForEach(contexts, id: \.self) { Text("\(Format.tokens($0)) tokens").tag($0) }
                        }
                        Toggle("Arrêter s'il reste inactif", isOn: $stopWhenIdle)
                        if stopWhenIdle {
                            Picker("Après", selection: $idleMinutes) {
                                ForEach([15, 30, 60, 120], id: \.self) { Text($0 < 60 ? "\($0) min" : "\($0 / 60) h").tag($0) }
                            }
                        }
                    }
                } header: {
                    Text(item.name)
                } footer: {
                    if engine == .omlx { Text("oMLX applique ses propres réglages de contexte pour ce modèle.") }
                    else if engine != nil {
                        Text("Le serveur écoute sur 127.0.0.1, sur un port libre entre 18100 et 18199. Il continue de tourner si l'app est quittée."
                             + (stopWhenIdle ? " L'arrêt pour inactivité n'est compté que pendant que l'app est ouverte : sans requête ni client pendant ce temps, le serveur s'arrête et libère sa mémoire." : ""))
                    }
                }
                if let estimate {
                    EstimateSection(estimate: estimate)
                }
            }
            .formStyle(.grouped)

            HStack {
                if let job = model.launches[item.id] {
                    ProgressView().controlSize(.small)
                    TimelineView(.periodic(from: job.startedAt, by: 1)) { context in
                        Text("Chargement sur \(job.engine.title)… \(Int(context.date.timeIntervalSince(job.startedAt))) s").foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(model.launches[item.id] == nil ? "Annuler" : "Fermer") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if let engine, let estimate {
                    let needsForce = estimate.verdict == .tooLarge && engine != .omlx
                    Button(needsForce ? "Lancer quand même…" : "Lancer") {
                        if needsForce { confirmForce = true } else { start(engine, force: false) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.launches[item.id] != nil)
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 600)
        .onAppear {
            engine = engine ?? engines.first
            context = min(65_536, maxContext)
        }
        .confirmationDialog("Lancer sans assez de mémoire ?", isPresented: $confirmForce) {
            Button("Lancer quand même", role: .destructive) { if let engine { start(engine, force: true) } }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Il manque environ \(Format.memory(estimate?.shortfallBytes ?? 0)). macOS va compresser ou écrire de la mémoire sur le disque : tout le Mac peut ralentir fortement, et le moteur peut s'arrêter.")
        }
    }

    private func start(_ engine: EngineKind, force: Bool) {
        Task {
            await model.launch(item, engine: engine, context: engine == .omlx ? nil : context, force: force,
                               idleStopAfterMinutes: engine != .omlx && stopWhenIdle ? idleMinutes : nil)
        }
    }
}

/// Weights, cache and margin against what the engine can use now, with what to free when it does not fit.
struct EstimateSection: View {
    var estimate: MemoryEstimate

    private func speedDetail(_ speed: SpeedEstimate) -> String {
        var parts = ["borne de la bande passante (\(Int(speed.bandwidth ?? 0)) Go/s ÷ \(Format.memory(speed.activeBytes ?? 0)) lus par token, \(speed.activeBasis ?? "dense"))"]
        if let expected = speed.expectedTokensPerSecond { parts.insert("≈ \(SpeedEstimate.format(expected)) tok/s attendus d'après vos mesures", at: 0) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        SwiftUI.Section {
            LabeledContent("Poids") {
                VStack(alignment: .trailing) {
                    Text(Format.memory(estimate.weightsBytes))
                    Text(estimate.weightsMeasurement.map { "mesuré (\($0.source), \($0.measuredAt.formatted(date: .abbreviated, time: .omitted)))" } ?? "taille sur disque")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Cache de contexte") {
                VStack(alignment: .trailing) {
                    Text(Format.memory(estimate.kvCacheBytes))
                    if let perToken = estimate.kvBytesPerToken {
                        Text("\(Format.tokens(estimate.context)) tokens · \(Format.memory(perToken * 1024)) pour 1K").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent("Marge d'exécution", value: Format.memory(estimate.overheadBytes))
            LabeledContent("Total estimé", value: Format.memory(estimate.totalBytes)).fontWeight(.semibold)
            LabeledContent("Disponible") {
                VStack(alignment: .trailing) {
                    Text(Format.memory(max(0, estimate.availableBytes)))
                    Text(estimate.availableBasis).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
            }
            if let gpu = estimate.gpuAvailableBytes {
                LabeledContent("Plafond du GPU") {
                    VStack(alignment: .trailing) {
                        Text(Format.memory(max(0, gpu)))
                        Text("\(Format.memory(estimate.gpuLimitBytes ?? 0)) (\(estimate.gpuLimitSource ?? "macOS")) moins les modèles en mémoire")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                }
            }
            LabeledContent("Verdict") {
                switch estimate.verdict {
                case .fits: StatePill(text: "Tient en mémoire", color: .green)
                case .tight: StatePill(text: "Tient, de justesse", color: .orange)
                case .tooLarge: StatePill(text: "Il manque \(Format.memory(estimate.shortfallBytes))", color: .red)
                }
            }
            if estimate.verdict != .fits {
                ForEach(estimate.toFree.prefix(6), id: \.self) { candidate in
                    LabeledContent {
                        Text(Format.memory(candidate.bytes)).monospacedDigit()
                    } label: {
                        Text(candidate.title)
                        if let detail = candidate.detail { Text(detail).font(.caption) }
                    }
                }
            }
            if let speed = estimate.speed {
                LabeledContent("Vitesse de génération") {
                    VStack(alignment: .trailing) {
                        Text(speed.kind == .measured ? "\(SpeedEstimate.format(speed.tokensPerSecond)) tok/s" : "≤ \(SpeedEstimate.format(speed.tokensPerSecond)) tok/s")
                        Text(speed.kind == .measured ? speed.summary : speedDetail(speed))
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                }
                .help("Chaque token généré relit les poids actifs : la bande passante de la puce fixe un plafond. Les petits modèles restent bien en dessous, et le décodage spéculatif de MTPLX peut le dépasser. Une mesure (« Mesurer » dans « En cours ») remplace cette borne.")
            }
        } header: {
            Text("Mémoire")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if estimate.verdict != .fits {
                    Text("À libérer : les modèles en cours se déchargent ou s'arrêtent depuis « En cours » ; les apps se quittent normalement.")
                }
                ForEach(estimate.notes, id: \.self) { Text($0) }
            }
        }
    }
}
