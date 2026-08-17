import Foundation
import Observation

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    var role: Role
    var text: String
}

/// Chat mínimo para probar el modelo. Vive en el App (no en el panel) para que
/// la conversación sobreviva a abrir/cerrar el MenuBarExtra.
@Observable
@MainActor
final class ChatModel {
    var messages: [ChatMessage] = []
    var input = ""
    var isGenerating = false
    var error: String?

    private var task: Task<Void, Never>?
    private let endpoint = URL(string: "http://127.0.0.1:8080/v1/chat/completions")!
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30 // el TTFT puede tardar (prefill largo)
        cfg.timeoutIntervalForResource = 600
        session = URLSession(configuration: cfg)
    }

    func send(modelName: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        input = ""
        error = nil
        messages.append(.init(role: .user, text: text))
        messages.append(.init(role: .assistant, text: ""))
        isGenerating = true
        task = Task { await stream(modelName: modelName) }
    }

    func cancel() {
        task?.cancel()
        isGenerating = false
    }

    func clear() {
        cancel()
        messages.removeAll()
        error = nil
    }

    private func stream(modelName: String) async {
        defer { isGenerating = false }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // El placeholder vacío del asistente (último) no forma parte del historial.
        let history = messages.dropLast().map {
            ["role": $0.role == .user ? "user" : "assistant", "content": $0.text]
        }
        let body: [String: Any] = [
            "model": modelName,
            "messages": Array(history),
            "max_tokens": 1024,
            "stream": true,
            // Chat de prueba: respuesta directa, sin gastar tokens en razonar.
            "enable_thinking": false,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (bytes, resp) = try await session.bytes(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                fail("El servidor devolvió \((resp as? HTTPURLResponse)?.statusCode ?? 0).")
                return
            }
            for try await line in bytes.lines {
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))
                if payload == "[DONE]" { break }
                guard let d = payload.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let choices = obj["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any],
                      let piece = delta["content"] as? String
                else { continue }
                if !messages.isEmpty {
                    messages[messages.count - 1].text += piece
                }
            }
        } catch {
            // Cancelación pedida por el usuario: se conserva lo ya generado.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
            let refused = (error as? URLError)?.code == .cannotConnectToHost
            fail(refused ? "El servidor está parado." : error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        error = message
        if messages.last?.role == .assistant, messages.last?.text.isEmpty == true {
            messages.removeLast()
        }
    }
}
