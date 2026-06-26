import Foundation

struct CodexSessionService {
    private let fileManager: FileManager
    private let iso8601Formatter = ISO8601DateFormatter()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func scanSessions(for instances: [CodexInstance]) -> CodexSessionScanResult {
        var sessions: [CodexSessionThread] = []
        var skippedFileCount = 0

        for instance in instances {
            let homeURL = codexHomeURL(for: instance)
            let index = readSessionIndexMap(in: homeURL)

            for directoryName in SessionDirectory.allCases {
                let rootURL = homeURL.appendingPathComponent(directoryName.rawValue, isDirectory: true)
                guard fileManager.fileExists(atPath: rootURL.path) else { continue }

                for rolloutURL in listRolloutFiles(under: rootURL) {
                    guard let thread = readThread(
                        rolloutURL: rolloutURL,
                        sessionDirectory: directoryName,
                        homeURL: homeURL,
                        instance: instance,
                        index: index
                    ) else {
                        skippedFileCount += 1
                        continue
                    }
                    sessions.append(thread)
                }
            }
        }

        sessions.sort { left, right in
            switch (left.updatedAt, right.updatedAt) {
            case let (leftDate?, rightDate?) where leftDate != rightDate:
                return leftDate > rightDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
            }
        }

        return CodexSessionScanResult(sessions: sessions, skippedFileCount: skippedFileCount)
    }

    func copySessions(
        sessionIDs: Set<CodexSessionThread.ID>,
        to targetInstance: CodexInstance,
        from instances: [CodexInstance]
    ) throws -> CodexSessionCopySummary {
        let requestedSessionCount = sessionIDs.count
        guard requestedSessionCount > 0 else {
            return CodexSessionCopySummary(
                requestedSessionCount: 0,
                copiedSessionCount: 0,
                skippedSessionCount: 0,
                missingSessionCount: 0,
                backupDirectory: nil
            )
        }

        let scan = scanSessions(for: instances)
        let sessionsByID = Dictionary(uniqueKeysWithValues: scan.sessions.map { ($0.id, $0) })
        let targetHomeURL = codexHomeURL(for: targetInstance)
        var copiedSessions: [CodexSessionThread] = []
        var skippedSessionCount = 0
        var missingSessionCount = 0
        var backupDirectory: URL?

        for id in sessionIDs {
            guard let session = sessionsByID[id] else {
                missingSessionCount += 1
                continue
            }
            guard session.instanceID != targetInstance.id else {
                skippedSessionCount += 1
                continue
            }

            let sourceURL = URL(fileURLWithPath: session.rolloutPath)
            let targetURL = targetHomeURL.appendingPathComponent(session.relativeRolloutPath)
            if pathsPointToSameFile(sourceURL, targetURL) {
                skippedSessionCount += 1
                continue
            }

            try copyRollout(
                session: session,
                to: targetURL,
                targetHomeURL: targetHomeURL,
                backupDirectory: &backupDirectory,
                shouldBackupExisting: fileManager.fileExists(atPath: targetURL.path)
            )

            var copied = session
            copied.instanceID = targetInstance.id
            copied.instanceName = targetInstance.managedAppName
            copied.codexHome = targetHomeURL.path
            copied.rolloutPath = targetURL.path
            copied.id = sessionDisplayID(
                instanceID: targetInstance.id,
                threadID: session.threadID,
                relativeRolloutPath: copied.relativeRolloutPath
            )
            copiedSessions.append(copied)
        }

        if !copiedSessions.isEmpty {
            let repairSummary = try repairSessionIndex(
                for: targetInstance,
                preferredSessions: copiedSessions,
                existingBackupDirectory: backupDirectory
            )
            backupDirectory = repairSummary.backupDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
        }

        return CodexSessionCopySummary(
            requestedSessionCount: requestedSessionCount,
            copiedSessionCount: copiedSessions.count,
            skippedSessionCount: skippedSessionCount,
            missingSessionCount: missingSessionCount,
            backupDirectory: backupDirectory?.path
        )
    }

