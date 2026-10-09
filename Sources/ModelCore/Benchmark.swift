import Foundation

public struct BenchmarkRun: Codable, Hashable, Sendable {
    public var kind: String
    public var promptTokens: Int?
    public var completionTokens: Int?
    /// Usage was not reported: counts estimated from characters (4 per token).
    public var tokensEstimated: Bool
    public var timeToFirstToken: Double?
    public var prefillTokensPerSecond: Double?
    public var decodeTokensPerSecond: Double?
    public var totalSeconds: Double
    /// The engine streamed reasoning although it was asked not to.
    public var reasoningObserved: Bool
    public var succeeded: Bool
    public var note: String?

    public var title: String {
        switch kind {
        case "court": "Consigne courte"
        case "long": "Contexte long (≈ 13K tokens)"
        case "outil": "Appel d'outil"
        default: kind
        }
    }
}

/// One measurement of one model on one engine, with what is needed to compare it later.
public struct BenchmarkResult: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var date: Date
    public var engine: EngineKind
    public var engineVersion: String?
    public var model: String
    public var machine: String
    public var context: Int?
    public var recipeID: String?
    /// For oMLX the process holds every loaded model: its peak covers them all.
    public var peakMemoryBytes: Int64?
    public var loadSeconds: Int?
    public var runs: [BenchmarkRun]
    /// What else used the engine or the Mac during the measure; non-empty means the numbers are not representative.
    public var conditions: [String] = []

    public var disturbed: Bool { !conditions.isEmpty }

    public var decodeTokensPerSecond: Double? { runs.first { $0.kind == "court" }?.decodeTokensPerSecond }
    public var prefillTokensPerSecond: Double? { runs.first { $0.kind == "long" }?.prefillTokensPerSecond }
    public var timeToFirstToken: Double? { runs.first { $0.kind == "court" }?.timeToFirstToken }
    public var toolCallSucceeded: Bool? { runs.first { $0.kind == "outil" }?.succeeded }
    public var longContextSucceeded: Bool? { runs.first { $0.kind == "long" }?.succeeded }
    public var reasoningObserved: Bool { runs.contains { $0.reasoningObserved } }
}

public final class BenchmarkStore: @unchecked Sendable {
    public static let shared = BenchmarkStore(file: AppPaths.support.appending(path: "benchmarks.json"))

    private let file: URL
    private let lock = NSLock()

    public init(file: URL) { self.file = file }

    public func all() -> [BenchmarkResult] { lock.withLock { read() }.sorted { $0.date > $1.date } }

    public func add(_ result: BenchmarkResult) throws {
        try lock.withLock {
            var results = read()
            results.append(result)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(results).write(to: file, options: .atomic)
        }
    }

    private func read() -> [BenchmarkResult] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([BenchmarkResult].self, from: data)) ?? []
    }
}

public enum Benchmark {
    /// Fixed, synthetic prompts: nothing the user typed is sent or stored.
    struct Prompt {
        var kind: String
        var body: [String: Any]
        var check: (StreamOutcome) -> (Bool, String?)
    }

    struct StreamOutcome {
        var text = ""
        var reasoning = ""
        var toolArguments = ""
        var toolName: String?
        var finishReason: String?
        var promptTokens: Int?
        var completionTokens: Int?
        var firstDelta: Date?
        var lastDelta: Date?
        var deltaCount = 0
        var error: String?
    }

