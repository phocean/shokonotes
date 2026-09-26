import XCTest
@testable import Shokonotes
import AppKit

final class HotKeyTests: XCTestCase {
    func testDefaultChordsHaveDisplayNames() {
        XCTAssertTrue(KeyChord.quickNoteDefault.displayName.contains("N"))
        XCTAssertTrue(KeyChord.activateDefault.displayName.contains("S"))
        XCTAssertTrue(KeyChord.quickNoteDefault.displayName.contains("⌘"))
    }

    func testChordRoundTrip() throws {
        let data = try JSONEncoder().encode(KeyChord.quickNoteDefault)
        let decoded = try JSONDecoder().decode(KeyChord.self, from: data)
        XCTAssertEqual(decoded, KeyChord.quickNoteDefault)
    }

    // MARK: - The bring-to-front shortcut is a toggle

    /// The only case that closes: he is in Shokonotes and looking at the
    /// library.
    func testShortcutClosesOnlyWhenTheLibraryIsGenuinelyInFront() {
        XCTAssertEqual(
            ActivateShortcutAction.decide(
                applicationIsActive: true,
                windowIsVisible: true,
                windowIsKey: true,
                windowIsMiniaturized: false),
            .close)
    }

    /// The shortcut's main purpose: reaching the library from another
    /// application. A press from over there raises it even though the window
    /// is open and, to AppKit, still "key" within its own inactive app.
    func testShortcutRaisesFromAnotherApplication() {
        XCTAssertEqual(
            ActivateShortcutAction.decide(
                applicationIsActive: false,
                windowIsVisible: true,
                windowIsKey: true,
                windowIsMiniaturized: false),
            .raise)
    }

    /// A minimized library is restored, never "closed" — and that holds even
    /// if AppKit were to call a miniaturized window visible and key.
    func testShortcutRaisesMiniaturizedWindow() {
        XCTAssertEqual(
            ActivateShortcutAction.decide(
                applicationIsActive: true,
                windowIsVisible: false,
                windowIsKey: false,
                windowIsMiniaturized: true),
            .raise)
        XCTAssertEqual(
            ActivateShortcutAction.decide(
                applicationIsActive: true,
                windowIsVisible: true,
                windowIsKey: true,
                windowIsMiniaturized: true),
            .raise)
    }

    /// Closed window, or Settings holding the keyboard while the library sits
    /// behind it: both are "put the library in front of me".
    func testShortcutRaisesWhenTheLibraryIsNotTheKeyWindow() {
        XCTAssertEqual(
            ActivateShortcutAction.decide(
                applicationIsActive: true,
                windowIsVisible: false,
                windowIsKey: false,
                windowIsMiniaturized: false),
            .raise)
        XCTAssertEqual(
            ActivateShortcutAction.decide(
                applicationIsActive: true,
                windowIsVisible: true,
                windowIsKey: false,
                windowIsMiniaturized: false),
            .raise)
    }

    /// There is no window at all yet — the handler asks with every flag false.
    func testShortcutRaisesWhenThereIsNoWindow() {
        XCTAssertEqual(
            ActivateShortcutAction.decide(
                applicationIsActive: true,
                windowIsVisible: false,
                windowIsKey: false,
                windowIsMiniaturized: false),
            .raise)
        XCTAssertEqual(
            ActivateShortcutAction.decide(
                applicationIsActive: false,
                windowIsVisible: false,
                windowIsKey: false,
                windowIsMiniaturized: false),
            .raise)
    }

    /// Exhaustive: of the sixteen combinations, exactly one closes.
    func testExactlyOneCombinationCloses() {
        var closing = 0
        for active in [false, true] {
            for visible in [false, true] {
                for key in [false, true] {
                    for mini in [false, true] {
                        if ActivateShortcutAction.decide(
                            applicationIsActive: active,
                            windowIsVisible: visible,
                            windowIsKey: key,
                            windowIsMiniaturized: mini) == .close {
                            closing += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(closing, 1)
    }
}
