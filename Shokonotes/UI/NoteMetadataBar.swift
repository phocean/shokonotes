import SwiftUI

struct NoteMetadataBar: View {
    let note: NoteSnapshot
    @ObservedObject var model: LibraryModel
    /// Tags currently filtering the list, by value. A chip is solid iff its
    /// name is in this set; the bar does not read `LibraryModel.shared`.
    let activeTags: Set<String>
    let completions: (String) -> [String]
    /// Presented from `LibraryView` so a row-anchored popover and this one
    /// cannot both be on screen: opening either dismisses the other.
    @Binding var tagEditorPresented: Bool
    var onWillPresentTagEditor: () -> Void

    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .focused($titleFocused)
                .onSubmit { commitTitle() }

            if note.fileStemDiffersFromTitle {
                HStack(spacing: 8) {
                    Text("\(note.fileName).\(note.fileExtension)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Rename file") {
                        _ = model.matchFilenameToTitle(note)
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
            }

            tagRow
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .onAppear { titleDraft = note.title }
        .onChange(of: note.url) { _, _ in
            titleDraft = note.title
            tagEditorPresented = false
        }
        .onChange(of: note.title) { _, new in
            if !titleFocused { titleDraft = new }
        }
        .onChange(of: titleFocused) { _, focused in
            if !focused { commitTitle() }
        }
    }

    /// The same chip as a note-list row: one device, one geometry, read from
    /// `RowPalette`. Clicking any chip, or the dashed `+`, opens the existing
    /// `TagPopover` — a fourth door, not a second editor. No inline `×`.
    ///
    /// The `+` is shown even when the note has no tags, so the header still
    /// has a door. Tab from the title field reaches this row; the row is a
    /// focus section of its own and is not the preview pane's default focus,
    /// so a right arrow from the note list still lands on the preview.
    ///
    /// No `tag` glyph here, and it is not an omission to be "fixed": in a list row
    /// the glyph disambiguates a line that follows a `folder` line and a `doc` line.
    /// In the header there is nothing to disambiguate — the chip *is* the sign —
    /// and a leading glyph would steal the chips' alignment on the title's own
    /// vertical.
    private var tagRow: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(note.tags, id: \.self) { tag in
                Button(action: presentTagEditor) {
                    TagChip(name: tag, isActive: TagChip.isActive(tag, filters: activeTags))
                }
                .buttonStyle(.plain)
                .focusable()
                .accessibilityLabel(tag)
            }
            Button(action: presentTagEditor) {
                TagChip.Add()
            }
            .buttonStyle(.plain)
            .focusable()
            .accessibilityLabel(Text("Add tags"))
        }
        .focusSection()
        .popover(isPresented: $tagEditorPresented, arrowEdge: .bottom) {
            TagPopover(
                urls: [note.url],
                model: model,
                completions: completions,
                dismiss: { tagEditorPresented = false }
            )
        }
    }

    private func presentTagEditor() {
        onWillPresentTagEditor()
        tagEditorPresented = true
    }

    private func commitTitle() {
        model.setTitle(note, to: titleDraft)
    }
}
