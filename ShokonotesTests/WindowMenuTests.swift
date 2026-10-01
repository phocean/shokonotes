import AppKit
import XCTest
@testable import Shokonotes

@MainActor
final class WindowMenuTests: XCTestCase {
    /// App Review guideline 4: a closed library window must be reopenable
    /// from a menu. The item has no window target, so it stays enabled.
    func testWindowMenuListsLibraryWithCommandZero() throws {
        let menu = try XCTUnwrap(MainMenu.windowMenuItem().submenu)
        let item = try XCTUnwrap(menu.items.first { $0.action == #selector(AppDelegate.showLibraryWindow(_:)) })
        XCTAssertEqual(item.keyEquivalent, "0")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
        XCTAssertNil(item.target)
        let minimize = try XCTUnwrap(menu.items.firstIndex { $0.action == #selector(NSWindow.performMiniaturize(_:)) })
        XCTAssertGreaterThan(try XCTUnwrap(menu.items.firstIndex(of: item)), minimize)
    }
}
