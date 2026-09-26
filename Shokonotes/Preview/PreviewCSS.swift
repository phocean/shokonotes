import Foundation
#if os(iOS)
import UIKit

/// iOS type surface. Palettes and bundle reads live in `PreviewThemeCSS`.
enum PreviewTheme: String, CaseIterable, Identifiable {
    case system, github, paper, sepia, nord, midnight, solarized
    var id: String { rawValue }
    var title: String { PreviewThemeCSS.title(self) }
    func pageCSS(isDark: Bool) -> String { PreviewThemeCSS.pageCSS(self, isDark: isDark) }
    func syntaxCSS(isDark: Bool) -> String { PreviewThemeCSS.syntaxCSS(self, isDark: isDark) }
}

enum PreviewCodeTheme: String, CaseIterable, Identifiable {
    case github, atomOne, solarized
    var id: String { rawValue }
    var title: String { PreviewSyntaxCSS.title(self) }
    func stylesheetName(isDark: Bool) -> String { PreviewSyntaxCSS.stylesheetName(self, isDark: isDark) }
    func css(isDark: Bool) -> String { PreviewSyntaxCSS.css(self, isDark: isDark) }
    static func highlightScript() -> String { PreviewSyntaxCSS.highlightScript() }
}

enum AppearanceProbe {
    static var isDark: Bool {
        UITraitCollection.current.userInterfaceStyle == .dark
    }
}
#endif

/// Page palettes and syntax mapping. One table so Mac and iOS cannot drift.
enum PreviewThemeCSS {
    struct Palette {
        var scheme: String
        var text: String
        var muted: String
        var faint: String
        var bg: String
        var fill: String
        var line: String
        var accent: String
    }

    static func title(_ theme: PreviewTheme) -> String {
        switch theme {
        case .system: return "System"
        case .github: return "GitHub"
        case .paper: return "Paper"
        case .sepia: return "Sepia"
        case .nord: return "Nord"
        case .midnight: return "Midnight"
        case .solarized: return "Solarized"
        }
    }

    static func palette(_ theme: PreviewTheme, isDark: Bool) -> Palette? {
        switch theme {
        case .system:
            return nil
        case .github:
            if isDark {
                return Palette(
                    scheme: "dark",
                    text: "#e6edf3", muted: "#9198a1", faint: "#6e7681",
                    bg: "#0d1117", fill: "#161b22", line: "#30363d", accent: "#4493f8"
                )
            }
            return Palette(
                scheme: "light",
                text: "#1f2328", muted: "#656d76", faint: "#8c959f",
                bg: "#ffffff", fill: "#f6f8fa", line: "#d0d7de", accent: "#0969da"
            )
        case .paper:
            return Palette(
                scheme: "light",
                text: "#2a241c", muted: "#6b6156", faint: "#94897c",
                bg: "#f4efe4", fill: "#e8e0d0", line: "#d4cbb8", accent: "#8b5e34"
            )
        case .sepia:
            return Palette(
                scheme: "light",
                text: "#5b4636", muted: "#8a7360", faint: "#a89078",
                bg: "#f2e6ce", fill: "#e8d7b5", line: "#d4c09a", accent: "#a15c2e"
            )
        case .nord:
            return Palette(
                scheme: "dark",
                text: "#eceff4", muted: "#a8b1c3", faint: "#7b88a1",
                bg: "#2e3440", fill: "#3b4252", line: "#4c566a", accent: "#88c0d0"
            )
        case .midnight:
            return Palette(
                scheme: "dark",
                text: "#e8e8e8", muted: "#9a9a9a", faint: "#6e6e6e",
                bg: "#111111", fill: "#1c1c1c", line: "#2a2a2a", accent: "#6cb6ff"
            )
        case .solarized:
            if isDark {
                return Palette(
                    scheme: "dark",
                    text: "#839496", muted: "#586e75", faint: "#657b83",
                    bg: "#002b36", fill: "#073642", line: "#0a3944", accent: "#268bd2"
                )
            }
            return Palette(
                scheme: "light",
                text: "#657b83", muted: "#93a1a1", faint: "#93a1a1",
                bg: "#fdf6e3", fill: "#eee8d5", line: "#e6dcc3", accent: "#268bd2"
            )
        }
    }

