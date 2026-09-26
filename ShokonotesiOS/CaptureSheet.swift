import SwiftUI

struct CaptureSheet: View {
    @ObservedObject var library: LibraryModel
    var onFinished: () -> Void

    @State private var draft = ""
    @State private var sealed = false
    @FocusState private var editorFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($editorFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Start writing…")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            .navigationTitle("New Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { finish(save: false) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { finish(save: true) }
                }
            }
        }
        .onAppear { editorFocused = true }
        .onDisappear { finish(save: true) }
    }

    /// One write, on Done or on a non-cancel dismiss. Empty text creates nothing.
    /// The caller dismisses; it must not push the new note.
    private func finish(save: Bool) {
        guard !sealed else { return }
        sealed = true
        if save { _ = library.captureInboxNote(text: draft) }
        onFinished()
    }
}
