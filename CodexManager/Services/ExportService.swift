import AppKit
import CodexPoolsCore
import Foundation
import UniformTypeIdentifiers

struct ExportService {
    @MainActor
    func export(instances: [CodexInstance]) throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "codex-pools-instances.json"
        panel.title = "Export Codex Pools Configuration"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let data = try JSONEncoder.instanceEncoder.encode(instances)
        try data.write(to: url, options: .atomic)
    }
}
