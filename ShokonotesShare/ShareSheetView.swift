import SwiftUI

struct ShareSheetView: View {
    @ObservedObject var model: ShareModel
    @FocusState private var editorFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if model.didSave {
                    confirmation
                } else {
                    editor
                }
            }
            .navigationTitle("Shokonotes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !model.didSave {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { model.cancel() }
                            .disabled(model.isPosting)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Post") { model.post() }
                            .disabled(model.isLoading || model.isPosting)
                    }
                }
            }
        }
    }

    private var confirmation: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("Added to Inbox")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $model.draft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .disabled(model.isLoading || model.isPosting)
            if model.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: model.isLoading) { _, loading in
            if !loading { editorFocused = true }
        }
    }
}