    static func pageCSS(_ theme: PreviewTheme, isDark: Bool) -> String {
        guard let palette = palette(theme, isDark: isDark) else { return "" }
        return """
        :root {
          color-scheme: \(palette.scheme);
          --text: \(palette.text);
          --muted: \(palette.muted);
          --faint: \(palette.faint);
          --bg: \(palette.bg);
          --fill: \(palette.fill);
          --line: \(palette.line);
          --accent: \(palette.accent);
        }
        html, body { background: \(palette.bg); }
        """
    }

    static func syntaxCSS(_ theme: PreviewTheme, isDark: Bool) -> String {
        switch theme {
        case .system, .github:
            return PreviewCodeTheme.github.css(isDark: isDark)
        case .solarized:
            return PreviewCodeTheme.solarized.css(isDark: isDark)
        case .paper, .sepia:
            return PreviewCodeTheme.github.css(isDark: false)
        case .nord, .midnight:
            return PreviewCodeTheme.github.css(isDark: true)
        }
    }
}

enum PreviewSyntaxCSS {
    static func title(_ theme: PreviewCodeTheme) -> String {
        switch theme {
        case .github: return "GitHub"
        case .atomOne: return "Atom One"
        case .solarized: return "Solarized"
        }
    }

    static func stylesheetName(_ theme: PreviewCodeTheme, isDark: Bool) -> String {
        switch theme {
        case .github: return isDark ? "github-dark" : "github-light"
        case .atomOne: return isDark ? "atom-one-dark" : "atom-one-light"
        case .solarized: return isDark ? "solarized-dark" : "solarized-light"
        }
    }

    /// Cached per stylesheet name, which already encodes light vs dark.
    static func css(_ theme: PreviewCodeTheme, isDark: Bool) -> String {
        let name = stylesheetName(theme, isDark: isDark)
        return PreviewAssetCache.shared.value(for: "syntax-css:" + name) {
            guard let url = Bundle.main.url(
                forResource: name,
                withExtension: "css",
                subdirectory: "Preview/themes"
            ) ?? Bundle.main.url(forResource: name, withExtension: "css") else {
                return ""
            }
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
    }

    /// 683 KiB of JavaScript. Read from the bundle once, not once per note.
    /// The bundled library is highlight.js v9 (`highlightBlock`); a future
    /// build may only expose `highlightElement`. The appended bootstrap
    /// selects `pre code` and calls whichever exists.
    static func highlightScript() -> String {
        PreviewAssetCache.shared.value(for: "highlight-js") {
            let url = Bundle.main.url(forResource: "highlight.min", withExtension: "js", subdirectory: "Preview")
                ?? Bundle.main.url(forResource: "highlight.min", withExtension: "js")
            guard let url, let source = try? String(contentsOf: url, encoding: .utf8) else {
                return ""
            }
            return source + "\n" + highlightBootstrap
        }
    }

    /// ES5 on purpose: it is appended to whatever generation of the library is
    /// bundled, and it must not be the thing that fails to parse.
    private static let highlightBootstrap = """
    try {
        (function () {
            var blocks = document.querySelectorAll('pre code');
            for (var i = 0; i < blocks.length; i++) {
                var block = blocks[i];
                if (hljs.highlightElement) {
                    hljs.highlightElement(block);
                } else if (hljs.highlightBlock) {
                    hljs.highlightBlock(block);
                }
            }
        })();
    } catch (e) {}
    """
}

enum PreviewMeasure: Int, CaseIterable, Identifiable {
    case narrow = 36
    case medium = 44
    case wide = 56
    case full = 0

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .narrow: return "Narrow"
        case .medium: return "Medium"
        case .wide: return "Wide"
        case .full: return "Full width"
        }
    }
}

enum PreviewFont: String, CaseIterable, Identifiable {
    case system, serif, rounded, mono
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .serif: return "Serif"
        case .rounded: return "Rounded"
        case .mono: return "Mono"
        }
    }

    var bodyFamily: String {
        switch self {
        case .system:
            return #"-apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif"#
        case .serif:
            return #""New York", "Iowan Old Style", Palatino, Georgia, serif"#
        case .rounded:
            return #""SF Pro Rounded", -apple-system, BlinkMacSystemFont, sans-serif"#
        case .mono:
            return #"ui-monospace, "SF Mono", Menlo, monospace"#
        }
    }

    var displayFamily: String {
        switch self {
        case .system:
            return #"-apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", sans-serif"#
        case .serif:
            return #""New York", "Iowan Old Style", Palatino, Georgia, serif"#
        case .rounded:
            return #""SF Pro Rounded", -apple-system, BlinkMacSystemFont, sans-serif"#
        case .mono:
            return #"ui-monospace, "SF Mono", Menlo, monospace"#
        }
    }
}