    func syncSessionsAcrossIdleInstances(
        _ instances: [CodexInstance],
        runningInstanceIDs: Set<CodexInstance.ID>
    ) throws -> CodexSessionSyncSummary {
        let idleInstances = instances.filter { !runningInstanceIDs.contains($0.id) }
        let skippedRunningInstanceCount = instances.count - idleInstances.count
        guard idleInstances.count >= 2 else {
            return CodexSessionSyncSummary(
                instanceCount: instances.count,
                threadUniverseCount: 0,
                mutatedInstanceCount: 0,
                addedSessionCount: 0,
                updatedSessionCount: 0,
                skippedRunningInstanceCount: skippedRunningInstanceCount,
                items: []
            )
        }

        let sessions = scanSessions(for: idleInstances).sessions
        let bestByThreadID = bestSessionsByThreadID(sessions)
        let sessionsByInstanceID = Dictionary(grouping: sessions, by: \.instanceID)
        var items: [CodexSessionSyncItem] = []
        var totalAdded = 0
        var totalUpdated = 0

        for target in idleInstances {
            let targetSessions = bestSessionsByThreadID(sessionsByInstanceID[target.id] ?? [])
            var added = 0
            var updated = 0
            var syncedSessions: [CodexSessionThread] = []
            var backupDirectory: URL?
            let targetHomeURL = codexHomeURL(for: target)

            for threadID in bestByThreadID.keys.sorted() {
                guard let best = bestByThreadID[threadID],
                      best.instanceID != target.id
                else {
                    continue
                }

                if let existing = targetSessions[threadID] {
                    guard isSession(best, fresherThan: existing) else { continue }
                    let targetURL = targetHomeURL.appendingPathComponent(existing.relativeRolloutPath)
                    try copyRollout(
                        session: best,
                        to: targetURL,
                        targetHomeURL: targetHomeURL,
                        backupDirectory: &backupDirectory,
                        shouldBackupExisting: true
                    )
                    updated += 1
                    syncedSessions.append(retargeted(best, to: target, targetURL: targetURL))
                } else {
                    let targetURL = targetHomeURL.appendingPathComponent(best.relativeRolloutPath)
                    try copyRollout(
                        session: best,
                        to: targetURL,
                        targetHomeURL: targetHomeURL,
                        backupDirectory: &backupDirectory,
                        shouldBackupExisting: fileManager.fileExists(atPath: targetURL.path)
                    )
                    added += 1
                    syncedSessions.append(retargeted(best, to: target, targetURL: targetURL))
                }
            }

            if added > 0 || updated > 0 {
                let repairSummary = try repairSessionIndex(
                    for: target,
                    preferredSessions: syncedSessions,
                    existingBackupDirectory: backupDirectory
                )
                backupDirectory = repairSummary.backupDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
                totalAdded += added
                totalUpdated += updated
                items.append(CodexSessionSyncItem(
                    instanceID: target.id,
                    instanceName: target.managedAppName,
                    addedSessionCount: added,
                    updatedSessionCount: updated,
                    backupDirectory: backupDirectory?.path
                ))
            }
        }

        return CodexSessionSyncSummary(
            instanceCount: instances.count,
            threadUniverseCount: bestByThreadID.count,
            mutatedInstanceCount: items.count,
            addedSessionCount: totalAdded,
            updatedSessionCount: totalUpdated,
            skippedRunningInstanceCount: skippedRunningInstanceCount,
            items: items
        )
    }

