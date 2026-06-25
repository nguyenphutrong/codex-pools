import Combine
import Foundation

@MainActor
final class InstanceStore: ObservableObject {
    enum ImportMode {
        case merge
        case replace
    }

    @Published private(set) var instances: [CodexInstance] = []
    @Published var selectedInstanceID: CodexInstance.ID?
    @Published var errorMessage: String?
    @Published var pendingImportedInstances: [CodexInstance]?
    @Published private var launchingInstanceIDs: Set<CodexInstance.ID> = []

    private let exportService = ExportService()
    private let importService = ImportService()
    private let launchService = LaunchService()
    private let fileManager: FileManager
    private let configURL: URL
    private let iconDirectoryURL: URL

    var selectedInstance: CodexInstance? {
        guard let selectedInstanceID else { return instances.first }
        return instances.first { $0.id == selectedInstanceID }
    }

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let home = fileManager.homeDirectoryForCurrentUser
        self.configURL = home
            .appendingPathComponent(".config")
            .appendingPathComponent("codex-pools")
            .appendingPathComponent("instances.json")

        self.iconDirectoryURL = home
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Codex Pools")
            .appendingPathComponent("Icons")

        load()
    }

    func load() {
        do {
            guard fileManager.fileExists(atPath: configURL.path) else {
                instances = []
                return
            }

            let data = try Data(contentsOf: configURL)
            instances = try JSONDecoder.instanceDecoder.decode([CodexInstance].self, from: data)

            if selectedInstanceID == nil {
                selectedInstanceID = instances.first?.id
            }
        } catch {
            errorMessage = "Could not load instances: \(error.localizedDescription)"
            instances = []
        }
    }

    func createInstance() {
        let baseName = nextAvailableName(prefix: "Codex")
        let instance = CodexInstance(
            name: baseName,
            codexHome: CodexInstance.defaultHomePath(for: baseName)
        )

        instances.append(instance)
        selectedInstanceID = instance.id
        save()
    }

    func update(_ instance: CodexInstance) {
        guard let index = instances.firstIndex(where: { $0.id == instance.id }) else { return }
        instances[index] = instance
        selectedInstanceID = instance.id
        save()
    }

    func delete(_ instance: CodexInstance, deleteHomeDirectory: Bool) {
        do {
            if deleteHomeDirectory {
                try removeHomeDirectoryIfPresent(instance.codexHome)
            }
            try launchService.removeManagedBundle(for: instance)

            instances.removeAll { $0.id == instance.id }
            selectedInstanceID = instances.first?.id
            save()
        } catch {
            errorMessage = "Could not delete instance: \(error.localizedDescription)"
        }
    }

    func duplicate(_ instance: CodexInstance, newName: String) {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let newHome = CodexInstance.defaultHomePath(for: trimmedName)
        do {
            try fileManager.createDirectory(
                at: URL(fileURLWithPath: newHome, isDirectory: true),
                withIntermediateDirectories: true
            )

            let clone = CodexInstance(
                name: trimmedName,
                iconPath: instance.iconPath,
                codexHome: newHome
            )
            instances.append(clone)
            selectedInstanceID = clone.id
            save()
        } catch {
            errorMessage = "Could not duplicate instance: \(error.localizedDescription)"
        }
    }

    func copyIcon(from sourceURL: URL) -> String? {
        do {
            try fileManager.createDirectory(at: iconDirectoryURL, withIntermediateDirectories: true)

            let ext = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension
            let destination = iconDirectoryURL
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)

            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }

            if sourceURL.startAccessingSecurityScopedResource() {
                defer { sourceURL.stopAccessingSecurityScopedResource() }
                try fileManager.copyItem(at: sourceURL, to: destination)
            } else {
                try fileManager.copyItem(at: sourceURL, to: destination)
            }

            return destination.path
        } catch {
            errorMessage = "Could not copy icon: \(error.localizedDescription)"
            return nil
        }
    }

    func launch(_ instance: CodexInstance) async {
        guard !isLaunching(instance) else { return }
        launchingInstanceIDs.insert(instance.id)
        defer {
            launchingInstanceIDs.remove(instance.id)
        }

        do {
            try await launchService.launch(instance: instance)

            var launched = instance
            launched.lastLaunchedAt = Date()
            update(launched)
        } catch {
            errorMessage = "Could not launch Codex: \(error.localizedDescription)"
        }
    }

    func isLaunching(_ instance: CodexInstance) -> Bool {
        launchingInstanceIDs.contains(instance.id)
    }

    func exportInstances() {
        do {
            try exportService.export(instances: instances)
        } catch {
            errorMessage = "Could not export instances: \(error.localizedDescription)"
        }
    }

    func selectConfigurationForImport() {
        do {
            pendingImportedInstances = try importService.selectInstances()
        } catch {
            errorMessage = "Could not import instances: \(error.localizedDescription)"
        }
    }

    func importPendingInstances(mode: ImportMode) {
        guard let importedInstances = pendingImportedInstances else { return }

        switch mode {
        case .merge:
            merge(importedInstances)
        case .replace:
            instances = importedInstances
        }

        selectedInstanceID = importedInstances.first?.id ?? instances.first?.id
        pendingImportedInstances = nil
        save()
    }

    func cancelPendingImport() {
        pendingImportedInstances = nil
    }

    private func save() {
        do {
            try fileManager.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let data = try JSONEncoder.instanceEncoder.encode(instances)
            try data.write(to: configURL, options: .atomic)
        } catch {
            errorMessage = "Could not save instances: \(error.localizedDescription)"
        }
    }

    private func removeHomeDirectoryIfPresent(_ path: String) throws {
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func nextAvailableName(prefix: String) -> String {
        let existingNames = Set(instances.map(\.name))
        if !existingNames.contains(prefix) {
            return prefix
        }

        var index = 2
        while existingNames.contains("\(prefix) \(index)") {
            index += 1
        }
        return "\(prefix) \(index)"
    }

    private func merge(_ importedInstances: [CodexInstance]) {
        var mergedInstances = instances

        for imported in importedInstances {
            if let index = mergedInstances.firstIndex(where: { $0.id == imported.id }) {
                mergedInstances[index] = imported
            } else {
                mergedInstances.append(imported)
            }
        }

        instances = mergedInstances
    }
}
