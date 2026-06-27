import Foundation

public struct CodexInstance: Identifiable, Codable, Equatable {
    public enum BundleStatus: String, Codable, Equatable {
        case ready
        case needsRebuild
        case missingSourceApp
    }

    public var id: UUID
    public var name: String
    public var iconPath: String?
    public var codexHome: String
    public var bundleStatus: BundleStatus
    public var bundleShortVersion: String?
    public var bundleBuildVersion: String?
    public var sourceShortVersion: String?
    public var sourceBuildVersion: String?
    public var extraEnvVars: [String: String]
    public var launchArgs: [String]
    public var createdAt: Date
    public var lastLaunchedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        iconPath: String? = nil,
        codexHome: String,
        bundleStatus: BundleStatus = .missingSourceApp,
        bundleShortVersion: String? = nil,
        bundleBuildVersion: String? = nil,
        sourceShortVersion: String? = nil,
        sourceBuildVersion: String? = nil,
        extraEnvVars: [String: String] = [:],
        launchArgs: [String] = [],
        createdAt: Date = Date(),
        lastLaunchedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.iconPath = iconPath
        self.codexHome = codexHome
        self.bundleStatus = bundleStatus
        self.bundleShortVersion = bundleShortVersion
        self.bundleBuildVersion = bundleBuildVersion
        self.sourceShortVersion = sourceShortVersion
        self.sourceBuildVersion = sourceBuildVersion
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
        case bundleStatus
        case bundleShortVersion
        case bundleBuildVersion
        case sourceShortVersion
        case sourceBuildVersion
        case extraEnvVars
        case launchArgs
        case createdAt
        case lastLaunchedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        iconPath = try container.decodeIfPresent(String.self, forKey: .iconPath)
        codexHome = try container.decode(String.self, forKey: .codexHome)
        bundleStatus = try container.decodeIfPresent(BundleStatus.self, forKey: .bundleStatus) ?? .missingSourceApp
        bundleShortVersion = try container.decodeIfPresent(String.self, forKey: .bundleShortVersion)
        bundleBuildVersion = try container.decodeIfPresent(String.self, forKey: .bundleBuildVersion)
        sourceShortVersion = try container.decodeIfPresent(String.self, forKey: .sourceShortVersion)
        sourceBuildVersion = try container.decodeIfPresent(String.self, forKey: .sourceBuildVersion)
        extraEnvVars = try container.decodeIfPresent([String: String].self, forKey: .extraEnvVars) ?? [:]
        launchArgs = try container.decodeIfPresent([String].self, forKey: .launchArgs) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastLaunchedAt = try container.decodeIfPresent(Date.self, forKey: .lastLaunchedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(iconPath, forKey: .iconPath)
        try container.encode(codexHome, forKey: .codexHome)
        try container.encode(bundleStatus, forKey: .bundleStatus)
        try container.encodeIfPresent(bundleShortVersion, forKey: .bundleShortVersion)
        try container.encodeIfPresent(bundleBuildVersion, forKey: .bundleBuildVersion)
        try container.encodeIfPresent(sourceShortVersion, forKey: .sourceShortVersion)
        try container.encodeIfPresent(sourceBuildVersion, forKey: .sourceBuildVersion)
        try container.encode(extraEnvVars, forKey: .extraEnvVars)
        try container.encode(launchArgs, forKey: .launchArgs)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastLaunchedAt, forKey: .lastLaunchedAt)
    }
}

public extension CodexInstance {
    static func defaultHomePath(for name: String) -> String {
        InstanceNaming.defaultHomePath(
            for: name,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
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

    var bundleVersionSummary: String {
        let bundleVersion = Self.cleanVersion(bundleShortVersion)
        let sourceVersion = Self.cleanVersion(sourceShortVersion)

        if let bundleVersion {
            if bundleStatus == .needsRebuild,
               let sourceVersion,
               Self.versionChanged(
                   bundleShortVersion: bundleVersion,
                   bundleBuildVersion: bundleBuildVersion,
                   sourceShortVersion: sourceVersion,
                   sourceBuildVersion: sourceBuildVersion
               ) {
                return "v\(bundleVersion) -> v\(sourceVersion)"
            }

            return "v\(bundleVersion)"
        }

        if sourceVersion != nil {
            return "Not built yet"
        }

        return "Version unknown"
    }

    var detailedBundleVersionSummary: String {
        let bundleVersion = Self.versionWithBuild(shortVersion: bundleShortVersion, buildVersion: bundleBuildVersion)
        let sourceVersion = Self.versionWithBuild(shortVersion: sourceShortVersion, buildVersion: sourceBuildVersion)

        if let bundleVersion {
            if bundleStatus == .needsRebuild,
               let sourceVersion,
               Self.versionChanged(
                   bundleShortVersion: bundleShortVersion,
                   bundleBuildVersion: bundleBuildVersion,
                   sourceShortVersion: sourceShortVersion,
                   sourceBuildVersion: sourceBuildVersion
               ) {
                return "\(bundleVersion) -> \(sourceVersion)"
            }

            return bundleVersion
        }

        if let sourceVersion {
            return "Not built yet (source \(sourceVersion))"
        }

        return "Version unknown"
    }

    private static func versionChanged(
        bundleShortVersion: String?,
        bundleBuildVersion: String?,
        sourceShortVersion: String?,
        sourceBuildVersion: String?
    ) -> Bool {
        cleanVersion(bundleShortVersion) != cleanVersion(sourceShortVersion) ||
            cleanVersion(bundleBuildVersion) != cleanVersion(sourceBuildVersion)
    }

    private static func versionWithBuild(shortVersion: String?, buildVersion: String?) -> String? {
        guard let shortVersion = cleanVersion(shortVersion) else { return nil }
        guard let buildVersion = cleanVersion(buildVersion), buildVersion != shortVersion else {
            return "v\(shortVersion)"
        }

        return "v\(shortVersion) (\(buildVersion))"
    }

    private static func cleanVersion(_ version: String?) -> String? {
        let trimmed = version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
