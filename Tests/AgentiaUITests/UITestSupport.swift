import AppKit
import XCTest
@testable import AgentiaUI

/// Shared helpers for the window tests.
///
/// Both the "does the content clear the traffic lights" check and the
/// find-a-subview search were written twice, once in each layout test file, and
/// the two searches did not even agree — one walked the whole tree, the other
/// looked only at direct children and happened to work because the views it
/// wanted were one level down.

extension XCTestCase {

    /// Assert that a view does not sit on top of the window buttons.
    ///
    /// The bug this exists for: the sidebar's Files/Outline control laid out
    /// underneath the close and minimise buttons.
    func assertClearsWindowButtons(_ view: NSView,
                                   in window: NSWindow,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) {
        let viewInWindow = view.convert(view.bounds, to: nil)

        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind) else { continue }
            let buttonInWindow = button.convert(button.bounds, to: nil)
            XCTAssertFalse(viewInWindow.intersects(buttonInWindow),
                           "\(type(of: view)) is drawn over the \(kind)",
                           file: file, line: line)
        }
    }
}

extension NSWindow {

    /// The first view of a given type anywhere below the content view.
    ///
    /// Searches the whole tree rather than direct children only: a view moving
    /// one level deeper is a layout change, not a reason for a test to stop
    /// finding it.
    func firstDescendant<T: NSView>(_ type: T.Type) -> T? {
        var queue = contentView?.subviews ?? []
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let match = view as? T { return match }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
}
