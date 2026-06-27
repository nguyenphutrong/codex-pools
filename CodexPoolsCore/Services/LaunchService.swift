import AppKit
import Foundation

public struct LaunchService {
    private let bundleCloneService: BundleCloneService
    private let fileManager: FileManager
    private let userDataRootURL: URL

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.bundleCloneService = BundleCloneService(fileManager: fileManager)

        self.userDataRootURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Codex Pools")
            .appendingPathComponent("User Data", isDirectory: true)
    }

    public func launch(instance: CodexInstance) async throws {
        let homePath = NSString(string: instance.codexHome).expandingTildeInPath
        let userDataURL = userDataDirectoryURL(for: instance)
        let appURL = try bundleCloneService.prepareBundle(for: instance)

        try fileManager.createDirectory(
            at: URL(fileURLWithPath: homePath, isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: userDataURL, withIntermediateDirectories: true)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [
            // Local clones are re-signed, so Chromium Keychain ACL prompts can repeat.
            "--use-mock-keychain"
        ] + sanitizedLaunchArgs(from: instance.launchArgs) + [
            "--user-data-dir=\(userDataURL.path)"
        ]

        var environment = ProcessInfo.processInfo.environment
        environment.merge(instance.extraEnvVars) { _, new in new }
        environment["CODEX_HOME"] = homePath
        environment["CODEX_INSTANCE_ID"] = instance.id.uuidString
        environment["CODEX_SPARKLE_ENABLED"] = "false"
        configuration.environment = environment

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(
                at: appURL,
                configuration: configuration
            ) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public func removeManagedBundle(for instance: CodexInstance) throws {
        try bundleCloneService.removeBundle(for: instance)
        try removeManagedUserData(for: instance)
    }

    public func bundleDetails(for instance: CodexInstance) -> BundleCloneService.BundleDetails {
        bundleCloneService.bundleDetails(for: instance)
    }

    public func managedBundleURL(for instance: CodexInstance) -> URL {
        bundleCloneService.bundleURL(for: instance)
    }

    @discardableResult
    public func prepareBundle(for instance: CodexInstance) throws -> URL {
        try bundleCloneService.prepareBundle(for: instance)
    }

    @discardableResult
    public func rebuildBundle(for instance: CodexInstance) throws -> URL {
        try bundleCloneService.rebuildBundle(for: instance)
    }

    public func revealBundle(for instance: CodexInstance) throws {
        let appURL = try bundleCloneService.prepareBundle(for: instance)
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
    }

    public func quit(instance: CodexInstance) throws {
        let runningApplications = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == instance.managedBundleIdentifier
        }

        for application in runningApplications {
            guard application.terminate() else {
                throw LaunchServiceError.couldNotTerminate(instance.managedAppName)
            }
        }
    }
}

private extension LaunchService {
    func userDataDirectoryURL(for instance: CodexInstance) -> URL {
        userDataRootURL.appendingPathComponent(instance.id.uuidString, isDirectory: true)
    }

    func removeManagedUserData(for instance: CodexInstance) throws {
        let url = userDataDirectoryURL(for: instance)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func sanitizedLaunchArgs(from launchArgs: [String]) -> [String] {
        var result: [String] = []
        var shouldSkipNext = false

        for arg in launchArgs {
            let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if shouldSkipNext {
                shouldSkipNext = false
                continue
            }

            if trimmed == "--user-data-dir" {
                shouldSkipNext = true
                continue
            }

            if trimmed.hasPrefix("--user-data-dir=") {
                continue
            }

            result.append(trimmed)
        }

        return result
    }
}

private enum LaunchServiceError: LocalizedError {
    case couldNotTerminate(String)

    var errorDescription: String? {
        switch self {
        case .couldNotTerminate(let name):
            return "Could not quit \(name)."
        }
    }
}
