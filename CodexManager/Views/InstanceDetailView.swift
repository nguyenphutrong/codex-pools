import SwiftUI

struct InstanceDetailView: View {
    @EnvironmentObject private var store: InstanceStore
    let instance: CodexInstance

    @State private var draft: CodexInstance
    @State private var duplicateName = ""
    @State private var isShowingDuplicateSheet = false
    @State private var isShowingDeleteDialog = false

    init(instance: CodexInstance) {
        self.instance = instance
        _draft = State(initialValue: instance)
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 16) {
                    IconPickerView(iconPath: $draft.iconPath)
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
                            BundleStatusBadge(status: draft.bundleStatus)
                        }
                    }
                }
                .padding(12)
                .liquidGlassPanel()
            }

            if shouldShowRebuildWarning {
                Section {
                    Label(
                        "\(draft.managedAppName) is running and its app bundle needs to be rebuilt. Quit it before launching again so Codex Pools can prepare the updated bundle.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .font(.callout)
                }
            }

            Section("Configuration") {
                TextField("Name", text: nameBinding)
                TextField("CODEX_HOME", text: $draft.codexHome)
            }

            Section("Environment") {
                EnvVarEditorView(variables: $draft.extraEnvVars)
            }

            Section("Launch Arguments") {
                LaunchArgsEditorView(arguments: $draft.launchArgs)
            }

            Section("Activity") {
                LabeledContent("Version", value: draft.detailedBundleVersionSummary)
                LabeledContent("Created", value: draft.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Last launched", value: lastLaunchedText)
            }

            Section {
                HStack {
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
                    .disabled(!canSave || isLaunching)

                    Button {
                        store.quit(draft)
                    } label: {
                        Label("Quit", systemImage: "stop.fill")
                    }
                    .liquidGlassButtonStyle()
                    .disabled(!isRunning || isLaunching)

                    Button {
                        Task { await store.restart(draft) }
                    } label: {
                        Label("Restart", systemImage: "arrow.clockwise")
                    }
                    .liquidGlassButtonStyle()
                    .disabled(!isRunning || !canSave || isLaunching)

                    Button {
                        store.update(draft)
                    } label: {
                        Label("Save", systemImage: "checkmark")
                    }
                    .liquidGlassButtonStyle()
                    .keyboardShortcut("s", modifiers: [.command])
                    .disabled(!canSave || isLaunching)

                    Button {
                        duplicateName = "\(draft.name) Copy"
                        isShowingDuplicateSheet = true
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    .liquidGlassButtonStyle()

                    Spacer()

                    Button(role: .destructive) {
                        isShowingDeleteDialog = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .liquidGlassButtonStyle()
                }
                .padding(10)
                .liquidGlassPanel(cornerRadius: 14)
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .navigationTitle(draft.name)
        .id(instance.id)
        .onChange(of: instance) { newInstance in
            draft = newInstance
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
