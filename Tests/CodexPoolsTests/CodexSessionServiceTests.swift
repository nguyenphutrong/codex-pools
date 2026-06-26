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
        XCTAssertEqual(result.sessions[0].id, "\(instance.id.uuidString):thread-1:sessions/2026/06/26/rollout-thread-1.jsonl")
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
        XCTAssertEqual(result.sessions[0].lineCount, 0)
    }

    func testScanSessionsFallsBackToFileMetadataWithoutReadingFullRollout() throws {
        let home = try makeTemporaryDirectory()
        let rolloutURL = home
            .appendingPathComponent("sessions/2026/06/26", isDirectory: true)
            .appendingPathComponent("rollout-large.jsonl")
        try FileManager.default.createDirectory(
            at: rolloutURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let content = """
        {"type":"session_meta","payload":{"id":"large","cwd":"/repo/large"}}
        \(String(repeating: "x", count: 512 * 1024))

        """
        try content.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let modifiedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-25T08:09:10Z"))
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: rolloutURL.path)

        let instance = CodexInstance(name: "Large", codexHome: home.path)
        let result = CodexSessionService().scanSessions(for: [instance])

        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions[0].threadID, "large")
        XCTAssertEqual(result.sessions[0].byteCount, content.utf8.count)
        XCTAssertEqual(result.sessions[0].updatedAt, modifiedAt)
    }

    func testScanSessionsKeepsDuplicateThreadIDsWithDifferentRolloutPaths() throws {
        let home = try makeTemporaryDirectory()
        try writeRollout(
            at: home.appendingPathComponent("sessions/2026/06/26/rollout-one.jsonl"),
            threadID: "duplicate",
            title: "Duplicate One",
            timestamp: "2026-06-26T03:00:00Z"
        )
        try writeRollout(
            at: home.appendingPathComponent("archived_sessions/2026/06/27/rollout-two.jsonl"),
            threadID: "duplicate",
            title: "Duplicate Two",
            timestamp: "2026-06-27T03:00:00Z"
        )
        let instance = CodexInstance(name: "Duplicates", codexHome: home.path)

        let result = CodexSessionService().scanSessions(for: [instance])

        XCTAssertEqual(result.sessions.count, 2)
        XCTAssertEqual(Set(result.sessions.map(\.threadID)), ["duplicate"])
        XCTAssertEqual(Set(result.sessions.map(\.id)).count, 2)
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

    func testSyncSessionsAcrossIdleInstancesAddsMissingAndUpdatesStaleSessions() throws {
        let firstHome = try makeTemporaryDirectory()
        let secondHome = try makeTemporaryDirectory()
        let thirdHome = try makeTemporaryDirectory()
        let sharedPath = "sessions/2026/06/26/rollout-shared.jsonl"
        try writeRollout(
            at: firstHome.appendingPathComponent(sharedPath),
            threadID: "shared",
            title: "Shared New",
            timestamp: "2026-06-26T05:00:00Z"
        )
        try writeRollout(
            at: secondHome.appendingPathComponent(sharedPath),
            threadID: "shared",
            title: "Shared Old",
            timestamp: "2026-06-25T05:00:00Z"
        )
        try writeRollout(
            at: firstHome.appendingPathComponent("sessions/2026/06/26/rollout-only-first.jsonl"),
            threadID: "only-first",
            title: "Only First",
            timestamp: "2026-06-26T06:00:00Z"
        )

        let first = CodexInstance(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "First",
            codexHome: firstHome.path
        )
        let second = CodexInstance(
            id: UUID(uuidString: "66666666-7777-8888-9999-000000000000")!,
            name: "Second",
            codexHome: secondHome.path
        )
        let third = CodexInstance(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Third",
            codexHome: thirdHome.path
        )

        let summary = try CodexSessionService().syncSessionsAcrossIdleInstances(
            [first, second, third],
            runningInstanceIDs: []
        )

        XCTAssertEqual(summary.threadUniverseCount, 2)
        XCTAssertEqual(summary.mutatedInstanceCount, 2)
        XCTAssertEqual(summary.addedSessionCount, 3)
        XCTAssertEqual(summary.updatedSessionCount, 1)
        XCTAssertEqual(summary.skippedRunningInstanceCount, 0)

        let secondShared = try String(contentsOf: secondHome.appendingPathComponent(sharedPath), encoding: .utf8)
        XCTAssertTrue(secondShared.contains("Shared New"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: secondHome.appendingPathComponent("sessions/2026/06/26/rollout-only-first.jsonl").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: thirdHome.appendingPathComponent(sharedPath).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: thirdHome.appendingPathComponent("sessions/2026/06/26/rollout-only-first.jsonl").path
        ))
    }

    func testSyncSessionsAcrossIdleInstancesSkipsRunningInstances() throws {
        let firstHome = try makeTemporaryDirectory()
        let secondHome = try makeTemporaryDirectory()
        try writeRollout(
            at: firstHome.appendingPathComponent("sessions/2026/06/26/rollout-thread.jsonl"),
            threadID: "thread",
            title: "Thread",
            timestamp: "2026-06-26T05:00:00Z"
        )
        let first = CodexInstance(name: "First", codexHome: firstHome.path)
        let second = CodexInstance(name: "Second", codexHome: secondHome.path)

        let summary = try CodexSessionService().syncSessionsAcrossIdleInstances(
            [first, second],
            runningInstanceIDs: [second.id]
        )

        XCTAssertEqual(summary.skippedRunningInstanceCount, 1)
        XCTAssertEqual(summary.mutatedInstanceCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: secondHome.appendingPathComponent("sessions/2026/06/26/rollout-thread.jsonl").path
        ))
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

        if let modifiedAt = ISO8601DateFormatter().date(from: timestamp) {
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        }
    }
}
