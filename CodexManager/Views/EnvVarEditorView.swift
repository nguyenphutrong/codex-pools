import SwiftUI

struct EnvVarEditorView: View {
    @Binding var variables: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(variables.keys.sorted(), id: \.self) { key in
                HStack(spacing: 8) {
                    TextField("Key", text: keyBinding(for: key))
                    TextField("Value", text: valueBinding(for: key))

                    Button {
                        variables.removeValue(forKey: key)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                addVariable()
            } label: {
                Label("Add Environment Variable", systemImage: "plus")
            }
        }
    }

    private func keyBinding(for key: String) -> Binding<String> {
        Binding(
            get: { key },
            set: { newKey in
                let value = variables.removeValue(forKey: key) ?? ""
                variables[newKey] = value
            }
        )
    }

    private func valueBinding(for key: String) -> Binding<String> {
        Binding(
            get: { variables[key] ?? "" },
            set: { variables[key] = $0 }
        )
    }

    private func addVariable() {
        var index = variables.count + 1
        var key = "NEW_VARIABLE_\(index)"

        while variables.keys.contains(key) {
            index += 1
            key = "NEW_VARIABLE_\(index)"
        }

        variables[key] = ""
    }
}
