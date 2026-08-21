import XCTest
@testable import AgentiaCore

final class MathDetectionTests: XCTestCase {

    func testDisplayMathTriggers() {
        XCTAssertTrue(MathDetection.present(in: "$$E = mc^2$$"))
        XCTAssertTrue(MathDetection.present(in: "Text\n\n$$\nx = 1\n$$\n"))
    }

    func testBracketDelimitersTrigger() {
        XCTAssertTrue(MathDetection.present(in: "Euler: \\(e^{i\\pi} = -1\\) yes"))
        XCTAssertTrue(MathDetection.present(in: "Display:\n\\[\n\\int_0^1 x\\,dx\n\\]\n"))
    }

    func testBeginBlockTriggers() {
        XCTAssertTrue(MathDetection.present(in: "\\begin{equation} y = x \\end{equation}"))
    }

    func testCurrencyDoesNotTrigger() {
        XCTAssertFalse(MathDetection.present(in: "It costs $100 and maybe $200 later."))
        XCTAssertFalse(MathDetection.present(in: "No math here at all."))
        XCTAssertFalse(MathDetection.present(in: ""))
    }

    func testCodeBlocksAreIgnored() {
        // Auto-render skips fenced code, so a ``` block mentioning $$ must not
        // switch KaTeX on for the whole document.
        XCTAssertFalse(MathDetection.present(in: "```bash\necho '$$ is not math'\n```\nPlain text."))
    }

    func testMathOutsideTheFenceStillTriggers() {
        XCTAssertTrue(MathDetection.present(in: "```text\nnothing\n```\nAnd \\(x=1\\)."))
    }
}
