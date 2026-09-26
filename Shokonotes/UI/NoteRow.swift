import SwiftUI

struct NoteRow: View {
    let title: String
    let excerpt: String
    let tags: [String]
    let date: Date
    let folderPath: String?
    let fileName: String
    let fileExtension: String
    let showFileName: Bool
    let isPinned: Bool
    var showExcerpt: Bool = true
    var showDate: Bool = true
    var showTags: Bool = true
    var showFolder: Bool = false
    var compact: Bool = false
    let activeTags: Set<String>

    init(
        note: NoteSnapshot,
        showExcerpt: Bool = true,
        showDate: Bool = true,
        showTags: Bool = true,
        showFolder: Bool = false,
        compact: Bool = false,
        activeTags: Set<String> = []
    ) {
        self.title = note.title
        self.excerpt = note.excerpt
        self.tags = note.tags
        self.date = note.modifiedAt
        self.folderPath = note.folderPathLabel
        self.fileName = note.fileName
        self.fileExtension = note.fileExtension
        self.showFileName = note.fileStemDiffersFromTitle
        self.isPinned = note.isPinned
        self.showExcerpt = showExcerpt
        self.showDate = showDate
        self.showTags = showTags
        self.showFolder = showFolder
        self.compact = compact
        self.activeTags = activeTags
    }

    private var visibleExcerpt: String? {
        guard showExcerpt, !excerpt.isEmpty else { return nil }
        if excerpt.caseInsensitiveCompare(title) == .orderedSame { return nil }
        return excerpt
    }

    /// The selected row is a wash the list background shows through, so the
    /// labels never change colour: primary stays primary, secondary stays
    /// secondary, in both themes and in every selection state.
    private var primaryLabel: Color { .primary }
    private var secondaryLabel: Color { Color(nsColor: .secondaryLabelColor) }

    private var visibleFolderPath: String? {
        guard showFolder, let folderPath, !folderPath.isEmpty else { return nil }
        return folderPath
    }

