import AppKit
import Combine
import Foundation

@MainActor
final class InstanceStore: ObservableObject {
    enum ImportMode {
        case merge
        case replace
    }

    @Published private(set) var instances: [CodexInstance] = []
    @Published private(set) var templates: [CodexTemplate] = []
    @Published var selectedInstanceID: CodexInstance.ID?
    @Published var errorMessage: String?
    @Published var isShowingTemplatePicker = false
    @Published var pendingImportedInstances: [CodexInstance]?
    @Published private(set) var sessionScanResult = CodexSessionScanResult(sessions: [], skippedFileCount: 0)
    @Published private(set) var sessionStatusMessage: String?
    @Published private(set) var isScanningSessions = false
    @Published private(set) var analyticsScanResult = CodexAnalyticsScanResult(snapshot: .empty, skippedFileCount: 0)
    @Published private(set) var analyticsStatusMessage: String?
    @Published private(set) var isScanningAnalytics = false
    @Published private(set) var isPerformingSessionMutation = false
    @Published private(set) var runningInstanceIDs: Set<CodexInstance.ID> = []
    @Published private var launchingInstanceIDs: Set<CodexInstance.ID> = []

    private let exportService = ExportService()
    private let importService = ImportService()
    private let launchService = LaunchService()
    private let fileManager: FileManager
    private let configURL: URL
    private let templatesURL: URL
    private let iconDirectoryURL: URL
    private var runningAppsCancellable: AnyCancellable?
    private var sessionScanTask: Task<Void, Never>?
    private var analyticsScanTask: Task<Void, Never>?
    private var sessionMutationTask: Task<Void, Never>?
    private var sessionScanGeneration = 0
    private var analyticsScanGeneration = 0

    var originalInstance: CodexInstance {
        CodexInstance.original(homeDirectory: fileManager.homeDirectoryForCurrentUser)
    }

    var visibleInstances: [CodexInstance] {
        [originalInstance] + instances
    }

    var selectedInstance: CodexInstance? {
        guard let selectedInstanceID else { return visibleInstances.first }
        return visibleInstances.first { $0.id == selectedInstanceID } ?? visibleInstances.first
    }

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let home = fileManager.homeDirectoryForCurrentUser
        self.configURL = home
            .appendingPathComponent(".config")
            .appendingPathComponent("codex-pools")
            .appendingPathComponent("instances.json")
        self.templatesURL = home
            .appendingPathComponent(".config")
            .appendingPathComponent("codex-pools")
            .appendingPathComponent("templates.json")

        self.iconDirectoryURL = home
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Codex Pools")
            .appendingPathComponent("Icons")

