import AppKit
import Combine
import Foundation

@MainActor
final class InstanceStore: ObservableObject {
    @Published private(set) var instances: [CodexInstance] = []
    @Published var selectedInstanceID: CodexInstance.ID?
    @Published var errorMessage: String?
    @Published private(set) var runningInstanceIDs: Set<CodexInstance.ID> = []
    @Published private var launchingInstanceIDs: Set<CodexInstance.ID> = []

    private let launchService = LaunchService()
    private let fileManager: FileManager
    private let configURL: URL
    private let iconDirectoryURL: URL
    private var runningAppsCancellable: AnyCancellable?

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
        refreshBundleStatuses()
        startRunningAppsObserver()
    }

    func load() {
        do {
            guard fileManager.fileExists(atPath: configURL.path) else {
                instances = []
                return
            }

            let data = try Data(contentsOf: configURL)
            instances = try JSONDecoder.instanceDecoder.decode([CodexInstance].self, from: data)
            refreshRunningInstances()

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
        var instance = CodexInstance(
            name: baseName,
            codexHome: CodexInstance.defaultHomePath(for: baseName)
        )
        instance.bundleStatus = launchService.bundleStatus(for: instance)

        instances.append(instance)
        selectedInstanceID = instance.id
        save()
    }

    func update(_ instance: CodexInstance) {
        guard let index = instances.firstIndex(where: { $0.id == instance.id }) else { return }
        var updated = instance
        updated.bundleStatus = launchService.bundleStatus(for: updated)
        instances[index] = updated
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

            var clone = CodexInstance(
                name: trimmedName,
                iconPath: instance.iconPath,
                codexHome: newHome
            )
            clone.bundleStatus = launchService.bundleStatus(for: clone)
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
            launched.bundleStatus = launchService.bundleStatus(for: launched)
            update(launched)
        } catch {
            errorMessage = "Could not launch Codex: \(error.localizedDescription)"
            refreshBundleStatuses()
        }
    }

    func isLaunching(_ instance: CodexInstance) -> Bool {
        launchingInstanceIDs.contains(instance.id)
    }

    func isRunning(_ instance: CodexInstance) -> Bool {
        runningInstanceIDs.contains(instance.id)
    }

    private func startRunningAppsObserver() {
        refreshRunningInstances()
        runningAppsCancellable = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshRunningInstances()
            }
    }

    private func refreshRunningInstances() {
        let runningBundleIdentifiers = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        runningInstanceIDs = Set(
            instances
                .filter { runningBundleIdentifiers.contains($0.managedBundleIdentifier) }
                .map(\.id)
        )
    }

    private func refreshBundleStatuses() {
        var didChange = false
        instances = instances.map { instance in
            var updated = instance
            let status = launchService.bundleStatus(for: updated)
            if updated.bundleStatus != status {
                updated.bundleStatus = status
                didChange = true
            }
            return updated
        }

        if didChange {
            save()
        }
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
}

private extension JSONDecoder {
    static var instanceDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var instanceEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
