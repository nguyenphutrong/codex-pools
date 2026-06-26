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

    func scanAnalytics(
        for instances: [CodexInstance],
        progress: @escaping (String) -> Void = { _ in }
    ) throws -> CodexAnalyticsScanResult {
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
        let outputReader = DataReader()
        let progressReader = ProgressReader(progress: progress)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                outputReader.consume(data)
            }
        }
        errorOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                return
            }
            progressReader.consume(data)
        }

        try process.run()
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
        errorOutput.fileHandleForReading.readabilityHandler = nil

        outputReader.consume(output.fileHandleForReading.readDataToEndOfFile())
        let outputData = outputReader.data
        progressReader.finish()
        guard process.terminationStatus == 0 else {
            let message = progressReader.errorText
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

private final class ProgressReader {
    private let lock = NSLock()
    private var buffer = Data()
    private var errorLines: [String] = []
    private let progress: (String) -> Void

    var errorText: String {
        lock.lock()
        defer { lock.unlock() }
        return errorLines.joined(separator: "\n")
    }

    init(progress: @escaping (String) -> Void) {
        self.progress = progress
    }

    func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let newlineRange = buffer.firstRange(of: Data([0x0A])) {
            let lineData = buffer[..<newlineRange.lowerBound]
            buffer.removeSubrange(..<newlineRange.upperBound)
            if let line = String(data: Data(lineData), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !line.isEmpty {
                lines.append(line)
            }
        }
        lock.unlock()

        for line in lines {
            handle(line)
        }
    }

    func finish() {
        lock.lock()
        let remaining = buffer
        buffer.removeAll()
        lock.unlock()

        if let line = String(data: remaining, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !line.isEmpty {
            handle(line)
        }
    }

    private func handle(_ line: String) {
        guard let data = line.data(using: .utf8),
              let event = try? JSONDecoder().decode(CodexAnalyticsCLIProgress.self, from: data),
              event.type == "progress"
        else {
            lock.lock()
            errorLines.append(line)
            lock.unlock()
            return
        }
        progress(event.message)
    }
}

private final class DataReader {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func consume(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }
}

private struct CodexAnalyticsCLIProgress: Decodable {
    var type: String
    var phase: String
    var scanned: Int
    var total: Int
    var cacheHits: Int
    var parsed: Int
    var skipped: Int

    var message: String {
        switch phase {
        case "discovering":
            return "Discovering Codex JSONL sessions..."
        case "complete":
            return "Analyzed \(scanned) of \(total) sessions. Cache hits: \(cacheHits), parsed: \(parsed), skipped: \(skipped)."
        default:
            guard total > 0 else {
                return "Preparing Codex analytics scan..."
            }
            let percent = Int((Double(scanned) / Double(total) * 100).rounded())
            return "Analyzing \(scanned) of \(total) sessions (\(percent)%). Cache hits: \(cacheHits), parsed: \(parsed), skipped: \(skipped)."
        }
    }
}
