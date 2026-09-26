import AppKit
import SwiftUI

/// **The** tag editor. One popover, opened identically by the left swipe, the
/// context menu, the keyboard, and the preview-header chips — there is no
/// second code path and no second surface. The header is a fourth door into
/// this room, not a second editor: its chips do not toggle, they present this
/// view. Removal lives here, which is the half that was missing from "one
/// editor, not two".
///
/// Two halves, in reading order. On top an `NSTokenField` for tags that do not
/// exist yet — several in one pass. Below, the alphabetical list of the tags the
/// library already has, checkable, which is what stops `projet` being typed next
/// to `projets`.
///
/// # What the suggestion lot added, and what it did not
///
/// Two attachments, both inside this popover — no new surface, no setting, no
/// screen of advice. A **suggested head** above the alphabetical list, read once
/// on open from `LibraryModel.tagSuggestions(for:)`; and a **hygiene line**
/// under the field when what is being typed nearly duplicates an existing tag.
///
/// Both keep the rule that governs the lot: when counting has nothing to say,
/// **nothing is drawn**. No header, no placeholder, no "no suggestions" line, no
/// recent tags standing in. The right to say nothing is the feature — a header
/// over filler is exactly the intrusion this design exists to avoid.
///
/// # Nothing here confirms anything
///
/// Every toggle and every token writes immediately (decided 2026-09-13), the way
/// Finder and Notes behave. There is no OK button and there will not be one: a
/// button would ask "does Escape cancel or commit?", a question with no good
/// answer. Escape closes the popover and that is all it does. If the count of
/// front-matter rewrites ever hurts, the engine coalesces them.
///
/// # Form
///
/// The metrics are the folder-symbol popover's, read from `FolderSymbolPicker`
/// rather than chosen again: width 300, a 260 pt scroller, header inset 14, the
/// radius-6 field box padded 12. Two values for one device is a defect
/// regardless of which looks better in isolation. **Nothing here is tinted**:
/// the focused note-list selection remains the app's one washed surface, and the
/// keyboard highlight in this list is the system's own selection fill, as in the
/// picker.
struct TagPopover: View {
    /// Identity, not state: the snapshots are re-read from the model on every
    /// pass, because every toggle writes and republishes while the popover is
    /// open. Holding stale values here would show the human the tags he had
    /// before his own click.
    let urls: [URL]
    @ObservedObject var model: LibraryModel
    /// What AppKit's own completion menu offers under the caret: the library's
    /// existing tag names, matched on the substring. It stayed exactly that
    /// through the suggestion lot — ranked suggestions are a *section*, read
    /// once on open, not a thing that moves while a word is being typed.
    let completions: (String) -> [String]
    let dismiss: () -> Void

    private enum Half: Hashable { case offer, list }

    /// One line of the checkable column. A suggested tag is also a library tag,
    /// so it is drawn **twice** — once in the head, once in the alphabetical
    /// list, which stays untouched. A bare `String` could not tell the two rows
    /// apart, and the keyboard highlight would land on both at once.
    enum Row: Hashable {
        case suggested(String)
        case library(String)

        var tag: String {
            switch self {
            case .suggested(let tag), .library(let tag): return tag
            }
        }
    }

    @State private var highlighted: Row?
    @FocusState private var focus: Half?
    /// Read **once**, when the popover opens, and never again while it is open.
    ///
    /// Not an optimisation: every toggle writes and republishes, so a live read
    /// would drop a suggestion the moment it was accepted and re-rank the rest
    /// under the pointer. The lot's rule is that nothing reorders while the
    /// popover is open, and freezing here is how that rule is kept.
    @State private var suggestions: [TagSuggestion] = []
    /// The half-typed word, reported by the token field. The hygiene offer is
    /// derived from it rather than stored, so it can never outlive the text.
    @State private var typed = ""
    @State private var fieldHandle = TagTokenField.Handle()

    /// How a tag stands across the selection. Finder's three states: the dash is
    /// the one that could not exist in a per-note editor, and it is why a
    /// multiple selection gets a real answer here instead of a guess.
    ///
    /// Internal, and computed from tag lists rather than from snapshots, so the
    /// rule that decides between a checkmark, a dash and nothing — and the rule
    /// that decides which way a dash toggles — can be tested without a window
    /// and without a library on disk.
    enum Presence {
        case all, some, none

        var symbol: String? {
            switch self {
            case .all: return "checkmark"
            case .some: return "minus"
            case .none: return nil
            }
        }