    @discardableResult
    func repairSessionIndex(
        for instance: CodexInstance,
        preferredSessions: [CodexSessionThread] = [],
        existingBackupDirectory: URL? = nil
    ) throws -> CodexSessionRepairSummary {
        let homeURL = codexHomeURL(for: instance)
        let scan = scanSessions(for: [instance])
        let preferredByThreadID = Dictionary(uniqueKeysWithValues: preferredSessions.map { ($0.threadID, $0) })
        let sessions = scan.sessions.map { preferredByThreadID[$0.threadID] ?? $0 }
        let indexURL = homeURL.appendingPathComponent("session_index.jsonl")
        var backupDirectory = existingBackupDirectory

        if fileManager.fileExists(atPath: indexURL.path) {
            let backupRoot = try ensureBackupDirectory(&backupDirectory, targetHomeURL: homeURL)
            try backupExistingFile(indexURL, rootURL: homeURL, backupDirectory: backupRoot)
        }

        let lines = sessions
            .sorted { $0.threadID < $1.threadID }
            .compactMap(sessionIndexLine)
            .joined(separator: "\n")
        let content = lines.isEmpty ? "" : "\(lines)\n"
        try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
        try content.write(to: indexURL, atomically: true, encoding: .utf8)

        return CodexSessionRepairSummary(
            instanceID: instance.id,
            indexedSessionCount: sessions.count,
            backupDirectory: backupDirectory?.path
        )
    }

    private func codexHomeURL(for instance: CodexInstance) -> URL {
        URL(fileURLWithPath: NSString(string: instance.codexHome).expandingTildeInPath, isDirectory: true)
    }

