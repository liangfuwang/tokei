import Foundation

/// Presentation-only aliases. Keys use the existing card IDs so naming never changes account attribution.
enum ClaudeAccountDisplayNames {
    static let defaultsKey = "claudeAccountDisplayNames"

    static func names(in raw: String) -> [String: String] {
        guard let data = raw.data(using: .utf8),
              let names = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return names
    }

    static func title(for accountID: String, in raw: String) -> String {
        let custom = names(in: raw)[accountID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty { return "Claude Code · \(custom)" }
        if accountID == "claude" { return "Claude Code" }
        let fallback = String(accountID.dropFirst("claude-".count))
        return "Claude Code · \(fallback)"
    }

    static func updating(_ raw: String, accountID: String, name: String) -> String {
        var values = names(in: raw)
        if name.isEmpty { values.removeValue(forKey: accountID) }
        else { values[accountID] = String(name.prefix(64)) }
        guard let data = try? JSONEncoder().encode(values),
              let result = String(data: data, encoding: .utf8) else { return raw }
        return result
    }

    /// Only enumerate directory names and login-marker existence; never open account files or credentials.
    static func localAccountIDs(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let children = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        let extras = children.filter { name in
            name.hasPrefix(".claude-") && name.count > ".claude-".count &&
            FileManager.default.fileExists(atPath: home.appendingPathComponent(name)
                .appendingPathComponent(".claude.json").path)
        }.map { "claude-" + $0.dropFirst(".claude-".count) }.sorted()
        return ["claude"] + extras
    }
}
