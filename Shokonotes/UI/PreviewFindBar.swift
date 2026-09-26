import SwiftUI

/// Find within the shown note. The web view does the searching — `window.find`
/// wraps around on its own, which is what makes the arrows circular — so this
/// carries no match count, only whether the last search hit anything.
struct PreviewFindBar: View {
    @ObservedObject var model: LibraryModel
    @FocusState private var focused: Bool
    @State private var missing = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Find in Note", text: $model.previewFindQuery)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { step(backwards: false) }
                .onChange(of: model.previewFindQuery) { _, query in
                    // Do not search here: the host already runs find when
                    // `findQuery` changes. A second `window.find` wrap-arounds
                    // and skips the hit.
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        missing = false
                    }
                }
                .frame(minWidth: 120, maxWidth: 280)

            if missing, !model.previewFindQuery.isEmpty {
                Text("No results")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button { step(backwards: true) } label: {
                Image(systemName: "chevron.up")
            }
            .help("Find Previous")

            Button { step(backwards: false) } label: {
                Image(systemName: "chevron.down")
            }
            .help("Find Next")

            Spacer(minLength: 0)

            Button("Done") { close() }
                .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .onAppear {
            focused = true
            PreviewBridge.shared.onFindResult = { found in missing = !found }
        }
        .onDisappear { PreviewBridge.shared.onFindResult = nil }
        // The menu item re-opens an already open bar; that is a request for the
        // caret, not for a second bar.
        .onChange(of: model.previewFindFocus) { _, _ in focused = true }
        .onExitCommand { close() }
    }

    private func step(backwards: Bool) {
        let query = model.previewFindQuery
        guard !query.isEmpty else {
            missing = false
            return
        }
        PreviewBridge.shared.find(query, backwards: backwards) { found in
            missing = !found
        }
    }

    private func close() {
        model.hidePreviewFind()
        PreviewBridge.shared.becomeFirstResponder()
    }
}
