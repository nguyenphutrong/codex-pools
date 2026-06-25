import AppKit
import SwiftUI

struct InstanceListView: View {
    @EnvironmentObject private var store: InstanceStore

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $store.selectedInstanceID) {
                ForEach(store.instances) { instance in
                    InstanceRow(instance: instance)
                        .tag(instance.id)
                }
            }
            .listStyle(.sidebar)

            Divider()

            Button {
                store.createInstance()
            } label: {
                Label("New Instance", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(12)
        }
        .navigationTitle("Instances")
    }
}

private struct InstanceRow: View {
    let instance: CodexInstance

    var body: some View {
        HStack(spacing: 10) {
            CodexIconImage(iconPath: instance.iconPath)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(instance.name)
                    .lineLimit(1)
                Text(instance.codexHome)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(lastLaunchedText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private var lastLaunchedText: String {
        guard let lastLaunchedAt = instance.lastLaunchedAt else {
            return "Never launched"
        }

        return "Last launched \(lastLaunchedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

struct CodexIconImage: View {
    let iconPath: String?

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var image: NSImage {
        if let iconPath, let custom = NSImage(contentsOfFile: iconPath) {
            return custom
        }

        return NSWorkspace.shared.icon(forFile: "/Applications/Codex.app")
    }
}
