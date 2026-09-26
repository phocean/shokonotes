#import <XCTest/XCTest.h>
#import <AppKit/AppKit.h>

/// Apple's `NSTableView.h` contract, in the language of the exception:
///
///     rowActionsVisible can be queried to determine if the "row actions"
///     are visible or not. Set rowActionsVisible=NO to hide the row actions.
///     Setting rowActionsVisible=YES is currently not supported and will
///     throw an exception.
///
/// `NoteListRowActions.dismiss()` only writes `false` because of this.
/// The setter is view-based-only; a bare `NSTableView` throws a different
/// assertion, so these tables implement `viewForTableColumn`.
@interface RowActionsVisibleContractTests : XCTestCase
@end

@interface SNViewBasedTableSupport : NSObject <NSTableViewDelegate, NSTableViewDataSource>
@end

@implementation SNViewBasedTableSupport
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return 0; }
- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    return [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 100, 20)];
}
@end

@implementation RowActionsVisibleContractTests {
    SNViewBasedTableSupport *_support;
}

- (NSTableView *)viewBasedTable {
    NSTableView *table = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 240, 80)];
    [table addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"col"]];
    _support = [SNViewBasedTableSupport new];
    table.delegate = _support;
    table.dataSource = _support;
    [table reloadData];
    return table;
}

- (void)testSettingRowActionsVisibleTrueThrows {
    NSTableView *table = [self viewBasedTable];
    XCTAssertFalse(table.rowActionsVisible);
    XCTAssertThrows((table.rowActionsVisible = YES),
                    @"dismiss only writes NO: setting YES throws");
}

- (void)testSettingRowActionsVisibleFalseDoesNotThrow {
    NSTableView *table = [self viewBasedTable];
    XCTAssertNoThrow((table.rowActionsVisible = NO));
    XCTAssertFalse(table.rowActionsVisible);
}

@end
