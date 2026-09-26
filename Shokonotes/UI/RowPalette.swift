import SwiftUI
import AppKit

/// The one place the library's row form and row colours are written down.
///
/// The note list paints its focused selection in the app's chocolate wash
/// instead of the system accent — a product decision, so that the selected note
/// is tied to Shokonotes' identity. It applies to the note list only: sidebar
/// folders keep the system selection colour, which is the macOS convention for a
/// source list.
///
/// Every colour below is a dynamic `NSColor`, so light and dark are resolved by
/// AppKit from the view's own appearance rather than by a `colorScheme` read in
/// a view body. The wash is the identity; the pin is a mark of the same hue,
/// not a second surface. A tag chip is a hairline at rest and a solid fill
/// when it is acting — never a wash of the identity colour.
enum RowPalette {
    /// A **pale wash** of the app's colour, the way Notes tints its selected row
    /// in a soft yellow and keeps the text dark. A dark block with cream text was
    /// the problem, not the shade of the block.
    ///
    /// Two deliberate choices. The wash is **opaque**, not an alpha: the list
    /// background is always `textBackgroundColor`, so an alpha composes with
    /// nothing and only makes the shipped value indirect. And the character comes
    /// from **chroma, not alpha**: raising alpha darkens the wash and eats the
    /// contrast of the labels sitting on it, while raising saturation at a held
    /// luminance buys the warmth for free.
    ///
    /// **Colour weight follows area.** The geometry is shared with the sidebar —
    /// radius 8, inset 8 — but the band is not: a list row is roughly
    /// 70 × 364 pt against the sidebar's 24 × 204, 5.2 times the area. Carrying
    /// the heavier colour on the larger surface was backwards. A sidebar row can
    /// hold a flat strong fill across one line; four lines of a list row can hold
    /// only a wash. Hence `#E1C2A3` light and `#524539` dark (same hue as
    /// `#DBBD9E` / `#574A3D`, a smaller luminance step than the rejected
    /// `#E3CCB4`).
    ///
    /// Labels are untouched by all of this, which is the point: the row keeps the
    /// colours of an unselected row, `.primary` and `.secondary`, in all four
    /// states and both themes. Title 9.88:1 light on this wash; secondary 3.67:1,
    /// still under 4.5:1 — reaching that floor would be paler than `#E3CCB4`.
    static let selectionBackground = Color(nsColor: dynamicColor(light: 0xE1C2A3, dark: 0x524539))

    /// The keyboard is elsewhere, or the window is inactive: the system grey, in
    /// the same inset shape. That is what Notes does, and what the rest of macOS
    /// does.
    ///
    /// Written as `quaternaryLabelColor` **flattened onto the paper** rather than
    /// laid over it as an alpha, so the value cannot drift with whatever sits
    /// behind the list.
    ///
    /// In dark mode "lighter" inverts: raising luminance over `#1E1E1E` paper
    /// makes the row heavier, not lighter. What is wanted is *less distance from
    /// the paper*, so the dark grey comes **down** from `#464646` to `#343434` —
    /// 1.77:1 to 1.34:1 against the paper, the largest single gain of the set.
    /// Pulling the grey towards the paper is also what opens the gap the focused
    /// wash needs: focus distinction goes from 1.11:1 to 1.43:1 in light.
    static let unfocusedSelectionBackground = Color(nsColor: dynamicColor(light: 0xE6E6E6, dark: 0x343434))

    /// The fill for an **emphasized** selection outside the note list — the
    /// focused sidebar row, and the sidebar drop target. Never `Color.accentColor`:
    /// AppKit does not fill with the raw accent, and white on the raw accent fails
    /// 3:1 for five of the eight system accents (yellow 1.51:1, orange 2.31,
    /// green 2.22, teal 2.16). `selectedContentBackgroundColor` holds 3.19:1 light
    /// / 3.75:1 dark whatever accent the user picked.
    static let emphasizedSelectionBackground = Color(nsColor: .selectedContentBackgroundColor)

    /// The pin on a pinned note. A **mark**, not a wash: the identity colour
    /// is still the focused list selection, and a second band would spend it.
    /// A few pixels of glyph can carry the pigment the row cannot — same 30°
    /// hue as `#E1C2A3` / `#524539`, dropped in light and lifted in dark so it
    /// reads on paper, on the grey, and on the wash itself. Not system yellow.
    ///
    /// Light `#8A5C2E` is 5.7:1 on white and 3.4:1 on the wash. Dark `#CB9C6C`
    /// is 6.8:1 on `#1E1E1E` paper and 3.7:1 on `#524539`. Labels stay
    /// `.primary` / `.secondary`; this colour is the pin and only the pin.
    static let pinForeground = Color(nsColor: dynamicColor(light: 0x8A5C2E, dark: 0xCB9C6C))

    /// One chip, two states, wherever a tag is drawn — list row, preview header,
    /// popover list. Hollow is "the note carries this tag". Solid is "this tag
    /// is acting": checked in the popover, or currently filtering the list.
    ///
    /// The hairline is `tertiaryLabelColor`, not `separatorColor`. Separator is
    /// 9.8 % of the label and measures ~1.23:1 on the focused wash — gone.
    /// Tertiary is 26 % / 25 % and composites at ~1.8:1 light / ~2.0:1 dark on
    /// paper, on the unfocused grey, and on the wash, which is the test that
    /// matters: chips sit on all three. An opaque 22 % grey (the mockup's
    /// "percentage of label") is 1.00:1 on `#E1C2A3` and is not shipped.
    ///
    /// Hollow text is `secondaryLabelColor`, the same secondary the row already
    /// accepts on the wash (3.5:1 light / 4.1:1 dark). Active fill cannot be
    /// live `labelColor`: that alpha would composite onto the wash and tint the
    /// pill chocolate, which is the identity colour used as a surface, and a
    /// second one. The fill is label flattened onto paper, opaque, near-black
    /// / near-white. Active text is the paper. No call site overrides these.
    static let tagBorder = Color(nsColor: .tertiaryLabelColor)
    static let tagText = Color(nsColor: .secondaryLabelColor)
    static let tagActiveFill = Color(nsColor: dynamicColor(light: 0x272727, dark: 0xDDDDDD))
    static let tagActiveText = Color(nsColor: .textBackgroundColor)
    static let tagFont: Font = .caption.weight(.medium)
    static let tagActiveFont: Font = .caption.weight(.semibold)
    static let tagPaddingH: CGFloat = 7
    static let tagPaddingV: CGFloat = 1.5
    static let tagStroke: CGFloat = 1
    static let tagDash: [CGFloat] = [3, 2]

    /// The shape **both** panes select with: one inset rounded rectangle, like a
    /// standard macOS source list. Never a full-width band — a band is what left
    /// the list's own highlight showing past its edges.
    ///
    /// A macOS selection radius does not depend on the pane or on the row height
    /// (Mail draws the same corner on a 60 pt band and on a 24 pt one), so the
    /// sidebar, the note list and the drop target all read these three values and
    /// nothing else. If a capture shows macOS drawing 6 for a `List(.sidebar)`,
    /// the whole scale moves to 6 here and nowhere else.
    static let selectionCornerRadius: CGFloat = 8
    static let selectionInset: CGFloat = 8
    static let selectionVerticalInset: CGFloat = 2

    private static func dynamicColor(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        }
    }
}

private extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
