import Foundation

struct CodexInstance: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var iconPath: String?
    var codexHome: String
    var createdAt: Date
    var lastLaunchedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        iconPath: String? = nil,
        codexHome: String,
        createdAt: Date = Date(),
        lastLaunchedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.iconPath = iconPath
        self.codexHome = codexHome
        self.createdAt = createdAt
        self.lastLaunchedAt = lastLaunchedAt
    }
}

extension CodexInstance {
    static func defaultHomePath(for name: String) -> String {
        let slug = name
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")

        let safeSlug = slug.isEmpty ? "codex-instance" : slug
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".codex").appendingPathComponent(safeSlug).path
    }

    var managedBundleIdentifier: String {
        "com.nguyenphutrong.codexpools.instance.\(id.uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
    }

    var managedAppName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? "Codex Pool" : trimmedName
    }

    var managedAppBundleName: String {
        let invalidCharacters = CharacterSet(charactersIn: "/:")
            .union(.newlines)
            .union(.controlCharacters)

        let sanitized = managedAppName
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return "\(sanitized.isEmpty ? "Codex Pool" : sanitized).app"
    }
}
