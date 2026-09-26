import AppKit
import XCTest
@testable import Shokonotes

/// The rules `TagPopover` draws and writes from, taken away from the window.
///
/// Three states across a multiple selection is the part of this editor that is
/// easy to get subtly wrong and invisible when it is — a dash drawn as a
/// checkmark writes the right thing and says the wrong one, and the opposite
/// mistake removes a tag from notes the human never meant to touch.
@MainActor
final class TagPopoverTests: XCTestCase {
    func testPresenceIsAllWhenEveryNoteCarriesTheTag() {
        let presence = TagPopover.Presence.of("client", across: [["client"], ["client", "draft"]])
        XCTAssertEqual(presence, .all)
    }

    func testPresenceIsSomeWhenOnlyPartOfTheSelectionCarriesIt() {
        let presence = TagPopover.Presence.of("client", across: [["client"], ["draft"]])
        XCTAssertEqual(presence, .some)
    }

    func testPresenceIsNoneWhenNobodyCarriesIt() {
        let presence = TagPopover.Presence.of("client", across: [["draft"], ["draft"]])
        XCTAssertEqual(presence, .none)
    }

    /// No selection is not "on every note of an empty set".
    func testPresenceOnAnEmptySelectionIsNone() {
        XCTAssertEqual(TagPopover.Presence.of("client", across: []), .none)
    }

    func testMarksAreCheckmarkDashAndNothing() {
        XCTAssertEqual(TagPopover.Presence.all.symbol, "checkmark")
        XCTAssertEqual(TagPopover.Presence.some.symbol, "minus")
        XCTAssertNil(TagPopover.Presence.none.symbol)
    }

    /// Solid when the tag is acting — including mixed. Hollow only when it
    /// is on none of the selection. A third fill is not a state this device has.
    func testChipIsSolidWhenTheTagIsActing() {
        XCTAssertTrue(TagPopover.Presence.all.paintsChipActive)
        XCTAssertTrue(TagPopover.Presence.some.paintsChipActive)
        XCTAssertFalse(TagPopover.Presence.none.paintsChipActive)
    }

    /// Finder's rule: a dash goes to on, so the first press makes the selection
    /// agree and only the second takes the tag away from all of it.
    func testPressOnAMixedTagAdds() {
        XCTAssertTrue(TagPopover.Presence.some.pressAdds)
        XCTAssertTrue(TagPopover.Presence.none.pressAdds)
        XCTAssertFalse(TagPopover.Presence.all.pressAdds)
    }

    func testCommonTagsAreTheIntersectionSortedForDisplay() {
        let common = TagPopover.Presence.common(across: [
            ["draft", "client", "2026"],
            ["client", "2026"],
            ["2026", "client", "archive"],
        ])
        XCTAssertEqual(common, ["2026", "client"])
    }

    /// The token field is seeded with what is true of the whole selection, so a
    /// tag on only some of the notes must not become a token — it is the dash in
    /// the list below, which is the only surface that can say "some".
    func testCommonTagsExcludeAPartiallyCarriedTag() {
        XCTAssertEqual(TagPopover.Presence.common(across: [["client"], ["draft"]]), [])
    }

    func testCommonTagsOfNoSelectionIsEmpty() {
        XCTAssertEqual(TagPopover.Presence.common(across: []), [])
    }

    // MARK: - The suggested head

    /// Below the suggestion threshold nothing comes
    /// back, and nothing at all is drawn: no header row, no placeholder, no
    /// substitute list of recent tags. The navigable sequence is the
    /// alphabetical list and only the alphabetical list.
    func testNoSuggestionsMeansNoSectionAtAll() {
        XCTAssertFalse(TagPopover.showsSuggestedSection([]))
        let rows = TagPopover.rows(suggested: [], library: ["archive", "client", "draft"])
        XCTAssertEqual(rows, [.library("archive"), .library("client"), .library("draft")])
        // Nothing from the head leaked into the sequence.
        XCTAssertTrue(rows.allSatisfy { if case .library = $0 { return true } else { return false } })
    }

