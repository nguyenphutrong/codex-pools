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
