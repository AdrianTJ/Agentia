import XCTest
@testable import AgentiaCore

/// The reader's font-size preference.
///
/// A multiplier rather than an absolute size, so each theme keeps the
/// relationship it designed between body size, measure and typeface.
final class DisplayPreferenceTests: XCTestCase {

    func testDefaultAddsNothingToThePage() {
        XCTAssertEqual(RenderShell.Display.default.css, "",
                       "an unmodified render must carry no extra bytes")
        XCTAssertEqual(RenderShell.Display(fontScale: 1.0).css, "")
    }

    func testScaleBecomesACustomProperty() {
        XCTAssertTrue(RenderShell.Display(fontScale: 1.3).css
            .hasPrefix(":root{--agentia-scale:1.3000}"))
    }

    /// Paper is a fixed size, so scaling type there does not aid reading — it
    /// only lengthens the document. Found by dogfooding: the torture fixture
    /// went from 3 pages to 8 at 2x with identical content.
    ///
    /// The reset must travel with the scale rather than sit in base.css: this
    /// block is written into a later `<style>` at the same specificity, so a
    /// reset there loses. That is exactly how the first fix failed.
    func testPrintResetsTheScaleAndShipsWithIt() {
        let css = RenderShell.Display(fontScale: 2.0).css
        XCTAssertTrue(css.contains("@media print{:root{--agentia-scale:1}}"), css)

        let scaleAt = try! XCTUnwrap(css.range(of: "--agentia-scale:2.0000"))
        let printAt = try! XCTUnwrap(css.range(of: "@media print"))
        XCTAssertLessThan(scaleAt.lowerBound, printAt.lowerBound,
                          "the reset must come after the value it overrides")
    }

    /// Nothing is emitted at all when unmodified, so an untouched render is
    /// byte-identical to one from before the feature existed.
    func testNoPrintResetWhenThereIsNoScale() {
        XCTAssertFalse(RenderShell.Display(fontScale: 1.0).css.contains("@media print"))
    }

    /// Below ~0.7 the measure collapses to a few words a line; above ~2 a wide
    /// table cannot fit the page at any width. Clamped in the type so no caller
    /// can render an unusable page.
    func testScaleIsClamped() {
        // Asserts the clamped value, not the whole string: the declaration also
        // carries the print reset, and this test is about the bounds.
        XCTAssertTrue(RenderShell.Display(fontScale: 12).css
            .hasPrefix(":root{--agentia-scale:2.0000}"))
        XCTAssertTrue(RenderShell.Display(fontScale: 0.01).css
            .hasPrefix(":root{--agentia-scale:0.7000}"))
        XCTAssertTrue(RenderShell.Display(fontScale: -5).css
            .hasPrefix(":root{--agentia-scale:0.7000}"))
    }

    /// A scale formatted in scientific notation would not parse as CSS, and the
    /// page would silently render at the theme's size.
    func testTinyScaleNeverEmitsAnExponent() {
        let css = RenderShell.Display(fontScale: 0.0000001).css
        XCTAssertFalse(css.lowercased().contains("e-"), css)
    }

    func testPageCarriesTheScale() throws {
        let shell = try RenderShell.bundled()
        let theme = try ThemeStore.bundled().loadAll().first!

        let scaled = try shell.page(content: "<p>x</p>", theme: theme, title: "T",
                                    display: RenderShell.Display(fontScale: 1.5))
        XCTAssertTrue(scaled.contains("--agentia-scale:1.5000"))

        // Matched on the declaration, not the name: base.css legitimately
        // *reads* var(--agentia-scale, 1), so a bare substring search finds
        // that and would pass no matter what the preference did.
        let plain = try shell.page(content: "<p>x</p>", theme: theme, title: "T")
        XCTAssertFalse(plain.contains(":root{--agentia-scale"))
    }

    /// The preference is applied over the theme, so it has to come after it in
    /// the document or the cascade would drop it.
    func testUserCSSFollowsTheThemeCSS() throws {
        let shell = try RenderShell.bundled()
        let theme = try ThemeStore.bundled().loadAll().first!
        let page = try shell.page(content: "<p>x</p>", theme: theme, title: "T",
                                  display: RenderShell.Display(fontScale: 1.5))

        let themeMark = try XCTUnwrap(page.range(of: theme.css.prefix(40)))
        // The declaration, again — base.css's reference to the same name
        // appears earlier in the document and would make this pass vacuously.
        let userMark = try XCTUnwrap(page.range(of: ":root{--agentia-scale"))
        XCTAssertLessThan(themeMark.lowerBound, userMark.lowerBound)
    }

    /// Every bundled theme must actually be selectable, which means each one
    /// needs the display name the picker shows.
    func testEveryBundledThemeHasAName() throws {
        let themes = try ThemeStore.bundled().loadAll()
        XCTAssertEqual(themes.count, 6, "six themes ship")
        for theme in themes {
            XCTAssertFalse(theme.name.isEmpty, "\(theme.id) needs a display name")
            XCTAssertNotEqual(theme.name, theme.id,
                              "\(theme.id): the picker shows a name, not a filename")
        }
    }
}
