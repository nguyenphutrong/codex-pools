import AppKit
import SwiftUI

struct AnalyticsView: View {
    @EnvironmentObject private var store: InstanceStore
    @State private var selection: AnalyticsSection = .dashboard
    @State private var projectFilter: String?

    var body: some View {
        AnalyticsContent(
            snapshot: store.analyticsResult().snapshot,
            isScanning: store.isScanningAnalytics(),
            selection: $selection,
            projectFilter: $projectFilter,
            title: "Analytics",
            subtitle: nil,
            onRefresh: { store.refreshAnalytics() }
        )
        .frame(minWidth: 860, minHeight: 620)
        .onAppear {
            if store.analyticsResult().snapshot.sessions.isEmpty {
                store.refreshAnalytics()
            }
        }
    }
}

struct AnalyticsContent: View {
    let snapshot: CodexAnalyticsSnapshot
    let isScanning: Bool
    @Binding var selection: AnalyticsSection
    @Binding var projectFilter: String?
    var title: String
    var subtitle: String?
    var onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            detail
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Picker("Analytics Section", selection: $selection) {
                ForEach(AnalyticsSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 420)

            Button {
                onRefresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isScanning)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var detail: some View {
        if isScanning && snapshot.sessions.isEmpty {
            AnalyticsLoadingView()
        } else if snapshot.sessions.isEmpty {
            AnalyticsEmptyView()
        } else {
            switch selection {
            case .dashboard:
                AnalyticsDashboardView(snapshot: snapshot)
            case .sessions:
                AnalyticsSessionsView(snapshot: snapshot, projectFilter: $projectFilter)
            case .projects:
                AnalyticsProjectsView(snapshot: snapshot, projectFilter: $projectFilter, selection: $selection)
            case .costs:
                AnalyticsCostsView(snapshot: snapshot)
            }
        }
    }
}

enum AnalyticsSection: String, CaseIterable, Identifiable {
    case dashboard
    case sessions
    case projects
    case costs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .sessions: return "Sessions"
        case .projects: return "Projects"
        case .costs: return "Costs"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: return "chart.bar.xaxis"
        case .sessions: return "text.bubble"
        case .projects: return "folder"
        case .costs: return "dollarsign.circle"
        }
    }
}

private struct AnalyticsDashboardView: View {
    let snapshot: CodexAnalyticsSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AnalyticsHeader(title: "Dashboard", subtitle: dateRangeText)

                LazyVGrid(columns: kpiColumns, spacing: 12) {
                    AnalyticsMetricCard(title: "Sessions", value: number(snapshot.overview.totalSessions), footnote: "\(snapshot.overview.archivedSessions) archived")
                    AnalyticsMetricCard(title: "Projects", value: number(snapshot.overview.totalProjects), footnote: "workspace folders")
                    AnalyticsMetricCard(title: "Messages", value: number(snapshot.overview.totalMessages), footnote: "\(number(snapshot.overview.totalToolCalls)) tool calls")
                    AnalyticsMetricCard(title: "Tokens", value: number(snapshot.overview.tokenUsage.totalTokens), footnote: tokenBreakdown(snapshot.overview.tokenUsage))
                    AnalyticsMetricCard(title: "Est. Cost", value: money(snapshot.overview.estimatedCost), footnote: "public pricing")
                }

                HStack(alignment: .top, spacing: 14) {
                    AnalyticsListPanel(title: "Top Projects") {
                        ForEach(snapshot.projects.prefix(8)) { project in
                            AnalyticsRankRow(
                                title: project.name,
                                detail: "\(project.sessionCount) sessions",
                                value: money(project.estimatedCost)
                            )
                        }
                    }

                    AnalyticsListPanel(title: "Top Models") {
                        ForEach(snapshot.overview.topModels) { model in
                            AnalyticsRankRow(
                                title: model.name,
                                detail: "\(model.count) mentions",
                                value: model.estimatedCost.map(money) ?? "--"
                            )
                        }
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    AnalyticsListPanel(title: "Monthly Sessions") {
                        ForEach(snapshot.overview.sessionsByMonth.suffix(12)) { bucket in
                            AnalyticsBarRow(
                                title: bucket.name,
                                value: bucket.sessionCount,
                                maxValue: maxMonthlySessions
                            )
                        }
                    }

                    AnalyticsListPanel(title: "Peak Hours") {
                        ForEach(Array(snapshot.overview.hourlyActivity.enumerated()), id: \.offset) { hour, count in
                            if count > 0 {
                                AnalyticsBarRow(
                                    title: String(format: "%02d:00", hour),
                                    value: count,
                                    maxValue: maxHourlySessions
                                )
                            }
                        }
                    }
                }
            }
            .padding(22)
        }
    }

    private var kpiColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 150), spacing: 12)]
    }

    private var maxMonthlySessions: Int {
        max(snapshot.overview.sessionsByMonth.map(\.sessionCount).max() ?? 1, 1)
    }

    private var maxHourlySessions: Int {
        max(snapshot.overview.hourlyActivity.max() ?? 1, 1)
    }

    private var dateRangeText: String {
        let start = snapshot.overview.firstSeenAt.map(shortDate) ?? "unknown"
        let end = snapshot.overview.lastSeenAt.map(shortDate) ?? "unknown"
        return "\(start) - \(end)"
    }
}