    public static func run(baseURL: String, model: String, engine: EngineKind, engineVersion: String?, machine: MachineInfo,
                           pid: Int32?, context: Int?, recipeID: String?, loadSeconds: Int? = nil, otherClients: [String] = [],
                           omlxURL: String? = nil,
                           progress: @escaping @Sendable (String) -> Void = { _ in }) async -> BenchmarkResult {
        // oMLX reports its active requests. On oMLX, anything beyond ours means another client shared the model;
        // on another engine, any oMLX request shared the GPU.
        let statusURL = engine == .omlx ? baseURL : omlxURL
        let concurrency = statusURL.map { statusURL in Task.detached { () -> Int in
            var highest = 0
            while !Task.isCancelled {
                if let status = await EngineDetector.fetch(statusURL + "/api/status"),
                   let root = (try? JSONSerialization.jsonObject(with: status)) as? [String: Any] {
                    let active = ((root["active_requests"] as? NSNumber)?.intValue ?? 0) + ((root["waiting_requests"] as? NSNumber)?.intValue ?? 0)
                    highest = max(highest, active)
                }
                try? await Task.sleep(for: .seconds(1))
            }
            return highest
        } }
        var peak: Int64 = 0
        let sampler = pid.map { pid in
            Task.detached { () -> Int64 in
                var highest: Int64 = 0
                while !Task.isCancelled {
                    if let footprint = ProcessScanner.footprint(of: pid) { highest = max(highest, footprint) }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                return highest
            }
        }
        progress("Échauffement")
        _ = await stream(baseURL: baseURL, body: request(model: model, messages: [["role": "user", "content": "Bonjour."]], maxTokens: 8))
        var runs: [BenchmarkRun] = []
        for prompt in prompts(model: model) {
            progress(BenchmarkRun(kind: prompt.kind, tokensEstimated: false, totalSeconds: 0, reasoningObserved: false, succeeded: false).title)
            let start = Date()
            let outcome = await stream(baseURL: baseURL, body: prompt.body)
            let total = Date().timeIntervalSince(start)
            var run = BenchmarkRun(kind: prompt.kind, tokensEstimated: false, totalSeconds: total,
                                   reasoningObserved: !outcome.reasoning.isEmpty, succeeded: false)
            if let error = outcome.error {
                run.note = error
                runs.append(run)
                continue
            }
            (run.succeeded, run.note) = prompt.check(outcome)
            let generated = outcome.text + outcome.reasoning + outcome.toolArguments
            run.promptTokens = outcome.promptTokens
            run.completionTokens = outcome.completionTokens
            if outcome.completionTokens == nil {
                run.tokensEstimated = true
                run.completionTokens = max(1, generated.count / 4)
                run.promptTokens = estimatedPromptTokens(prompt.body)
            }
            if let first = outcome.firstDelta {
                let ttft = first.timeIntervalSince(start)
                run.timeToFirstToken = ttft
                if let prompted = run.promptTokens, ttft > 0 { run.prefillTokensPerSecond = Double(prompted) / ttft }
                // A speed needs a stream: tool arguments often arrive in one piece.
                if let last = outcome.lastDelta, let completed = run.completionTokens, completed > 1,
                   outcome.deltaCount >= 4, last.timeIntervalSince(first) >= 0.2 {
                    run.decodeTokensPerSecond = Double(completed - 1) / last.timeIntervalSince(first)
                }
            }
            runs.append(run)
        }
        sampler?.cancel()
        if let sampler { peak = await sampler.value }
        concurrency?.cancel()
        var conditions: [String] = []
        let ours = engine == .omlx ? 1 : 0
        if let concurrency, case let highest = await concurrency.value, highest > ours {
            conditions.append(engine == .omlx ? "Jusqu'à \(highest - ours) requête(s) d'autres clients en même temps sur oMLX"
                                              : "oMLX traitait \(highest) requête(s) en même temps (GPU partagé)")
        }
        if !otherClients.isEmpty { conditions.append("Autres clients connectés au moteur : \(otherClients.joined(separator: ", "))") }
        return BenchmarkResult(id: UUID().uuidString, date: Date(), engine: engine, engineVersion: engineVersion, model: model,
                               machine: "\(machine.chip) · \(Format.memory(machine.memoryBytes))", context: context, recipeID: recipeID,
                               peakMemoryBytes: peak > 0 ? peak : nil, loadSeconds: loadSeconds, runs: runs, conditions: conditions)
    }

    static func request(model: String, messages: [[String: Any]], maxTokens: Int, tools: [[String: Any]]? = nil) -> [String: Any] {
        var body: [String: Any] = ["model": model, "messages": messages, "max_tokens": maxTokens, "stream": true, "temperature": 0,
                                   "stream_options": ["include_usage": true],
                                   // Honoured by oMLX; MTPLX decides at launch (`--reasoning`), which the result records.
                                   "chat_template_kwargs": ["enable_thinking": false]]
        if let tools { body["tools"] = tools }
        return body
    }

    static func prompts(model: String) -> [Prompt] {
        let code = String(UUID().uuidString.prefix(8))
        // A fresh header defeats prefix caches: the long prompt is really read each time.
        var paragraphs = ["Session \(UUID().uuidString). Lis attentivement le texte suivant."]
        for index in 1...300 {
            paragraphs.append("Paragraphe \(index) : l'inventaire du rayon \(index % 17) compte \(index * 7 % 101) boîtes, rangées par ordre d'arrivée et vérifiées chaque semaine par l'équipe du matin.")
            if index == 280 { paragraphs.append("Note importante : le code de vérification est \(code).") }
        }
        let long = paragraphs.joined(separator: "\n")
        let tool: [String: Any] = ["type": "function", "function": [
            "name": "meteo", "description": "Donne la météo actuelle d'une ville.",
            "parameters": ["type": "object", "properties": ["ville": ["type": "string"]], "required": ["ville"]]
        ]]
        return [
            Prompt(kind: "court", body: request(model: model, messages: [["role": "user", "content": "Décris en quelques phrases comment fonctionne une bibliothèque municipale."]], maxTokens: 128)) { outcome in
                (!(outcome.text + outcome.reasoning).isEmpty, nil)
            },
            Prompt(kind: "long", body: request(model: model, messages: [["role": "user", "content": long + "\n\nQuel est le code de vérification mentionné dans le texte ? Réponds uniquement par ce code."]], maxTokens: 48)) { outcome in
                outcome.text.contains(code) ? (true, nil) : (false, "Code non retrouvé dans la réponse")
            },
            Prompt(kind: "outil", body: request(model: model, messages: [["role": "user", "content": "Quel temps fait-il à Lyon ? Utilise l'outil prévu."]], maxTokens: 256, tools: [tool])) { outcome in
                guard outcome.toolName == "meteo" else { return (false, "Pas d'appel d'outil") }
                let arguments = (try? JSONSerialization.jsonObject(with: Data(outcome.toolArguments.utf8))) as? [String: Any]
                return arguments?["ville"] != nil ? (true, nil) : (false, "Arguments illisibles : \(outcome.toolArguments.prefix(80))")
            }
        ]
    }

    static func estimatedPromptTokens(_ body: [String: Any]) -> Int {
        let messages = body["messages"] as? [[String: Any]] ?? []
        return max(1, messages.compactMap { $0["content"] as? String }.joined().count / 4)
    }

    /// Streams one chat completion and records when deltas arrive. Retries once without `stream_options`
    /// for an engine that refuses it.
    static func stream(baseURL: String, body: [String: Any]) async -> StreamOutcome {
        var outcome = await attempt(baseURL: baseURL, body: body)
        if outcome.error?.contains("400") == true {
            var plain = body
            plain["stream_options"] = nil
            outcome = await attempt(baseURL: baseURL, body: plain)
        }
        return outcome
    }

    static func attempt(baseURL: String, body: [String: Any]) async -> StreamOutcome {
        var outcome = StreamOutcome()
        guard let url = URL(string: baseURL + "/v1/chat/completions"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { outcome.error = "requête invalide"; return outcome }
        var request = URLRequest(url: url, timeoutInterval: 900)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                var detail = ""
                for try await line in bytes.lines { detail += line; if detail.count > 300 { break } }
                outcome.error = "réponse \(status) : \(detail.prefix(200))"
                return outcome
            }
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let chunk = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
                if let usage = chunk["usage"] as? [String: Any] {
                    outcome.promptTokens = (usage["prompt_tokens"] as? NSNumber)?.intValue ?? outcome.promptTokens
                    outcome.completionTokens = (usage["completion_tokens"] as? NSNumber)?.intValue ?? outcome.completionTokens
                }
                guard let choice = (chunk["choices"] as? [[String: Any]])?.first else { continue }
                if let reason = choice["finish_reason"] as? String { outcome.finishReason = reason }
                guard let delta = choice["delta"] as? [String: Any] else { continue }
                var produced = false
                if let content = delta["content"] as? String, !content.isEmpty { outcome.text += content; produced = true }
                if let reasoning = (delta["reasoning_content"] ?? delta["reasoning"]) as? String, !reasoning.isEmpty {
                    outcome.reasoning += reasoning
                    produced = true
                }
                for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                    let function = call["function"] as? [String: Any]
                    if let name = function?["name"] as? String, !name.isEmpty { outcome.toolName = name }
                    if let arguments = function?["arguments"] as? String { outcome.toolArguments += arguments }
                    produced = true
                }
                if produced {
                    outcome.deltaCount += 1
                    let now = Date()
                    if outcome.firstDelta == nil { outcome.firstDelta = now }
                    outcome.lastDelta = now
                }
            }
        } catch {
            outcome.error = error.localizedDescription
        }
        return outcome
    }
}

