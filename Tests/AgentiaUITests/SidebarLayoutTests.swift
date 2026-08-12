import AppKit
import XCTest
@testable import AgentiaUI

/// The sidebar, open.
///
/// This is where the reported bug was visible: the Files/Outline control sitting
/// on top of the traffic lights. The collapsed sidebar in
/// `DocumentWindowLayoutTests` cannot show it, because a zero-width view
/// intersects nothing.
///
/// These assert geometry, which is what the bug actually was. They are not a
/// substitute for looking at the thing: an offscreen `cacheDisplay` render was
/// tried here first and drew the frames but not the layer-backed controls
/// inside them, which is worse than no picture at all. Appearance is checked by
/// capturing the running app's window — see the note in the README.
final class SidebarLayoutTests: XCTestCase {

    private var controller: DocumentWindowController!

    override func setUp() {
        super.setUp()
        controller = DocumentWindowController(webView: HardenedWebView())
        controller.setSidebarVisible(true, animated: false)
        controller.window?.layoutIfNeeded()
    }

    override func tearDown() {
        controller = nil
        super.tearDown()
    }

    private var window: NSWindow { controller.window! }

    private func firstDescendant<T: NSView>(_ type: T.Type) -> T? {
        var queue = window.contentView?.subviews ?? []
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let match = view as? T { return match }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    func testSidebarOpensToItsFullWidth() {
        let sidebar = firstDescendant(SidebarView.self)
        XCTAssertEqual(sidebar?.frame.width, SidebarView.preferredWidth)
        XCTAssertEqual(sidebar?.isHidden, false)
    }

    /// The bug, exactly: the sidebar's mode control overlapping the window
    /// buttons.
    func testModeControlClearsTheWindowButtons() throws {
        let control = try XCTUnwrap(firstDescendant(NSSegmentedControl.self),
                                    "sidebar mode control not found")
        let controlInWindow = control.convert(control.bounds, to: nil)

        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try XCTUnwrap(window.standardWindowButton(kind))
            let buttonInWindow = button.convert(button.bounds, to: nil)
            XCTAssertFalse(controlInWindow.intersects(buttonInWindow),
                           "Files/Outline control is drawn over the \(kind)")
        }
    }

    /// The document keeps the rest of the window: a sidebar that overlapped the
    /// web view would hide the left edge of every line of text.
    func testSidebarAndDocumentDoNotOverlap() throws {
        let sidebar = try XCTUnwrap(firstDescendant(SidebarView.self))
        let web = try XCTUnwrap(firstDescendant(HardenedWebView.self))
        XCTAssertFalse(sidebar.frame.intersects(web.frame))
        XCTAssertEqual(sidebar.frame.maxX, web.frame.minX, accuracy: 0.5)
    }

    func testClosingTheSidebarGivesTheWidthBack() {
        let web = firstDescendant(HardenedWebView.self)
        let openWidth = web?.frame.width ?? 0

        controller.setSidebarVisible(false, animated: false)
        window.layoutIfNeeded()

        XCTAssertEqual(web?.frame.width ?? 0, openWidth + SidebarView.preferredWidth,
                       accuracy: 0.5)
        XCTAssertEqual(firstDescendant(SidebarView.self)?.isHidden, true)
    }

    /// Whether the sidebar is open is remembered, so opening the file list once
    /// does not have to be done again on every launch.
    func testVisibilityIsRemembered() {
        XCTAssertTrue(Preferences.sidebarVisible)

        controller.setSidebarVisible(false, animated: false)
        XCTAssertFalse(Preferences.sidebarVisible)
    }
}
