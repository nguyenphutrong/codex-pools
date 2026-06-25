import AppKit
import SwiftUI

struct IconPickerView: View {
    @EnvironmentObject private var store: InstanceStore
    @Binding var iconPath: String?

    var body: some View {
        VStack(spacing: 8) {
            CodexIconImage(iconPath: iconPath)
                .frame(width: 72, height: 72)

            HStack(spacing: 8) {
                Button {
                    pickIcon()
                } label: {
                    Label("Pick", systemImage: "photo")
                }

                if iconPath != nil {
                    Button {
                        iconPath = nil
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .labelStyle(.iconOnly)
        }
    }

    private func pickIcon() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.icns, .png, .jpeg, .tiff, .gif, .bmp]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        iconPath = store.copyIcon(from: url)
    }
}
