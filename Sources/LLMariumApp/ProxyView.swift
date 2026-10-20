import AppKit
import ModelCore
import ServiceManagement
import SwiftUI

/// The proxy hosted by the app: it runs while the app runs, so the app can open at login.
@MainActor
final class ProxyController: ObservableObject {
    static let shared = ProxyController()

    enum State: Equatable {
        case off
        case starting
        case running(Int)
        case failed(String)
    }

    @Published private(set) var state: State = .off
    @Published private(set) var recent: [String] = []
    @Published var config = ProxyConfig.load()
    private(set) var server: ProxyServer?

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "proxyEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "proxyEnabled") }
    }

    var url: String? {
        if case .running(let port) = state { return "http://127.0.0.1:\(port)" }
        return nil
    }

    func startIfEnabled() { if enabled { start() } }

    func start() {
        guard server == nil else { return }
        enabled = true
        config = ProxyConfig.load()
        state = .starting
        let server = ProxyServer(port: config.port, tableProvider: {
            RouteTable.build(runtime: await Runtime.current(), config: ProxyConfig.load())
        }, logFile: AppPaths.logs.appending(path: "proxy.log"), log: { line in
            Task { @MainActor in ProxyController.shared.append(line) }
        })
        self.server = server
        Task {
            do {
                try await server.start()
                state = .running(server.port)
            } catch {
                self.server = nil
                state = .failed("\(error)")
            }
        }
    }

    func stop() {
        enabled = false
        server?.stop()
        server = nil
        state = .off
    }

    func append(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        recent.insert("\(stamp)  \(line)", at: 0)
        if recent.count > 50 { recent.removeLast(recent.count - 50) }
    }

    func reloadConfig() { config = ProxyConfig.load() }

    var table: RouteTable? { server?.currentTable }
}

struct ProxyView: View {
    var snapshot: InventorySnapshot
    @EnvironmentObject private var model: InventoryModel
    @ObservedObject private var proxy = ProxyController.shared
    @State private var keyFor: RemoteProvider?
    @State private var message: String?
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    private var table: RouteTable {
        proxy.table ?? RouteTable(aliases: proxy.config.aliases, servers: [], providers: proxy.config.providers)
    }