    private var showsContextLine: Bool {
        !compact && (visibleFolderPath != nil || showFileName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if isPinned {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(RowPalette.pinForeground)
                        .imageScale(.small)
                }

                Text(title)
                    .font(compact ? .subheadline.weight(.semibold) : .headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(primaryLabel)

                Spacer(minLength: 8)

                if showDate {
                    Text(Self.formatted(date))
                        .font(compact ? .caption : .subheadline)
                        .foregroundStyle(secondaryLabel)
                        .layoutPriority(1)
                }
            }

            if showsContextLine {
                contextLine
            }

            if showTags, !tags.isEmpty {
                tagLine
            }

            if let visibleExcerpt {
                Text(visibleExcerpt)
                    .font(compact ? .caption : .subheadline)
                    .foregroundStyle(secondaryLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, compact ? 2 : 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        // No background here: the selection is handed to the list through
        // `listRowBackground` (see `NoteRowBackground`), which owns the whole
        // row. Painting inside the content could never reach the few points the
        // list keeps for itself on either side.
        //
        // The horizontal padding is 16 against a band inset by 8, which leaves
        // 8 pt of margin inside the band — the same 8 everywhere in the scale.
        .contentShape(Rectangle())
    }

    /// Folder path and file name on one line: symbol, path, a middle dot, symbol,
    /// file name. The path is what locates the note, so it is the one that keeps
    /// its width; the file name is the technical detail and gives way first —
    /// that is what the layout priority says, and it does not need to be said a
    /// second time by dimming the file name: `secondary × 0.8` measures 2.83:1,
    /// under the threshold. When only the file name is shown, which is the common
    /// case outside search, the separator and the folder symbol are not drawn at
    /// all.
    ///
    /// This line is the one genuinely subordinate level in the row, and `.caption`
    /// is its floor: 13 / 11 / 10 from the title down. On macOS `.footnote`,
    /// `.caption` and `.caption2` all resolve to 10 pt Regular, so going below
    /// `.caption` buys nothing and `.imageScale(.small)` would only make the
    /// glyphs smaller than the 10 pt text beside them.
    @ViewBuilder
    private var contextLine: some View {
        HStack(spacing: 4) {
            if let visibleFolderPath {
                Image(systemName: "folder")
                Text(visibleFolderPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(2)
            }

            if showFileName {
                if visibleFolderPath != nil {
                    Text(verbatim: "·")
                        .accessibilityHidden(true)
                }
                Image(systemName: "doc")
                Text("\(fileName).\(fileExtension)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
            }
        }
        .font(.caption)
        .foregroundStyle(secondaryLabel)
    }

    /// One tag symbol at the head of the row, not one per chip: the chips
    /// already read as tags, and a repeated glyph would only add noise. The
    /// symbol is what makes the line legible at a glance next to the folder and
    /// file line above it. A chip is solid only when its name is among the
    /// tags currently filtering the list — passed in by value, not read from
    /// the model. The row is not a control; a click does not toggle the filter.
    @ViewBuilder
    private var tagLine: some View {
        HStack(spacing: 4) {
            Image(systemName: "tag")
                .font(.caption)
                .foregroundStyle(secondaryLabel)
                .accessibilityHidden(true)

            ForEach(tags.prefix(6), id: \.self) { tag in
                TagChip(name: tag, isActive: TagChip.isActive(tag, filters: activeTags))
            }
        }
        .lineLimit(1)
    }

    static func formatted(_ date: Date) -> String {
        RowDateLabel.string(for: date)
    }
}

/// The selected row's tint, handed to the list rather than painted inside the
/// row. `listRowBackground` is the row's background, but — measured, not assumed —
/// it does **not** replace the highlight the table draws: it composites on top of
/// it. That is what `ListHighlightSuppressor` is for, and why it is attached here
/// rather than to the selected rows only.
///
/// An inset rounded rectangle, as in Notes: margins on both sides, not a band
/// across the column. One radius, one inset, in all four states: focused,
/// unfocused, inactive window, multiple selection.
/// `isEmphasized` arrives **by value**, and that is not a style preference.
/// Read as `@Environment(\.controlActiveState)` *here*, it measured `.inactive`
/// on a foreground window with the keyboard in the list: a `listRowBackground`
/// view is not in the row's own environment chain, so the window's active state
/// never reached it and the wash never appeared — the row stayed on the grey.
/// The caller is in the chain, works it out, and hands it over.
///
/// This is a SwiftUI problem and it stops at this column. The folder column is
/// an `NSOutlineView` (`SidebarSourceList`): it draws its own selection in
/// AppKit, from the row view's `isSelected` and `isEmphasized`, and
/// `controlActiveState` plays no part in it at all.
struct NoteRowBackground: View {
    let isSelected: Bool
    let isEmphasized: Bool

    var body: some View {
        // On every row, selected or not, so the table's own highlight is switched
        // off before the first selection is made and again after any rebuild.
        fill.suppressingListHighlight()
    }

    @ViewBuilder
    private var fill: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: RowPalette.selectionCornerRadius, style: .continuous)
                .fill(
                    isEmphasized
                        ? RowPalette.selectionBackground
                        : RowPalette.unfocusedSelectionBackground
                )
                .padding(.horizontal, RowPalette.selectionInset)
                .padding(.vertical, RowPalette.selectionVerticalInset)
        } else {
            Color.clear
        }
    }
}

/// The list asks for a date label once per row and again on every redraw, and
/// the answer depends on what "today" means. The day's boundaries and the three
/// format styles are worked out once and reused; crossing midnight (or the
/// clock moving backwards) lands outside the cached day and rebuilds it, so
/// "Yesterday" never gets stuck on a window left open overnight.
@MainActor
private enum RowDateLabel {
    private static var dayStart = Date.distantFuture
    private static var dayEnd = Date.distantPast
    private static var yesterdayStart = Date.distantPast
    private static var yearStart = Date.distantFuture
    private static var yearEnd = Date.distantPast

    private static let timeStyle = Date.FormatStyle(date: .omitted, time: .shortened)
    private static let monthDayStyle = Date.FormatStyle.dateTime.month(.abbreviated).day()
    private static let dateStyle = Date.FormatStyle(date: .abbreviated, time: .omitted)

    static func string(for date: Date) -> String {
        refresh()
        if date >= dayStart, date < dayEnd {
            return date.formatted(timeStyle)
        }
        if date >= yesterdayStart, date < dayStart {
            return NSLocalizedString("Yesterday", comment: "")
        }
        if date >= yearStart, date < yearEnd {
            return date.formatted(monthDayStyle)
        }
        return date.formatted(dateStyle)
    }

    private static func refresh() {
        let now = Date()
        guard now >= dayEnd || now < dayStart else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        dayStart = today
        dayEnd = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        yesterdayStart = calendar.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-86_400)
        // A new year always starts on a new day, so the year window is rebuilt
        // by the same check.
        let year = calendar.dateInterval(of: .year, for: now)
        yearStart = year?.start ?? today
        yearEnd = year?.end ?? dayEnd
    }
}
