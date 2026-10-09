import Darwin
import Foundation

/// Actions that free memory. Each one is asked for explicitly by the user, after a warning, and checks first
/// that the process is still the one the user saw: a PID can be reused by another process in the meantime.
public enum ModelActions {
    public enum StopResult: Equatable, Sendable {
        case stopped
        /// Still alive after the polite request: the user may choose to force it.
        case stillRunning
        /// The PID now belongs to another process, or is gone: nothing was sent.
        case processChanged
        case failed(String)
    }

    public enum UnloadResult: Equatable, Sendable {
        case unloaded
        case authenticationRequired
        case failed(String)
    }

    /// Asks oMLX to release a model. Its server and other models keep running.
    public static func unloadOMLX(model: String, baseURL: String) async -> UnloadResult {
        let escaped = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? model
        guard let url = URL(string: "\(baseURL)/v1/models/\(escaped)/unload") else { return .failed("adresse invalide") }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200: return .unloaded
            case 401, 403: return .authenticationRequired
            case let code:
                let detail = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["detail"] as? String
                return .failed(detail ?? "réponse \(code) d'oMLX")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Asks ComfyUI to unload its models and free memory. It does so once the running job is finished, without interrupting it.
    public static func freeComfyUI(baseURL: String) async -> UnloadResult {
        guard let url = URL(string: baseURL + "/free") else { return .failed("adresse invalide") }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"unload_models": true, "free_memory": true}"#.utf8)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return code == 200 ? .unloaded : .failed("réponse \(code) de ComfyUI")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Sends SIGTERM (or SIGKILL when `force`) and waits for the process to exit.
    public static func stop(pid: Int32, startedAt: Date?, force: Bool = false, timeout: TimeInterval = 10) async -> StopResult {
        guard isSameProcess(pid: pid, startedAt: startedAt) else { return .processChanged }
        guard kill(pid, force ? SIGKILL : SIGTERM) == 0 else {
            return errno == ESRCH ? .stopped : .failed(String(cString: strerror(errno)))
        }
        let deadline = Date().addingTimeInterval(force ? 3 : timeout)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            if !isSameProcess(pid: pid, startedAt: startedAt) { return .stopped }
        }
        return .stillRunning
    }

    /// Same PID and same start time (to the second) as when the user chose it.
    public static func isSameProcess(pid: Int32, startedAt: Date?) -> Bool {
        guard let current = ProcessScanner.bsdInfo(of: pid) else { return false }
        guard let startedAt else { return true }
        return abs(current.startedAt.timeIntervalSince(startedAt)) < 1
    }
}

extension RunningModel {
    /// Stopping the process of an engine app (oMLX) would quit the engine: models are unloaded instead.
    public var canUnloadInEngine: Bool { role == .omlx || comfyUI != nil }
    public var canStopProcess: Bool { role != .omlx }

    /// What the user should know before stopping or unloading, in French, one point per line.
    public var stopWarnings: [String] {
        var warnings: [String] = []
        if !clients.isEmpty {
            warnings.append("Connecté en ce moment : \(clients.map(\.title).joined(separator: ", ")). Ses requêtes en cours échoueront.")
        } else {
            warnings.append("Aucun client connecté à cet instant, mais une app peut l'appeler par intermittence.")
        }
        if launcher.isOrphan {
            warnings.append("Son lanceur n'est plus actif : rien ne le relancera.")
        } else if launcher.certainty == .certain, !launcher.steps.isEmpty {
            warnings.append("Lancé par \(launcher.summary), qui peut le relancer s'il le surveille.")
        }
        if role == .omlx {
            warnings.append("oMLX interrompt les requêtes en cours sur ce modèle ; il le rechargera à la prochaine demande.")
        }
        if let comfyUI, comfyUI.runningJobs > 0 {
            warnings.append("ComfyUI a une génération en cours\(comfyUI.pendingJobs > 0 ? " et \(comfyUI.pendingJobs) en attente" : "") : l'arrêt du processus l'interromprait, alors que « Libérer la mémoire » attend sa fin.")
        }
        return warnings
    }
}
