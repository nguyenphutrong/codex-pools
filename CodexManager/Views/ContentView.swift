import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: InstanceStore

    var body: some View {
        NavigationSplitView {
            InstanceListView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if let instance = store.selectedInstance {
                InstanceDetailView(instance: instance)
            } else {
                EmptyInstanceView()
            }
        }
        .alert("Codex Pools", isPresented: errorBinding) {
            Button("OK") {
                store.errorMessage = nil
            }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .confirmationDialog(
            "Import Configuration",
            isPresented: importPromptBinding,
            titleVisibility: .visible
        ) {
            Button("Merge with Existing Instances") {
                store.importPendingInstances(mode: .merge)
            }

            Button("Replace Existing Instances", role: .destructive) {
                store.importPendingInstances(mode: .replace)
            }

            Button("Cancel", role: .cancel) {
                store.cancelPendingImport()
            }
        } message: {
            Text("Choose whether to merge the selected configuration into the current list or replace the current list.")
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.selectConfigurationForImport()
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }

                Button {
                    store.exportInstances()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(store.instances.isEmpty)
            }
        }
        .sheet(isPresented: $store.isShowingTemplatePicker) {
            TemplatePickerView()
                .environmentObject(store)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )
    }

    private var importPromptBinding: Binding<Bool> {
        Binding(
            get: { store.pendingImportedInstances != nil },
            set: { if !$0 { store.cancelPendingImport() } }
        )
    }
}

private struct EmptyInstanceView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No Instances")
                .font(.title3.weight(.semibold))
            Text("Create an instance to launch Codex with an isolated CODEX_HOME.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
