import Foundation

struct CodexSessionThread: Identifiable, Equatable {
    var id: String
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
