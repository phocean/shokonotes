import XCTest
@testable import Shokonotes

final class InboxShareQueueTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var queue: InboxShareQueue!

    override func setUp() async throws {
        suite = "shokonotes-inbox-queue-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        queue = InboxShareQueue(defaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testEmptyQueueHasNoItems() {
        XCTAssertEqual(queue.items, [])
        XCTAssertEqual(queue.drain(), [])
        XCTAssertEqual(queue.items, [])
        XCTAssertNil(defaults.data(forKey: InboxShareQueue.key))
    }

    func testOneShareIsPeekable() {
        queue.enqueue("hello from Brave")
        XCTAssertEqual(queue.items, ["hello from Brave"])
        XCTAssertEqual(queue.items, ["hello from Brave"], "peek must not clear")
    }

    func testTwoSharesDoNotClobber() {
        queue.enqueue("first")
        queue.enqueue("second")
        XCTAssertEqual(queue.items, ["first", "second"])
    }

    func testDrainEmptiesAndPreservesOrder() {
        queue.enqueue("first")
        queue.enqueue("second")
        XCTAssertEqual(queue.drain(), ["first", "second"])
        XCTAssertEqual(queue.items, [])
        XCTAssertEqual(queue.drain(), [])
        XCTAssertNil(defaults.data(forKey: InboxShareQueue.key))
    }

    func testEmptyTextIsIgnored() {
        queue.enqueue("")
        queue.enqueue("   \n\t  ")
        queue.enqueue("kept")
        queue.enqueue("  ")
        XCTAssertEqual(queue.items, ["kept"])
    }

    func testJSONRoundTripsQuotesAndNewlines() {
        queue.enqueue("He said \"hi\"\n\nnext line")
        XCTAssertEqual(queue.items, ["He said \"hi\"\n\nnext line"])
    }

    func testSecondInstanceSeesTheSameItems() {
        queue.enqueue("shared")
        let other = InboxShareQueue(defaults: defaults)
        XCTAssertEqual(other.items, ["shared"])
        XCTAssertEqual(other.drain(), ["shared"])
        XCTAssertEqual(queue.items, [])
    }
}
