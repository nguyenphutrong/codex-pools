import Foundation

struct CodexSessionService {
    private static let analyticsDetailedSessionLimit = 250
    private static let analyticsDetailedByteLimit = 64 * 1024 * 1024

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

    func scanAnalytics(for instances: [CodexInstance]) -> CodexAnalyticsScanResult {
        var candidates: [AnalyticsCandidate] = []
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
                    candidates.append(AnalyticsCandidate(
                        thread: thread,
                        rolloutURL: rolloutURL,
                        sessionDirectory: directoryName,
                        homeURL: homeURL,
                        instance: instance,
                        index: index
                    ))
                }
            }
        }

        candidates.sort { left, right in
            switch (left.thread.updatedAt, right.thread.updatedAt) {
            case let (leftDate?, rightDate?) where leftDate != rightDate:
                return leftDate > rightDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return left.thread.byteCount > right.thread.byteCount
            }
        }

        var sessions: [CodexSessionAnalytics] = []
        var detailedCount = 0
        var detailedBytes = 0
        for candidate in candidates {
            let shouldParseDetails = detailedCount < Self.analyticsDetailedSessionLimit
                && detailedBytes + candidate.thread.byteCount <= Self.analyticsDetailedByteLimit

            if shouldParseDetails,
               let session = readAnalytics(candidate) {
                sessions.append(session)
                detailedCount += 1
                detailedBytes += candidate.thread.byteCount
            } else {
                sessions.append(lightweightAnalytics(from: candidate.thread))
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

        return CodexAnalyticsScanResult(
            snapshot: buildAnalyticsSnapshot(from: sessions),
            skippedFileCount: skippedFileCount
        )
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

    private func readAnalytics(
        _ candidate: AnalyticsCandidate
    ) -> CodexSessionAnalytics? {
        readAnalytics(
            thread: candidate.thread,
            rolloutURL: candidate.rolloutURL,
            homeURL: candidate.homeURL,
            index: candidate.index
        )
    }

    private func readAnalytics(
        rolloutURL: URL,
        sessionDirectory: SessionDirectory,
        homeURL: URL,
        instance: CodexInstance,
        index: [String: [String: Any]]
    ) -> CodexSessionAnalytics? {
        guard let thread = readThread(
            rolloutURL: rolloutURL,
            sessionDirectory: sessionDirectory,
            homeURL: homeURL,
            instance: instance,
            index: index
        ) else {
            return nil
        }

        return readAnalytics(
            thread: thread,
            rolloutURL: rolloutURL,
            homeURL: homeURL,
            index: index
        )
    }

    private func readAnalytics(
        thread: CodexSessionThread,
        rolloutURL: URL,
        homeURL: URL,
        index: [String: [String: Any]]
    ) -> CodexSessionAnalytics? {
        guard let firstLine = try? firstNonEmptyLine(in: rolloutURL),
              let metadata = decodeJSONObject(firstLine),
              let payload = metadata["payload"] as? [String: Any]
        else {
            return nil
        }

        var parser = RolloutAnalyticsParser(service: self)
        do {
            try forEachNonEmptyLine(in: rolloutURL) { line in
                guard let object = decodeJSONObject(line) else { return }
                parser.consume(object)
            }
        } catch {
            return nil
        }

        let attributes = (try? fileManager.attributesOfItem(atPath: rolloutURL.path)) ?? [:]
        let parsed = parser.finish()
        let title = title(in: index[thread.threadID])
            ?? parsed.firstUserTitle
            ?? title(in: metadata)
            ?? thread.threadID
        let createdAt = dateValue(payload["timestamp"])
            ?? (attributes[.creationDate] as? Date)
        let updatedAt = thread.updatedAt
            ?? parsed.lastEventAt
            ?? (attributes[.modificationDate] as? Date)

        let estimatedCost = parsed.modelUsage.reduce(into: 0.0) { total, item in
            total += CodexModelPricing.estimatedCost(for: item.key, usage: item.value) ?? 0
        }
        let hasPricedModel = parsed.modelUsage.contains { CodexModelPricing.price(for: $0.key) != nil }

        return CodexSessionAnalytics(
            id: thread.id,
            threadID: thread.threadID,
            instanceID: thread.instanceID,
            instanceName: thread.instanceName,
            codexHome: thread.codexHome,
            title: title,
            workspacePath: thread.workspacePath,
            rolloutPath: thread.rolloutPath,
            relativeRolloutPath: thread.relativeRolloutPath,
            createdAt: createdAt,
            updatedAt: updatedAt,
            isArchived: thread.isArchived,
            source: stringValue(payload["source"]),
            originator: stringValue(payload["originator"]),
            cliVersion: stringValue(payload["cli_version"]),
            modelProvider: stringValue(payload["model_provider"]),
            userMessageCount: parsed.userMessageCount,
            assistantMessageCount: parsed.assistantMessageCount,
            systemMessageCount: parsed.systemMessageCount,
            userCharacterCount: parsed.userCharacterCount,
            assistantCharacterCount: parsed.assistantCharacterCount,
            tokenUsage: parsed.tokenUsage,
            models: parsed.models,
            toolCalls: parsed.toolCalls
                .map { CodexToolCallSummary(name: $0.key, count: $0.value) }
                .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count },
            estimatedCost: hasPricedModel ? estimatedCost : nil
        )
    }

    private func lightweightAnalytics(from thread: CodexSessionThread) -> CodexSessionAnalytics {
        CodexSessionAnalytics(
            id: thread.id,
            threadID: thread.threadID,
            instanceID: thread.instanceID,
            instanceName: thread.instanceName,
            codexHome: thread.codexHome,
            title: thread.title,
            workspacePath: thread.workspacePath,
            rolloutPath: thread.rolloutPath,
            relativeRolloutPath: thread.relativeRolloutPath,
            createdAt: nil,
            updatedAt: thread.updatedAt,
            isArchived: thread.isArchived,
            source: nil,
            originator: nil,
            cliVersion: nil,
            modelProvider: nil,
            userMessageCount: 0,
            assistantMessageCount: 0,
            systemMessageCount: 0,
            userCharacterCount: 0,
            assistantCharacterCount: 0,
            tokenUsage: .zero,
            models: [],
            toolCalls: [],
            estimatedCost: nil
        )
    }

    private func forEachNonEmptyLine(in url: URL, _ body: (String) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        var pending = Data()
        while true {
            let chunk = handle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty {
                if let line = trimmedLine(from: pending) {
                    body(line)
                }
                return
            }

            pending.append(chunk)
            while let newlineRange = pending.firstRange(of: Data([0x0A])) {
                let lineData = pending[..<newlineRange.lowerBound]
                pending.removeSubrange(..<newlineRange.upperBound)
                if let line = trimmedLine(from: Data(lineData)) {
                    body(line)
                }
            }
        }
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

    private func intValue(_ value: Any?) -> Int {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String,
           let integer = Int(value) {
            return integer
        }
        return 0
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

    private func buildAnalyticsSnapshot(from sessions: [CodexSessionAnalytics]) -> CodexAnalyticsSnapshot {
        var totalUsage = CodexTokenUsage.zero
        var totalMessages = 0
        var totalToolCalls = 0
        var modelCounts: [String: Int] = [:]
        var modelUsage: [String: CodexTokenUsage] = [:]
        var toolCounts: [String: Int] = [:]
        var monthBuckets: [String: (count: Int, usage: CodexTokenUsage, cost: Double)] = [:]
        var dayBuckets: [String: Int] = [:]
        var hourly = Array(repeating: 0, count: 24)
        var firstSeenAt: Date?
        var lastSeenAt: Date?
        var unknownPricingModels = Set<String>()

        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "yyyy-MM"
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current

        for session in sessions {
            totalUsage.add(session.tokenUsage)
            totalMessages += session.messageCount
            totalToolCalls += session.toolCalls.reduce(0) { $0 + $1.count }

            if let date = session.updatedAt ?? session.createdAt {
                firstSeenAt = minDate(firstSeenAt, date)
                lastSeenAt = maxDate(lastSeenAt, date)
                let month = monthFormatter.string(from: date)
                monthBuckets[month, default: (0, .zero, 0)].count += 1
                monthBuckets[month]?.usage.add(session.tokenUsage)
                monthBuckets[month]?.cost += session.estimatedCost ?? 0
                dayBuckets[dayFormatter.string(from: date), default: 0] += 1
                let hour = calendar.component(.hour, from: date)
                if hourly.indices.contains(hour) {
                    hourly[hour] += 1
                }
            }

            for model in session.models {
                let normalized = CodexModelPricing.normalizedModelName(model) ?? model
                modelCounts[normalized, default: 0] += 1
                if CodexModelPricing.price(for: normalized) == nil {
                    unknownPricingModels.insert(normalized)
                }
            }

            if let primaryModel = session.primaryModel {
                let normalized = CodexModelPricing.normalizedModelName(primaryModel) ?? primaryModel
                modelUsage[normalized, default: .zero].add(session.tokenUsage)
            }

            for tool in session.toolCalls {
                toolCounts[tool.name, default: 0] += tool.count
            }
        }

        let projects = buildProjects(from: sessions)
        let costs = buildCostBreakdown(
            from: sessions,
            projects: projects,
            unknownPricingModelCount: unknownPricingModels.count
        )
        let archivedCount = sessions.filter(\.isArchived).count
        let topModels = makeModelSummaries(
            counts: modelCounts,
            usageByModel: modelUsage,
            limit: 10
        )
        let topTools = makeToolSummaries(counts: toolCounts, limit: 10)
        let monthlySessions = monthBuckets
            .map { month, value in
                CodexCostBucket(
                    name: month,
                    cost: value.cost,
                    sessionCount: value.count,
                    tokenUsage: value.usage
                )
            }
            .sorted { $0.name < $1.name }
        let dailyActivity = dayBuckets
            .map { CodexDailyActivity(day: $0.key, sessionCount: $0.value) }
            .sorted { $0.day < $1.day }
        let overview = CodexAnalyticsOverview(
            totalSessions: sessions.count,
            archivedSessions: archivedCount,
            totalProjects: projects.count,
            totalMessages: totalMessages,
            totalToolCalls: totalToolCalls,
            tokenUsage: totalUsage,
            estimatedCost: costs.totalCost,
            firstSeenAt: firstSeenAt,
            lastSeenAt: lastSeenAt,
            topModels: topModels,
            topTools: topTools,
            sessionsByMonth: monthlySessions,
            dailyActivity: dailyActivity,
            hourlyActivity: hourly
        )

        return CodexAnalyticsSnapshot(
            sessions: sessions,
            projects: projects,
            overview: overview,
            costs: costs
        )
    }

    private func buildProjects(from sessions: [CodexSessionAnalytics]) -> [CodexProjectAnalytics] {
        let grouped = Dictionary(grouping: sessions) { session in
            session.workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "(no project)"
        }

        return grouped.map { folder, items in
            var usage = CodexTokenUsage.zero
            var messageCount = 0
            var cost = 0.0
            var instances: [String: Int] = [:]
            var modelCounts: [String: Int] = [:]
            var modelUsage: [String: CodexTokenUsage] = [:]
            var toolCounts: [String: Int] = [:]
            var firstSeenAt: Date?
            var lastSeenAt: Date?

            for item in items {
                usage.add(item.tokenUsage)
                messageCount += item.messageCount
                cost += item.estimatedCost ?? 0
                instances[item.instanceName, default: 0] += 1
                if let date = item.updatedAt ?? item.createdAt {
                    firstSeenAt = minDate(firstSeenAt, date)
                    lastSeenAt = maxDate(lastSeenAt, date)
                }
                for model in item.models {
                    let normalized = CodexModelPricing.normalizedModelName(model) ?? model
                    modelCounts[normalized, default: 0] += 1
                }
                if let primaryModel = item.primaryModel {
                    let normalized = CodexModelPricing.normalizedModelName(primaryModel) ?? primaryModel
                    modelUsage[normalized, default: .zero].add(item.tokenUsage)
                }
                for tool in item.toolCalls {
                    toolCounts[tool.name, default: 0] += tool.count
                }
            }

            let topModels = makeModelSummaries(
                counts: modelCounts,
                usageByModel: modelUsage,
                limit: 6
            )
            let topTools = makeToolSummaries(counts: toolCounts, limit: 6)
            return CodexProjectAnalytics(
                folder: folder,
                name: projectName(for: folder),
                sessionCount: items.count,
                messageCount: messageCount,
                tokenUsage: usage,
                estimatedCost: cost,
                firstSeenAt: firstSeenAt,
                lastSeenAt: lastSeenAt,
                instances: instances,
                topModels: topModels,
                topTools: topTools
            )
        }
        .sorted { $0.sessionCount == $1.sessionCount ? $0.name < $1.name : $0.sessionCount > $1.sessionCount }
    }

    private func buildCostBreakdown(
        from sessions: [CodexSessionAnalytics],
        projects: [CodexProjectAnalytics],
        unknownPricingModelCount: Int
    ) -> CodexCostBreakdown {
        var byModel: [String: (count: Int, usage: CodexTokenUsage, cost: Double)] = [:]
        var byInstance: [String: (count: Int, usage: CodexTokenUsage, cost: Double)] = [:]
        var byMonth: [String: (count: Int, usage: CodexTokenUsage, cost: Double)] = [:]
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "yyyy-MM"

        for session in sessions {
            let cost = session.estimatedCost ?? 0
            byInstance[session.instanceName, default: (0, .zero, 0)].count += 1
            byInstance[session.instanceName]?.usage.add(session.tokenUsage)
            byInstance[session.instanceName]?.cost += cost

            if let date = session.updatedAt ?? session.createdAt {
                let month = monthFormatter.string(from: date)
                byMonth[month, default: (0, .zero, 0)].count += 1
                byMonth[month]?.usage.add(session.tokenUsage)
                byMonth[month]?.cost += cost
            }

            if let model = session.primaryModel {
                let normalized = CodexModelPricing.normalizedModelName(model) ?? model
                byModel[normalized, default: (0, .zero, 0)].count += 1
                byModel[normalized]?.usage.add(session.tokenUsage)
                byModel[normalized]?.cost += CodexModelPricing.estimatedCost(for: normalized, usage: session.tokenUsage) ?? 0
            }
        }

        let byProject: [CodexCostBucket] = projects.map {
            CodexCostBucket(
                name: $0.name,
                cost: $0.estimatedCost,
                sessionCount: $0.sessionCount,
                tokenUsage: $0.tokenUsage
            )
        }
        .sorted { $0.cost == $1.cost ? $0.name < $1.name : $0.cost > $1.cost }
        let topSessions: [CodexSessionAnalytics] = sessions
            .filter { ($0.estimatedCost ?? 0) > 0 }
            .sorted { ($0.estimatedCost ?? 0) > ($1.estimatedCost ?? 0) }
            .prefix(20)
            .map { $0 }

        return CodexCostBreakdown(
            totalCost: sessions.reduce(0) { $0 + ($1.estimatedCost ?? 0) },
            unknownPricingModelCount: unknownPricingModelCount,
            byModel: makeCostBuckets(byModel, sortByCost: true),
            byProject: byProject,
            byInstance: makeCostBuckets(byInstance, sortByCost: true),
            byMonth: makeCostBuckets(byMonth, sortByCost: false),
            topSessions: topSessions
        )
    }

    private func makeModelSummaries(
        counts: [String: Int],
        usageByModel: [String: CodexTokenUsage],
        limit: Int
    ) -> [CodexModelSummary] {
        let summaries: [CodexModelSummary] = counts.map { name, count in
            let usage = usageByModel[name] ?? .zero
            return CodexModelSummary(
                name: name,
                count: count,
                usage: usage,
                estimatedCost: CodexModelPricing.estimatedCost(for: name, usage: usage)
            )
        }
        return Array(summaries
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
            .prefix(limit))
    }

    private func makeToolSummaries(counts: [String: Int], limit: Int) -> [CodexToolCallSummary] {
        let summaries: [CodexToolCallSummary] = counts.map {
            CodexToolCallSummary(name: $0.key, count: $0.value)
        }
        return Array(summaries
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
            .prefix(limit))
    }

    private func makeCostBuckets(
        _ values: [String: (count: Int, usage: CodexTokenUsage, cost: Double)],
        sortByCost: Bool
    ) -> [CodexCostBucket] {
        values
            .map {
                CodexCostBucket(
                    name: $0.key,
                    cost: $0.value.cost,
                    sessionCount: $0.value.count,
                    tokenUsage: $0.value.usage
                )
            }
            .sorted { left, right in
                if sortByCost, left.cost != right.cost {
                    return left.cost > right.cost
                }
                return left.name < right.name
            }
    }

    private func minDate(_ current: Date?, _ candidate: Date) -> Date {
        guard let current else { return candidate }
        return min(current, candidate)
    }

    private func maxDate(_ current: Date?, _ candidate: Date) -> Date {
        guard let current else { return candidate }
        return max(current, candidate)
    }

    private func projectName(for folder: String) -> String {
        guard folder != "(no project)" else { return folder }
        let url = URL(fileURLWithPath: folder)
        return url.lastPathComponent.isEmpty ? folder : url.lastPathComponent
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

    private struct RolloutAnalyticsParser {
        private let service: CodexSessionService
        private var currentModel: String?
        private var previousTotalUsage: RawTokenUsage?
        private var toolNamesByCallID: [String: String] = [:]

        private(set) var firstUserTitle: String?
        private(set) var lastEventAt: Date?
        private(set) var userMessageCount = 0
        private(set) var assistantMessageCount = 0
        private(set) var systemMessageCount = 0
        private(set) var userCharacterCount = 0
        private(set) var assistantCharacterCount = 0
        private(set) var tokenUsage = CodexTokenUsage.zero
        private(set) var modelUsage: [String: CodexTokenUsage] = [:]
        private(set) var models: [String] = []
        private(set) var toolCalls: [String: Int] = [:]

        init(service: CodexSessionService) {
            self.service = service
        }

        mutating func consume(_ object: [String: Any]) {
            if let timestamp = service.dateValue(object["timestamp"]) {
                lastEventAt = service.maxDate(lastEventAt, timestamp)
            }

            switch service.stringValue(object["type"]) {
            case "turn_context":
                if let payload = object["payload"] as? [String: Any],
                   let model = extractModel(from: payload) {
                    currentModel = model
                    models.append(model)
                }
            case "response_item":
                guard let payload = object["payload"] as? [String: Any],
                      let payloadType = service.stringValue(payload["type"])
                else { return }
                consumeResponseItem(payload: payload, payloadType: payloadType)
            case "event_msg":
                consumeEventMessage(object)
            default:
                return
            }
        }

        func finish() -> RolloutAnalyticsParser {
            self
        }

        private mutating func consumeResponseItem(payload: [String: Any], payloadType: String) {
            if payloadType == "message" {
                let role = service.stringValue(payload["role"])
                switch role {
                case "user":
                    let text = extractUserText(payload["content"])
                    guard !text.isEmpty, !isBootstrapMessage(text) else { return }
                    userMessageCount += 1
                    userCharacterCount += text.count
                    if firstUserTitle == nil {
                        firstUserTitle = cleanPrompt(text)
                    }
                case "assistant":
                    let text = extractAssistantText(payload["content"])
                    assistantMessageCount += 1
                    assistantCharacterCount += text.count
                case "system":
                    systemMessageCount += 1
                default:
                    return
                }
                if let model = extractModel(from: payload) {
                    currentModel = model
                    models.append(model)
                }
                return
            }

            if payloadType == "reasoning" {
                let text = extractReasoningSummary(payload)
                if !text.isEmpty {
                    assistantCharacterCount += text.count
                }
                return
            }

            if isToolCallPayload(payloadType) {
                let name = service.stringValue(payload["name"])
                    ?? (payloadType == "web_search_call" ? "web_search" : "tool")
                toolCalls[name, default: 0] += 1
                if let callID = service.stringValue(payload["call_id"]) {
                    toolNamesByCallID[callID] = name
                }
            }
        }

        private mutating func consumeEventMessage(_ object: [String: Any]) {
            guard let payload = object["payload"] as? [String: Any],
                  service.stringValue(payload["type"]) == "token_count"
            else {
                return
            }

            let info = payload["info"] as? [String: Any] ?? [:]
            let lastUsage = rawUsage(from: info["last_token_usage"])
            let totalUsage = rawUsage(from: info["total_token_usage"])
            var usage = lastUsage
            if usage == nil, let totalUsage {
                usage = totalUsage.subtracting(previousTotalUsage)
            }
            if let totalUsage {
                previousTotalUsage = totalUsage
            }
            guard let usage else { return }

            let delta = usage.delta
            guard delta.totalTokens > 0 else { return }
            tokenUsage.add(delta)

            let model = extractModel(from: info)
                ?? extractModel(from: payload)
                ?? currentModel
            if let model {
                currentModel = model
                models.append(model)
                modelUsage[model, default: .zero].add(delta)
            }
        }

        private func extractUserText(_ content: Any?) -> String {
            extractContentText(content, acceptedTypes: ["input_text"])
        }

        private func extractAssistantText(_ content: Any?) -> String {
            extractContentText(content, acceptedTypes: ["output_text", "text"])
        }

        private func extractContentText(_ content: Any?, acceptedTypes: Set<String>) -> String {
            guard let items = content as? [[String: Any]] else { return "" }
            return items.compactMap { item in
                guard let type = service.stringValue(item["type"]),
                      acceptedTypes.contains(type),
                      let text = service.stringValue(item["text"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty
                else {
                    return nil
                }
                return text
            }
            .joined(separator: "\n")
        }

        private func extractReasoningSummary(_ payload: [String: Any]) -> String {
            guard let items = payload["summary"] as? [[String: Any]] else { return "" }
            return items.compactMap { item in
                service.stringValue(item["text"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        }

        private func isBootstrapMessage(_ text: String) -> Bool {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("<user_instructions>") || trimmed.hasPrefix("<environment_context>")
        }

        private func cleanPrompt(_ text: String) -> String {
            let cleaned = text
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard cleaned.count > 120 else { return cleaned }
            return String(cleaned.prefix(120))
        }

        private func isToolCallPayload(_ type: String) -> Bool {
            type == "function_call" || type == "custom_tool_call" || type == "web_search_call"
        }

        private func extractModel(from object: [String: Any]) -> String? {
            if let model = service.stringValue(object["model"])?.nilIfEmpty
                ?? service.stringValue(object["model_name"])?.nilIfEmpty {
                return model
            }
            if let info = object["info"] as? [String: Any],
               let model = extractModel(from: info) {
                return model
            }
            if let metadata = object["metadata"] as? [String: Any],
               let model = extractModel(from: metadata) {
                return model
            }
            return nil
        }

        private func rawUsage(from value: Any?) -> RawTokenUsage? {
            guard let object = value as? [String: Any] else { return nil }
            let input = service.intValue(object["input_tokens"])
            let cached = service.intValue(object["cached_input_tokens"])
                + service.intValue(object["cache_read_input_tokens"])
            let output = service.intValue(object["output_tokens"])
            let cacheWrite = service.intValue(object["cache_creation_input_tokens"])
                + service.intValue(object["cache_write_input_tokens"])
            let total = service.intValue(object["total_tokens"])
            guard input > 0 || cached > 0 || output > 0 || cacheWrite > 0 || total > 0 else {
                return nil
            }
            return RawTokenUsage(
                inputTokens: input,
                cachedInputTokens: cached,
                outputTokens: output,
                cacheWriteTokens: cacheWrite,
                totalTokens: total > 0 ? total : input + output + cacheWrite
            )
        }
    }
}

private enum SessionDirectory: String, CaseIterable {
    case sessions
    case archived = "archived_sessions"
}

private struct AnalyticsCandidate {
    var thread: CodexSessionThread
    var rolloutURL: URL
    var sessionDirectory: SessionDirectory
    var homeURL: URL
    var instance: CodexInstance
    var index: [String: [String: Any]]
}

private struct RawTokenUsage: Equatable {
    var inputTokens: Int
    var cachedInputTokens: Int
    var outputTokens: Int
    var cacheWriteTokens: Int
    var totalTokens: Int

    var delta: CodexTokenUsage {
        let cacheRead = min(cachedInputTokens, inputTokens)
        return CodexTokenUsage(
            inputTokens: max(inputTokens - cacheRead, 0),
            outputTokens: outputTokens,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWriteTokens
        )
    }

    func subtracting(_ previous: RawTokenUsage?) -> RawTokenUsage {
        RawTokenUsage(
            inputTokens: max(inputTokens - (previous?.inputTokens ?? 0), 0),
            cachedInputTokens: max(cachedInputTokens - (previous?.cachedInputTokens ?? 0), 0),
            outputTokens: max(outputTokens - (previous?.outputTokens ?? 0), 0),
            cacheWriteTokens: max(cacheWriteTokens - (previous?.cacheWriteTokens ?? 0), 0),
            totalTokens: max(totalTokens - (previous?.totalTokens ?? 0), 0)
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
