import Foundation

struct CodexTokenUsage: Equatable {
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int

    static let zero = CodexTokenUsage(
        inputTokens: 0,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheWriteTokens: 0
    )

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
    }

    mutating func add(_ other: CodexTokenUsage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheWriteTokens += other.cacheWriteTokens
    }
}

struct CodexToolCallSummary: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var count: Int
}

struct CodexModelSummary: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var count: Int
    var usage: CodexTokenUsage
    var estimatedCost: Double?
}

struct CodexSessionAnalytics: Identifiable, Equatable {
    var id: String
    var threadID: String
    var instanceID: CodexInstance.ID
    var instanceName: String
    var codexHome: String
    var title: String
    var workspacePath: String?
    var rolloutPath: String
    var relativeRolloutPath: String
    var createdAt: Date?
    var updatedAt: Date?
    var isArchived: Bool
    var source: String?
    var originator: String?
    var cliVersion: String?
    var modelProvider: String?
    var userMessageCount: Int
    var assistantMessageCount: Int
    var systemMessageCount: Int
    var userCharacterCount: Int
    var assistantCharacterCount: Int
    var tokenUsage: CodexTokenUsage
    var models: [String]
    var toolCalls: [CodexToolCallSummary]
    var estimatedCost: Double?

    var messageCount: Int {
        userMessageCount + assistantMessageCount + systemMessageCount
    }

    var primaryModel: String? {
        mostFrequent(models)
    }
}

struct CodexProjectAnalytics: Identifiable, Equatable {
    var id: String { folder }
    var folder: String
    var name: String
    var sessionCount: Int
    var messageCount: Int
    var tokenUsage: CodexTokenUsage
    var estimatedCost: Double
    var firstSeenAt: Date?
    var lastSeenAt: Date?
    var instances: [String: Int]
    var topModels: [CodexModelSummary]
    var topTools: [CodexToolCallSummary]
}

struct CodexCostBucket: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var cost: Double
    var sessionCount: Int
    var tokenUsage: CodexTokenUsage
}

struct CodexCostBreakdown: Equatable {
    var totalCost: Double
    var unknownPricingModelCount: Int
    var byModel: [CodexCostBucket]
    var byProject: [CodexCostBucket]
    var byInstance: [CodexCostBucket]
    var byMonth: [CodexCostBucket]
    var topSessions: [CodexSessionAnalytics]
}

struct CodexDailyActivity: Identifiable, Equatable {
    var id: String { day }
    var day: String
    var sessionCount: Int
}

struct CodexAnalyticsOverview: Equatable {
    var totalSessions: Int
    var archivedSessions: Int
    var totalProjects: Int
    var totalMessages: Int
    var totalToolCalls: Int
    var tokenUsage: CodexTokenUsage
    var estimatedCost: Double
    var firstSeenAt: Date?
    var lastSeenAt: Date?
    var topModels: [CodexModelSummary]
    var topTools: [CodexToolCallSummary]
    var sessionsByMonth: [CodexCostBucket]
    var dailyActivity: [CodexDailyActivity]
    var hourlyActivity: [Int]
}

struct CodexAnalyticsSnapshot: Equatable {
    var sessions: [CodexSessionAnalytics]
    var projects: [CodexProjectAnalytics]
    var overview: CodexAnalyticsOverview
    var costs: CodexCostBreakdown
}

struct CodexAnalyticsScanResult: Equatable {
    var snapshot: CodexAnalyticsSnapshot
    var skippedFileCount: Int
}

extension CodexAnalyticsSnapshot {
    static let empty = CodexAnalyticsSnapshot(
        sessions: [],
        projects: [],
        overview: CodexAnalyticsOverview(
            totalSessions: 0,
            archivedSessions: 0,
            totalProjects: 0,
            totalMessages: 0,
            totalToolCalls: 0,
            tokenUsage: .zero,
            estimatedCost: 0,
            firstSeenAt: nil,
            lastSeenAt: nil,
            topModels: [],
            topTools: [],
            sessionsByMonth: [],
            dailyActivity: [],
            hourlyActivity: Array(repeating: 0, count: 24)
        ),
        costs: CodexCostBreakdown(
            totalCost: 0,
            unknownPricingModelCount: 0,
            byModel: [],
            byProject: [],
            byInstance: [],
            byMonth: [],
            topSessions: []
        )
    )
}

private func mostFrequent(_ values: [String]) -> String? {
    var counts: [String: Int] = [:]
    for value in values where !value.isEmpty {
        counts[value, default: 0] += 1
    }
    return counts.sorted { left, right in
        if left.value != right.value {
            return left.value > right.value
        }
        return left.key < right.key
    }.first?.key
}
