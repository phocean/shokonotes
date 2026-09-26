import XCTest
@testable import Shokonotes

/// The chip's active state is a value: a name is solid iff it is among the
/// tags currently filtering the list. The row does not reach for a model.
final class TagChipTests: XCTestCase {
    func testAChipIsActiveWhenItsNameIsAmongTheFilters() {
        XCTAssertTrue(TagChip.isActive("dfir", filters: ["dfir", "incident"]))
        XCTAssertFalse(TagChip.isActive("draft", filters: ["dfir"]))
        XCTAssertFalse(TagChip.isActive("dfir", filters: []))
    }
}
