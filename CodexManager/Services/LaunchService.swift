import Foundation

struct LaunchService {
    private let codexAppPath = "/Applications/Codex.app"

    func launch(instance: CodexInstance) throws {
        let homePath = NSString(string: instance.codexHome).expandingTildeInPath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", codexAppPath]

        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = homePath
        process.environment = environment

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: homePath, isDirectory: true),
            withIntermediateDirectories: true
        )

        try process.run()
    }
}
