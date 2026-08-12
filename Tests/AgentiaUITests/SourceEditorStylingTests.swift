import AppKit
import XCTest
@testable import AgentiaCore
@testable import AgentiaUI

/// That the styling actually reaches the text.
///
/// `MarkdownEditorStyleTests` covers which ranges are what; nothing there can
/// tell whether the editor ever applied them. This is the wiring: spans in,
/// attributes on screen.
final class SourceEditorStylingTests: XCTestCase {

    private var editor: SourceEditor!

    override func setUp() {
        super.setUp()
        editor = SourceEditor(onDirty: {})
        editor.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        editor.layoutSubtreeIfNeeded()
    }

    override func tearDown() {
        editor = nil
        super.tearDown()
    }

    private func font(at location: Int) throws -> NSFont {
        try XCTUnwrap(editor.attribute(.font, at: location) as? NSFont)
    }

    private func colour(at location: Int) throws -> NSColor {
        try XCTUnwrap(editor.attribute(.foregroundColor, at: location) as? NSColor)
    }

    private func location(of substring: String, in source: String) throws -> Int {
        let range = (source as NSString).range(of: substring)
        XCTAssertNotEqual(range.location, NSNotFound, "\(substring) not in the fixture")
        return range.location
    }

    // MARK: - The point of the whole feature

    func testHeadingsAreLargerThanBodyText() throws {
        let source = "# Big\n\nplain\n"
        editor.load(source)

        let heading = try font(at: location(of: "Big", in: source))
        let body = try font(at: location(of: "plain", in: source))
        XCTAssertGreaterThan(heading.pointSize, body.pointSize)
    }

    func testHeadingLevelsDescend() throws {
        let source = "# One\n\n## Two\n\n### Three\n"
        editor.load(source)

        let h1 = try font(at: location(of: "One", in: source)).pointSize
        let h2 = try font(at: location(of: "Two", in: source)).pointSize
        let h3 = try font(at: location(of: "Three", in: source)).pointSize
        XCTAssertGreaterThan(h1, h2)
        XCTAssertGreaterThan(h2, h3)
    }

    func testBoldIsActuallyBold() throws {
        let source = "a **strong** b\n"
        editor.load(source)

        let bold = try font(at: location(of: "strong", in: source))
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.bold))

        let plain = try font(at: location(of: "a ", in: source))
        XCTAssertFalse(plain.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testItalicIsActuallyItalic() throws {
        let source = "a *soft* b\n"
        editor.load(source)
        let italic = try font(at: location(of: "soft", in: source))
        XCTAssertTrue(italic.fontDescriptor.symbolicTraits.contains(.italic))
    }

    /// Emphasis inside a heading keeps the heading's size — which is why the
    /// view adds a trait to the existing font instead of replacing it.
    func testBoldInsideAHeadingStaysHeadingSized() throws {
        let source = "# A **big** title\n\nplain\n"
        editor.load(source)

        let boldInHeading = try font(at: location(of: "big", in: source))
        let body = try font(at: location(of: "plain", in: source))
        XCTAssertTrue(boldInHeading.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertGreaterThan(boldInHeading.pointSize, body.pointSize,
                             "bold replaced the heading font instead of refining it")
    }

    func testCodeIsMonospaced() throws {
        let source = "use `let x = 1` here\n"
        editor.load(source)
        let code = try font(at: location(of: "let x", in: source))
        XCTAssertTrue(code.isFixedPitch, "code should be monospaced")
    }

    /// The markers recede rather than vanish: they stay in the text, drawn in a
    /// dimmer colour than the content they wrap.
    func testMarkersAreDimmedButPresent() throws {
        let source = "## Title\n"
        editor.load(source)

        XCTAssertEqual(editor.text, source, "styling must never rewrite the text")

        let marker = try colour(at: location(of: "##", in: source))
        let content = try colour(at: location(of: "Title", in: source))
        XCTAssertNotEqual(marker, content)
    }

    // MARK: - The text is never touched

    /// The guarantee that makes this approach worth choosing over editing the
    /// rendered HTML.
    func testStylingLeavesTheDocumentByteForByte() {
        for source in [
            "# Heading\n\nSome **bold** and `code`.\n",
            "```swift\nlet x = 1\n```\n",
            "- a\n- b\n\n> quote\n\n[link](./a.md)\n",
            "Trailing spaces   \nand\ttabs\n",
            "emoji 👋 and accents é\n",
        ] {
            editor.load(source)
            XCTAssertEqual(editor.text, source)
        }
    }

    func testTypingLeavesTheTextExactlyAsTyped() {
        editor.load("")
        editor.insertText("# Title\n\nsome **bold**")
        XCTAssertEqual(editor.text, "# Title\n\nsome **bold**")
    }

    // MARK: - Reader settings

    func testTextSizeScalesTheWholeDocument() throws {
        let source = "# Heading\n\nbody\n"
        editor.load(source)
        let before = try font(at: location(of: "body", in: source)).pointSize

        editor.applyFontScale(2.0)
        let after = try font(at: location(of: "body", in: source)).pointSize

        XCTAssertEqual(after, before * 2, accuracy: 0.01)
        // And the styling survives the change rather than resetting to plain.
        let heading = try font(at: location(of: "Heading", in: source)).pointSize
        XCTAssertGreaterThan(heading, after)
    }

    /// Text is laid out in a measure and centred, not run edge to edge across a
    /// wide window.
    func testTextIsLaidOutInACentredColumn() {
        editor.frame = NSRect(x: 0, y: 0, width: 1600, height: 600)
        editor.layoutSubtreeIfNeeded()

        let inset = editor.textInsets.width
        XCTAssertGreaterThan(inset, 100, "text runs the full width of a wide window")
    }

    /// A narrow window gives its width to the text rather than keeping a measure
    /// it no longer has room for.
    func testANarrowWindowKeepsTheMargins() {
        editor.frame = NSRect(x: 0, y: 0, width: 420, height: 600)
        editor.layoutSubtreeIfNeeded()

        let inset = editor.textInsets.width
        XCTAssertEqual(inset, 24, accuracy: 0.5)
    }

    // MARK: - Dirty tracking still works

    func testStylingDoesNotMarkTheBufferDirty() {
        editor.load("# Heading\n")
        XCTAssertFalse(editor.isDirty,
                       "applying attributes must not read as the reader typing")
    }
}
