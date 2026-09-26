import XCTest
@testable import Shokonotes

/// In-page find may only run when the query changed or a new document
/// finished loading. `window.find` wrap-arounds, so repeating it on a
/// SwiftUI refresh of the same note hops the highlight.
final class PreviewFindPolicyTests: XCTestCase {

    func testUnchangedNoteDoesNotSearch() {
        XCTAssertFalse(
            PreviewFindPolicy.shouldSearchOnShow(documentChanged: false, queryChanged: false)
        )
    }

    func testQueryChangeOnTheSameNoteSearches() {
        XCTAssertTrue(
            PreviewFindPolicy.shouldSearchOnShow(documentChanged: false, queryChanged: true)
        )
    }

    func testNewDocumentWaitsForDidFinish() {
        // `show` also passes an in-flight `currentNavigation` as
        // `documentChanged`, so a query typed while the page is still
        // loading does not search twice — `didFinish` runs find once.
        XCTAssertFalse(
            PreviewFindPolicy.shouldSearchOnShow(documentChanged: true, queryChanged: false)
        )
        XCTAssertFalse(
            PreviewFindPolicy.shouldSearchOnShow(documentChanged: true, queryChanged: true)
        )
    }
}
