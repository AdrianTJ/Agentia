import AppKit
import XCTest
@testable import AgentiaCore
@testable import AgentiaUI

/// Switching between the editor and the rendered view, with unsaved edits in
/// play.
///
/// The bug these were written for: typing into the scratchpad and switching to
/// the rendered view showed "This document is empty." `render()` was reading
/// `snapshot.source` — the bytes read from disk — while the reader's text
/// existed only in the editor. Since checking what you wrote is the reason to
/// switch views at all, the feature failed in exactly the case it was for.
final class ViewModeTests: XCTestCase {

    private var controller: DocumentWindowController!
    private var url: URL!

    override func setUp() {
        super.setUp()
        controller = DocumentWindowController(webView: HardenedWebView())
        controller.window?.layoutIfNeeded()

        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentia-ui-\(UUID().uuidString).md")
    }

    override func tearDown() {
        if let url { try? FileManager.default.removeItem(at: url) }
        controller = nil
        super.tearDown()
    }

    private func open(_ contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        controller.open(url)
    }

    /// Type the way a keystroke does. `insertText` goes through the text system,
    /// so the editor's delegate fires and the buffer becomes dirty exactly as it
    /// would for a person at the keyboard — a test hook that set the string
    /// directly would skip the very callback under test.
    private func type(_ text: String) throws {
        let editor = try XCTUnwrap(controller.sourceEditor)
        editor.insertText(text)
    }

    // MARK: - What gets rendered

    func testCleanBufferRendersWhatIsOnDisk() throws {
        try open("# On disk\n")
        XCTAssertEqual(controller.currentSource, "# On disk\n")
    }

    /// The reported bug, at the level it actually broke.
    func testRenderedViewUsesUnsavedEdits() throws {
        try open("")                       // an empty scratchpad
        controller.toggleSource(nil)       // into the editor
        try type("# My notes\n")

        controller.toggleSource(nil)       // back to the rendered view
        XCTAssertEqual(controller.mode, .rendered)
        XCTAssertEqual(controller.currentSource, "# My notes\n",
                       "the rendered view is showing the file, not what was typed")
    }

    /// The user-visible symptom, stated directly: a document with typed text is
    /// not empty, whatever the file on disk still says.
    func testTypedTextIsNotTreatedAsAnEmptyDocument() throws {
        try open("")
        controller.toggleSource(nil)
        try type("something")
        controller.toggleSource(nil)

        XCTAssertFalse(
            controller.currentSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "this is the exact test render() applies before showing \"This document is empty.\""
        )
    }

    func testEditsSurviveAToggleBackIntoTheEditor() throws {
        try open("# Start\n")
        controller.toggleSource(nil)
        try type("edited ")
        controller.toggleSource(nil)       // rendered
        controller.toggleSource(nil)       // and back

        // Contains, not hasPrefix: the text lands at the caret, wherever that
        // is. What matters is that it survived the round trip.
        XCTAssertTrue(controller.currentSource.contains("edited "),
                      "returning to the editor reloaded the file over the edits")
    }

    // MARK: - Dirty state

    func testTypingMarksTheDocumentEdited() throws {
        try open("# Start\n")
        XCTAssertFalse(controller.canSave)

        controller.toggleSource(nil)
        try type("x")

        XCTAssertTrue(controller.canSave)
        XCTAssertEqual(controller.window?.isDocumentEdited, true,
                       "no dot in the close button means nothing warns the reader")
    }

    func testDiscardingEditsClearsTheState() throws {
        try open("# Start\n")
        controller.toggleSource(nil)
        try type("x")
        controller.discardEdits()

        XCTAssertFalse(controller.canSave)
        XCTAssertEqual(controller.window?.isDocumentEdited, false)
    }

    // MARK: - Termination

    /// Info.plist opts into sudden termination, which is a promise the process
    /// can be SIGKILLed with nothing running first — no
    /// `applicationShouldTerminate`, so no unsaved-changes prompt, and the
    /// buffer is gone with no crash report to show for it. That promise has to
    /// be withdrawn while there are unsaved edits.
    func testUnsavedEditsHoldOffSuddenTermination() throws {
        try open("# Start\n")
        XCTAssertFalse(controller.isHoldingTermination)

        controller.toggleSource(nil)
        try type("x")
        XCTAssertTrue(controller.isHoldingTermination,
                      "macOS may kill the process and take the unsaved buffer with it")
    }

    /// And restored afterwards — a viewer with nothing unsaved should stay cheap
    /// for the system to reclaim. The ProcessInfo calls are counted, so an
    /// unbalanced pair would leave the app pinned forever.
    func testDiscardingEditsReleasesTheHold() throws {
        try open("# Start\n")
        controller.toggleSource(nil)
        try type("x")
        controller.discardEdits()

        XCTAssertFalse(controller.isHoldingTermination)
    }

    func testRepeatedTypingHoldsTerminationOnlyOnce() throws {
        try open("# Start\n")
        controller.toggleSource(nil)
        try type("a")
        try type("b")
        try type("c")
        controller.discardEdits()

        // If the disable/enable calls were unbalanced, the count would still be
        // positive here and the process would never be reclaimable again.
        XCTAssertFalse(controller.isHoldingTermination)
    }
}