        load()
        loadTemplates()
        refreshBundleStatuses()
        startRunningAppsObserver()
    }

    func load() {
        do {
            guard fileManager.fileExists(atPath: configURL.path) else {
                instances = []
                selectedInstanceID = visibleInstances.first?.id
                return
            }

            let data = try Data(contentsOf: configURL)
            instances = try JSONDecoder.instanceDecoder
                .decode([CodexInstance].self, from: data)
                .filter(\.isEditable)
            refreshRunningInstances()

            if selectedInstanceID == nil {
                selectedInstanceID = visibleInstances.first?.id
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
        isShowingTemplatePicker = false
        save()
    }

    func createInstance(from template: CodexTemplate) {
        let baseName = nextAvailableName(prefix: template.name)
        var instance = CodexInstance(
            name: baseName,
            codexHome: nextAvailableTemplateHomePath(for: template),
            extraEnvVars: template.extraEnvVars,
            launchArgs: template.launchFlags
        )
        instance.bundleStatus = launchService.bundleStatus(for: instance)

        instances.append(instance)
        selectedInstanceID = instance.id
        isShowingTemplatePicker = false
        save()
    }

    func showTemplatePicker() {
        isShowingTemplatePicker = true
    }

    func loadTemplates() {
        do {
            guard fileManager.fileExists(atPath: templatesURL.path) else {
                templates = CodexTemplate.builtInTemplates
                saveTemplates()
                return
            }

            let data = try Data(contentsOf: templatesURL)
            let decodedTemplates = try JSONDecoder.instanceDecoder.decode([CodexTemplate].self, from: data)
            templates = decodedTemplates.isEmpty ? CodexTemplate.builtInTemplates : decodedTemplates

            if decodedTemplates.isEmpty {
                saveTemplates()
            }
        } catch {
            errorMessage = "Could not load templates: \(error.localizedDescription)"
            templates = CodexTemplate.builtInTemplates
        }
    }

    func update(_ instance: CodexInstance) {
        guard instance.isEditable else { return }
        guard let index = instances.firstIndex(where: { $0.id == instance.id }) else { return }
        var updated = instance
        updated.bundleStatus = launchService.bundleStatus(for: updated)
        instances[index] = updated
        selectedInstanceID = instance.id
        save()
    }

    func delete(_ instance: CodexInstance, deleteHomeDirectory: Bool) {
        guard instance.isEditable else { return }
        do {
            if deleteHomeDirectory {
                try removeHomeDirectoryIfPresent(instance.codexHome)
            }
            try launchService.removeManagedBundle(for: instance)

            instances.removeAll { $0.id == instance.id }
            selectedInstanceID = visibleInstances.first?.id
            save()
        } catch {
            errorMessage = "Could not delete instance: \(error.localizedDescription)"
        }
    }

    func duplicate(_ instance: CodexInstance, newName: String) {
        guard instance.isEditable else { return }
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
        guard instance.isEditable else { return }
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

    func quit(_ instance: CodexInstance) {
        guard instance.isEditable else { return }
        do {
            try launchService.quit(instance: instance)
            refreshRunningInstances()
        } catch {
            errorMessage = "Could not quit Codex: \(error.localizedDescription)"
        }
    }

    func restart(_ instance: CodexInstance) async {
        guard instance.isEditable else { return }
        guard !isLaunching(instance) else { return }

        quit(instance)
        await waitUntilNotRunning(instance)
        guard !isRunning(instance) else { return }
        await launch(instance)
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
        let managedImportedInstances = importedInstances.filter(\.isEditable)

        switch mode {
        case .merge:
            merge(managedImportedInstances)
        case .replace:
            instances = managedImportedInstances
        }

        selectedInstanceID = managedImportedInstances.first?.id ?? visibleInstances.first?.id
        pendingImportedInstances = nil
        save()
    }

    func cancelPendingImport() {
        pendingImportedInstances = nil
    }

    func isRunning(_ instance: CodexInstance) -> Bool {
        runningInstanceIDs.contains(instance.id)
    }

    func refreshSessions() {
        sessionScanGeneration += 1
        let generation = sessionScanGeneration
        let instancesSnapshot = visibleInstances

        sessionScanTask?.cancel()
        isScanningSessions = true
        sessionScanTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                CodexSessionService().scanSessions(for: instancesSnapshot)
            }.value

            guard let self,
                  !Task.isCancelled,
                  generation == self.sessionScanGeneration
            else {
                return
            }

            self.sessionScanResult = result
            self.isScanningSessions = false
        }
    }

    func refreshAnalytics(for instances: [CodexInstance]? = nil) {
        analyticsScanGeneration += 1
        let generation = analyticsScanGeneration
        let instancesSnapshot = instances ?? visibleInstances

        analyticsScanTask?.cancel()
        isScanningAnalytics = true
        analyticsStatusMessage = nil
        analyticsScanTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                CodexSessionService().scanAnalytics(for: instancesSnapshot)
            }.value

            guard let self,
                  !Task.isCancelled,
                  generation == self.analyticsScanGeneration
            else {
                return
            }

            self.analyticsScanResult = result
            self.analyticsStatusMessage = "Loaded \(result.snapshot.sessions.count) analytics session(s)."
            self.isScanningAnalytics = false
        }
    }

    func cancelSessionRefresh() {
        sessionScanGeneration += 1
        sessionScanTask?.cancel()
        sessionScanTask = nil
        isScanningSessions = false
    }

    func cancelAnalyticsRefresh() {
        analyticsScanGeneration += 1
        analyticsScanTask?.cancel()
        analyticsScanTask = nil
        isScanningAnalytics = false
    }

    func copySessions(_ sessionIDs: Set<CodexSessionThread.ID>, to targetInstanceID: CodexInstance.ID) {
        guard !isPerformingSessionMutation,
              let target = visibleInstances.first(where: { $0.id == targetInstanceID })
        else {
            return
        }

        let instancesSnapshot = visibleInstances
        isPerformingSessionMutation = true
        sessionMutationTask = Task { [weak self] in
            let result: Result<CodexSessionCopySummary, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let summary = try CodexSessionService().copySessions(
                        sessionIDs: sessionIDs,
                        to: target,
                        from: instancesSnapshot
                    )
                    return .success(summary)
                } catch {
                    return .failure(error)
                }
            }.value

            guard let self, !Task.isCancelled else { return }
            self.isPerformingSessionMutation = false

            switch result {
            case .success(let summary):
                self.sessionStatusMessage = "Copied \(summary.copiedSessionCount) session(s) to \(target.managedAppName)."
                self.refreshSessions()
                self.refreshAnalytics()
            case .failure(let error):
                self.errorMessage = "Could not copy sessions: \(error.localizedDescription)"
            }
        }
    }

    func syncSessionsAcrossIdleInstances() {
        guard !isPerformingSessionMutation else {
            return
        }

        let instancesSnapshot = visibleInstances
        let runningInstanceIDsSnapshot = runningInstanceIDs
        isPerformingSessionMutation = true
        sessionMutationTask = Task { [weak self] in
            let result: Result<CodexSessionSyncSummary, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let summary = try CodexSessionService().syncSessionsAcrossIdleInstances(
                        instancesSnapshot,
                        runningInstanceIDs: runningInstanceIDsSnapshot
                    )
                    return .success(summary)
                } catch {
                    return .failure(error)
                }
            }.value

            guard let self, !Task.isCancelled else { return }
            self.isPerformingSessionMutation = false

            switch result {
            case .success(let summary):
                self.sessionStatusMessage = "Synced \(summary.addedSessionCount + summary.updatedSessionCount) session(s) across \(summary.mutatedInstanceCount) instance(s)."
                self.refreshSessions()
                self.refreshAnalytics()
            case .failure(let error):
                self.errorMessage = "Could not sync sessions: \(error.localizedDescription)"
            }
        }
    }

    func repairSessionIndex(for instanceID: CodexInstance.ID) {
        guard !isPerformingSessionMutation,
              let instance = visibleInstances.first(where: { $0.id == instanceID })
        else {
            return
        }

        isPerformingSessionMutation = true
        sessionMutationTask = Task { [weak self] in
            let result: Result<CodexSessionRepairSummary, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let summary = try CodexSessionService().repairSessionIndex(for: instance)
                    return .success(summary)
                } catch {
                    return .failure(error)
                }
            }.value

            guard let self, !Task.isCancelled else { return }
            self.isPerformingSessionMutation = false

            switch result {
            case .success(let summary):
                self.sessionStatusMessage = "Rebuilt \(summary.indexedSessionCount) session index entries for \(instance.managedAppName)."
                self.refreshSessions()
                self.refreshAnalytics()
            case .failure(let error):
                self.errorMessage = "Could not repair session index: \(error.localizedDescription)"
            }
        }
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
            visibleInstances
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

    private func waitUntilNotRunning(_ instance: CodexInstance) async {
        for _ in 0..<20 {
            refreshRunningInstances()
            if !isRunning(instance) {
                return
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
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

    private func saveTemplates() {
        do {
            try fileManager.createDirectory(
                at: templatesURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let data = try JSONEncoder.instanceEncoder.encode(templates)
            try data.write(to: templatesURL, options: .atomic)
        } catch {
            errorMessage = "Could not save templates: \(error.localizedDescription)"
        }
    }

    private func removeHomeDirectoryIfPresent(_ path: String) throws {
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func nextAvailableName(prefix: String) -> String {
        InstanceNaming.nextAvailableName(prefix: prefix, existingNames: Set(instances.map(\.name)))
    }

    private func nextAvailableTemplateHomePath(for template: CodexTemplate) -> String {
        let home = fileManager.homeDirectoryForCurrentUser
        let codexDirectory = home.appendingPathComponent(".codex")
        let basePath = codexDirectory.appendingPathComponent(template.safeHomePathSuffix).path
        let existingHomes = Set(instances.map(\.codexHome))

        if !existingHomes.contains(basePath) {
            return basePath
        }

        var index = 2
        while existingHomes.contains("\(basePath)-\(index)") {
            index += 1
        }

        return "\(basePath)-\(index)"
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
