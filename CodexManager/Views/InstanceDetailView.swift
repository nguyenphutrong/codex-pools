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
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Configuration") {
                TextField("Name", text: nameBinding)
                TextField("CODEX_HOME", text: $draft.codexHome)
            }

            Section("Activity") {
                LabeledContent("Created", value: draft.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Last launched", value: lastLaunchedText)
            }

            Section {
                HStack {
                    Button {
                        Task { await store.launch(draft) }
                    } label: {
                        Label("Launch", systemImage: "play.fill")
                    }
                    .keyboardShortcut(.return, modifiers: [.command])

                    Button {
                        store.update(draft)
                    } label: {
                        Label("Save", systemImage: "checkmark")
                    }
                    .keyboardShortcut("s", modifiers: [.command])
                    .disabled(!canSave)

                    Button {
                        duplicateName = "\(draft.name) Copy"
                        isShowingDuplicateSheet = true
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }

                    Spacer()

                    Button(role: .destructive) {
                        isShowingDeleteDialog = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
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
            !draft.codexHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
