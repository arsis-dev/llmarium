import AppKit
import ModelCore
import SwiftUI

/// Pick a harness and a project folder for a running model; say what will be configured, then open it.
struct HarnessSheet: View {
    var target: HarnessTarget
    var initial: HarnessKind
    @EnvironmentObject private var model: InventoryModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind: HarnessKind = .claudeCode
    @State private var directory = UserDefaults.standard.string(forKey: "lastProjectFolder") ?? NSHomeDirectory()
    @State private var opening = false
    @State private var error: String?

    private var reason: String? { HarnessPlanner.unavailableReason(kind, target: target, installed: model.installedHarnesses) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                SwiftUI.Section {
                    Picker("Harness", selection: $kind) {
                        ForEach(HarnessKind.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    if kind != .deepseekHarness {
                        LabeledContent("Dossier du projet") {
                            HStack {
                                Text((directory as NSString).abbreviatingWithTildeInPath).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                                Button("Choisir…", action: chooseFolder)
                            }
                        }
                    }
                } header: {
                    Text("\(target.modelID) · \(target.engine.title)")
                } footer: {
                    if let reason {
                        Text(reason).foregroundStyle(.red)
                    } else {
                        Text(kind.configurationSummary)
                    }
                }
                SwiftUI.Section {
                    LabeledContent("Adresse", value: target.baseURL)
                    LabeledContent("Contexte", value: target.contextWindow.map { "\(Format.tokens($0)) tokens" } ?? "non précisé")
                    LabeledContent("Ouverture") {
                        Text(kind == .deepseekHarness ? "App DeepSeek Harness ; choisir « \(target.modelID) (local) »" : "Nouvelle fenêtre Ghostty")
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .formStyle(.grouped)
            if let error {
                Text(error).foregroundStyle(.red).padding(.horizontal, 20)
            }
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Ouvrir") { open() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(reason != nil || opening)
            }
            .padding(16)
        }
        .frame(width: 520, height: 460)
        .onAppear { kind = initial }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: directory)
        panel.prompt = "Choisir"
        if panel.runModal() == .OK, let url = panel.url { directory = url.path }
    }

    private func open() {
        opening = true
        defer { opening = false }
        do {
            let launch = try HarnessPlanner.prepare(kind, target: target, directory: directory)
            try HarnessOpener.open(launch)
            UserDefaults.standard.set(directory, forKey: "lastProjectFolder")
            if kind == .deepseekHarness {
                model.launchOutcome = ActionOutcome(title: "DeepSeek Harness configuré",
                                                    message: "Choisissez « \(target.modelID) (local) » dans son sélecteur de modèle. Si l'app était déjà ouverte, redémarrez-la pour qu'elle relise sa configuration.")
            }
            dismiss()
        } catch {
            self.error = "\(error)"
        }
    }
}
