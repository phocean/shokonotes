import SwiftUI
import UIKit

/// iOS copy of the Mac chip/pin metrics. `RowPalette` is AppKit; this file
/// must not import it.
enum IOSPalette {
    /// The hue as a *mark*, never a surface: the pin glyph only.
    /// Light `#8A5C2E`, dark `#CB9C6C`.
    static let pinForeground = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 203 / 255, green: 156 / 255, blue: 108 / 255, alpha: 1)
        }
        return UIColor(red: 138 / 255, green: 92 / 255, blue: 46 / 255, alpha: 1)
    })

    static let tagBorder = Color(uiColor: .tertiaryLabel)
    static let tagText = Color(uiColor: .secondaryLabel)
    static let tagActiveFill = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(white: 221 / 255, alpha: 1)
        }
        return UIColor(white: 39 / 255, alpha: 1)
    })
    static let tagActiveText = Color(uiColor: .systemBackground)
    static let tagFont: Font = .caption.weight(.medium)
    static let tagActiveFont: Font = .caption.weight(.semibold)
    static let tagPaddingH: CGFloat = 7
    static let tagPaddingV: CGFloat = 1.5
    static let tagStroke: CGFloat = 1
}

/// Hairline at rest, solid fill when this name is the current tag filter.
struct IOSTagChip: View {
    let name: String
    let isActive: Bool

    static func isActive(_ name: String, filters: Set<String>) -> Bool {
        filters.contains(name)
    }

    var body: some View {
        Text(name)
            .font(isActive ? IOSPalette.tagActiveFont : IOSPalette.tagFont)
            .foregroundStyle(isActive ? IOSPalette.tagActiveText : IOSPalette.tagText)
            .lineLimit(1)
            .padding(.horizontal, IOSPalette.tagPaddingH)
            .padding(.vertical, IOSPalette.tagPaddingV)
            .background {
                Capsule().fill(isActive ? IOSPalette.tagActiveFill : Color.clear)
            }
            .overlay {
                Capsule().strokeBorder(
                    isActive ? Color.clear : IOSPalette.tagBorder,
                    lineWidth: IOSPalette.tagStroke
                )
            }
    }
}
