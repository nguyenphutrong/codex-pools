import Foundation

struct CodexInstance: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var iconPath: String?
    var codexHome: String
    var extraEnvVars: [String: String]
    var launchArgs: [String]
    var createdAt: Date
    var lastLaunchedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        iconPath: String? = nil,
        codexHome: String,
        extraEnvVars: [String: String] = [:],
        launchArgs: [String] = [],
        createdAt: Date = Date(),
        lastLaunchedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.iconPath = iconPath
        self.codexHome = codexHome
        self.extraEnvVars = extraEnvVars
        self.launchArgs = launchArgs
        self.createdAt = createdAt
        self.lastLaunchedAt = lastLaunchedAt
    }
}

extension CodexInstance {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case iconPath
        case codexHome
        case extraEnvVars
        case launchArgs
        case createdAt
        case lastLaunchedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        iconPath = try container.decodeIfPresent(String.self, forKey: .iconPath)
        codexHome = try container.decode(String.self, forKey: .codexHome)
        extraEnvVars = try container.decodeIfPresent([String: String].self, forKey: .extraEnvVars) ?? [:]
        launchArgs = try container.decodeIfPresent([String].self, forKey: .launchArgs) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastLaunchedAt = try container.decodeIfPresent(Date.self, forKey: .lastLaunchedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(iconPath, forKey: .iconPath)
        try container.encode(codexHome, forKey: .codexHome)
        try container.encode(extraEnvVars, forKey: .extraEnvVars)
        try container.encode(launchArgs, forKey: .launchArgs)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastLaunchedAt, forKey: .lastLaunchedAt)
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
