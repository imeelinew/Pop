import Foundation
import TOMLDecoder

struct Configuration: Decodable, Sendable {
    struct Shortcut: Decodable, Sendable {
        var key: String
        var modifiers: [String]
    }

    var model: String
    var api_key: String
    var base_url: String
    var shortcut: Shortcut

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
        } else {
            let data = try Data(contentsOf: fileURL)
            let decoder = TOMLDecoder()
            if (try? decoder.decode(Configuration.self, from: data)) == nil,
               let old = try? decoder.decode(LegacyConfiguration.self, from: data) {
                let migrated = Configuration(model: old.llm.model, api_key: old.llm.api_key,
                                             base_url: old.llm.base_url, shortcut: old.shortcut)
                try migrated.contents().write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func load() throws -> Configuration {
        let result: Configuration
        do {
            result = try TOMLDecoder().decode(Configuration.self, from: Data(contentsOf: fileURL))
        } catch {
            throw PopError.message("Invalid config.toml. Check its syntax and required fields.")
        }
        guard let url = URL(string: result.base_url),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw PopError.message("Invalid API base URL.")
        }
        guard !result.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PopError.message("Model is missing.")
        }
        return result
    }

    private func contents() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        func quoted(_ value: String) throws -> String {
            String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        let modifiers = try shortcut.modifiers.map { try quoted($0) }.joined(separator: ", ")
        return """
        model = \(try quoted(model))
        api_key = \(try quoted(api_key))
        base_url = \(try quoted(base_url))

        [shortcut]
        key = \(try quoted(shortcut.key))
        modifiers = [\(modifiers)]

        """
    }

    private struct LegacyConfiguration: Decodable {
        struct LLM: Decodable {
            var model: String
            var api_key: String
            var base_url: String
        }
        var llm: LLM
        var shortcut: Shortcut
    }
}

enum PopError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}
