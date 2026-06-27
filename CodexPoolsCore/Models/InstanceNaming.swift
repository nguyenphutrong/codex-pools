import Foundation

public enum InstanceNaming {
    public static func defaultHomePath(for name: String, homeDirectory: URL) -> String {
        let slug = name
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")

        let safeSlug = slug.isEmpty ? "codex-instance" : slug
        return homeDirectory
            .appendingPathComponent(".codex")
            .appendingPathComponent(safeSlug)
            .path
    }

    public static func nextAvailableName(prefix: String, existingNames: Set<String>) -> String {
        if !existingNames.contains(prefix) {
            return prefix
        }

        var index = 2
        while existingNames.contains("\(prefix) \(index)") {
            index += 1
        }
        return "\(prefix) \(index)"
    }
}