    /// An empty library and no suggestions is still nothing — the placeholder
    /// belongs to "no tags at all", never to "no suggestions".
    func testNoSuggestionsAndNoTagsIsAnEmptySequence() {
        XCTAssertFalse(TagPopover.showsSuggestedSection([]))
        XCTAssertEqual(TagPopover.rows(suggested: [], library: []), [])
    }

    func testSuggestionsPrecedeTheUntouchedAlphabeticalList() {
        let suggested = [
            TagSuggestion(tag: "recipe", reason: .inText, score: 1.0),
            TagSuggestion(tag: "client", reason: .thisFolder, score: 0.9),
        ]
        let rows = TagPopover.rows(suggested: suggested, library: ["archive", "client", "recipe"])
        XCTAssertEqual(
            rows,
            [
                .suggested("recipe"), .suggested("client"),
                .library("archive"), .library("client"), .library("recipe"),
            ])
        XCTAssertTrue(TagPopover.showsSuggestedSection(suggested))
    }

    /// A suggested tag is also a library tag, so it is drawn twice. The two
    /// rows must be distinguishable or the keyboard highlight lands on both.
    func testASuggestedRowIsNotEqualToItsLibraryRow() {
        XCTAssertNotEqual(TagPopover.Row.suggested("client"), TagPopover.Row.library("client"))
        XCTAssertEqual(TagPopover.Row.suggested("client").tag, "client")
        XCTAssertEqual(TagPopover.Row.library("client").tag, "client")
    }

    // MARK: - Four words, in both languages

    /// Locale-independent on purpose: this bundle runs in whatever language the
    /// machine is set to, and the word-for-word English and French values are
    /// asserted against the catalog in `LocalizationTests`. What is checked here
    /// is the rule that holds in every language.
    ///
    /// The ceiling is four, not three. Three words bought a nominal fragment
    /// ("in the text") that a translator cannot turn into a justification in
    /// Japanese or Korean without a verb, and French cannot carry that verb in
    /// three words either ("Apparaît dans le texte"). The rule the count is
    /// standing in for — one glance, no sentence — is unchanged; the budget
    /// moved by one word so the reason can be a statement.
    func testReasonsAreAtMostFourWords() {
        for reason in [TagSuggestionReason.inText, .thisFolder, .withTag("client")] {
            let text = TagPopover.reasonText(reason)
            XCTAssertFalse(text.isEmpty)
            XCTAssertLessThanOrEqual(
                text.split(separator: " ").count, 4, "too long: \(text)")
        }
    }

    /// The three reasons are three different sentences. A switch that fell
    /// through would say "this folder" about a word in the text.
    func testTheThreeReasonsAreDistinct() {
        let texts = Set([
            TagPopover.reasonText(.inText),
            TagPopover.reasonText(.thisFolder),
            TagPopover.reasonText(.withTag("client")),
        ])
        XCTAssertEqual(texts.count, 3)
    }

    /// The companion tag is interpolated, never localized: it is the human's
    /// own word, carried through whatever language the sentence is in, and it
    /// is what makes the reason an explanation rather than a label.
    func testCompanionTagIsCarriedVerbatim() {
        XCTAssertTrue(TagPopover.reasonText(.withTag("Projet été")).contains("#Projet été"))
        XCTAssertTrue(TagPopover.reasonText(.withTag("client")).contains("#client"))
        XCTAssertFalse(TagPopover.reasonText(.withTag("client")).contains("%@"))
    }

    // MARK: - The three states survive the new head

    /// The head changes where rows sit, not what a mark means. A suggested tag
    /// is by construction one the note does not carry, so its mark is empty and
    /// its press adds.
    func testASuggestedTagIsUncheckedAndItsPressAdds() {
        let presence = TagPopover.Presence.of("recipe", across: [["client"]])
        XCTAssertEqual(presence, .none)
        XCTAssertNil(presence.symbol)
        XCTAssertTrue(presence.pressAdds)
    }

