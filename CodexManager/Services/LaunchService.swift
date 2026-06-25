import AppKit
import Foundation

struct LaunchService {
    private let codexAppPath = "/Applications/Codex.app"

    func launch(instance: CodexInstance) async throws {
        let homePath = NSString(string: instance.codexHome).expandingTildeInPath

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: homePath, isDirectory: true),
            withIntermediateDirectories: true
        )

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true

        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = homePath
        configuration.environment = environment

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: codexAppPath),
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
}
