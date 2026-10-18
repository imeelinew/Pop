import Foundation

struct TranslationClient: Sendable {
    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { var content: String? }
            var delta: Delta
            var finish_reason: String?
        }
        struct APIError: Decodable { var message: String }
        var choices: [Choice]?
        var error: APIError?
    }

    func translate(_ text: String, configuration: Configuration.LLM,
                   onDelta: @MainActor @Sendable (String) -> Void) async throws {
        guard !configuration.api_key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PopError.message("Add your API key to config.toml.")
        }
        guard let baseURL = URL(string: configuration.base_url) else { throw PopError.message("Invalid API URL.") }
        let url = baseURL.appending(path: "chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout_seconds
        request.setValue("Bearer \(configuration.api_key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        var body = try JSONSerialization.jsonObject(with: Data(configuration.extra_body.utf8)) as! [String: Any]
        body["model"] = configuration.model
        body["stream"] = true
        body["messages"] = [
            ["role": "system", "content": configuration.system_prompt],
            ["role": "user", "content": text]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = configuration.timeout_seconds
        sessionConfiguration.timeoutIntervalForResource = configuration.timeout_seconds
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw PopError.message("Invalid API response.") }
        guard (200..<300).contains(http.statusCode) else {
            // Do not surface provider bodies, which may echo credentials or input text.
            switch http.statusCode {
            case 401, 403: throw PopError.message("API key rejected (\(http.statusCode)).")
            case 402: throw PopError.message("API balance insufficient (402).")
            case 429: throw PopError.message("API rate limit reached (429).")
            default: throw PopError.message("API request failed (\(http.statusCode)).")
            }
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
            throw PopError.message("API did not return a streaming response.")
        }
        var eventData: [String] = []
        var hasContent = false
        var finished = false
        let decoder = JSONDecoder()

        func consume(_ data: String) async throws -> Bool {
            if data.trimmingCharacters(in: .whitespaces) == "[DONE]" { return true }
            let chunk = try decoder.decode(Chunk.self, from: Data(data.utf8))
            if chunk.error != nil { throw PopError.message("The API reported a streaming error.") }
            if let choice = chunk.choices?.first {
                if let content = choice.delta.content, !content.isEmpty {
                    hasContent = true
                    await onDelta(content)
                }
                if let reason = choice.finish_reason {
                    if reason == "length" { throw PopError.message("Output limit reached. Translation is incomplete.") }
                    if reason != "stop" { throw PopError.message("Translation stopped by the provider.") }
                    finished = true
                }
            }
            return false
        }

        // AsyncBytes.lines omits empty lines, but SSE uses them as event boundaries.
        // Decode raw UTF-8 only after a whole line arrives, preserving multibyte text.
        var lineBytes: [UInt8] = []
        var previousWasCR = false
        var done = false
        for try await byte in bytes {
            try Task.checkCancellation()
            if byte == 10 && previousWasCR {
                previousWasCR = false
                continue
            }
            previousWasCR = byte == 13
            if byte == 10 || byte == 13 {
                let line = String(decoding: lineBytes, as: UTF8.self)
                lineBytes.removeAll(keepingCapacity: true)
                if line.isEmpty {
                    if !eventData.isEmpty {
                        done = try await consume(eventData.joined(separator: "\n"))
                        eventData.removeAll(keepingCapacity: true)
                        if done { finished = true; break }
                    }
                } else if line.hasPrefix("data:") {
                    let value = line.dropFirst(5)
                    eventData.append(String(value.first == " " ? value.dropFirst() : value))
                }
            } else {
                lineBytes.append(byte)
                guard lineBytes.count < 1_048_576 else { throw PopError.message("API stream event is too large.") }
            }
        }
        if !lineBytes.isEmpty {
            let line = String(decoding: lineBytes, as: UTF8.self)
            if line.hasPrefix("data:") { eventData.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
        }
        if !eventData.isEmpty, try await consume(eventData.joined(separator: "\n")) { finished = true }
        guard hasContent else { throw PopError.message("The model returned no translation.") }
        guard finished else { throw PopError.message("Connection ended. Translation is incomplete.") }
    }
}