    func testThreeStatesAreUnchangedWithASuggestedHeadPresent() {
        let lists = [["client"], ["client", "draft"]]
        XCTAssertEqual(TagPopover.Presence.of("client", across: lists), .all)
        XCTAssertEqual(TagPopover.Presence.of("draft", across: lists), .some)
        XCTAssertEqual(TagPopover.Presence.of("recipe", across: lists), .none)
        // And the head is still a head: the rows below are untouched.
        let rows = TagPopover.rows(
            suggested: [TagSuggestion(tag: "recipe", reason: .inText, score: 1.0)],
            library: ["client", "draft"])
        XCTAssertEqual(rows, [.suggested("recipe"), .library("client"), .library("draft")])
    }

    // MARK: - The hygiene offer

    /// It appears for the near-duplicate the human is typing, and it offers the
    /// existing tag rather than rewriting his.
    func testTheHygieneOfferNamesTheExistingTagAndNotTheTypedOne() {
        let offer = TagHygiene.nearDuplicate(of: "Projets", among: ["projet", "client"])
        XCTAssertEqual(offer?.existing, "projet")
        XCTAssertEqual(offer?.typed, "Projets")
    }

    /// Ignoring it is the effortless path: the moment the word stops colliding
    /// there is no offer left to ignore, so nothing is in the way of Return.
    func testTheOfferDisappearsAsSoonAsTheWordStopsColliding() {
        XCTAssertNil(TagHygiene.nearDuplicate(of: "", among: ["projet"]))
        XCTAssertNil(TagHygiene.nearDuplicate(of: "recette", among: ["projet"]))
        // And a word already spelled exactly like an existing tag offers
        // nothing: there is no duplicate about to be born.
        XCTAssertNil(TagHygiene.nearDuplicate(of: "projet", among: ["projet"]))
    }

    // MARK: - Escape, in one press

    /// The defect: Escape was two-step, gated on a flag set from AppKit *asking*
    /// for completions rather than from a menu being on screen. Type the start of
    /// an existing tag, press Escape before the list drops down, and the press
    /// was spent clearing a flag — nothing visible happened and the popover
    /// stayed open until a second Escape.
    ///
    /// The fix is that the rule has no such input left to be wrong about: Escape
    /// maps to `.closeEditor` and there is no argument by which it can become
    /// anything else. This is the regression that must not come back.
    func testEscapeAlwaysClosesTheEditorInOnePress() {
        XCTAssertEqual(
            TagTokenField.command(for: #selector(NSResponder.cancelOperation(_:))),
            .closeEditor)
    }

    /// The rest of the field's keyboard contract, so the popover stays crossable
    /// without a pointer: Tab leaves the field for the list below, and anything
    /// else is AppKit's — a completion session's own arrow keys and Return
    /// included.
    func testTabLeavesTheFieldAndEverythingElseIsAppKits() {
        XCTAssertEqual(
            TagTokenField.command(for: #selector(NSResponder.insertTab(_:))), .leaveField)
        XCTAssertEqual(
            TagTokenField.command(for: #selector(NSResponder.insertNewline(_:))), .passThrough)
        XCTAssertEqual(
            TagTokenField.command(for: #selector(NSResponder.moveDown(_:))), .passThrough)
        XCTAssertEqual(
            TagTokenField.command(for: #selector(NSResponder.deleteBackward(_:))), .passThrough)
    }

    // MARK: - What the hygiene line is asked about

    /// The half-typed word sits beside the tokens, never in place of one.
    func testPartialTextIsTheUncommittedWord() {
        XCTAssertEqual(
            TagTokenField.partial(in: ["client", "proj"], committed: ["client"]), "proj")
        XCTAssertEqual(
            TagTokenField.partial(in: ["client"], committed: ["client"]), "")
        XCTAssertEqual(TagTokenField.partial(in: [], committed: []), "")
        XCTAssertEqual(
            TagTokenField.partial(in: ["client", "  proj "], committed: ["client"]), "proj")
    }
}