private struct AnalyticsSessionsView: View {
    let snapshot: CodexAnalyticsSnapshot
    @Binding var projectFilter: String?
    @State private var searchText = ""
    @State private var selectedSessionID: CodexSessionAnalytics.ID?

    var body: some View {
        VStack(spacing: 0) {
            AnalyticsToolbar(
                title: "Sessions",
                subtitle: "\(filtered.count) of \(snapshot.sessions.count) sessions"
            ) {
                if projectFilter != nil {
                    Button("Clear Project Filter") {
                        projectFilter = nil
                    }
                }
                Button {
                    revealSelected()
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
                .disabled(selectedSession == nil)
            }

            Table(filtered, selection: $selectedSessionID) {
                TableColumn("Title") { session in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title)
                            .lineLimit(1)
                        Text(session.threadID)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                TableColumn("Instance", value: \.instanceName)
                    .width(min: 90, ideal: 120)
                TableColumn("Project") { session in
                    Text(session.workspacePath ?? "No project")
                        .foregroundStyle(session.workspacePath == nil ? .tertiary : .secondary)
                        .lineLimit(1)
                }
                .width(min: 190, ideal: 260)
                TableColumn("Updated") { session in
                    Text(session.updatedAt.map(shortDateTime) ?? "Unknown")
                        .foregroundStyle(.secondary)
                }
                .width(min: 120, ideal: 140)
                TableColumn("Messages") { session in
                    Text(number(session.messageCount))
                        .monospacedDigit()
                }
                .width(80)
                TableColumn("Tokens") { session in
                    Text(number(session.tokenUsage.totalTokens))
                        .monospacedDigit()
                }
                .width(90)
                TableColumn("Model") { session in
                    Text(session.primaryModel ?? "--")
                        .lineLimit(1)
                }
                .width(min: 100, ideal: 140)
                TableColumn("Cost") { session in
                    Text(session.estimatedCost.map(money) ?? "--")
                        .monospacedDigit()
                }
                .width(80)
            }
            .searchable(text: $searchText, prompt: "Search sessions")
        }
    }

    private var filtered: [CodexSessionAnalytics] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return snapshot.sessions.filter { session in
            if let projectFilter, session.workspacePath != projectFilter {
                return false
            }
            guard !query.isEmpty else { return true }
            return [
                session.title,
                session.threadID,
                session.instanceName,
                session.workspacePath ?? "",
                session.primaryModel ?? ""
            ].contains { $0.lowercased().contains(query) }
        }
    }

    private var selectedSession: CodexSessionAnalytics? {
        guard let selectedSessionID else { return nil }
        return snapshot.sessions.first { $0.id == selectedSessionID }
    }

    private func revealSelected() {
        guard let selectedSession else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: selectedSession.rolloutPath)])
    }
}

private struct AnalyticsProjectsView: View {
    let snapshot: CodexAnalyticsSnapshot
    @Binding var projectFilter: String?
    @Binding var selection: AnalyticsSection
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            AnalyticsToolbar(
                title: "Projects",
                subtitle: "\(filtered.count) workspace folders"
            ) {}

            Table(filtered) {
                TableColumn("Project") { project in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                            .fontWeight(.medium)
                        Text(project.folder)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                TableColumn("Sessions") { project in
                    Text(number(project.sessionCount))
                        .monospacedDigit()
                }
                .width(80)
                TableColumn("Messages") { project in
                    Text(number(project.messageCount))
                        .monospacedDigit()
                }
                .width(90)
                TableColumn("Tokens") { project in
                    Text(number(project.tokenUsage.totalTokens))
                        .monospacedDigit()
                }
                .width(90)
                TableColumn("Top Model") { project in
                    Text(project.topModels.first?.name ?? "--")
                        .lineLimit(1)
                }
                .width(min: 120, ideal: 160)
                TableColumn("Tools") { project in
                    Text(project.topTools.first.map { "\($0.name) (\($0.count))" } ?? "--")
                        .lineLimit(1)
                }
                .width(min: 120, ideal: 160)
                TableColumn("Cost") { project in
                    Text(money(project.estimatedCost))
                        .monospacedDigit()
                }
                .width(80)
                TableColumn("Last Seen") { project in
                    Text(project.lastSeenAt.map(shortDate) ?? "--")
                        .foregroundStyle(.secondary)
                }
                .width(90)
                TableColumn("") { project in
                    Button("Show") {
                        projectFilter = project.folder
                        selection = .sessions
                    }
                    .buttonStyle(.borderless)
                }
                .width(60)
            }
            .contextMenu(forSelectionType: CodexProjectAnalytics.ID.self) { ids in
                if let id = ids.first,
                   let project = snapshot.projects.first(where: { $0.id == id }) {
                    Button("Show Sessions") {
                        projectFilter = project.folder
                        selection = .sessions
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search projects")
        }
    }

    private var filtered: [CodexProjectAnalytics] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return snapshot.projects }
        return snapshot.projects.filter {
            $0.name.lowercased().contains(query) || $0.folder.lowercased().contains(query)
        }
    }
}

