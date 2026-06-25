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
                store.showTemplatePicker()
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
    @EnvironmentObject private var store: InstanceStore
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

                HStack(spacing: 6) {
                    if store.isRunning(instance) {
                        InstanceStateBadge(title: "Running", systemImage: "circle.fill", tint: .green)
                    }

                    BundleStatusBadge(status: instance.bundleStatus)
                }
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

struct BundleStatusBadge: View {
    let status: CodexInstance.BundleStatus

    var body: some View {
        switch status {
        case .ready:
            InstanceStateBadge(title: "Ready", systemImage: "checkmark.circle.fill", tint: .secondary)
        case .needsRebuild:
            InstanceStateBadge(title: "Needs rebuild", systemImage: "exclamationmark.triangle.fill", tint: .orange)
        case .missingSourceApp:
            InstanceStateBadge(title: "Missing Codex.app", systemImage: "xmark.octagon.fill", tint: .red)
        }
    }
}

struct InstanceStateBadge: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
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
