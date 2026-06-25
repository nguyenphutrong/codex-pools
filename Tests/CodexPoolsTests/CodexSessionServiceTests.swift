import Foundation
import XCTest
@testable import CodexPools

final class CodexSessionServiceTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs = []
        try super.tearDownWithError()
    }

    func testScanSessionsReadsRolloutsAndSessionIndex() throws {
        let home = try makeTemporaryDirectory()
        let rolloutURL = home
            .appendingPathComponent("sessions/2026/06/26", isDirectory: true)
            .appendingPathComponent("rollout-thread-1.jsonl")
        try FileManager.default.createDirectory(
            at: rolloutURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {"type":"session_meta","payload":{"id":"thread-1","cwd":"/repo/app"}}
        {"type":"event","timestamp":"2026-06-26T01:02:03Z","payload":{"text":"hello"}}

        """.write(to: rolloutURL, atomically: true, encoding: .utf8)
        try """
        {"id":"thread-1","thread_name":"Fix checkout bug","updated_at":"2026-06-26T02:03:04Z"}

        """.write(
            to: home.appendingPathComponent("session_index.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let instance = CodexInstance(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "Work",
            codexHome: home.path
        )

        let result = CodexSessionService().scanSessions(for: [instance])

        XCTAssertEqual(result.skippedFileCount, 0)
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions[0].id, "\(instance.id.uuidString):thread-1")
        XCTAssertEqual(result.sessions[0].title, "Fix checkout bug")
        XCTAssertEqual(result.sessions[0].workspacePath, "/repo/app")
        XCTAssertEqual(result.sessions[0].relativeRolloutPath, "sessions/2026/06/26/rollout-thread-1.jsonl")
        XCTAssertFalse(result.sessions[0].isArchived)
    }

    func testScanSessionsFallsBackAndSkipsInvalidRollouts() throws {
        let home = try makeTemporaryDirectory()
        let archivedURL = home
            .appendingPathComponent("archived_sessions/2026/06/26", isDirectory: true)
            .appendingPathComponent("rollout-thread-2.jsonl")
        let invalidURL = home
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("rollout-invalid.jsonl")
        try FileManager.default.createDirectory(
            at: archivedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: invalidURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {"type":"session_meta","payload":{"id":"thread-2"}}
        {"type":"event","timestamp":1782445323000}

        """.write(to: archivedURL, atomically: true, encoding: .utf8)
        try #"{"type":"event"}"#.write(to: invalidURL, atomically: true, encoding: .utf8)

        let instance = CodexInstance(name: "Archive", codexHome: home.path)
        let result = CodexSessionService().scanSessions(for: [instance])

        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.skippedFileCount, 1)
        XCTAssertEqual(result.sessions[0].title, "thread-2")
        XCTAssertTrue(result.sessions[0].isArchived)
        XCTAssertEqual(result.sessions[0].lineCount, 2)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-pools-session-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }
}