    private func listRolloutFiles(under rootURL: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true
            else {
                continue
            }

            let fileName = url.lastPathComponent
            if fileName.hasPrefix("rollout-") && fileName.hasSuffix(".jsonl") {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private func readThread(
        rolloutURL: URL,
        sessionDirectory: SessionDirectory,
        homeURL: URL,
        instance: CodexInstance,
        index: [String: [String: Any]]
    ) -> CodexSessionThread? {
        guard let firstLine = try? firstNonEmptyLine(in: rolloutURL),
              let metadata = decodeJSONObject(firstLine),
              metadata["type"] as? String == "session_meta",
              let threadID = sessionID(in: metadata)
        else {
            return nil
        }

        let indexEntry = index[threadID]
        let attributes = (try? fileManager.attributesOfItem(atPath: rolloutURL.path)) ?? [:]
        let title = title(in: indexEntry) ?? title(in: metadata) ?? threadID
        let updatedAt = updatedAt(in: indexEntry)
            ?? (attributes[.modificationDate] as? Date)

        let relativeRolloutPath = relativePath(from: homeURL, to: rolloutURL)
        return CodexSessionThread(
            id: sessionDisplayID(
                instanceID: instance.id,
                threadID: threadID,
                relativeRolloutPath: relativeRolloutPath
            ),
            threadID: threadID,
            instanceID: instance.id,
            instanceName: instance.managedAppName,
            codexHome: homeURL.path,
            title: title,
            workspacePath: workspacePath(in: metadata),
            rolloutPath: rolloutURL.path,
            relativeRolloutPath: relativeRolloutPath,
            updatedAt: updatedAt,
            byteCount: fileSize(in: attributes),
            lineCount: lineCount(in: indexEntry),
            isArchived: sessionDirectory == .archived
        )
    }

    private func firstNonEmptyLine(in url: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        var pending = Data()
        while true {
            let chunk = handle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty {
                return trimmedLine(from: pending)
            }

            pending.append(chunk)
            while let newlineRange = pending.firstRange(of: Data([0x0A])) {
                let lineData = pending[..<newlineRange.lowerBound]
                pending.removeSubrange(..<newlineRange.upperBound)

                if let line = trimmedLine(from: Data(lineData)) {
                    return line
                }
            }
        }
    }

    private func trimmedLine(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let line = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }

    private func readSessionIndexMap(in homeURL: URL) -> [String: [String: Any]] {
        let indexURL = homeURL.appendingPathComponent("session_index.jsonl")
        guard let content = try? String(contentsOf: indexURL, encoding: .utf8) else {
            return [:]
        }

        var map: [String: [String: Any]] = [:]
        for line in content.split(whereSeparator: \.isNewline).map(String.init) {
            guard let object = decodeJSONObject(line),
                  let id = stringValue(object["id"])
                    ?? stringValue(object["session_id"])
                    ?? stringValue(object["thread_id"])
            else {
                continue
            }
            map[id] = object
        }
        return map
    }

    private func decodeJSONObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private func sessionID(in metadata: [String: Any]) -> String? {
        if let payload = metadata["payload"] as? [String: Any] {
            return stringValue(payload["id"]) ?? stringValue(payload["session_id"])
        }
        return stringValue(metadata["id"]) ?? stringValue(metadata["session_id"])
    }

    private func workspacePath(in metadata: [String: Any]) -> String? {
        if let payload = metadata["payload"] as? [String: Any] {
            return stringValue(payload["cwd"])
        }
        return stringValue(metadata["cwd"])
    }

    private func title(in object: [String: Any]?) -> String? {
        guard let object else { return nil }
        if let payload = object["payload"] as? [String: Any],
           let payloadTitle = title(in: payload) {
            return payloadTitle
        }
        for key in ["thread_name", "threadName", "title", "name"] {
            if let value = stringValue(object[key])?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func updatedAt(in object: [String: Any]?) -> Date? {
        guard let object else { return nil }
        for key in ["updated_at", "updatedAt", "last_updated_at", "lastUpdatedAt"] {
            if let date = dateValue(object[key]) {
                return date
            }
        }
        return nil
    }

    private func lineCount(in object: [String: Any]?) -> Int {
        guard let object else { return 0 }
        for key in ["line_count", "lineCount"] {
            if let number = object[key] as? NSNumber {
                return number.intValue
            }
            if let text = object[key] as? String,
               let count = Int(text) {
                return count
            }
        }
        return 0
    }

    private func fileModifiedAt(_ url: URL) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private func fileSize(in attributes: [FileAttributeKey: Any]) -> Int {
        if let number = attributes[.size] as? NSNumber {
            return number.intValue
        }
        if let size = attributes[.size] as? Int {
            return size
        }
        return 0
    }

    private func dateValue(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: normalizedMilliseconds(number.int64Value) / 1_000)
        }
        if let text = value as? String {
            if let date = iso8601Formatter.date(from: text) {
                return date
            }
            if let integer = Int64(text) {
                return Date(timeIntervalSince1970: normalizedMilliseconds(integer) / 1_000)
            }
        }
        return nil
    }

    private func normalizedMilliseconds(_ timestamp: Int64) -> TimeInterval {
        if timestamp > 10_000_000_000_000 {
            return TimeInterval(timestamp / 1_000)
        }
        if timestamp > 10_000_000_000 {
            return TimeInterval(timestamp)
        }
        return TimeInterval(timestamp * 1_000)
    }

    private func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            return value
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private func relativePath(from rootURL: URL, to fileURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return fileURL.lastPathComponent }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    private func bestSessionsByThreadID(_ sessions: [CodexSessionThread]) -> [String: CodexSessionThread] {
        sessions.reduce(into: [:]) { result, session in
            guard let existing = result[session.threadID] else {
                result[session.threadID] = session
                return
            }
            if isSession(session, fresherThan: existing) {
                result[session.threadID] = session
            }
        }
    }

    private func isSession(_ candidate: CodexSessionThread, fresherThan existing: CodexSessionThread) -> Bool {
        switch (candidate.updatedAt, existing.updatedAt) {
        case let (candidateDate?, existingDate?) where candidateDate != existingDate:
            return candidateDate > existingDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            if candidate.byteCount != existing.byteCount {
                return candidate.byteCount > existing.byteCount
            }
            return candidate.lineCount > existing.lineCount
        }
    }

    private func retargeted(
        _ session: CodexSessionThread,
        to target: CodexInstance,
        targetURL: URL
    ) -> CodexSessionThread {
        var retargeted = session
        let targetHomeURL = codexHomeURL(for: target)
        retargeted.instanceID = target.id
        retargeted.instanceName = target.managedAppName
        retargeted.codexHome = targetHomeURL.path
        retargeted.rolloutPath = targetURL.path
        retargeted.relativeRolloutPath = relativePath(from: targetHomeURL, to: targetURL)
        retargeted.id = sessionDisplayID(
            instanceID: target.id,
            threadID: session.threadID,
            relativeRolloutPath: retargeted.relativeRolloutPath
        )
        return retargeted
    }

    private func sessionDisplayID(
        instanceID: CodexInstance.ID,
        threadID: String,
        relativeRolloutPath: String
    ) -> String {
        "\(instanceID.uuidString):\(threadID):\(relativeRolloutPath)"
    }

    private func copyRollout(
        session: CodexSessionThread,
        to targetURL: URL,
        targetHomeURL: URL,
        backupDirectory: inout URL?,
        shouldBackupExisting: Bool
    ) throws {
        let sourceURL = URL(fileURLWithPath: session.rolloutPath)
        if shouldBackupExisting, fileManager.fileExists(atPath: targetURL.path) {
            let backupRoot = try ensureBackupDirectory(&backupDirectory, targetHomeURL: targetHomeURL)
            try backupExistingFile(targetURL, rootURL: targetHomeURL, backupDirectory: backupRoot)
            try fileManager.removeItem(at: targetURL)
        }

        try fileManager.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: targetURL.path) {
            try fileManager.removeItem(at: targetURL)
        }
        try fileManager.copyItem(at: sourceURL, to: targetURL)
        restoreModifiedDate(from: sourceURL, to: targetURL)
    }

    private func ensureBackupDirectory(_ backupDirectory: inout URL?, targetHomeURL: URL) throws -> URL {
        if let backupDirectory {
            return backupDirectory
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = targetHomeURL
            .appendingPathComponent(".codex-pools", isDirectory: true)
            .appendingPathComponent("session-backups", isDirectory: true)
            .appendingPathComponent("\(formatter.string(from: Date()))-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        backupDirectory = directory
        return directory
    }

    private func backupExistingFile(_ fileURL: URL, rootURL: URL, backupDirectory: URL) throws {
        let backupURL = backupDirectory.appendingPathComponent(relativePath(from: rootURL, to: fileURL))
        try fileManager.createDirectory(
            at: backupURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }
        try fileManager.copyItem(at: fileURL, to: backupURL)
        restoreModifiedDate(from: fileURL, to: backupURL)
    }

    private func restoreModifiedDate(from sourceURL: URL, to targetURL: URL) {
        guard let modifiedAt = fileModifiedAt(sourceURL) else { return }
        try? fileManager.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: targetURL.path)
    }

    private func pathsPointToSameFile(_ left: URL, _ right: URL) -> Bool {
        if left.standardizedFileURL.path == right.standardizedFileURL.path {
            return true
        }
        guard let leftResolved = try? left.resolvingSymlinksInPath().resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let rightResolved = try? right.resolvingSymlinksInPath().resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        else {
            return false
        }
        return String(describing: leftResolved) == String(describing: rightResolved)
    }

    private func sessionIndexLine(for session: CodexSessionThread) -> String? {
        var object: [String: Any] = [
            "id": session.threadID,
            "thread_name": session.title,
            "rollout_path": session.relativeRolloutPath
        ]
        if let workspacePath = session.workspacePath {
            object["cwd"] = workspacePath
        }
        if let updatedAt = session.updatedAt {
            object["updated_at"] = iso8601Formatter.string(from: updatedAt)
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

private enum SessionDirectory: String, CaseIterable {
    case sessions
    case archived = "archived_sessions"
}
