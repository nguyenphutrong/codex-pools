import AppKit
import Foundation

struct LaunchService {
    private let bundleCloneService = BundleCloneService()

    func launch(instance: CodexInstance) async throws {
        let homePath = NSString(string: instance.codexHome).expandingTildeInPath
        let appURL = try bundleCloneService.prepareBundle(for: instance)

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: homePath, isDirectory: true),
            withIntermediateDirectories: true
        )

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [
            // Local clones are re-signed, so Chromium Keychain ACL prompts can repeat.
            "--use-mock-keychain"
        ] + instance.launchArgs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var environment = ProcessInfo.processInfo.environment
        environment.merge(instance.extraEnvVars) { _, new in new }
        environment["CODEX_HOME"] = homePath
        environment["CODEX_INSTANCE_ID"] = instance.id.uuidString
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

    func removeManagedBundle(for instance: CodexInstance) throws {
        try bundleCloneService.removeBundle(for: instance)
    }

    func bundleStatus(for instance: CodexInstance) -> CodexInstance.BundleStatus {
        bundleCloneService.bundleStatus(for: instance)
    }

    func quit(instance: CodexInstance) throws {
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

private enum LaunchServiceError: LocalizedError {
    case couldNotTerminate(String)

    var errorDescription: String? {
        switch self {
        case .couldNotTerminate(let name):
            return "Could not quit \(name)."
        }
    }
}
