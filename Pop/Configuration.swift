import Foundation
import TOMLDecoder

struct Configuration: Decodable, Sendable {
    struct LLM: Decodable, Sendable {
        var base_url: String
        var api_key: String
        var model: String
        var system_prompt: String
        var timeout_seconds: Double = 60
        var extra_body: String = "{}"
    }

    struct Shortcut: Decodable, Sendable {
        var key: String
        var modifiers: [String]
    }

    struct Selection: Decodable, Sendable {
        var max_characters: Int = 12000
    }

    var llm: LLM
    var shortcut: Shortcut
    var selection: Selection = Selection()

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Pop/config.toml")
    }

    static func prepare() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            guard let template = Bundle.main.url(forResource: "config.example", withExtension: "toml") else {
                throw PopError.message("Configuration template missing.")
            }
            try FileManager.default.copyItem(at: template, to: fileURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    static func load() throws -> Configuration {
        let result: Configuration
        do {
            result = try TOMLDecoder().decode(Configuration.self, from: Data(contentsOf: fileURL))
        } catch {
            throw PopError.message("Invalid config.toml. Check its syntax and required fields.")
        }
        guard let url = URL(string: result.llm.base_url),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw PopError.message("Invalid API base URL.")
        }
        guard !result.llm.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !result.llm.system_prompt.isEmpty,
              (5...300).contains(result.llm.timeout_seconds),
              (1...100000).contains(result.selection.max_characters) else {
            throw PopError.message("Invalid model, prompt, timeout or selection limit.")
        }
        guard let extra = result.llm.extra_body.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: extra) as? [String: Any],
              Set(fields.keys).isDisjoint(with: ["model", "messages", "stream"]) else {
            throw PopError.message("extra_body must be a JSON object without model, messages or stream.")
        }
        return result
    }
}

enum PopError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}
