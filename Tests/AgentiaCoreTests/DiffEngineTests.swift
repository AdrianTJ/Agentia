import XCTest
@testable import AgentiaCore

/// Vector-driven so the same expectations are checked here and by
/// `tools/verify-diff-vectors.py`, which is the reference implementation.
/// Regenerate with `python3 tools/verify-diff-vectors.py --emit`.
final class DiffEngineTests: XCTestCase {

    private struct Vectors: Decodable {
        struct Case: Decodable {
            let name: String
            let old: String
            let new: String
            let expected: [DiffRange]
        }
        let quadraticLimit: Int
        let cases: [Case]
    }

    private func loadVectors() throws -> Vectors {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "diff-vectors",
                              withExtension: "json",
                              subdirectory: "Fixtures"),
            "diff-vectors.json is missing from the test bundle"
        )
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    func testMatchesReferenceVectors() throws {
        let vectors = try loadVectors()
        XCTAssertFalse(vectors.cases.isEmpty)

        for testCase in vectors.cases {
            let actual = DiffEngine.changes(from: testCase.old, to: testCase.new)
            XCTAssertEqual(actual, testCase.expected, "case: \(testCase.name)")
        }
    }

    func testQuadraticLimitMatchesReference() throws {
        let vectors = try loadVectors()
        XCTAssertEqual(DiffEngine.quadraticLimit, vectors.quadraticLimit,
                       "Swift and the reference implementation must agree on the limit")
    }

    // MARK: - Line splitting

    func testLineSplitting() {
        XCTAssertEqual(DiffEngine.lines(of: ""), [])
        XCTAssertEqual(DiffEngine.lines(of: "a"), ["a"])
        XCTAssertEqual(DiffEngine.lines(of: "a\n"), ["a"])
        XCTAssertEqual(DiffEngine.lines(of: "a\nb"), ["a", "b"])
        XCTAssertEqual(DiffEngine.lines(of: "a\r\nb\r\n"), ["a", "b"])
        XCTAssertEqual(DiffEngine.lines(of: "a\rb"), ["a", "b"])
        // A blank line in the middle is real content and must survive.
        XCTAssertEqual(DiffEngine.lines(of: "a\n\nb\n"), ["a", "", "b"])
        // Only one trailing newline is absorbed.
        XCTAssertEqual(DiffEngine.lines(of: "a\n\n"), ["a", ""])
    }

    // MARK: - Properties that must hold for any input

    func testRangesAreOrderedNonOverlappingAndInBounds() {
        let old = "alpha\nbravo\ncharlie\ndelta\necho\nfoxtrot\n"
        let new = "alpha\nBRAVO\ncharlie\nnew line\ndelta\nECHO\nfoxtrot\nappended\n"

        let ranges = DiffEngine.changes(from: old, to: new)
        let lineCount = DiffEngine.lines(of: new).count

        XCTAssertFalse(ranges.isEmpty)

        var previousEnd = 0
        for range in ranges {
            XCTAssertGreaterThanOrEqual(range.start, 1, "start is 1-based")
            XCTAssertLessThanOrEqual(range.end, lineCount, "end is within the new text")
            XCTAssertLessThanOrEqual(range.start, range.end, "range is not inverted")
            XCTAssertGreaterThan(range.start, previousEnd, "ranges do not overlap")
            previousEnd = range.end
        }
    }

    func testNoChangeForIdenticalLargeDocument() {
        let body = (1...500).map { "line \($0)" }.joined(separator: "\n") + "\n"
        XCTAssertEqual(DiffEngine.changes(from: body, to: body), [])
    }

    func testExceedingQuadraticLimitFallsBackToOneModifiedRange() {
        // Two documents that share nothing, both past the limit.
        let old = (1...(DiffEngine.quadraticLimit + 10))
            .map { "old \($0)" }.joined(separator: "\n")
        let new = (1...(DiffEngine.quadraticLimit + 20))
            .map { "new \($0)" }.joined(separator: "\n")

        let ranges = DiffEngine.changes(from: old, to: new)

        XCTAssertEqual(ranges.count, 1, "the fallback reports a single range")
        XCTAssertEqual(ranges.first?.kind, .modified)
        XCTAssertEqual(ranges.first?.start, 1)
        XCTAssertEqual(ranges.first?.end, DiffEngine.lines(of: new).count)
    }

    func testLargeButMostlyUnchangedDocumentStillUsesPreciseDiff() {
        // Head/tail trimming must keep this off the quadratic path even though
        // the document is far larger than the limit.
        var lines = (1...(DiffEngine.quadraticLimit * 2)).map { "line \($0)" }
        let old = lines.joined(separator: "\n") + "\n"
        lines[DiffEngine.quadraticLimit] = "CHANGED"
        let new = lines.joined(separator: "\n") + "\n"

        let ranges = DiffEngine.changes(from: old, to: new)

        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges.first?.kind, .modified)
        XCTAssertEqual(ranges.first?.start, DiffEngine.quadraticLimit + 1)
        XCTAssertEqual(ranges.first?.lineCount, 1,
                       "trimming should isolate the single changed line")
    }

    func testFirstOpenShowsNoDiff() {
        // Opening a document for the first time has no previous revision; the
        // whole page must not light up as added.
        XCTAssertEqual(DiffEngine.changes(from: "", to: "# Anything\n"), [])
    }
}
