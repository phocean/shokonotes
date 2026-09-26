import SwiftUI

enum IOSFilingSheet: Identifiable {
    case tags(URL)
    case move(URL)

    var id: String {
        switch self {
        case .tags(let url): return "tags:" + url.path
        case .move(let url): return "move:" + url.path
        }
    }
}

extension View {
    /// Leading Pin + Tags…, trailing Trash — or Restore + Delete Forever in
    /// Trash. Tags… is the Mac's own leading swipe, and it does not exist on
    /// a trashed note.
    ///
    /// The swipe acts on the row it was made on, not on the selection: a
    /// swipe names its own note, the way Mail's does, and tagging nine other
    /// notes because they happened to be selected would be a surprise. These
    /// lists have no multiple selection at all, so it is already true here —
    /// nothing may introduce one.
    ///
    /// `onTags` is the closure the context menu already uses: one path to the
    /// tag editor, never two.
    func iosNoteRowActions(
        note: NoteSnapshot,
        library: LibraryModel,
        onTags: @escaping () -> Void,
        onMove: @escaping () -> Void,
        onDeleteForever: @escaping () -> Void
    ) -> some View {
        swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                library.togglePin([note])
            } label: {
                Label(
                    note.isPinned ? "Unpin" : "Pin",
                    systemImage: note.isPinned ? "pin.slash.fill" : "pin.fill"
                )
            }
            .tint(.orange)
            if !note.isTrashed {
                Button(action: onTags) {
                    Label("Tags…", systemImage: "tag")
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: !note.isTrashed) {
            if note.isTrashed {
                Button {
                    library.restore([note])
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                .tint(.green)
                Button(role: .destructive) {
                    onDeleteForever()
                } label: {
                    Label("Delete Forever", systemImage: "trash")
                }
            } else {
                Button(role: .destructive) {
                    library.delete([note])
                } label: {
                    Label("Trash", systemImage: "trash")
                }
            }
        }
        .contextMenu {
            Button {
                library.togglePin([note])
            } label: {
                Label(
                    note.isPinned ? "Unpin" : "Pin",
                    systemImage: note.isPinned ? "pin.slash" : "pin"
                )
            }
            Button(action: onTags) {
                Label("Tags…", systemImage: "tag")
            }
            if !note.isTrashed {
                Button(action: onMove) {
                    Label("Move", systemImage: "folder")
                }
                ShareLink(item: note.url, preview: SharePreview(note.title)) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
                let favourite = Favourite.note(note.relativePath)
                if library.isFavourite(favourite) {
                    Button {
                        library.removeFavourite(favourite)
                    } label: {
                        Label("Remove from Favourites", systemImage: "star.slash")
                    }
                } else {
                    Button {
                        library.addFavourite(favourite)
                    } label: {
                        Label("Add to Favourites", systemImage: "star")
                    }
                }
                Button(role: .destructive) {
                    library.delete([note])
                } label: {
                    Label("Trash", systemImage: "trash")
                }
            } else {
                Button {
                    library.restore([note])
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                Button(role: .destructive, action: onDeleteForever) {
                    Label("Delete Forever", systemImage: "trash")
                }
            }
        }
    }
}

/// Note’s tags with remove, a field to add, library names as typed matches.
/// `tagSuggestions` is read once on open.
struct IOSTagsSheet: View {
    let url: URL
    @ObservedObject var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var suggestions: [TagSuggestion] = []
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                if let note, !note.tags.isEmpty {
                    Section {
                        ForEach(note.tags, id: \.self) { tag in
                            HStack(spacing: 10) {
                                IOSTagChip(
                                    name: tag,
                                    isActive: IOSTagChip.isActive(tag, filters: library.selectedTags)
                                )
                                Spacer(minLength: 8)
                                Button {
                                    library.applyTag(tag, add: false, to: [note])
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove tag")
                            }
                        }
                    }
                }

                Section {
                    TextField("Add tags", text: $draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($fieldFocused)
                        .submitLabel(.done)
                        .onSubmit(addDraft)
                    if let offer {
                        Button {
                            add(offer.existing)
                        } label: {
                            Text(String(
                                format: String(localized: "Use \"%@\" instead"),
                                offer.existing
                            ))
                        }
                    }
                    ForEach(matchingLibraryTags, id: \.self) { tag in
                        Button {
                            add(tag)
                        } label: {
                            Text(tag)
                        }
                    }
                }

                if let note {
                    let open = suggestions.filter { !note.tags.contains($0.tag) }
                    if !open.isEmpty {
                        Section("Suggested") {
                            ForEach(open) { item in
                                Button {
                                    add(item.tag)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.tag)
                                        Text(reasonLabel(item.reason))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if let note {
                    suggestions = library.tagSuggestions(for: note)
                }
                fieldFocused = true
            }
        }
    }

    private var note: NoteSnapshot? { library.note(with: url) }

    private var offer: TagDuplicateOffer? {
        library.tagDuplicateOffer(for: draft)
    }

    private var matchingLibraryTags: [String] {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.count >= 1, let note else { return [] }
        let owned = Set(note.tags)
        return library.tags
            .filter { tag in
                !owned.contains(tag) && tag.localizedStandardContains(typed)
            }
            .prefix(10)
            .map { $0 }
    }

    private func addDraft() {
        add(draft)
    }

    private func add(_ tag: String) {
        let name = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let note else { return }
        draft = ""
        guard !note.tags.contains(name) else { return }
        library.applyTag(name, add: true, to: [note])
    }

    private func reasonLabel(_ reason: TagSuggestionReason) -> String {
        switch reason {
        case .inText:
            return String(localized: "in the text")
        case .thisFolder:
            return String(localized: "this folder")
        case .withTag(let tag):
            return String(format: String(localized: "with #%@" ), tag)
        }
    }
}

/// Inbox (library root) plus the folder tree. One tap moves and dismisses.
struct IOSMoveSheet: View {
    let url: URL
    @ObservedObject var library: LibraryModel
    var onRelocated: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        move(to: library.rootURL)
                    } label: {
                        Label("Inbox", systemImage: "tray")
                    }
                    .disabled(isInInbox)
                }
                if !folders.isEmpty {
                    Section("Folders") {
                        ForEach(folders) { folder in
                            Button {
                                move(to: folder.url)
                            } label: {
                                Label(folder.name, systemImage: folderImage(folder.symbol))
                            }
                            .disabled(isCurrent(folder.url))
                        }
                    }
                }
            }
            .navigationTitle("Move")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var note: NoteSnapshot? { library.note(with: url) }

    private var folders: [FolderSnapshot] { library.allFoldersFlat() }

    private var isInInbox: Bool {
        guard let note, let root = library.rootURL else { return false }
        return note.folderURL.standardizedFileURL == root.standardizedFileURL
    }

    private func isCurrent(_ folder: URL) -> Bool {
        guard let note else { return false }
        return note.folderURL.standardizedFileURL == folder.standardizedFileURL
    }

    private func move(to folder: URL?) {
        guard let folder, let note else { return }
        library.move([note], to: folder)
        onRelocated()
        dismiss()
    }

    private func folderImage(_ symbol: String?) -> String {
        let name = symbol?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "folder" : name
    }
}
