import Foundation

struct CodexInstance: Identifiable, Codable, Equatable {
    enum BundleStatus: String, Codable, Equatable {
        case ready
        case needsRebuild
        case missingSourceApp
    }

    enum Kind: String, Codable, Equatable {
        case managed
        case original
    }

    var id: UUID
    var kind: Kind
    var name: String
    var iconPath: String?
    var codexHome: String
    var bundleStatus: BundleStatus
    var extraEnvVars: [String: String]
    var launchArgs: [String]
    var createdAt: Date
    var lastLaunchedAt: Date?

    init(
        id: UUID = UUID(),
        kind: Kind = .managed,
        name: String,
        iconPath: String? = nil,
        codexHome: String,
        bundleStatus: BundleStatus = .missingSourceApp,
        extraEnvVars: [String: String] = [:],
        launchArgs: [String] = [],
        createdAt: Date = Date(),
        lastLaunchedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.iconPath = iconPath
        self.codexHome = codexHome
        self.bundleStatus = bundleStatus
        self.extraEnvVars = extraEnvVars
        self.launchArgs = launchArgs
        self.createdAt = createdAt
        self.lastLaunchedAt = lastLaunchedAt
    }
}

extension CodexInstance {
    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case name
        case iconPath
        case codexHome
        case bundleStatus
        case extraEnvVars
        case launchArgs
        case createdAt
        case lastLaunchedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .managed
        name = try container.decode(String.self, forKey: .name)
        iconPath = try container.decodeIfPresent(String.self, forKey: .iconPath)
        codexHome = try container.decode(String.self, forKey: .codexHome)
        bundleStatus = try container.decodeIfPresent(BundleStatus.self, forKey: .bundleStatus) ?? .missingSourceApp
        extraEnvVars = try container.decodeIfPresent([String: String].self, forKey: .extraEnvVars) ?? [:]
        launchArgs = try container.decodeIfPresent([String].self, forKey: .launchArgs) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastLaunchedAt = try container.decodeIfPresent(Date.self, forKey: .lastLaunchedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(iconPath, forKey: .iconPath)
        try container.encode(codexHome, forKey: .codexHome)
        try container.encode(bundleStatus, forKey: .bundleStatus)
        try container.encode(extraEnvVars, forKey: .extraEnvVars)
        try container.encode(launchArgs, forKey: .launchArgs)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastLaunchedAt, forKey: .lastLaunchedAt)
    }
}

extension CodexInstance {
    static let originalID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    static func defaultHomePath(for name: String) -> String {
        InstanceNaming.defaultHomePath(
            for: name,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    static func original(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> CodexInstance {
        CodexInstance(
            id: originalID,
            kind: .original,
            name: "Codex",
            codexHome: homeDirectory.appendingPathComponent(".codex", isDirectory: true).path,
            bundleStatus: .ready,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    var isOriginal: Bool {
        kind == .original
    }

    var isEditable: Bool {
        kind == .managed
    }

    var managedBundleIdentifier: String {
        if isOriginal {
            return "com.openai.codex"
        }
        return "com.nguyenphutrong.codexpools.instance.\(id.uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
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
