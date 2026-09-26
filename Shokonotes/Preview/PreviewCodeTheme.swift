import Foundation
import AppKit

enum PreviewCodeTheme: String, CaseIterable, Identifiable {
    case github
    case atomOne
    case solarized

    var id: String { rawValue }

    var title: String { PreviewSyntaxCSS.title(self) }

    func stylesheetName(isDark: Bool) -> String {
        PreviewSyntaxCSS.stylesheetName(self, isDark: isDark)
    }

    func css(isDark: Bool) -> String {
        PreviewSyntaxCSS.css(self, isDark: isDark)
    }

    static func highlightScript() -> String {
        PreviewSyntaxCSS.highlightScript()
    }
}

enum AppearanceProbe {
    static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
