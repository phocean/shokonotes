import XCTest
@testable import Shokonotes

final class LocalizationTests: XCTestCase {
    func testSettingsExplanationsHaveFrench() throws {
        let catalog = try loadCatalog()
        let keys = [
            "Follow the title applies when you rename in the app. Files open in an external editor are never renamed in the background.",
            "Double-clicking a note opens it here. Shokonotes itself never edits note contents. The global quick-note shortcut always opens the editor.",
            "Quick note creates a note in the Inbox and opens your editor, from any app. Showing and hiding the library never quits Shokonotes. Click the field, then type a shortcut. Delete clears it.",
            "Show or hide Shokonotes",
            "When a note has no YAML title, the first line of the body is used. Off: the file name.",
            "The Dock badge uses the system label. Unsigned local builds often cannot display it.",
            "Line breaks in the file become new lines in the preview. Off: standard Markdown.",
            "Turns quotes and dashes into typographic forms in the preview only. Files are not modified.",
            "The preview theme changes colours and code highlighting. Files are not modified.",
            "New notes use a placeholder name on disk. Change the title and tags in Shokonotes. Rename the file here — never from the external editor.",
            "One folder name per line. These folders stay on disk and are omitted from the sidebar. A leading * matches a suffix, for example *.assets.",
        ]
        for key in keys {
            let french = try frenchValue(for: key, in: catalog)
            XCTAssertFalse(french.isEmpty, "empty fr: \(key)")
            XCTAssertNotEqual(french, key, "untranslated: \(key)")
        }
    }

    func testInboxIsLocalizedToFrenchMailboxName() throws {
        let catalog = try loadCatalog()
        XCTAssertNil(catalog["INBOX"], "verbatim INBOX must not stay in the catalog")
        let french = try frenchValue(for: "Inbox", in: catalog)
        XCTAssertEqual(french, "Boîte de réception")
        for (key, entry) in catalog {
            guard let dict = entry as? [String: Any],
                  let locs = dict["localizations"] as? [String: Any],
                  let fr = locs["fr"] as? [String: Any],
                  let unit = fr["stringUnit"] as? [String: Any],
                  let value = unit["value"] as? String else { continue }
            XCTAssertFalse(value.contains("INBOX"), "French still says INBOX in \(key)")
        }
    }

    func testPreviewPickerTitlesHaveFrench() throws {
        let catalog = try loadCatalog()
        let keys = ["Serif", "Rounded", "Comfortable", "Relaxed", "Narrow", "Hidden", "Small", "Paper", "Sepia", "Nord", "Midnight"]
        for key in keys {
            let french = try frenchValue(for: key, in: catalog)
            XCTAssertFalse(french.isEmpty, "empty fr: \(key)")
        }
    }

    /// The export path speaks to the user in four places — the save panel's
    /// button, the alert title, and two failure reasons — plus its own menu
    /// title. An English string in a French menu is the defect this catches.
    func testExportStringsHaveFrench() throws {
        let catalog = try loadCatalog()
        let keys = [
            "Export",
            "Export as PDF…",
            "The note could not be exported.",
            "The note could not be rendered for export.",
            "The PDF could not be written to \"%@\".",
        ]
        for key in keys {
            let french = try frenchValue(for: key, in: catalog)
            XCTAssertFalse(french.isEmpty, "empty fr: \(key)")
            XCTAssertNotEqual(french, key, "untranslated: \(key)")
        }
        // The reason string is built with `String(format:)`; a French value that
        // dropped the placeholder would print the sentence without the name.
        let written = try frenchValue(for: "The PDF could not be written to \"%@\".", in: catalog)
        XCTAssertTrue(written.contains("%@"), "lost the placeholder: \(written)")
    }

    /// The tag editor speaks to the user in four places: the menu item and the
    /// two gestures that share its title, the token field's placeholder, the line
    /// shown when the library has no tags at all, and the header of a multiple
    /// selection. An English word in a French popover is the defect this catches.
    func testTagEditorStringsHaveFrench() throws {
        let catalog = try loadCatalog()
        let keys = ["Tags…", "Add tags", "No tags in this library yet", "%lld notes selected"]
        for key in keys {
            let french = try frenchValue(for: key, in: catalog)
            XCTAssertFalse(french.isEmpty, "empty fr: \(key)")
            XCTAssertNotEqual(french, key, "untranslated: \(key)")
        }
        // The header is built with `String(localized:)` over plural variations;
        // a French form that lost the placeholder would say "notes selected"
        // with no number. `frenchValue` reads the "other" form here.
        let header = try frenchValue(for: "%lld notes selected", in: catalog)
        XCTAssertTrue(header.contains("%lld"), "lost the placeholder: \(header)")
    }

