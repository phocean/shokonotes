import SwiftUI

/// The tag chip. One view, one geometry, read only from `RowPalette`.
///
/// Hollow is at rest: the note carries this name. Solid is acting: the name is
/// checked in the tag popover, or it is currently filtering the note list.
/// Call sites pass `isActive` by value; the chip does not reach for a model.
///
/// Not a control. The preview header wraps it in a button that opens
/// `TagPopover`. A list row does not: clicking a row chip must not toggle
/// the filter.
struct TagChip: View {
    let name: String
    let isActive: Bool

    /// Solid iff this name is among the tags currently filtering the list.
    static func isActive(_ name: String, filters: Set<String>) -> Bool {
        filters.contains(name)
    }

    var body: some View {
        Text(name)
            .font(isActive ? RowPalette.tagActiveFont : RowPalette.tagFont)
            .foregroundStyle(isActive ? RowPalette.tagActiveText : RowPalette.tagText)
            .lineLimit(1)
            .padding(.horizontal, RowPalette.tagPaddingH)
            .padding(.vertical, RowPalette.tagPaddingV)
            .background { chipFill }
            .overlay { chipStroke }
    }

    private var chipFill: some View {
        Capsule().fill(isActive ? RowPalette.tagActiveFill : Color.clear)
    }

    private var chipStroke: some View {
        Capsule().strokeBorder(
            isActive ? Color.clear : RowPalette.tagBorder,
            lineWidth: RowPalette.tagStroke
        )
    }

    /// The dashed `+` that joins the header chip row. Same capsule, same
    /// padding, same hairline — dashed rather than solid, so it reads as a
    /// door and not as a tag the note already carries.
    struct Add: View {
        var body: some View {
            Image(systemName: "plus")
                .font(RowPalette.tagFont)
                .foregroundStyle(RowPalette.tagText)
                .padding(.horizontal, RowPalette.tagPaddingH)
                .padding(.vertical, RowPalette.tagPaddingV)
                .overlay {
                    Capsule().strokeBorder(
                        RowPalette.tagBorder,
                        style: StrokeStyle(
                            lineWidth: RowPalette.tagStroke,
                            dash: RowPalette.tagDash
                        )
                    )
                }
                .accessibilityHidden(true)
        }
    }
}
