import SwiftUI

struct LaunchArgsEditorView: View {
    @Binding var arguments: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(arguments.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    TextField("Argument", text: argumentBinding(at: index))

                    Button {
                        arguments.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                arguments.append("")
            } label: {
                Label("Add Launch Argument", systemImage: "plus")
            }
        }
    }

    private func argumentBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { arguments[index] },
            set: { arguments[index] = $0 }
        )
    }
}
