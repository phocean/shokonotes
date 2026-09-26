import XCTest
@testable import Shokonotes

/// Print-info shape only. These tests do not create a window or drive a
/// print panel: XCTest's memory checker has already crashed this target
/// for a windowed table, and a real printer is the human's pass.
@MainActor
final class NotePrinterTests: XCTestCase {

    func testPrintInfoPaginatesLikePDFExportAndSpools() {
        let info = NotePrinter.printInfo(from: NSPrintInfo())
        XCTAssertEqual(info.horizontalPagination, .fit)
        XCTAssertEqual(info.verticalPagination, .automatic)
        XCTAssertFalse(info.isHorizontallyCentered)
        XCTAssertFalse(info.isVerticallyCentered)
        XCTAssertEqual(info.topMargin, 36)
        XCTAssertEqual(info.bottomMargin, 36)
        XCTAssertEqual(info.leftMargin, 36)
        XCTAssertEqual(info.rightMargin, 36)
        XCTAssertEqual(info.jobDisposition, .spool)
    }

    func testPrintInfoDoesNotMutateTheSharedPrintInfo() {
        let shared = NSPrintInfo.shared
        let centeredBefore = shared.isVerticallyCentered
        let paginationBefore = shared.horizontalPagination
        let dispositionBefore = shared.jobDisposition

        let info = NotePrinter.printInfo(from: shared)
        info.isVerticallyCentered = true
        info.horizontalPagination = .clip
        info.jobDisposition = .save

        XCTAssertEqual(shared.isVerticallyCentered, centeredBefore)
        XCTAssertEqual(shared.horizontalPagination, paginationBefore)
        XCTAssertEqual(shared.jobDisposition, dispositionBefore)
    }

    func testPrintPanelSheetsOnAVisibleLibraryAndFallsBackOtherwise() {
        XCTAssertTrue(
            NotePrinter.printPanelAttachesToLibrary(isVisible: true, isMiniaturized: false)
        )
        XCTAssertFalse(
            NotePrinter.printPanelAttachesToLibrary(isVisible: false, isMiniaturized: false),
            "a closed library must not take the sheet — that would restore it"
        )
        XCTAssertFalse(
            NotePrinter.printPanelAttachesToLibrary(isVisible: true, isMiniaturized: true)
        )
    }
}
