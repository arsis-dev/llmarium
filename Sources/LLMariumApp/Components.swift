import ModelCore
import SwiftUI

/// A short state with a colored dot; the text always carries the meaning.
struct StatePill: View {
    var text: String
    var color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

extension EngineStatus {
    var stateText: String {
        guard installation.isInstalled else { return "Non installé" }
        guard isRunning else { return "Arrêté" }
        return instances.allSatisfy { $0.api == .ok } ? "Actif" : instances.first?.api.title ?? "Actif"
    }

    var stateColor: Color {
        guard installation.isInstalled else { return .secondary.opacity(0.4) }
        guard isRunning else { return .secondary }
        return instances.allSatisfy { $0.api == .ok } ? .green : .orange
    }
}

extension MemoryPressure {
    var color: Color {
        switch self {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        case .unknown: .secondary
        }
    }
}

/// Used memory against total, with the oMLX ceiling marked when known.
struct MemoryBar: View {
    var stats: MemoryStats
    var ceiling: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let total = max(Double(stats.totalBytes), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(stats.pressure.color.gradient)
                        .frame(width: width * min(Double(stats.usedBytes) / total, 1))
                    if let ceiling {
                        Rectangle().fill(.primary.opacity(0.6)).frame(width: 2)
                            .offset(x: width * min(Double(ceiling) / total, 1) - 1)
                            .help("Plafond mémoire d'oMLX : \(Format.memory(ceiling))")
                    }
                }
            }
            .frame(height: 8)
            HStack {
                Text("\(Format.memory(stats.usedBytes)) utilisés sur \(Format.memory(stats.totalBytes))")
                Spacer()
                StatePill(text: "Pression \(stats.pressure.title.lowercased())", color: stats.pressure.color)
            }
            .font(.callout)
        }
    }
}

extension LocalModel {
    var summary: String {
        if isBrokenLink { return "Lien cassé · \(brokenReason ?? "")" }
        var parts = [format.title]
        if let spec {
            if let type = spec.modelType { parts.append(type) }
            if let bits = spec.quantBits { parts.append("\(bits) bits") }
            if let context = spec.maxContext { parts.append("contexte \(Format.tokens(context))") }
        }
        return parts.joined(separator: " · ")
    }
}
