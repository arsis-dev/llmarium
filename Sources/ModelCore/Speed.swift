import Foundation

/// How fast a model generates on this Mac: a measure when one exists, otherwise the bandwidth bound.
/// Each generated token reads every active weight once, so tokens per second cannot exceed bandwidth ÷ active
/// bytes. Small models stay well under it (fixed costs per token dominate) and MTPLX's speculative decoding
/// can exceed it: the bound is shown as such, never as a prediction.
public struct SpeedEstimate: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case measured, bound }

    public var kind: Kind
    public var tokensPerSecond: Double
    /// With the bound: what this engine reached on undisturbed measures here, as a share of the bound.
    public var expectedTokensPerSecond: Double?
    public var activeBytes: Int64?
    /// How the active share was found, in French: « 10 experts sur 512 », « d'après le nom (A3B) », « dense supposé ».
    public var activeBasis: String?
    public var bandwidth: Double?
    public var measuredAt: Date?
    public var disturbed = false

    /// One line, in French.
    public var summary: String {
        switch kind {
        case .measured:
            return "\(Self.format(tokensPerSecond)) tok/s mesurés" + (measuredAt.map { " le \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "")
                + (disturbed ? " (mesure perturbée)" : "")
        case .bound:
            let expected = expectedTokensPerSecond.map { "≈ \(Self.format($0)) tok/s attendus, " } ?? ""
            return expected + "≤ \(Self.format(tokensPerSecond)) tok/s (borne de la bande passante)"
        }
    }

    public static func format(_ value: Double) -> String { value >= 10 ? String(Int(value.rounded())) : value.formatted(.number.precision(.fractionLength(1))) }
}

public enum SpeedPlanner {
    /// Share of the weights read for each token, with how it was found.
    public static func activeShare(spec: ModelSpec?, name: String) -> (share: Double, basis: String) {
        if let spec, let experts = spec.experts, experts > 1, let perToken = spec.expertsPerToken,
           let layers = spec.layers, let hidden = spec.hiddenSize, let expertSize = spec.expertIntermediateSize {
            let expertTotal = Double(layers * experts * 3 * hidden * expertSize)
            let heads = spec.attentionHeads ?? 0
            let headDim = spec.headDim ?? (heads > 0 ? hidden / heads : 0)
            let attention = heads > 0 ? Double(2 * hidden * heads * headDim + 2 * hidden * (spec.kvHeads ?? heads) * headDim)
                                      : Double(4 * hidden * hidden)
            let shared = Double(3 * hidden * (spec.sharedExpertIntermediateSize ?? 0))
            let vocab = Double((spec.vocabSize ?? 0) * hidden)
            // Embeddings are looked up row by row; the output head is read whole for each token.
            let dense = Double(layers) * (attention + shared)
            let total = expertTotal + dense + vocab * (spec.tiedEmbeddings == true ? 1 : 2)
            let active = expertTotal * Double(perToken) / Double(experts) + dense + vocab
            return (min(1, active / total), "\(perToken) experts sur \(experts) par token")
        }
        if let match = name.firstMatch(of: #/(\d+(?:\.\d+)?)B-A(\d+(?:\.\d+)?)B/#.ignoresCase()),
           let total = Double(match.1), let active = Double(match.2), total > 0, active < total {
            return (active / total, "d'après le nom (\(match.1)B dont \(match.2)B actifs)")
        }
        return (1, spec?.layers == nil ? "dense supposé" : "dense")
    }

    /// Generation speed of `model` on `engine`. `measured` is the last benchmark of this pair; `calibration` gives
    /// (measured tok/s, bound tok/s) for undisturbed runs of other models on the same engine.
    public static func estimate(name: String, weightsBytes: Int64, spec: ModelSpec?, bandwidth: Double?,
                                measured: BenchmarkResult?, calibration: [(measured: Double, bound: Double)] = []) -> SpeedEstimate? {
        if let measured, let speed = measured.decodeTokensPerSecond {
            return SpeedEstimate(kind: .measured, tokensPerSecond: speed, measuredAt: measured.date, disturbed: measured.disturbed)
        }
        guard let bandwidth, weightsBytes > 0 else { return nil }
        let (share, basis) = activeShare(spec: spec, name: name)
        let active = Int64(Double(weightsBytes) * share)
        let bound = bandwidth * 1e9 / Double(max(active, 1))
        let ratios = calibration.filter { $0.bound > 0 }.map { min(1, $0.measured / $0.bound) }.sorted()
        let expected = ratios.isEmpty ? nil : bound * ratios[ratios.count / 2]
        return SpeedEstimate(kind: .bound, tokensPerSecond: bound, expectedTokensPerSecond: expected, activeBytes: active,
                             activeBasis: basis, bandwidth: bandwidth)
    }

    /// The estimate for a local model, from this Mac's benchmarks: the latest measure of the pair, otherwise the bound,
    /// calibrated by undisturbed measures of other models on the same engine.
    public static func estimate(model: LocalModel, engine: EngineKind, weightsBytes: Int64, machine: MachineInfo,
                                models: [LocalModel], benchmarks: [BenchmarkResult]) -> SpeedEstimate? {
        let here = benchmarks.filter { $0.engine == engine && $0.machine.hasPrefix(machine.chip) }
        let leaf = LaunchPlan.servedName(model)
        let measured = here.filter { $0.model == model.name || $0.model == leaf }.max { $0.date < $1.date }
        let calibration: [(measured: Double, bound: Double)] = here.compactMap { result in
            guard !result.disturbed, let speed = result.decodeTokensPerSecond, let bandwidth = machine.bandwidth,
                  let other = models.first(where: { $0.name == result.model || LaunchPlan.servedName($0) == result.model }) else { return nil }
            let share = activeShare(spec: other.spec, name: other.name).share
            return (speed, bandwidth * 1e9 / (Double(other.sizeBytes) * share))
        }
        return estimate(name: model.name, weightsBytes: weightsBytes, spec: model.spec, bandwidth: machine.bandwidth,
                        measured: measured, calibration: calibration)
    }
}

extension RadarItem {
    /// Bandwidth bound from the repository size and name (a radar item has no `config.json` yet).
    public func speedBound(bandwidth: Double?) -> SpeedEstimate? {
        guard let sizeBytes else { return nil }
        return SpeedPlanner.estimate(name: id, weightsBytes: sizeBytes, spec: nil, bandwidth: bandwidth, measured: nil)
    }
}