/// Best results the oMLX community published for this chip and model on omlx.ai: a reference, measured with
/// their own protocol (4K context). Only chip, memory and model name are sent; answers are kept an hour.
public struct CommunityBenchmark: Codable, Hashable, Sendable {
    public var id: String
    public var url: String
    public var prefillTokensPerSecond: Double?
    public var decodeTokensPerSecond: Double?
    public var quantization: String?
    public var omlxVersion: String?
    public var contextProfile: String?
    public var memoryGB: Int?
    public var gpuCores: Int?
    public var settings: [String]
}

public actor CommunityBenchmarks {
    public static let shared = CommunityBenchmarks()
    private var cache: [String: (date: Date, results: [CommunityBenchmark])] = [:]

    public func best(model: String, machine: MachineInfo) async -> [CommunityBenchmark] {
        if let cached = cache[model], Date().timeIntervalSince(cached.date) < 3600 { return cached.results }
        let chip = machine.chip.firstMatch(of: #/M(\d+)\s*(Pro|Max|Ultra)?/#)
        let name = chip.map { "M\($0.1)" } ?? "M1"
        let variant = chip?.2.map(String.init) ?? ""
        var components = URLComponents(string: "https://omlx.ai/api/benchmarks/best")!
        components.queryItems = [
            URLQueryItem(name: "chip", value: name), URLQueryItem(name: "variant", value: variant),
            URLQueryItem(name: "memory_gb", value: String(Int((Double(machine.memoryBytes) / Double(1 << 30)).rounded()))),
            URLQueryItem(name: "model", value: String(model.split(separator: "/").last ?? Substring(model))),
            URLQueryItem(name: "context", value: "4096"), URLQueryItem(name: "limit", value: "3"), URLQueryItem(name: "sort", value: "tg")
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let results = (root["results"] as? [[String: Any]] ?? []).compactMap { row -> CommunityBenchmark? in
            guard let id = row["id"] as? String else { return nil }
            return CommunityBenchmark(id: id, url: row["url"] as? String ?? "https://omlx.ai/benchmarks/performance/\(id)",
                                      prefillTokensPerSecond: (row["pp_tps"] as? NSNumber)?.doubleValue,
                                      decodeTokensPerSecond: (row["tg_tps"] as? NSNumber)?.doubleValue,
                                      quantization: row["quantization"] as? String, omlxVersion: row["omlx_version"] as? String,
                                      contextProfile: row["context_profile"] as? String, memoryGB: (row["memory_gb"] as? NSNumber)?.intValue,
                                      gpuCores: (row["gpu_cores"] as? NSNumber)?.intValue,
                                      settings: ((row["model_settings"] as? [String: Any]) ?? [:]).keys.sorted())
        }
        cache[model] = (Date(), results)
        return results
    }
}
