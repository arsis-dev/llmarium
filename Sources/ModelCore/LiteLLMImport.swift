import Foundation

/// Reads the `model_list` of a LiteLLM config to keep its names: local entries become aliases to the id the engine
/// serves, cloud entries become remote providers. `api_key` lines are never read; keys go to the Keychain separately.
public enum LiteLLMImport {
    public struct Result: Sendable {
        public var aliases: [ProxyAlias]
        public var providers: [RemoteProvider]
        public var skipped: [String]
    }

    /// Providers LiteLLM knows by prefix, with their public endpoints.
    static let knownProviders: [String: RemoteProvider] = [
        "deepseek": RemoteProvider(id: "deepseek", name: "DeepSeek", openAIBase: "https://api.deepseek.com/v1",
                                   anthropicBase: "https://api.deepseek.com/anthropic", models: [])
    ]

    public static func parse(_ yaml: String) -> Result {
        struct Entry { var name: String; var model: String?; var apiBase: String? }
        var entries: [Entry] = []
        for raw in yaml.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }
            if line.hasPrefix("- model_name:") {
                entries.append(Entry(name: value(of: line, after: "- model_name:")))
            } else if line.hasPrefix("model:"), entries.last?.model == nil {
                entries[entries.count - 1].model = value(of: line, after: "model:")
            } else if line.hasPrefix("api_base:"), entries.last?.apiBase == nil {
                entries[entries.count - 1].apiBase = value(of: line, after: "api_base:")
            }
        }

        var result = Result(aliases: [], providers: [], skipped: [])
        func provider(_ id: String, _ make: () -> RemoteProvider) -> Int {
            if let index = result.providers.firstIndex(where: { $0.id == id }) { return index }
            result.providers.append(make())
            return result.providers.count - 1
        }
        for entry in entries {
            guard let model = entry.model, let slash = model.firstIndex(of: "/") else {
                result.skipped.append("\(entry.name) : modèle non précisé")
                continue
            }
            let kind = String(model[..<slash])
            let upstream = String(model[model.index(after: slash)...])
            let base = entry.apiBase.flatMap(URL.init(string:))
            let isLocal = base.map { ["host.docker.internal", "localhost", "127.0.0.1"].contains($0.host ?? "") } ?? false
            if kind == "openai", isLocal {
                result.aliases.append(ProxyAlias(alias: entry.name, model: upstream))
            } else if kind == "openai", upstream == "*", let base, let host = base.host, entry.name.hasSuffix("*") {
                // `cline/*` → every `cline/<id>` goes to that endpoint as `<id>`.
                let id = host.split(separator: ".").dropLast().last.map(String.init) ?? host
                _ = provider(id) {
                    RemoteProvider(id: id, name: id.capitalized, openAIBase: base.absoluteString, anthropicBase: nil, models: [],
                                   prefix: String(entry.name.dropLast()))
                }
            } else if let known = knownProviders[kind] {
                let index = provider(kind) { known }
                if !result.providers[index].models.contains(upstream) { result.providers[index].models.append(upstream) }
                if entry.name != upstream { result.aliases.append(ProxyAlias(alias: entry.name, model: upstream, provider: kind)) }
            } else {
                result.skipped.append("\(entry.name) : fournisseur « \(kind) » non pris en charge")
            }
        }
        return result
    }

    /// Adds the imported names to a configuration, replacing aliases and merging providers that already exist.
    public static func merge(_ result: Result, into config: ProxyConfig) -> ProxyConfig {
        var merged = config
        for alias in result.aliases {
            merged.aliases.removeAll { $0.alias == alias.alias }
            merged.aliases.append(alias)
        }
        for provider in result.providers {
            if let index = merged.providers.firstIndex(where: { $0.id == provider.id }) {
                for model in provider.models where !merged.providers[index].models.contains(model) {
                    merged.providers[index].models.append(model)
                }
            } else {
                merged.providers.append(provider)
            }
        }
        return merged
    }

    static func value(of line: String, after prefix: String) -> String {
        var value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        if let comment = value.range(of: " #") { value = String(value[..<comment.lowerBound]) }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }
}