enum PreviewLineHeight: String, CaseIterable, Identifiable {
    case compact, comfortable, relaxed
    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: return "Compact"
        case .comfortable: return "Comfortable"
        case .relaxed: return "Relaxed"
        }
    }

    var css: String {
        switch self {
        case .compact: return "1.4"
        case .comfortable: return "1.62"
        case .relaxed: return "1.85"
        }
    }
}

enum PreviewImageSize: String, CaseIterable, Identifiable {
    case hidden, small, medium, full
    var id: String { rawValue }

    var title: String {
        switch self {
        case .hidden: return "Hidden"
        case .small: return "Small"
        case .medium: return "Medium"
        case .full: return "Full width"
        }
    }

    var cssMax: String {
        switch self {
        case .hidden: return "0"
        case .small: return "18rem"
        case .medium: return "28rem"
        case .full: return "100%"
        }
    }
}

struct PreviewStyle: Equatable {
    var fontSize: Int = 17
    var maxWidthEm: Int = 44
    var font: PreviewFont = .system
    var lineHeight: PreviewLineHeight = .comfortable
    var images: PreviewImageSize = .full
    var hardLineBreaks: Bool = false
    var smartPunctuation: Bool = true
    var showTitle: Bool = true
    var theme: PreviewTheme = .system

    static let `default` = PreviewStyle()

    var cacheKey: String {
        [
            font.rawValue,
            String(fontSize),
            String(maxWidthEm),
            lineHeight.rawValue,
            images.rawValue,
            hardLineBreaks ? "h" : "s",
            smartPunctuation ? "p" : "q",
            showTitle ? "t" : "n",
            theme.rawValue
        ].joined(separator: "-")
    }
}

enum PreviewCSS {
    static func sheet(fontSize: Int, maxWidthEm: Int) -> String {
        sheet(PreviewStyle(fontSize: fontSize, maxWidthEm: maxWidthEm))
    }

    /// `cacheKey` covers every style field, and the sheet also embeds
    /// `pageCSS(isDark:)`, so the current appearance is part of the key.
    /// Without it a light sheet would stay frozen in after switching to dark.
    static func sheet(_ style: PreviewStyle = .default) -> String {
        let isDark = AppearanceProbe.isDark
        let key = "sheet:" + style.cacheKey + (isDark ? ":dark" : ":light")
        return PreviewAssetCache.shared.value(for: key) { build(style, isDark: isDark) }
    }

