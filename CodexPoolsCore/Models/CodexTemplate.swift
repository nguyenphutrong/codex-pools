import Foundation

public struct CodexTemplate: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var iconName: String?
    public var homePathSuffix: String
    public var extraEnvVars: [String: String]
    public var launchFlags: [String]

    public init(
        id: UUID = UUID(),
        name: String,
        iconName: String? = nil,
        homePathSuffix: String,
        extraEnvVars: [String: String] = [:],
        launchFlags: [String] = []
    ) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.homePathSuffix = homePathSuffix
        self.extraEnvVars = extraEnvVars
        self.launchFlags = launchFlags
    }
}

public extension CodexTemplate {
    var safeHomePathSuffix: String {
        let slug = homePathSuffix
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")

        if !slug.isEmpty {
            return slug
        }

        let nameSlug = name
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")

        return nameSlug.isEmpty ? "codex-template" : nameSlug
    }

    static let builtInTemplates: [CodexTemplate] = [
        CodexTemplate(
            id: UUID(uuidString: "4A50A487-0118-43B4-8B01-C4ACBD5AF1E5")!,
            name: "Work",
            iconName: "briefcase.fill",
            homePathSuffix: "work"
        ),
        CodexTemplate(
            id: UUID(uuidString: "C4F278A9-F3BF-47A4-8BF1-BDE9647C7AB5")!,
            name: "Personal",
            iconName: "person.crop.circle.fill",
            homePathSuffix: "personal"
        ),
        CodexTemplate(
            id: UUID(uuidString: "A204E08B-016C-4104-8CD3-9400B04B4700")!,
            name: "Experiment",
            iconName: "sparkles",
            homePathSuffix: "experiment",
            extraEnvVars: ["CODEX_PROFILE": "experiment"],
            launchFlags: ["--use-mock-keychain"]
        )
    ]
}
