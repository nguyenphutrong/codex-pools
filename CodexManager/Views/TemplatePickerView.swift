import SwiftUI

struct TemplatePickerView: View {
    @EnvironmentObject private var store: InstanceStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Instance")
                .font(.headline)

            VStack(spacing: 8) {
                Button {
                    store.createInstance()
                    dismiss()
                } label: {
                    TemplateRow(
                        title: "Blank",
                        subtitle: "Start with the default Codex instance settings.",
                        systemImage: "plus.square"
                    )
                }
                .buttonStyle(.plain)

                ForEach(store.templates) { template in
                    Button {
                        store.createInstance(from: template)
                        dismiss()
                    } label: {
                        TemplateRow(
                            title: template.name,
                            subtitle: "~/.codex/\(template.safeHomePathSuffix)",
                            systemImage: template.iconName ?? "square.stack.3d.up"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

private struct TemplateRow: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(10)
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
