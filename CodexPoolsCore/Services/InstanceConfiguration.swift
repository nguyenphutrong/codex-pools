import Foundation

public struct InstanceConfiguration {
    public let url: URL
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.url = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("codex-pools")
            .appendingPathComponent("instances.json")
    }

    public func loadInstances() throws -> [CodexInstance] {
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder.instanceDecoder.decode([CodexInstance].self, from: data)
    }

    public func saveInstances(_ instances: [CodexInstance]) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let data = try JSONEncoder.instanceEncoder.encode(instances)
        try data.write(to: url, options: .atomic)
    }
}