    /// Favourites speaks in three places: the section header and the two
    /// context-menu items. An English word in a French sidebar is the defect
    /// this catches.
    func testFavouritesStringsHaveFrench() throws {
        let catalog = try loadCatalog()
        let keys = ["Favourites", "Add to Favourites", "Remove from Favourites"]
        for key in keys {
            let french = try frenchValue(for: key, in: catalog)
            XCTAssertFalse(french.isEmpty, "empty fr: \(key)")
            XCTAssertNotEqual(french, key, "untranslated: \(key)")
        }
    }

    /// One action, one name: the header, the multi-select placeholder, the
    /// list-header help, the context menu and the File menu all say this.
    func testRenameFileHasFrench() throws {
        let catalog = try loadCatalog()
        let french = try frenchValue(for: "Rename file", in: catalog)
        XCTAssertFalse(french.isEmpty, "empty fr: Rename file")
        XCTAssertNotEqual(french, "Rename file", "untranslated: Rename file")
    }

    /// The suggestion lot speaks in five places, all inside the tag popover:
    /// the section's one word, the three reasons, and the hygiene offer. The
    /// engine emits no user-facing string, so these are the whole vocabulary of
    /// the feature — an English word here is the defect this catches.
    func testTagSuggestionStringsHaveFrench() throws {
        let catalog = try loadCatalog()
        let keys = [
            "Suggested",
            "Appears in the text",
            "Common in this folder",
            "Often used with #%@",
            "Use \"%@\" instead",
        ]
        for key in keys {
            let french = try frenchValue(for: key, in: catalog)
            XCTAssertFalse(french.isEmpty, "empty fr: \(key)")
            XCTAssertNotEqual(french, key, "untranslated: \(key)")
        }
        // Both are built with `String(format:)`. A French value that lost its
        // placeholder would name no companion tag, and offer a tag with no name.
        XCTAssertTrue(try frenchValue(for: "Often used with #%@", in: catalog).contains("%@"))
        XCTAssertTrue(try frenchValue(for: "Use \"%@\" instead", in: catalog).contains("%@"))
    }

    /// First-launch and Storage share one action; the engine presents two
    /// failures if the canned tree is missing or the copy fails. An English
    /// word on that pane is the defect this catches.
    func testSampleLibraryStringsHaveFrench() throws {
        let catalog = try loadCatalog()
        let keys = [
            "Open Sample Library",
            "The sample library could not be found.",
            "The sample library could not be copied.",
        ]
        for key in keys {
            let french = try frenchValue(for: key, in: catalog)
            XCTAssertFalse(french.isEmpty, "empty fr: \(key)")
            XCTAssertNotEqual(french, key, "untranslated: \(key)")
        }
    }

    /// A reason is at most four words in **both** languages, and each one is a
    /// standalone statement rather than a fragment: the app still has to say
    /// why at a glance, but in a form a translator can read on its own.
    func testFrenchReasonsAreAtMostFourWords() throws {
        let catalog = try loadCatalog()
        for key in ["Appears in the text", "Common in this folder", "Often used with #%@"] {
            let french = try frenchValue(for: key, in: catalog)
            XCTAssertLessThanOrEqual(
                french.split(separator: " ").count, 4, "too long in French: \(french)")
        }
    }

    /// The retired fragments stay in the catalogue — no key is ever deleted —
    /// but nothing may draw them again: a fragment cannot be translated into a
    /// justification without the sentence it used to lean on.
    func testTheRetiredReasonFragmentsAreNoLongerDrawn() {
        let drawn = [
            TagPopover.reasonText(.inText),
            TagPopover.reasonText(.thisFolder),
            TagPopover.reasonText(.withTag("client")),
        ]
        for fragment in ["in the text", "this folder", "dans le texte", "ce dossier"] {
            XCTAssertFalse(drawn.contains(fragment), "still drawing the fragment: \(fragment)")
        }
    }

    /// The count of a multiple selection is one key in two places, and it
    /// carries plural variations rather than a hard-coded "notes": "1 notes"
    /// is wrong in German, Spanish, Italian and Portuguese, and the branches
    /// that guarantee two or more today are a convention, not a structure.
    func testTheSelectionCountIsPlural() throws {
        let catalog = try loadCatalog()
        for language in ["en", "fr"] {
            let forms = try pluralForms(for: "%lld notes selected", language: language, in: catalog)
            XCTAssertNotNil(forms["one"], "no singular in \(language)")
            XCTAssertNotNil(forms["other"], "no plural in \(language)")
            for (name, value) in forms {
                XCTAssertTrue(
                    value.contains("%lld"), "lost the placeholder in \(language).\(name): \(value)")
            }
        }
        XCTAssertNotEqual(
            try pluralForms(for: "%lld notes selected", language: "fr", in: catalog)["one"],
            try pluralForms(for: "%lld notes selected", language: "fr", in: catalog)["other"])
        for language in ["de", "es", "it", "pt-BR"] {
            let forms = try pluralForms(for: "%lld notes selected", language: language, in: catalog)
            XCTAssertNotNil(forms["one"], "no singular in \(language)")
            XCTAssertNotNil(forms["other"], "no plural in \(language)")
            XCTAssertNotEqual(forms["one"], forms["other"], "same forms in \(language)")
        }
        let russian = try pluralForms(for: "%lld notes selected", language: "ru", in: catalog)
        XCTAssertNotNil(russian["one"], "no singular in ru")
        XCTAssertNotNil(russian["few"], "no few in ru")
        XCTAssertNotNil(russian["many"], "no many in ru")
        XCTAssertNotNil(russian["other"], "no other in ru")
        XCTAssertNotEqual(russian["one"], russian["few"])
        XCTAssertNotEqual(russian["few"], russian["many"])
        for language in ["ja", "ko", "zh-Hans"] {
            let forms = try pluralForms(for: "%lld notes selected", language: language, in: catalog)
            XCTAssertNotNil(forms["other"], "no plural in \(language)")
            XCTAssertTrue(forms["other"]!.contains("%lld"), "lost placeholder in \(language)")
        }
    }

