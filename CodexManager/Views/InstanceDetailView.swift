import SwiftUI

struct InstanceDetailView: View {
    @EnvironmentObject private var store: InstanceStore
    let instance: CodexInstance

    @State private var draft: CodexInstance
    @State private var duplicateName = ""
    @State private var isShowingDuplicateSheet = false
    @State private var isShowingDeleteDialog = false
    @State private var analyticsSection: AnalyticsSection = .dashboard
    @State private var analyticsProjectFilter: String?

    init(instance: CodexInstance) {
        self.instance = instance
        _draft = State(initialValue: instance)
    }

    var body: some View {
        VStack(spacing: 0) {
            instanceHeader
            if shouldShowRebuildWarning {
                rebuildWarning
            }
            AnalyticsContent(
                snapshot: store.analyticsResult(for: [draft]).snapshot,
                isScanning: store.isScanningAnalytics(for: [draft]),
                selection: $analyticsSection,
                projectFilter: $analyticsProjectFilter,
                title: "Codex Analytics",
                subtitle: draft.codexHome,
                onRefresh: { store.refreshAnalytics(for: [draft]) }
            )
        }
        .navigationTitle(draft.name)
        .id(instance.id)
        .onAppear {
            store.refreshAnalytics(for: [draft])
        }
        .onChange(of: instance) { newInstance in
            draft = newInstance
            analyticsSection = .dashboard
            analyticsProjectFilter = nil
            store.refreshAnalytics(for: [newInstance])
        }
        .sheet(isPresented: $isShowingDuplicateSheet) {
            duplicateSheet
        }
        .confirmationDialog(
            "Delete \(draft.name)?",
            isPresented: $isShowingDeleteDialog,
            titleVisibility: .visible
        ) {
            Button("Delete Instance", role: .destructive) {
                store.delete(draft, deleteHomeDirectory: false)
            }
            Button("Delete Instance and CODEX_HOME", role: .destructive) {
                store.delete(draft, deleteHomeDirectory: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deleting CODEX_HOME is permanent. Keep it unless you are sure this instance's files are no longer needed.")
        }
    }

    private var instanceHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            IconPickerView(iconPath: $draft.iconPath)
                .disabled(isReadonly)

            VStack(alignment: .leading, spacing: 4) {
                Text(draft.name.isEmpty ? "Untitled Instance" : draft.name)
                    .font(.title2.weight(.semibold))
                Text(draft.codexHome)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if isRunning {
                        InstanceStateBadge(title: "Running", systemImage: "circle.fill", tint: .green)
                    }
                    if isReadonly {
                        InstanceStateBadge(title: "Readonly", systemImage: "lock", tint: .secondary)
                    } else {
                        BundleStatusBadge(status: draft.bundleStatus)
                    }
                    Text("Last launched \(lastLaunchedText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                Task { await store.launch(draft) }
            } label: {
                if isLaunching {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Launching")
                    }
                } else {
                    Label("Launch", systemImage: "play.fill")
                }
            }
            .liquidGlassButtonStyle(.prominent)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(isReadonly || !canSave || isLaunching)

            Button {
                store.quit(draft)
            } label: {
                Label("Quit", systemImage: "stop.fill")
            }
            .liquidGlassButtonStyle()
            .disabled(isReadonly || !isRunning || isLaunching)

            Button {
                Task { await store.restart(draft) }
            } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }
            .liquidGlassButtonStyle()
            .disabled(isReadonly || !isRunning || !canSave || isLaunching)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var rebuildWarning: some View {
        Label(
            "\(draft.managedAppName) is running and its app bundle needs to be rebuilt. Quit it before launching again so Codex Pools can prepare the updated bundle.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .foregroundStyle(.orange)
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.bottom, 10)
    }

    private var duplicateSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Duplicate Instance")
                .font(.headline)

            TextField("New name", text: $duplicateName)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 320)

            HStack {
                Spacer()
                Button("Cancel") {
                    isShowingDuplicateSheet = false
                }
                Button("Duplicate") {
                    store.duplicate(draft, newName: duplicateName)
                    isShowingDuplicateSheet = false
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(duplicateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !draft.codexHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            draft.extraEnvVars.keys.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } &&
            draft.launchArgs.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var isLaunching: Bool {
        store.isLaunching(draft)
    }

    private var isReadonly: Bool {
        draft.isOriginal
    }

    private var isRunning: Bool {
        store.isRunning(draft)
    }

    private var shouldShowRebuildWarning: Bool {
        isRunning && draft.bundleStatus == .needsRebuild
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { draft.name },
            set: { newName in
                let previousDefaultHome = CodexInstance.defaultHomePath(for: draft.name)
                let shouldUpdateHome = draft.codexHome == previousDefaultHome

                draft.name = newName

                if shouldUpdateHome {
                    draft.codexHome = CodexInstance.defaultHomePath(for: newName)
                }
            }
        )
    }

    private var lastLaunchedText: String {
        guard let lastLaunchedAt = draft.lastLaunchedAt else { return "Never" }
        return lastLaunchedAt.formatted(date: .abbreviated, time: .shortened)
    }
}

private enum LiquidGlassButtonProminence {
    case standard
    case prominent
}

private extension View {
    @ViewBuilder
    func liquidGlassPanel(cornerRadius: CGFloat = 18) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            self
        }
    }

    @ViewBuilder
    func liquidGlassButtonStyle(_ prominence: LiquidGlassButtonProminence = .standard) -> some View {
        if #available(macOS 26.0, *) {
            switch prominence {
            case .standard:
                self.buttonStyle(.glass)
            case .prominent:
                self.buttonStyle(.glassProminent)
            }
        } else {
            self
        }
    }
}
