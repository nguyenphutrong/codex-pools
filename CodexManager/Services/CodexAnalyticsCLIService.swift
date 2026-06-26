import Foundation

struct CodexAnalyticsCLIService {
    enum CLIError: LocalizedError {
        case unavailable
        case failed(String)
        case invalidOutput

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Codex Pools CLI is not available."
            case .failed(let message):
                return message.isEmpty ? "Codex Pools CLI failed." : message
            case .invalidOutput:
                return "Codex Pools CLI returned invalid analytics JSON."
            }
        }
    }

    func scanAnalytics(for instances: [CodexInstance]) throws -> CodexAnalyticsScanResult {
        guard instances.count == 1, let instance = instances.first else {
            throw CLIError.unavailable
        }
        let executableURL = try locateExecutable()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "analytics",
            "scan",
            "--instance-id",
            instance.id.uuidString,
            "--instance-name",
            instance.name,
            "--codex-home",
            instance.codexHome,
            "--json"
        ]

        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput

        try process.run()
        process.waitUntilExit()

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CLIError.failed(message)
        }
        guard !outputData.isEmpty else {
            throw CLIError.invalidOutput
        }
        do {
            return try Self.decodeScanResult(from: outputData)
        } catch {
            throw CLIError.invalidOutput
        }
    }

    static func decodeScanResult(from data: Data) throws -> CodexAnalyticsScanResult {
        try decoder.decode(CodexAnalyticsScanResult.self, from: data)
    }

    private func locateExecutable() throws -> URL {
        let fileManager = FileManager.default
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "codex-pools", withExtension: nil),
            URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("target/debug/codex-pools"),
            URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("target/release/codex-pools"),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".cargo/target-current/debug/codex-pools"),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".cargo/target-current/release/codex-pools")
        ]
        for candidate in candidates.compactMap({ $0 }) {
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw CLIError.unavailable
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = fractionalISO8601Formatter.date(from: value)
                ?? iso8601Formatter.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid RFC3339 date: \(value)"
            )
        }
        return decoder
    }()

    private static let fractionalISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Formatter = ISO8601DateFormatter()
}
