import AppKit
import SwiftUI

struct SessionBrowserView: View {
    @EnvironmentObject private var store: InstanceStore
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var selectedSessionIDs = Set<CodexSessionThread.ID>()
    @State private var targetInstanceID: CodexInstance.ID?
    @State private var repairInstanceID: CodexInstance.ID?
    @State private var pendingAction: PendingSessionAction?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
            Divider()
            footer
        }
        .frame(minWidth: 980, minHeight: 620)
        .onAppear {
            store.refreshSessions()
            targetInstanceID = store.visibleInstances.first?.id
            repairInstanceID = store.selectedInstance?.id ?? store.visibleInstances.first?.id
        }
        .onDisappear {
            store.cancelSessionRefresh()
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search sessions")
        .confirmationDialog(
            pendingAction?.title ?? "Confirm",
            isPresented: pendingActionBinding,
            titleVisibility: .visible
        ) {
            Button(pendingAction?.confirmTitle ?? "Continue") {
                performPendingAction()
            }
            Button("Cancel", role: .cancel) {
                pendingAction = nil
            }
        } message: {
            Text(pendingAction?.message ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Sessions")
                    .font(.title2.weight(.semibold))
                Text(summaryText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                store.refreshSessions()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.isScanningSessions || store.isPerformingSessionMutation)

            Button {
                dismiss()
            } label: {
                Label("Close", systemImage: "xmark")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var table: some View {
        Table(filteredSessions, selection: $selectedSessionIDs) {
            TableColumn("Title") { session in
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .lineLimit(1)
                    Text(session.threadID)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .padding(.vertical, 2)
            }

            TableColumn("Instance") { session in
                Text(session.instanceName)
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 150)

            TableColumn("Workspace") { session in
                Text(session.workspacePath ?? "No workspace")
                    .foregroundStyle(session.workspacePath == nil ? .tertiary : .secondary)
                    .lineLimit(1)
            }
            .width(min: 220, ideal: 320)

            TableColumn("Updated") { session in
                Text(session.updatedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Unknown")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 130, ideal: 160)

            TableColumn("State") { session in
                HStack(spacing: 8) {
                    if session.isArchived {
                        Label("Archived", systemImage: "archivebox")
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Live", systemImage: "message")
                            .foregroundStyle(.green)
                    }
                    Text(byteCountText(session.byteCount))
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
                .lineLimit(1)
            }
            .width(min: 120, ideal: 150)
        }
        .overlay {
            if store.isScanningSessions && store.sessionScanResult.sessions.isEmpty {
                loadingState
            } else if filteredSessions.isEmpty {
                emptyState
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Text("Scanning Sessions")
                .font(.headline)
            Text("Reading Codex rollout metadata in the background.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(28)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(searchText.isEmpty ? "No Sessions" : "No Matches")
                .font(.headline)
            Text(searchText.isEmpty ? "No Codex rollout sessions were found in the configured CODEX_HOME directories." : "Try a different title, workspace, instance, or thread id.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(28)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                openSelectedSession()
            } label: {
                Label("Reveal", systemImage: "folder")
            }
            .disabled(selectedSessions.count != 1 || store.isScanningSessions)

            Picker("Copy to", selection: targetSelection) {
                ForEach(store.visibleInstances) { instance in
                    Text(instance.managedAppName).tag(Optional(instance.id))
                }
            }
            .frame(width: 220)
            .disabled(store.visibleInstances.isEmpty || store.isPerformingSessionMutation)

            Button {
                pendingAction = .copy(selectedSessionIDs.count, targetName)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(selectedSessionIDs.isEmpty || targetInstanceID == nil || store.isPerformingSessionMutation)

            Divider()
                .frame(height: 18)

            Picker("Repair", selection: repairSelection) {
                ForEach(store.visibleInstances) { instance in
                    Text(instance.managedAppName).tag(Optional(instance.id))
                }
            }
            .frame(width: 220)
            .disabled(store.visibleInstances.isEmpty || store.isPerformingSessionMutation)

            Button {
                pendingAction = .repair(repairTargetName)
            } label: {
                Label("Repair Index", systemImage: "wrench.and.screwdriver")
            }
            .disabled(repairInstanceID == nil || store.isPerformingSessionMutation)

            Button {
                pendingAction = .sync
            } label: {
                Label("Sync Idle", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(store.visibleInstances.count < 2 || store.isPerformingSessionMutation)

            Spacer()

            if store.isPerformingSessionMutation {
                ProgressView()
                    .controlSize(.small)
                Text("Updating sessions...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if store.isScanningSessions {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let message = store.sessionStatusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var filteredSessions: [CodexSessionThread] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            return store.sessionScanResult.sessions
        }
        return store.sessionScanResult.sessions.filter { session in
            [
                session.title,
                session.threadID,
                session.instanceName,
                session.workspacePath ?? "",
                session.relativeRolloutPath
            ]
            .contains { $0.lowercased().contains(query) }
        }
    }

    private var selectedSessions: [CodexSessionThread] {
        store.sessionScanResult.sessions.filter { selectedSessionIDs.contains($0.id) }
    }

    private var summaryText: String {
        let total = store.sessionScanResult.sessions.count
        let skipped = store.sessionScanResult.skippedFileCount
        if store.isScanningSessions {
            return "Scanning session metadata..."
        }
        if skipped == 0 {
            return "\(total) session(s) across \(store.visibleInstances.count) instance(s)"
        }
        return "\(total) session(s), \(skipped) unreadable rollout file(s)"
    }

    private var targetName: String {
        targetInstanceID
            .flatMap { id in store.visibleInstances.first { $0.id == id }?.managedAppName }
            ?? "the selected instance"
    }

    private var repairTargetName: String {
        repairInstanceID
            .flatMap { id in store.visibleInstances.first { $0.id == id }?.managedAppName }
            ?? "the selected instance"
    }

    private var targetSelection: Binding<CodexInstance.ID?> {
        Binding(
            get: { targetInstanceID },
            set: { targetInstanceID = $0 }
        )
    }

    private var repairSelection: Binding<CodexInstance.ID?> {
        Binding(
            get: { repairInstanceID },
            set: { repairInstanceID = $0 }
        )
    }

    private var pendingActionBinding: Binding<Bool> {
        Binding(
            get: { pendingAction != nil },
            set: { if !$0 { pendingAction = nil } }
        )
    }

    private func performPendingAction() {
        guard let action = pendingAction else { return }
        switch action {
        case .copy:
            if let targetInstanceID {
                store.copySessions(selectedSessionIDs, to: targetInstanceID)
                selectedSessionIDs.removeAll()
            }
        case .repair:
            if let repairInstanceID {
                store.repairSessionIndex(for: repairInstanceID)
            }
        case .sync:
            store.syncSessionsAcrossIdleInstances()
        }
        pendingAction = nil
    }

    private func openSelectedSession() {
        guard let session = selectedSessions.first else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.rolloutPath)])
    }

    private func byteCountText(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

private enum PendingSessionAction {
    case copy(Int, String)
    case repair(String)
    case sync

    var title: String {
        switch self {
        case .copy:
            return "Copy Sessions"
        case .repair:
            return "Repair Session Index"
        case .sync:
            return "Sync Idle Instances"
        }
    }

    var confirmTitle: String {
        switch self {
        case .copy:
            return "Copy"
        case .repair:
            return "Repair"
        case .sync:
            return "Sync"
        }
    }

    var message: String {
        switch self {
        case .copy(let count, let targetName):
            return "Copy \(count) selected session(s) into \(targetName). Existing rollout files and session indexes are backed up before being replaced."
        case .repair(let name):
            return "Rebuild session_index.jsonl for \(name) from rollout files. The existing index is backed up first."
        case .sync:
            return "Copy missing or newer sessions across instances that are not currently running. Existing rollout files and indexes are backed up before changes."
        }
    }
}