    private static func build(_ style: PreviewStyle, isDark: Bool) -> String {
        let measure = style.maxWidthEm <= 0 ? "none" : "\(style.maxWidthEm)em"
        let size = max(13, min(style.fontSize, 24))
        let imageRule: String
        if style.images == .hidden {
            imageRule = "img, video { display: none !important; }"
        } else {
            imageRule = """
            img {
              display: block;
              max-width: min(100%, \(style.images.cssMax));
              max-height: 80vh;
              height: auto;
              margin: 1.4em auto;
              border-radius: 8px;
            }
            """
        }
        return """
        :root {
          color-scheme: light dark;
          --text: -apple-system-label;
          --muted: -apple-system-secondary-label;
          --faint: -apple-system-tertiary-label;
          --bg: transparent;
          --fill: -apple-system-quaternary-fill;
          --line: -apple-system-separator;
          --accent: -apple-system-control-accent;
          --font-size: \(size)px;
          --measure: \(measure);
          --leading: \(style.lineHeight.css);
          --font-body: \(style.font.bodyFamily);
          --font-display: \(style.font.displayFamily);
          --font-mono: ui-monospace, "SF Mono", Menlo, monospace;
        }
        html {
          font-size: var(--font-size);
          background: var(--bg);
        }
        html, body {
          margin: 0;
          padding: 0;
          color: var(--text);
          font-family: var(--font-body);
          font-weight: 400;
          line-height: var(--leading);
          font-optical-sizing: auto;
          -webkit-font-smoothing: antialiased;
          hanging-punctuation: first allow-end last;
        }
        body {
          box-sizing: border-box;
          padding: 2.5rem 2.75rem 5rem;
          max-width: var(--measure);
          margin-left: auto;
          margin-right: auto;
        }
        body > :first-child { margin-top: 0; }
        .note-masthead {
          margin: 0 0 1.75em;
          padding-bottom: 0.85em;
          border-bottom: 1px solid var(--line);
        }
        .note-masthead h1 {
          margin: 0;
          font-family: var(--font-display);
          font-size: 2.05em;
          font-weight: 700;
          line-height: 1.15;
          letter-spacing: -0.022em;
        }
        h1, h2, h3, h4, h5 {
          font-family: var(--font-display);
          font-weight: 650;
          line-height: 1.22;
          letter-spacing: -0.018em;
          margin: 1.7em 0 0.45em;
          text-wrap: balance;
        }
        h1 { font-size: 1.78em; font-weight: 700; margin-top: 0.15em; }
        h2 { font-size: 1.32em; }
        h3 { font-size: 1.12em; }
        h4, h5 { font-size: 1em; color: var(--muted); font-weight: 600; letter-spacing: 0; }
        p, ul, ol, pre, table, blockquote, dl { margin: 0.9em 0; }
        p { orphans: 2; widows: 2; }
        a {
          color: var(--accent);
          text-decoration: underline;
          text-decoration-thickness: 1px;
          text-underline-offset: 0.18em;
          text-decoration-color: color-mix(in srgb, var(--accent) 45%, transparent);
        }
        a:hover { text-decoration-color: var(--accent); }
        hr {
          border: 0;
          height: 1px;
          background: var(--line);
          margin: 2em auto;
          max-width: 8em;
        }
        ul, ol { padding-left: 1.4em; }
        li { margin: 0.22em 0; }
        li > p { margin: 0.25em 0; }
        li:has(> input[type="checkbox"]) {
          list-style: none;
          margin-left: -1.4em;
          padding-left: 0.15em;
        }
        input[type="checkbox"] {
          pointer-events: none;
          margin-right: 0.5em;
          vertical-align: -0.12em;
          accent-color: var(--accent);
          transform: scale(1.05);
        }
        blockquote {
          margin-left: 0;
          margin-right: 0;
          padding: 0.35em 0 0.35em 1.05em;
          border-left: 3px solid color-mix(in srgb, var(--accent) 55%, var(--line));
          color: var(--muted);
          background: color-mix(in srgb, var(--fill) 70%, transparent);
          border-radius: 0 8px 8px 0;
        }
        blockquote > :first-child { margin-top: 0; }
        blockquote > :last-child { margin-bottom: 0; }
        code, pre, kbd {
          font-family: var(--font-mono);
          font-size: 0.86em;
        }
        :not(pre) > code {
          background: var(--fill);
          padding: 0.12em 0.4em;
          border-radius: 5px;
          font-size: 0.9em;
        }
        kbd {
          background: var(--fill);
          border: 1px solid var(--line);
          border-bottom-width: 2px;
          border-radius: 4px;
          padding: 0.05em 0.35em;
          font-size: 0.82em;
        }
        pre {
          background: var(--fill);
          padding: 0;
          overflow: auto;
          border-radius: 10px;
          line-height: 1.5;
          border: 1px solid color-mix(in srgb, var(--line) 80%, transparent);
        }
        pre code,
        pre code.hljs {
          display: block;
          background: transparent;
          padding: 1em 1.15em;
          font-size: 0.92em;
        }
        table {
          border-collapse: collapse;
          width: 100%;
          font-size: 0.94em;
          overflow: auto;
          display: block;
        }
        th, td {
          border-bottom: 1px solid var(--line);
          padding: 0.5em 0.7em;
          text-align: left;
        }
        th {
          font-weight: 600;
          color: var(--muted);
          background: color-mix(in srgb, var(--fill) 80%, transparent);
        }
        tr:last-child td { border-bottom: 0; }
        del { color: var(--muted); }
        mark {
          background: color-mix(in srgb, var(--accent) 28%, transparent);
          color: inherit;
          padding: 0.05em 0.15em;
          border-radius: 3px;
        }
        sup, sub { font-size: 0.75em; }
        .footnotes {
          margin-top: 2.5em;
          padding-top: 1em;
          border-top: 1px solid var(--line);
          color: var(--muted);
          font-size: 0.88em;
        }
        ::selection {
          background: color-mix(in srgb, var(--accent) 32%, transparent);
        }
        \(imageRule)
        @media print {
          body { padding: 0; max-width: none; color: black; }
          a { color: inherit; text-decoration: none; }
          pre, blockquote { break-inside: avoid; }
        }
        \(style.theme.pageCSS(isDark: isDark))
        """
    }
}
