import Foundation

struct GenericChatProvider: ChatProvider {
    let id = "compatible"
    let name = "Compatible endpoint"
    var endpoint: String
    var apiKey: String?

    var zeroResponseMessage: String { "The endpoint didn’t return a reply." }

    func stream(
        messages: [TalkMessage],
        model: String,
        options: ChatTurnOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let endpoint = endpoint
        let apiKey = apiKey
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !model.isEmpty else {
                        throw ChatGPTAuthError("Enter a model ID for this endpoint.")
                    }
                    guard let url = GenericChatProvider.requestURL(from: endpoint) else {
                        throw ChatGPTAuthError("Enter a valid endpoint URL.")
                    }
                    let body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "messages": messages.map { GenericChatProvider.completionsMessage($0, options: options) }
                    ]
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if let apiKey, !apiKey.isEmpty {
                        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        throw ChatGPTAuthError("The endpoint returned \(http.statusCode).")
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let raw = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if raw == "[DONE]" { break }
                        guard let data = raw.data(using: .utf8),
                              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = object["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let text = delta["content"] as? String,
                              !text.isEmpty
                        else { continue }
                        continuation.yield(.text(text))
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func requestURL(from endpoint: String) -> URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasSuffix("/chat/completions") { return URL(string: trimmed) }
        if trimmed.hasSuffix("/v1") { return URL(string: trimmed + "/chat/completions") }
        return URL(string: trimmed + "/v1/chat/completions")
    }

    static func completionsMessage(_ message: TalkMessage, options: ChatTurnOptions) -> [String: Any] {
        [
            "role": message.role == .assistant ? "assistant" : "user",
            "content": completionsContent(message, options: options)
        ]
    }

    static func completionsContent(_ message: TalkMessage, options: ChatTurnOptions) -> Any {
        guard message.role != .assistant, !message.attachments.isEmpty else {
            return message.text
        }
        var parts: [[String: Any]] = []
        if !message.text.isEmpty {
            parts.append(["type": "text", "text": message.text])
        }
        for attachment in message.attachments {
            guard let prepared = options.payload(for: attachment.id) else {
                parts.append(["type": "text", "text": "Attachment \(attachment.filename) is missing and was not sent."])
                continue
            }
            switch prepared.route {
            case .nativeImage:
                let encoded = prepared.data.base64EncodedString()
                parts.append([
                    "type": "image_url",
                    "image_url": ["url": "data:\(prepared.ref.mimeType);base64,\(encoded)"]
                ])
            case .nativeFile:
                let encoded = prepared.data.base64EncodedString()
                parts.append([
                    "type": "file",
                    "file": [
                        "filename": prepared.ref.filename,
                        "file_data": "data:\(prepared.ref.mimeType);base64,\(encoded)"
                    ]
                ])
            case .extracted(let extracted):
                parts.append([
                    "type": "text",
                    "text": "Attached file: \(extracted.filename)\n\(extracted.text)"
                ])
            }
        }
        return parts.isEmpty ? message.text : parts
    }

    static func fetchOpenRouterModels(endpoint: String, apiKey: String?) async throws -> [OpenRouterModel] {
        guard let url = modelsURL(from: endpoint) else {
            throw ChatGPTAuthError("Enter a valid endpoint URL.")
        }
        var request = URLRequest(url: url)
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ChatGPTAuthError("Couldn’t list models (\(http.statusCode)).")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let name = row["name"] as? String ?? id
            let architecture = row["architecture"] as? [String: Any]
            let modalities = architecture?["input_modalities"] as? [String] ?? []
            return OpenRouterModel(
                id: id,
                name: name,
                image: modalities.contains("image"),
                file: modalities.contains("file")
            )
        }
    }

    private static func modelsURL(from endpoint: String) -> URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.hasSuffix("/models") { return URL(string: trimmed) }
        if trimmed.hasSuffix("/v1") { return URL(string: trimmed + "/models") }
        return URL(string: trimmed + "/v1/models")
    }
}

struct OpenRouterModel: Equatable, Sendable {
    var id: String
    var name: String
    var image: Bool
    var file: Bool
}
