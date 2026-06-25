import AppKit
import Foundation
import UniformTypeIdentifiers

struct ImportService {
    @MainActor
    func selectInstances() throws -> [CodexInstance]? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Import Codex Pools Configuration"

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let data = try Data(contentsOf: url)
        return try JSONDecoder.instanceDecoder.decode([CodexInstance].self, from: data)
    }
}
