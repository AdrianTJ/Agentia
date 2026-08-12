import AppKit
import XCTest
@testable import AgentiaUI

/// The window's geometry.
///
/// These exist because a build shipped with the sidebar's Files/Outline control
/// drawn underneath the traffic lights, overlapping the close and minimise
/// buttons, while every test in the project was green. Nothing could have caught
/// it: the whole AppKit layer lived in an executable target with `@main`, which
/// a test bundle cannot import. It is a library now, and this is the first thing
/// worth asserting about it.
///
/// No window is ever ordered on screen here. The layout is real — Auto Layout
/// runs against a real window — but `showWindow` is never called, so running the
/// suite does not steal focus from whoever is using the Mac.
final class DocumentWindowLayoutTests: XCTestCase {

    private var controller: DocumentWindowController!

    override func setUp() {
        super.setUp()
        controller = DocumentWindowController(webView: HardenedWebView())
        controller.window?.layoutIfNeeded()
    }

    override func tearDown() {
        controller = nil
        super.tearDown()
    }

    private var window: NSWindow { controller.window! }

    /// The bug itself, stated as the rule it broke.
    ///
    /// `.fullSizeContentView` extends the content view up behind the titlebar.
    /// Every subview in `makeContentView()` is pinned to the content view's own
    /// top, so with that flag set the sidebar header was laid out in the
    /// titlebar's space — on top of the window buttons.
    func testContentDoesNotExtendUnderTheTitlebar() {
        let content = window.contentView!
        XCTAssertEqual(content.frame.height, window.contentLayoutRect.height, accuracy: 0.5,
                       "content view reaches into the titlebar")
        XCTAssertEqual(content.frame.width, window.contentLayoutRect.width, accuracy: 0.5)
    }

    /// The same rule from the other side, in the coordinates that matter: no
    /// content may sit where the traffic lights are.
    func testNothingIsLaidOutBehindTheWindowButtons() {
        let content = window.contentView!
        let contentInWindow = content.convert(content.bounds, to: nil)

        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind) else { continue }
            let buttonInWindow = button.convert(button.bounds, to: nil)
            XCTAssertFalse(contentInWindow.intersects(buttonInWindow),
                           "content overlaps the \(kind) button")
        }
    }

    /// The sidebar starts collapsed, and collapsed means zero width — not merely
    /// hidden. Its contents are a fixed 228pt wide and would otherwise paint
    /// over the document.
    func testSidebarStartsCollapsedAndClipped() {
        let sidebar = window.contentView!.subviews.compactMap { $0 as? SidebarView }.first
        let found = try? XCTUnwrap(sidebar)
        guard let sidebar = found else { return }

        XCTAssertEqual(sidebar.frame.width, 0, accuracy: 0.5)
        XCTAssertTrue(sidebar.isHidden)
        XCTAssertTrue(sidebar.clipsToBounds,
                      "a collapsed sidebar that does not clip paints over the document")
    }

    /// Laying out the window must not produce Auto Layout conflicts. A conflict
    /// is resolved by breaking a constraint, and the survivor is whichever one
    /// AppKit picked — which is how the sidebar's mode control once stopped
    /// tracking the sidebar's edge.
    func testLayoutIsSatisfiable() {
        let content = window.contentView!
        XCTAssertFalse(content.hasAmbiguousLayout,
                       "ambiguous layout: some frame here is not determined by the constraints")
    }

    /// The editor and the web view occupy the same rectangle, so toggling
    /// between them moves nothing on screen.
    func testEditorAndWebViewShareTheSameFrame() {
        let content = window.contentView!
        let editor = content.subviews.compactMap { $0 as? SourceEditor }.first
        let web = content.subviews.compactMap { $0 as? HardenedWebView }.first

        guard let editor, let web else { return XCTFail("editor or web view missing") }
        XCTAssertEqual(editor.frame, web.frame)
    }
}
