import AppKit
import XCTest
@testable import AgentiaCore
@testable import AgentiaUI

/// The sidebar's list, driven the way AppKit drives it.
///
/// A table asks its delegate for a row by index, and the index it asks for is
/// the one it knew about — not necessarily the one the data has now. This list
/// is replaced from three directions: a new document's outline (which arrives
/// asynchronously, whenever the page reports its headings), a folder rescan, and
/// the Files/Outline segment. An unguarded subscript in that position is a trap
/// that takes the process down and the unsaved buffer with it.
///
/// A test cannot assert "does not crash" — a trap kills the runner — so these
/// pass here and would have taken the suite down before the guards.
final class SidebarDataTests: XCTestCase {

    private var controller: DocumentWindowController!
    private var sidebar: SidebarView!
    private let table = NSTableView()

    override func setUp() {
        super.setUp()
        controller = DocumentWindowController(webView: HardenedWebView())
        sidebar = SidebarView(controller: controller)
    }

    override func tearDown() {
        sidebar = nil
        controller = nil
        super.tearDown()
    }

    private func url(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    func testRowBeyondTheDocumentListIsNotFatal() {
        sidebar.reload(documents: [url("a.md"), url("b.md")], selected: nil)
        XCTAssertEqual(sidebar.numberOfRows(in: table), 2)

        XCTAssertNil(sidebar.tableView(table, viewFor: nil, row: 7))
        XCTAssertNotNil(sidebar.tableView(table, viewFor: nil, row: 1))
    }

    /// The list shrinking is the realistic version: a folder rescan returns
    /// fewer files than the table last drew.
    func testTheListShrinkingUnderTheTable() {
        sidebar.reload(documents: [url("a.md"), url("b.md"), url("c.md")], selected: nil)
        sidebar.reload(documents: [url("a.md")], selected: nil)

        XCTAssertEqual(sidebar.numberOfRows(in: table), 1)
        XCTAssertNil(sidebar.tableView(table, viewFor: nil, row: 2))
    }

    /// The outline is the more exposed of the two, because it is replaced
    /// whenever a page finishes loading rather than in response to anything the
    /// reader did.
    func testRowBeyondTheOutlineIsNotFatal() {
        sidebar.setOutline([
            OutlineItem(id: "agentia-h0", level: 1, title: "One"),
            OutlineItem(id: "agentia-h1", level: 2, title: "Two"),
        ])
        sidebar.select(mode: .outline)
        XCTAssertEqual(sidebar.numberOfRows(in: table), 2)

        XCTAssertNil(sidebar.tableView(table, viewFor: nil, row: 5))
        XCTAssertNotNil(sidebar.tableView(table, viewFor: nil, row: 0))
    }

    /// A document with no headings after one that had them: the segment falls
    /// back to Files, and the stale outline rows must not be reachable.
    func testOutlineEmptyingFallsBackToFiles() {
        sidebar.setOutline([OutlineItem(id: "agentia-h0", level: 1, title: "One")])
        sidebar.select(mode: .outline)
        sidebar.reload(documents: [url("a.md")], selected: nil)

        sidebar.setOutline([])

        XCTAssertEqual(sidebar.numberOfRows(in: table), 1,
                       "still listing the previous document's headings")
        XCTAssertNotNil(sidebar.tableView(table, viewFor: nil, row: 0))
    }

    func testSelectionOutsideTheListIsIgnored() {
        sidebar.reload(documents: [url("a.md")], selected: url("nowhere.md"))
        // No row matches, so nothing is selected — rather than an index that is
        // not there being handed to the table.
        XCTAssertEqual(sidebar.numberOfRows(in: table), 1)
    }
}
