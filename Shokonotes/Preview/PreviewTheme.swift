import AppKit

enum PreviewTheme: String, CaseIterable, Identifiable {
    case system
    case github
    case paper
    case sepia
    case nord
    case midnight
    case solarized

    var id: String { rawValue }

    var title: String { PreviewThemeCSS.title(self) }

    /// `nil` keeps the preview transparent so the window shows through.
    func hostBackground(isDark: Bool) -> NSColor? {
        guard let hex = PreviewThemeCSS.palette(self, isDark: isDark)?.bg else { return nil }
        return NSColor(srgbHex: hex)
    }

    func pageCSS(isDark: Bool) -> String {
        PreviewThemeCSS.pageCSS(self, isDark: isDark)
    }

    func syntaxCSS(isDark: Bool) -> String {
        PreviewThemeCSS.syntaxCSS(self, isDark: isDark)
    }
}

private extension NSColor {
    convenience init?(srgbHex hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