    /// Every shipping language has a value for every key, and keeps the
    /// placeholders the English source uses. A key that exists only in
    /// English and French is allowed to ship before the other eight.
    func testShippingLanguagesCoverTheCatalog() throws {
        let catalog = try loadCatalog()
        let languages = ["de", "es", "fr", "it", "ja", "ko", "pt-BR", "ru", "zh-Hans"]
        let placeholders = ["%@", "%lld"]
        for (key, raw) in catalog {
            guard let entry = raw as? [String: Any],
                  let locs = entry["localizations"] as? [String: Any] else {
                XCTFail("bad entry: \(key)")
                continue
            }
            let english = joinedValues(in: locs["en"] as? [String: Any] ?? [:])
            let present = Set(locs.keys)
            if present == Set(["en", "fr"]) {
                XCTAssertFalse(english.isEmpty, "empty en: \(key)")
                let french = joinedValues(in: locs["fr"] as? [String: Any] ?? [:])
                XCTAssertFalse(french.isEmpty, "empty fr: \(key)")
                for token in placeholders where english.contains(token) {
                    XCTAssertTrue(french.contains(token), "lost \(token) in fr: \(key)")
                }
                continue
            }
            for language in languages {
                guard let loc = locs[language] as? [String: Any] else {
                    XCTFail("missing \(language) for: \(key)")
                    continue
                }
                let value = joinedValues(in: loc)
                XCTAssertFalse(value.isEmpty, "empty \(language): \(key)")
                for token in placeholders where english.contains(token) {
                    XCTAssertTrue(
                        value.contains(token),
                        "lost \(token) in \(language): \(key)")
                }
            }
        }
    }

    private func loadCatalog() throws -> [String: Any] {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = tests
            .deletingLastPathComponent()
            .appendingPathComponent("Shokonotes/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data)
        guard let root = json as? [String: Any],
              let strings = root["strings"] as? [String: Any] else {
            throw XCTSkip("catalog shape")
        }
        return strings
    }

    /// The plural form of a key, or its single value. An entry with variations
    /// has no `stringUnit` of its own, so a lookup that only knew about
    /// `stringUnit` would report a translated key as missing.
    private func frenchValue(for key: String, in catalog: [String: Any]) throws -> String {
        guard let entry = catalog[key] as? [String: Any],
              let locs = entry["localizations"] as? [String: Any],
              let fr = locs["fr"] as? [String: Any] else {
            XCTFail("missing French for: \(key)")
            return ""
        }
        if let unit = fr["stringUnit"] as? [String: Any],
           let value = unit["value"] as? String {
            return value
        }
        if let value = variationValues(in: fr)["other"] {
            return value
        }
        XCTFail("missing French for: \(key)")
        return ""
    }

    /// The `plural` variations of one language of one key, by form name.
    private func pluralForms(
        for key: String, language: String, in catalog: [String: Any]
    ) throws -> [String: String] {
        guard let entry = catalog[key] as? [String: Any],
              let locs = entry["localizations"] as? [String: Any],
              let lang = locs[language] as? [String: Any] else {
            XCTFail("missing \(language) for: \(key)")
            return [:]
        }
        let forms = variationValues(in: lang)
        if forms.isEmpty { XCTFail("no plural variations for \(key) in \(language)") }
        return forms
    }

    /// The plural forms held by one language's entry, empty when it holds a
    /// single `stringUnit` instead.
    private func variationValues(in language: [String: Any]) -> [String: String] {
        guard let variations = language["variations"] as? [String: Any],
              let plural = variations["plural"] as? [String: Any] else { return [:] }
        var forms: [String: String] = [:]
        for (name, form) in plural {
            guard let form = form as? [String: Any],
                  let unit = form["stringUnit"] as? [String: Any],
                  let value = unit["value"] as? String else { continue }
            forms[name] = value
        }
        return forms
    }

    private func joinedValues(in language: [String: Any]) -> String {
        if let unit = language["stringUnit"] as? [String: Any],
           let value = unit["value"] as? String {
            return value
        }
        return variationValues(in: language).values.sorted().joined(separator: " ")
    }
}