    var body: some View {
        Form {
            SwiftUI.Section {
                Toggle("Activer le point d'entrée", isOn: Binding(get: { proxy.state == .starting || proxy.url != nil },
                                                                  set: { $0 ? proxy.start() : proxy.stop() }))
                LabeledContent("État") {
                    switch proxy.state {
                    case .off: StatePill(text: "Arrêté", color: .secondary)
                    case .starting: StatePill(text: "Démarrage…", color: .orange)
                    case .running: StatePill(text: "Actif", color: .green)
                    case .failed(let reason): StatePill(text: reason, color: .red)
                    }
                }
                LabeledContent("Adresse") {
                    HStack {
                        Text("http://127.0.0.1:\(String(proxy.config.port))/v1").font(.callout.monospaced()).textSelection(.enabled)
                        Button { copy("http://127.0.0.1:\(proxy.config.port)/v1") } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("Copier")
                    }
                }
                Toggle("Ouvrir LLMarium à la connexion", isOn: Binding(get: { openAtLogin }, set: setOpenAtLogin))
            } header: {
                Text("Point d'entrée")
            } footer: {
                Text("Une seule adresse, compatible OpenAI et Anthropic, pour tous les modèles en cours et les API distantes. Il n'écoute que sur cette machine, et tourne tant que l'app est ouverte. Le port se règle dans proxy.json (4000 pour remplacer LiteLLM, une fois celui-ci arrêté).")
            }

            SwiftUI.Section {
                if proxy.config.aliases.isEmpty { Text("Aucun").foregroundStyle(.secondary) }
                ForEach(proxy.config.aliases, id: \.alias) { alias in
                    LabeledContent {
                        switch table.resolve(model: alias.alias, path: "/v1/chat/completions") {
                        case .upstream(let upstream):
                            if let provider = upstream.providerID, !ProviderKeys.hasKey(for: provider) {
                                StatePill(text: "\(upstream.label) · clé absente", color: .orange)
                            } else {
                                StatePill(text: upstream.label, color: .green)
                            }
                        case .subscription(let target): StatePill(text: "\(target.cli.executableName) · abonnement", color: .green)
                        case .notFound: StatePill(text: proxy.table == nil ? "—" : "Cible absente", color: .secondary)
                        }
                    } label: {
                        Text(alias.alias)
                        Text("→ \(alias.model)\(alias.provider.map { " · \($0)" } ?? " · local seulement")").font(.caption.monospaced())
                    }
                }
                Button("Importer depuis une configuration LiteLLM…", action: importLiteLLM)
            } header: {
                Text("Noms stables")
            } footer: {
                Text("Chaque nom vise l'identifiant qu'un moteur sert ; il fonctionne quel que soit le moteur ou le port du moment.")
            }

            SwiftUI.Section("API distantes") {
                if proxy.config.providers.isEmpty { Text("Aucune").foregroundStyle(.secondary) }
                ForEach(proxy.config.providers, id: \.id) { provider in
                    LabeledContent {
                        if let cli = provider.cli {
                            let found = SubscriptionRunner.findExecutable(cli) != nil
                            StatePill(text: found ? "Abonnement · \(cli.executableName)" : "\(cli.executableName) introuvable", color: found ? .green : .orange)
                        } else {
                            HStack {
                                let hasKey = ProviderKeys.hasKey(for: provider.id)
                                StatePill(text: hasKey ? "Clé enregistrée" : "Clé absente", color: hasKey ? .green : .orange)
                                Button(hasKey ? "Remplacer…" : "Ajouter la clé…") { keyFor = provider }
                            }
                        }
                    } label: {
                        Text(provider.name)
                        Text(provider.prefix.map { "\($0)*" } ?? provider.models.joined(separator: ", ")).font(.caption)
                    }
                }
            }

            SwiftUI.Section {
                Button("Synchroniser Pi et DeepSeek Harness", action: synchronize)
                    .disabled(proxy.url == nil)
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            } header: {
                Text("Harness")
            } footer: {
                Text("Inscrit tous les modèles joignables dans Pi et DeepSeek Harness avec l'adresse du point d'entrée (une entrée « llmarium », sauvegarde avant écriture). « Ouvrir dans… » passe aussi par le point d'entrée quand il est actif.")
            }

            SwiftUI.Section("Dernières requêtes") {
                if proxy.recent.isEmpty { Text("Aucune").foregroundStyle(.secondary) }
                ForEach(Array(proxy.recent.prefix(20).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced()).lineLimit(2).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $keyFor) { provider in
            KeySheet(provider: provider)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func setOpenAtLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = "Ouverture à la connexion : \(error.localizedDescription)"
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func importLiteLLM() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "yaml")!, .init(filenameExtension: "yml")!]
        panel.prompt = "Importer"
        guard panel.runModal() == .OK, let url = panel.url, let yaml = try? String(contentsOf: url, encoding: .utf8) else { return }
        let imported = LiteLLMImport.parse(yaml)
        do {
            try LiteLLMImport.merge(imported, into: ProxyConfig.load()).save()
            proxy.reloadConfig()
            message = "\(imported.aliases.count) noms et \(imported.providers.count) API distantes importés." +
                (imported.skipped.isEmpty ? "" : " Ignorés : \(imported.skipped.joined(separator: " ; ")).")
        } catch {
            message = "Import impossible : \(error)"
        }
    }

    private func synchronize() {
        guard let url = proxy.url, let table = proxy.table else { return }
        let models = HarnessSync.catalog(snapshot: snapshot, table: table)
        do {
            let written = try HarnessSync.sync(proxy: url, models: models, installed: model.installedHarnesses)
            message = written.isEmpty ? "Ni Pi ni DeepSeek Harness ne sont installés."
                : "\(models.count) modèles inscrits dans \(written.map { ($0 as NSString).lastPathComponent }.joined(separator: " et ")). Redémarrez DeepSeek Harness s'il était ouvert."
        } catch {
            message = "Synchronisation impossible : \(error)"
        }
    }
}

extension RemoteProvider: Identifiable {}

/// The key is typed here and goes straight to the Keychain; it is never shown again.
struct KeySheet: View {
    var provider: RemoteProvider
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clé \(provider.name)").font(.headline)
            SecureField("Clé d'API", text: $key)
            Text("Enregistrée dans le trousseau de session, lue par le point d'entrée quand il transmet une requête à \(provider.name). Ni affichée, ni écrite dans un fichier.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                if ProviderKeys.hasKey(for: provider.id) {
                    Button("Retirer la clé", role: .destructive) {
                        ProviderKeys.removeKey(for: provider.id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Enregistrer") {
                    do {
                        try ProviderKeys.setKey(key.trimmingCharacters(in: .whitespacesAndNewlines), for: provider.id)
                        key = ""
                        dismiss()
                    } catch {
                        self.error = "\(error)"
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
