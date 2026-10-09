import ModelCore
import SwiftUI

/// The menu bar panel: engines, memory and disk at a glance.
struct MenuPanel: View {
    @EnvironmentObject private var model: InventoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Modèles locaux").font(.system(.title3, design: .serif).weight(.semibold))
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
