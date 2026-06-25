import Foundation

struct CodexSessionThread: Identifiable, Equatable {
    var id: String
    var threadID: String
    var instanceID: CodexInstance.ID
    var instanceName: String
    var codexHome: String
    var title: String
    var workspacePath: String?
    var rolloutPath: String
    var relativeRolloutPath: String
    var updatedAt: Date?
    var byteCount: Int
    var lineCount: Int
    var isArchived: Bool
}

struct CodexSessionScanResult: Equatable {
    var sessions: [CodexSessionThread]
    var skippedFileCount: Int
}

struct CodexSessionCopySummary: Equatable {
    var requestedSessionCount: Int
    var copiedSessionCount: Int
    var skippedSessionCount: Int
    var missingSessionCount: Int
    var backupDirectory: String?
}

struct CodexSessionRepairSummary: Equatable {
    var instanceID: CodexInstance.ID
    var indexedSessionCount: Int
    var backupDirectory: String?
}

struct CodexSessionSyncItem: Equatable {
    var instanceID: CodexInstance.ID
    var instanceName: String
    var addedSessionCount: Int
    var updatedSessionCount: Int
    var backupDirectory: String?
}

struct CodexSessionSyncSummary: Equatable {
    var instanceCount: Int
    var threadUniverseCount: Int
    var mutatedInstanceCount: Int
    var addedSessionCount: Int
    var updatedSessionCount: Int
    var skippedRunningInstanceCount: Int
    var items: [CodexSessionSyncItem]
}
