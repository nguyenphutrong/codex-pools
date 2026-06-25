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
        ]

        var environment = ProcessInfo.processInfo.environment
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
}
