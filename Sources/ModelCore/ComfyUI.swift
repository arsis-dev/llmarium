import Foundation

/// What a ComfyUI server says about its work: its API names the model files of each job, not the process.
public struct ComfyUIState: Codable, Hashable, Sendable {
    public var version: String?
    public var runningJobs: Int
    public var pendingJobs: Int
    /// Model files loaded by the running and pending jobs, or by the last finished one.
    public var models: [String]
    /// The models come from the last finished job: ComfyUI may still keep them cached in memory.
    public var modelsFromHistory: Bool

    public var activity: String {
        switch (runningJobs, pendingJobs) {
        case (0, 0): "Inactif"
        case (_, 0): "Génération en cours"
        default: "Génération en cours · \(pendingJobs) en attente"
        }
    }
}

public enum ComfyUIProbe {
    /// Read-only calls: `/system_stats`, `/queue` and the last `/history` entry.
    public static func probe(port: Int) async -> ComfyUIState? {
        let base = "http://127.0.0.1:\(port)"
        guard let stats = await json(base + "/system_stats"),
              let system = stats["system"] as? [String: Any], system["comfyui_version"] != nil || system["python_version"] != nil,
              stats["devices"] != nil else { return nil }
        var state = ComfyUIState(version: system["comfyui_version"] as? String, runningJobs: 0, pendingJobs: 0, models: [], modelsFromHistory: false)
        if let queue = await json(base + "/queue") {
            let running = queue["queue_running"] as? [[Any]] ?? []
            let pending = queue["queue_pending"] as? [[Any]] ?? []
            state.runningJobs = running.count
            state.pendingJobs = pending.count
            state.models = unique((running + pending).flatMap { job in job.count > 2 ? modelFiles(in: job[2]) : [] })
        }
        if state.models.isEmpty, let history = await json(base + "/history?max_items=1"),
           let last = history.values.first as? [String: Any], let prompt = last["prompt"] as? [Any], prompt.count > 2 {
            state.models = modelFiles(in: prompt[2])
            state.modelsFromHistory = !state.models.isEmpty
        }
        return state
    }

    /// Model files named by loader nodes of an API-format workflow (`{"id": {"class_type", "inputs"}}`).
    static func modelFiles(in workflow: Any) -> [String] {
        guard let nodes = workflow as? [String: Any] else { return [] }
        let extensions = [".safetensors", ".gguf", ".ckpt", ".pt", ".pth", ".bin", ".sft"]
        let files = nodes.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.flatMap { key -> [String] in
            guard let node = nodes[key] as? [String: Any], let inputs = node["inputs"] as? [String: Any] else { return [] }
            return inputs.keys.sorted().compactMap { name in
                guard let value = inputs[name] as? String, extensions.contains(where: { value.lowercased().hasSuffix($0) }) else { return nil }
                return (value as NSString).lastPathComponent
            }
        }
        return unique(files)
    }

    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    static func json(_ address: String) async -> [String: Any]? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.setValue("close", forHTTPHeaderField: "Connection")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
