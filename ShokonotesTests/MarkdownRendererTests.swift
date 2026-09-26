import XCTest
@testable import Shokonotes

final class MarkdownRendererTests: XCTestCase {
    func testTaskListCheckboxesAreDisabled() {
        let html = MarkdownRenderer.bodyHTML(from: "- [ ] open\n- [x] done\n")
        XCTAssertTrue(html.contains("checkbox"))
        XCTAssertFalse(
            html.lowercased().contains("<input type=\"checkbox\"")
                && !html.lowercased().contains("disabled")
        )
        XCTAssertTrue(html.lowercased().contains("disabled"))
    }

    func testPreviewCSSUsesSystemColors() {
        let css = PreviewCSS.sheet(fontSize: 17, maxWidthEm: 44)
        XCTAssertTrue(css.contains("-apple-system-label"))
        XCTAssertTrue(css.contains("44em"))
        XCTAssertTrue(css.contains("17px"))
        XCTAssertFalse(css.contains("#f7f1e5"))
    }

    func testCodeThemeFollowsAppearance() {
        XCTAssertEqual(PreviewCodeTheme.github.stylesheetName(isDark: false), "github-light")
        XCTAssertEqual(PreviewCodeTheme.github.stylesheetName(isDark: true), "github-dark")
        XCTAssertEqual(PreviewCodeTheme.atomOne.stylesheetName(isDark: true), "atom-one-dark")
        XCTAssertEqual(PreviewCodeTheme.solarized.stylesheetName(isDark: false), "solarized-light")
    }

    func testDoesNotInsertUnsafeScript() {
        let html = MarkdownRenderer.bodyHTML(from: "<script>alert(1)</script>")
        XCTAssertFalse(html.lowercased().contains("<script>"))
    }

    func testSoftLineBreaksAreDefault() {
        let html = MarkdownRenderer.bodyHTML(from: "one\ntwo\n")
        XCTAssertFalse(html.contains("<br"))
        let hard = MarkdownRenderer.bodyHTML(from: "one\ntwo\n", hardLineBreaks: true)
        XCTAssertTrue(hard.contains("<br"))
    }

    func testMastheadTitleIsSkippedWhenHeadingMatches() {
        let withHeading = MarkdownRenderer.html(
            from: "# Hello\n\nBody\n",
            title: "Hello",
            style: PreviewStyle(showTitle: true)
        )
        XCTAssertFalse(withHeading.contains("class=\"note-masthead\""))
        let without = MarkdownRenderer.html(
            from: "Just a paragraph\n",
            title: "Hello",
            style: PreviewStyle(showTitle: true)
        )
        XCTAssertTrue(without.contains("class=\"note-masthead\""))
        XCTAssertTrue(without.contains("<h1>Hello</h1>"))
    }

    func testSerifPreviewUsesNewYork() {
        let css = PreviewCSS.sheet(PreviewStyle(font: .serif))
        XCTAssertTrue(css.contains("New York"))
        XCTAssertFalse(css.contains("#f7f1e5"))
    }

    func testHiddenImagesRule() {
        let css = PreviewCSS.sheet(PreviewStyle(images: .hidden))
        XCTAssertTrue(css.contains("display: none"))
    }

    func testPaperThemeOverridesPageBackground() {
        let css = PreviewCSS.sheet(PreviewStyle(theme: .paper))
        XCTAssertTrue(css.contains("#f4efe4"))
        XCTAssertTrue(PreviewStyle(theme: .paper).cacheKey.contains("paper"))
        XCTAssertNotEqual(PreviewStyle(theme: .system).cacheKey, PreviewStyle(theme: .midnight).cacheKey)
    }

    func testNordThemeIsDarkPalette() {
        let css = PreviewTheme.nord.pageCSS(isDark: false)
        XCTAssertTrue(css.contains("#2e3440"))
        XCTAssertTrue(css.contains("color-scheme: dark"))
        XCTAssertTrue(PreviewTheme.system.pageCSS(isDark: true).isEmpty)
    }

    func testGitHubThemePageCSSExposesBackground() {
        let light = PreviewTheme.github.pageCSS(isDark: false)
        XCTAssertTrue(light.contains("--bg"))
        XCTAssertTrue(light.contains("#ffffff"))
        let dark = PreviewTheme.github.pageCSS(isDark: true)
        XCTAssertTrue(dark.contains("--bg"))
        XCTAssertTrue(dark.contains("#0d1117"))
    }

    func testSyntaxCSSFollowsPageTheme() {
        XCTAssertEqual(
            PreviewTheme.paper.syntaxCSS(isDark: true),
            PreviewCodeTheme.github.css(isDark: false)
        )
        XCTAssertEqual(
            PreviewTheme.nord.syntaxCSS(isDark: false),
            PreviewCodeTheme.github.css(isDark: true)
        )
        XCTAssertEqual(
            PreviewTheme.solarized.syntaxCSS(isDark: true),
            PreviewCodeTheme.solarized.css(isDark: true)
        )
        XCTAssertEqual(PreviewTheme.github.title, "GitHub")
    }

    func testThematicBreakAndFencedDashes() {
        let rule = MarkdownRenderer.bodyHTML(from: "before\n\n---\n\nafter\n")
        XCTAssertTrue(rule.contains("<hr"))
        let fenced = MarkdownRenderer.bodyHTML(from: "```\n---\n```\n")
        XCTAssertTrue(fenced.contains("---"))
        XCTAssertFalse(fenced.contains("<hr"))
    }

    func testGFMTableStrikethroughAndAutolink() {
        let table = MarkdownRenderer.bodyHTML(from: "| a | b |\n| --- | --- |\n| 1 | 2 |\n")
        XCTAssertTrue(table.contains("<table"))
        XCTAssertTrue(table.contains("<td>1</td>") || table.contains("<td>1</td>\n"))
        let strike = MarkdownRenderer.bodyHTML(from: "~~gone~~\n")
        XCTAssertTrue(strike.contains("<del>") || strike.contains("<s>"))
        let link = MarkdownRenderer.bodyHTML(from: "See https://example.com/x\n")
        XCTAssertTrue(link.contains("href=\"https://example.com/x\""))
    }
}
