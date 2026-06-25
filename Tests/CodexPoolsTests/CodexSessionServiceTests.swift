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
        XCTAssertEqual(result.sessions[0].threadID, "thread-1")
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

    func testCopySessionsCopiesRolloutAndRepairsIndex() throws {
        let sourceHome = try makeTemporaryDirectory()
        let targetHome = try makeTemporaryDirectory()
        let sourceRollout = sourceHome
            .appendingPathComponent("sessions/2026/06/26", isDirectory: true)
            .appendingPathComponent("rollout-thread-copy.jsonl")
        try writeRollout(
            at: sourceRollout,
            threadID: "thread-copy",
            title: "Copied Session",
            timestamp: "2026-06-26T03:04:05Z"
        )
        let source = CodexInstance(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "Source",
            codexHome: sourceHome.path
        )
        let target = CodexInstance(
            id: UUID(uuidString: "66666666-7777-8888-9999-000000000000")!,
            name: "Target",
            codexHome: targetHome.path
        )
        let service = CodexSessionService()
        let scanned = service.scanSessions(for: [source])

        let summary = try service.copySessions(
            sessionIDs: Set(scanned.sessions.map(\.id)),
            to: target,
            from: [source, target]
        )

        XCTAssertEqual(summary.requestedSessionCount, 1)
        XCTAssertEqual(summary.copiedSessionCount, 1)
        XCTAssertEqual(summary.skippedSessionCount, 0)
        XCTAssertEqual(summary.missingSessionCount, 0)
        XCTAssertNil(summary.backupDirectory)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: targetHome.appendingPathComponent("sessions/2026/06/26/rollout-thread-copy.jsonl").path
        ))

        let repairedIndex = try String(
            contentsOf: targetHome.appendingPathComponent("session_index.jsonl"),
            encoding: .utf8
        )
        XCTAssertTrue(repairedIndex.contains(#""id":"thread-copy""#))
        XCTAssertTrue(repairedIndex.contains(#""thread_name":"Copied Session""#))
    }

    func testCopySessionsBacksUpOverwrittenTargetFiles() throws {
        let sourceHome = try makeTemporaryDirectory()
        let targetHome = try makeTemporaryDirectory()
        let relativePath = "sessions/2026/06/26/rollout-thread-copy.jsonl"
        try writeRollout(
            at: sourceHome.appendingPathComponent(relativePath),
            threadID: "thread-copy",
            title: "Copied Session",
            timestamp: "2026-06-26T03:04:05Z"
        )
        try writeRollout(
            at: targetHome.appendingPathComponent(relativePath),
            threadID: "thread-copy",
            title: "Old Session",
            timestamp: "2026-06-25T03:04:05Z"
        )
        try #"{"id":"thread-copy","thread_name":"Old Session"}"#
            .appending("\n")
            .write(
                to: targetHome.appendingPathComponent("session_index.jsonl"),
                atomically: true,
                encoding: .utf8
            )

        let source = CodexInstance(name: "Source", codexHome: sourceHome.path)
        let target = CodexInstance(name: "Target", codexHome: targetHome.path)
        let service = CodexSessionService()
        let scanned = service.scanSessions(for: [source])

        let summary = try service.copySessions(
            sessionIDs: Set(scanned.sessions.map(\.id)),
            to: target,
            from: [source, target]
        )

        let backupDirectory = try XCTUnwrap(summary.backupDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: backupDirectory)
            .appendingPathComponent(relativePath)
            .path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: backupDirectory)
            .appendingPathComponent("session_index.jsonl")
            .path))

        let copiedContent = try String(
            contentsOf: targetHome.appendingPathComponent(relativePath),
            encoding: .utf8
        )
        XCTAssertTrue(copiedContent.contains("Copied Session"))
    }

    func testRepairSessionIndexBuildsIndexFromRollouts() throws {
        let home = try makeTemporaryDirectory()
        try writeRollout(
            at: home.appendingPathComponent("sessions/2026/06/26/rollout-thread-repair.jsonl"),
            threadID: "thread-repair",
            title: "Repair Me",
            timestamp: "2026-06-26T04:05:06Z"
        )
        let instance = CodexInstance(name: "Repair", codexHome: home.path)

        let summary = try CodexSessionService().repairSessionIndex(for: instance)

        XCTAssertEqual(summary.indexedSessionCount, 1)
        let index = try String(contentsOf: home.appendingPathComponent("session_index.jsonl"), encoding: .utf8)
        XCTAssertTrue(index.contains(#""id":"thread-repair""#))
        XCTAssertTrue(index.contains(#""rollout_path":"sessions\/2026\/06\/26\/rollout-thread-repair.jsonl""#))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-pools-session-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    private func writeRollout(
        at url: URL,
        threadID: String,
        title: String,
        timestamp: String
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {"type":"session_meta","payload":{"id":"\(threadID)","thread_name":"\(title)","cwd":"/repo/\(threadID)"}}
        {"type":"event","timestamp":"\(timestamp)","payload":{"text":"hello"}}

        """.write(to: url, atomically: true, encoding: .utf8)
    }
}
