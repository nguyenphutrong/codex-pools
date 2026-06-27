import CodexPoolsCore
import Darwin
import Foundation

@main
struct CodexPoolsCLI {
    static func main() async {
        do {
            try await run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            writeError(error.localizedDescription)
            exit(1)
        }
    }

    private static func run(arguments: [String]) async throws {
        guard let command = arguments.first else {
            printUsage()
            return
        }

        let configuration = InstanceConfiguration()
        let launchService = LaunchService()
        var instances = try configuration.loadInstances()

        switch command {
        case "list":
            try requireArgumentCount(arguments, 1)
            list(instances, launchService: launchService)

        case "launch":
            let instance = try resolveInstance(arguments: arguments, instances: instances)
            try await launchService.launch(instance: instance)
            update(instance: instance, in: &instances, launchService: launchService, launchedAt: Date())
            try configuration.saveInstances(instances)
            print("Launched \(instance.managedAppName)")

        case "rebuild":
            let instance = try resolveInstance(arguments: arguments, instances: instances)
            let url = try launchService.rebuildBundle(for: instance)
            update(instance: instance, in: &instances, launchService: launchService)
            try configuration.saveInstances(instances)
            print(url.path)

        case "reveal":
            let instance = try resolveInstance(arguments: arguments, instances: instances)
            try launchService.revealBundle(for: instance)

        case "path":
            let instance = try resolveInstance(arguments: arguments, instances: instances)
            print(launchService.managedBundleURL(for: instance).path)

        case "help", "--help", "-h":
            printUsage()

        default:
            throw CLIError.unknownCommand(command)
        }
    }

    private static func list(_ instances: [CodexInstance], launchService: LaunchService) {
        if instances.isEmpty {
            print("No instances found.")
            return
        }

        for instance in instances {
            let details = launchService.bundleDetails(for: instance)
            print("\(instance.id.uuidString)\t\(details.status.rawValue)\t\(instance.name)")
        }
    }

    private static func resolveInstance(arguments: [String], instances: [CodexInstance]) throws -> CodexInstance {
        try requireArgumentCount(arguments, 2)
        return try InstanceResolver.resolve(arguments[1], in: instances)
    }

    private static func update(
        instance: CodexInstance,
        in instances: inout [CodexInstance],
        launchService: LaunchService,
        launchedAt: Date? = nil
    ) {
        guard let index = instances.firstIndex(where: { $0.id == instance.id }) else { return }
        let details = launchService.bundleDetails(for: instance)
        instances[index].bundleStatus = details.status
        instances[index].bundleShortVersion = details.cloneShortVersion
        instances[index].bundleBuildVersion = details.cloneBuildVersion
        instances[index].sourceShortVersion = details.sourceShortVersion
        instances[index].sourceBuildVersion = details.sourceBuildVersion

        if let launchedAt {
            instances[index].lastLaunchedAt = launchedAt
        }
    }

    private static func requireArgumentCount(_ arguments: [String], _ count: Int) throws {
        guard arguments.count == count else {
            throw CLIError.invalidArguments
        }
    }

    private static func printUsage() {
        print(
            """
            Usage:
              codex-pools list
              codex-pools launch <name-or-id>
              codex-pools reveal <name-or-id>
              codex-pools rebuild <name-or-id>
              codex-pools path <name-or-id>
            """
        )
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

private enum CLIError: LocalizedError {
    case invalidArguments
    case unknownCommand(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Invalid arguments. Run 'codex-pools help' for usage."
        case .unknownCommand(let command):
            return "Unknown command '\(command)'. Run 'codex-pools help' for usage."
        }
    }
}