        /// What a press does next. A dash goes to **on**, which is Finder's
        /// answer and the only one that is not a trap: the first press makes the
        /// selection agree, the second takes the tag off all of it.
        var pressAdds: Bool { self != .all }

        /// Solid chip: the tag is acting (on every note, or mixed). Hollow:
        /// not acting. `.some` is solid — the dash already says "mixed", and a
        /// third fill is not a state this device has.
        var paintsChipActive: Bool { self != .none }

        /// An empty selection has nothing to be present on.
        static func of(_ tag: String, across tagLists: [[String]]) -> Presence {
            guard !tagLists.isEmpty else { return .none }
            let carriers = tagLists.filter { $0.contains(tag) }.count
            if carriers == 0 { return .none }
            return carriers == tagLists.count ? .all : .some
        }

        /// The tags true of **every** note in the selection — what the token
        /// field is seeded with. A tag on only some of them is not a token: the
        /// list below is the surface that can say "some", and a token cannot.
        static func common(across tagLists: [[String]]) -> [String] {
            guard let first = tagLists.first else { return [] }
            var common = Set(first)
            for tags in tagLists.dropFirst() { common.formIntersection(tags) }
            return common.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    private var notes: [NoteSnapshot] { urls.compactMap { model.note(with: $0) } }

    /// Already sorted by `LibraryStore.tags()`, localized-standard ascending.
    private var libraryTags: [String] { model.tags }

    private var commonTags: [String] { Presence.common(across: notes.map(\.tags)) }

    /// The existing tag the word under the caret nearly duplicates, or nil.
    /// Derived, never stored: an offer that outlived its text would invite a
    /// write the human had already typed his way out of.
    private var duplicateOffer: TagDuplicateOffer? {
        guard !typed.isEmpty else { return nil }
        return model.tagDuplicateOffer(for: typed)
    }

    /// Suggestions then the alphabetical list, in the one order the arrows walk.
    private var rows: [Row] { TagPopover.rows(suggested: suggestions, library: libraryTags) }

    var body: some View {
        VStack(spacing: 0) {
            header
            // The field and the hygiene line are one block: the offer is *about*
            // what is in the field, so it sits inside its padding rather than
            // floating between two sections.
            VStack(alignment: .leading, spacing: 6) {
                field
                if let offer = duplicateOffer { offerLine(offer) }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            tagList
        }
        .frame(width: 300)
        .onAppear(perform: loadSuggestions)
        .onExitCommand { dismiss() }
    }

    // MARK: - What the suggested head is made of

    /// Read once, on open. Only a **single** note is suggested for: the engine
    /// ranks one note against the library, and "why this tag" has no three-word
    /// answer for nine notes at once. A multiple selection therefore gets the
    /// alphabetical list alone.
    private func loadSuggestions() {
        let notes = self.notes
        guard notes.count == 1, let only = notes.first else {
            suggestions = []
            return
        }
        suggestions = model.tagSuggestions(for: only)
    }

    /// The navigable column. Pure, so the one rule that matters can be tested
    /// without a window: **no suggestions means no section at all** — the
    /// sequence is the alphabetical list and nothing else, with no header row
    /// and no placeholder standing in for the tags the app has nothing to say
    /// about.
    static func rows(suggested: [TagSuggestion], library: [String]) -> [Row] {
        suggested.map { Row.suggested($0.tag) } + library.map { Row.library($0) }
    }

    /// Whether the head exists. It exists only when the engine returned
    /// something; there is no empty state, because the right to say nothing is
    /// the feature.
    static func showsSuggestedSection(_ suggested: [TagSuggestion]) -> Bool {
        !suggested.isEmpty
    }

    /// The reason, in four words at most. The engine emits no user-facing
    /// string — these are the UI's, and they are the whole justification the
    /// app owes for a suggestion: if it cannot be said here, the suggestion
    /// does not exist.
    ///
    /// Each one is a **standalone statement about the tag**, not a fragment
    /// hung off the row ("in the text", "this folder"). A translator sees the
    /// string and nothing else, and a nominal fragment with no particle and no
    /// verb does not read as a justification in Japanese or Korean — it reads
    /// as a stray noun. The implied subject is the suggested tag itself, so
    /// every language can build a real clause around it. That costs one word
    /// in English and it buys a sentence in seven other languages.
    static func reasonText(_ reason: TagSuggestionReason) -> String {
        switch reason {
        case .inText:
            return NSLocalizedString(
                "Appears in the text", comment: "Why a tag is suggested")
        case .thisFolder:
            return NSLocalizedString(
                "Common in this folder", comment: "Why a tag is suggested")
        case .withTag(let companion):
            return String(
                format: NSLocalizedString(
                    "Often used with #%@", comment: "Why a tag is suggested"),
                companion)
        }
    }

    // MARK: - Header

    /// The picker's header inset, and its job: say what is being edited. One
    /// note shows its title; several show their count, so a toggle that is about
    /// to touch nine files says nine before it does.
    private var header: some View {
        HStack {
            Text(headerTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// `String(localized:)` and **not** `String(format: NSLocalizedString(…))`:
    /// the count key carries plural variations, and a String Catalog compiles
    /// those into a `.stringsdict`-shaped entry whose value is a rule token, not
    /// a sentence. `NSLocalizedString` hands that token back verbatim and plain
    /// `String(format:)` cannot resolve it — the header would print the rule.
    /// The localized-interpolation APIs (`String(localized:)` here, SwiftUI's
    /// `Text("\(count) notes selected")` in the preview pane) are the ones that
    /// pick the form, and both produce the same `%lld notes selected` key, so
    /// the two places stay one entry for the translator.
    private var headerTitle: String {
        let notes = self.notes
        if notes.count == 1, let only = notes.first { return only.title }
        return String(localized: "\(notes.count) notes selected")
    }

    // MARK: - The typing half

    /// The picker's search-field box, to the point: same radius, same insets,
    /// same border. The control inside is an `NSTokenField` instead of a
    /// `TextField`, and that is the only difference.
    private var field: some View {
        TagTokenField(
            initialTokens: commonTags,
            placeholder: NSLocalizedString("Add tags", comment: ""),
            completions: completions,
            onAdd: { tag in model.applyTag(tag, add: true, to: notes) },
            onRemove: { tag in model.applyTag(tag, add: false, to: notes) },
            onTyping: { text in
                typed = text
                // The offer under the caret has just gone: do not strand the
                // keyboard on a line that no longer exists.
                if focus == .offer, text.isEmpty { focus = nil }
            },
            onTab: {
                // Tab walks the popover top to bottom. The offer, when there is
                // one, is a stop on that walk — which is how it is reachable
                // without a pointer, and it is skipped entirely when absent.
                if duplicateOffer != nil {
                    focus = .offer
                } else {
                    if highlighted == nil { highlighted = rows.first }
                    focus = .list
                }
            },
            onEscape: dismiss,
            handle: fieldHandle
        )
        .frame(height: 22)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: .separatorColor))
                )
        )
    }

    // MARK: - The hygiene line

    /// One line, under the field, at the moment a duplicate is born.
    ///
    /// It **offers**; it never rewrites. Ignoring it is the effortless path:
    /// keep typing and it goes, press Return and the tag you wrote is the tag
    /// you get. Only a click, or Tab then Space, takes the existing name
    /// instead. No tint and no alarm colour — it is a sentence, not a warning.
    private func offerLine(_ offer: TagDuplicateOffer) -> some View {
        Button {
            accept(offer)
        } label: {
            Text(String(format: NSLocalizedString("Use \"%@\" instead", comment: ""), offer.existing))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background {
                    if focus == .offer {
                        RoundedRectangle(
                            cornerRadius: RowPalette.selectionCornerRadius, style: .continuous
                        )
                        .fill(RowPalette.emphasizedSelectionBackground)
                    }
                }
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focus, equals: .offer)
        .onKeyPress(.space) { accept(offer); return .handled }
        .onKeyPress(.return) { accept(offer); return .handled }
        .onKeyPress(.tab) {
            if highlighted == nil { highlighted = rows.first }
            focus = .list
            return .handled
        }
    }

    private func accept(_ offer: TagDuplicateOffer) {
        fieldHandle.accept(offer.existing)
        typed = ""
        focus = nil
    }

    // MARK: - The checkable half

    /// A `ScrollView` rather than a `List`, for the same reason the picker uses
    /// one: the arrows, Space and the highlight are written here in full, so
    /// there is no negotiation with a table over which of us owns the keystroke.
    @ViewBuilder
    private var tagList: some View {
        if libraryTags.isEmpty && suggestions.isEmpty {
            Text("No tags in this library yet")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    // Resolved once for the whole list, not once per row: the
                    // snapshots are looked up by URL, and a library with a few
                    // hundred tags would otherwise pay that lookup a few hundred
                    // times on every toggle.
                    let notes = self.notes
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // No suggestions, no section: no header, no separator,
                        // no placeholder. The alphabetical list simply starts.
                        if TagPopover.showsSuggestedSection(suggestions) {
                            suggestedHeader
                            ForEach(suggestions) { suggestion in
                                row(
                                    .suggested(suggestion.tag),
                                    reason: TagPopover.reasonText(suggestion.reason),
                                    in: notes
                                )
                                .id(Row.suggested(suggestion.tag))
                            }
                            Divider()
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                        }
                        ForEach(libraryTags, id: \.self) { tag in
                            row(.library(tag), reason: nil, in: notes)
                                .id(Row.library(tag))
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 12)
                }
                .frame(height: 260)
                .focusable()
                .focused($focus, equals: .list)
                .onKeyPress(.downArrow) { move(by: 1, proxy: proxy) }
                .onKeyPress(.upArrow) { move(by: -1, proxy: proxy) }
                .onKeyPress(.space) {
                    guard let highlighted else { return .ignored }
                    toggle(highlighted.tag)
                    return .handled
                }
            }
        }
    }

