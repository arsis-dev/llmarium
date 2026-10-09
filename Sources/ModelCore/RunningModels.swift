import Foundation

public struct ClientProcess: Codable, Hashable, Sendable {
    public var pid: Int32
    public var title: String
}

/// A process that holds a model in memory right now: an engine server with a model, or a model server started outside the engines.
public struct RunningModel: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "pid-\(pid)" }
    public var pid: Int32
    public var role: ProcessRole
    /// Loaded or served models; empty when the process does not say.
    public var models: [String]
    public var processDescription: String
    public var ports: [Int]
    public var footprintBytes: Int64
    public var startedAt: Date?
    public var launcher: LaunchAttribution
    /// Set when the process is a ComfyUI server: its jobs name the models it uses.
    public var comfyUI: ComfyUIState?
    /// Local processes connected to its ports at this moment. Clients that call it now and then may not show.
    public var clients: [ClientProcess]

    public var title: String {
        if comfyUI != nil { return processDescription }
        return models.isEmpty ? processDescription : models.joined(separator: ", ")
    }

    public var baseURL: String? { ports.first.map { "http://127.0.0.1:\($0)" } }
}

public enum RunningModelDetector {
    public static func detect(processes: [RunningProcess], engines: [EngineStatus], ports: PortTable,
                              comfyUI: [Int32: ComfyUIState] = [:], attributor: LaunchAttributor? = nil) -> [RunningModel] {
        let attributor = attributor ?? LaunchAttributor(processes: processes)
        let table = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var running: [RunningModel] = []

        for engine in engines {
            for instance in engine.instances {
                let models = engine.omlx.map { $0.models.filter { $0.loaded || $0.isLoading }.map(\.id) } ?? instance.servedModels
                // An idle oMLX holds no model; MTPLX and mlx-serve servers always hold the one they serve.
                if engine.kind == .omlx && models.isEmpty { continue }
                guard let process = table[instance.pid] else { continue }
                running.append(model(process, role: engine.kind == .omlx ? .omlx : engine.kind == .mtplx ? .mtplx : .mlxServe,
                                     models: models, description: engine.kind.title, ports: instance.ports,
                                     table: table, portTable: ports, attributor: attributor))
            }
        }
        for process in processes where process.role == .modelWorker {
            let comfy = comfyUI[process.pid]
            var entry = model(process, role: .modelWorker,
                              models: comfy?.models ?? process.modelHint.map { [$0] } ?? [],
                              description: comfy.map { "ComfyUI\($0.version.map { " \($0)" } ?? "")" } ?? process.workerDescription,
                              ports: ports.listening[process.pid] ?? [], table: table, portTable: ports, attributor: attributor)
            entry.comfyUI = comfy
            running.append(entry)
        }
        return running.sorted { $0.footprintBytes > $1.footprintBytes }
    }

    static func model(_ process: RunningProcess, role: ProcessRole, models: [String], description: String, ports: [Int],
                      table: [Int32: RunningProcess], portTable: PortTable, attributor: LaunchAttributor) -> RunningModel {
        // The app that owns a server (oMLX.app polling its own server) is not a client.
        let owners = [process.pid, process.parentPID, process.responsiblePID ?? process.pid, ProcessInfo.processInfo.processIdentifier]
        let clientPIDs = Set(ports.flatMap { portTable.clients[$0] ?? [] }).subtracting(owners)
        let clients = clientPIDs.sorted().map { pid in
            // Name agents by what they are (`node …/pi` is Pi), as the launcher chain does.
            ClientProcess(pid: pid, title: table[pid].map { attributor.step(for: $0)?.title ?? $0.appName ?? $0.name } ?? "PID \(pid)")
        }
        return RunningModel(pid: process.pid, role: role, models: models, processDescription: description, ports: ports,
                            footprintBytes: process.footprintBytes, startedAt: process.startedAt,
                            launcher: attributor.attribute(process), clients: clients)
    }
}

extension RunningProcess {
    /// The model a worker loads, read from its arguments: a cache or store path, a `.gguf` file or a `--model` value.
    public var modelHint: String? {
        if let cached = arguments.lazy.compactMap(Self.cachedModelName).first { return cached }
        for argument in arguments {
            for marker in ["/.omlx/models/", "/.mlx-serve/models/", "/.mtplx/models/"] {
                if let range = argument.range(of: marker) {
                    return String(argument[range.upperBound...]).replacingOccurrences(of: "--", with: "/")
                }
            }
            if argument.hasSuffix(".gguf") { return (argument as NSString).lastPathComponent }
        }
        if let flag = arguments.firstIndex(where: { ["--model", "-m", "--model-path"].contains($0) }), flag + 1 < arguments.count,
           !arguments[flag + 1].hasPrefix("-"), arguments[flag + 1] != "mtplx.server.openai" {
            return arguments[flag + 1]
        }
        return nil
    }
}