private struct AnalyticsCostsView: View {
    let snapshot: CodexAnalyticsSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AnalyticsHeader(
                    title: "Costs",
                    subtitle: "Estimates based on public API prices; actual billing can differ."
                )

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    AnalyticsMetricCard(title: "Total", value: money(snapshot.costs.totalCost), footnote: "estimated")
                    AnalyticsMetricCard(title: "Avg / Session", value: money(avgCost), footnote: "\(snapshot.overview.totalSessions) sessions")
                    AnalyticsMetricCard(title: "Models", value: number(snapshot.costs.byModel.count), footnote: "\(snapshot.costs.unknownPricingModelCount) unknown")
                    AnalyticsMetricCard(title: "Top Model", value: snapshot.costs.byModel.first?.name ?? "--", footnote: snapshot.costs.byModel.first.map { money($0.cost) } ?? "")
                }

                HStack(alignment: .top, spacing: 14) {
                    CostBucketPanel(title: "By Model", buckets: snapshot.costs.byModel)
                    CostBucketPanel(title: "By Project", buckets: Array(snapshot.costs.byProject.prefix(12)))
                }

                HStack(alignment: .top, spacing: 14) {
                    CostBucketPanel(title: "By Instance", buckets: snapshot.costs.byInstance)
                    CostBucketPanel(title: "By Month", buckets: snapshot.costs.byMonth)
                }

                AnalyticsListPanel(title: "Most Expensive Sessions") {
                    ForEach(snapshot.costs.topSessions) { session in
                        AnalyticsRankRow(
                            title: session.title,
                            detail: session.primaryModel ?? session.instanceName,
                            value: session.estimatedCost.map(money) ?? "--"
                        )
                    }
                }
            }
            .padding(22)
        }
    }

    private var avgCost: Double {
        guard snapshot.overview.totalSessions > 0 else { return 0 }
        return snapshot.costs.totalCost / Double(snapshot.overview.totalSessions)
    }
}

private struct CostBucketPanel: View {
    let title: String
    let buckets: [CodexCostBucket]

    var body: some View {
        AnalyticsListPanel(title: title) {
            ForEach(buckets) { bucket in
                AnalyticsRankRow(
                    title: bucket.name,
                    detail: "\(bucket.sessionCount) sessions, \(number(bucket.tokenUsage.totalTokens)) tokens",
                    value: money(bucket.cost)
                )
            }
        }
    }
}

private struct AnalyticsToolbar<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            actions
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

private struct AnalyticsHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AnalyticsMetricCard: View {
    let title: String
    let value: String
    let footnote: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(footnote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct AnalyticsListPanel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            VStack(spacing: 8) {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct AnalyticsRankRow: View {
    let title: String
    let detail: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

private struct AnalyticsBarRow: View {
    let title: String
    let value: Int
    let maxValue: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.monospacedDigit())
                .frame(width: 52, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.tertiary.opacity(0.18))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * CGFloat(value) / CGFloat(max(maxValue, 1)))
                }
            }
            .frame(height: 8)
            Text(number(value))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

private struct AnalyticsLoadingView: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Scanning Codex Analytics")
                .font(.headline)
            Text("Reading Codex JSONL sessions across configured CODEX_HOME directories.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AnalyticsEmptyView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No Analytics")
                .font(.headline)
            Text("No Codex sessions were found in the configured CODEX_HOME directories.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private func number(_ value: Int) -> String {
    value.formatted(.number)
}

private func money(_ value: Double) -> String {
    value.formatted(.currency(code: "USD").precision(.fractionLength(value < 1 ? 4 : 2)))
}

private func tokenBreakdown(_ usage: CodexTokenUsage) -> String {
    "in \(number(usage.inputTokens)), out \(number(usage.outputTokens))"
}

private func shortDate(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .omitted)
}

private func shortDateTime(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
}