    /// The section's one word. Secondary and small — it labels the rows below
    /// it, it does not announce a feature.
    private var suggestedHeader: some View {
        Text("Suggested")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
    }

    /// One row, suggested or alphabetical — **the same row**. No dashed
    /// variant, no paler capsule, no tint: a suggestion is a tag like any other
    /// and the only thing that distinguishes it is where it sits and the three
    /// words beside it. Nothing is pre-checked, and nothing has to be: the
    /// engine never suggests a tag the note already carries, so a suggested
    /// row's mark is empty by construction rather than by a special case.
    private func row(_ item: Row, reason: String?, in notes: [NoteSnapshot]) -> some View {
        let tag = item.tag
        let presence = presence(of: tag, in: notes)
        let isHighlighted = highlighted == item
        return Button {
            highlighted = item
            toggle(tag)
        } label: {
            HStack(spacing: 6) {
                // The mark's width is reserved in all three states, so the names
                // stay on one vertical and the list does not shuffle sideways as
                // tags are toggled.
                Group {
                    if let symbol = presence.symbol {
                        Image(systemName: symbol)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 12, height: 12)
                .font(.caption.weight(.semibold))

                // The reason moves under the tag rather than disappearing when
                // the name needs the width: it is the whole justification the
                // app owes, and a row 300 points wide runs out of room in
                // German long before it does in English. `ViewThatFits` takes
                // the second candidate — the same two pieces, stacked — so the
                // row grows in height instead of going silent. Nothing here
                // fixes a height, and the list scrolls, so a taller row is
                // free. The name is the same chip as a list row: solid when
                // this tag is acting.
                if let reason {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            TagChip(name: tag, isActive: presence.paintsChipActive)
                            Spacer(minLength: 6)
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        HStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 2) {
                                TagChip(name: tag, isActive: presence.paintsChipActive)
                                Text(reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                } else {
                    TagChip(name: tag, isActive: presence.paintsChipActive)
                    Spacer(minLength: 0)
                }
            }
            .font(.body)
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                if isHighlighted {
                    RoundedRectangle(
                        cornerRadius: RowPalette.selectionCornerRadius, style: .continuous
                    )
                    .fill(
                        focus == .list
                            ? RowPalette.emphasizedSelectionBackground
                            : RowPalette.unfocusedSelectionBackground
                    )
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(tag))
        .accessibilityAddTraits(presence == .all ? [.isSelected] : [])
    }

    // MARK: - Behaviour

    private func presence(of tag: String, in notes: [NoteSnapshot]) -> Presence {
        Presence.of(tag, across: notes.map(\.tags))
    }

    private func toggle(_ tag: String) {
        let notes = self.notes
        guard !notes.isEmpty else { return }
        model.applyTag(tag, add: presence(of: tag, in: notes).pressAdds, to: notes)
    }

    /// The arrows walk the suggested head and the alphabetical list as **one**
    /// sequence, so a suggestion is never a pointer-only zone and the boundary
    /// between the two is not a wall.
    private func move(by offset: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        let rows = self.rows
        guard !rows.isEmpty else { return .ignored }
        let current = highlighted.flatMap { rows.firstIndex(of: $0) }
        let next: Int
        if let current {
            next = min(max(current + offset, 0), rows.count - 1)
        } else {
            next = offset > 0 ? 0 : rows.count - 1
        }
        highlighted = rows[next]
        proxy.scrollTo(rows[next], anchor: nil)
        return .handled
    }
}
