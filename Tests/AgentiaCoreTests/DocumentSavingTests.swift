import XCTest
@testable import AgentiaCore

/// Whether it is safe to write a document back.
///
/// This app's premise makes the collision likely rather than exotic: it opens
/// files an agent is actively rewriting, and watches them so a rerun appears
/// immediately. Once the reader can edit, both sides move independently between
/// the read and the save.
final class DocumentSavingTests: XCTestCase {

    private func verdict(_ recorded: Data?, _ current: Data?,
                         exists: Bool = true) -> DocumentSaving.Verdict {
        DocumentSaving.verdict(recordedBytes: recorded, currentBytes: current,
                               fileExists: exists)
    }

    func testUntouchedFileIsSafeToWrite() {
        let bytes = Data("# Report\n".utf8)
        XCTAssertEqual(verdict(bytes, bytes), .safe)
    }

    func testAnyRewriteIsDetected() {
        XCTAssertEqual(verdict(Data("# A\n".utf8), Data("# B\n".utf8)), .changedOnDisk)
        // Same length, different content — the case a size comparison misses.
        XCTAssertEqual(verdict(Data("aaaa".utf8), Data("bbbb".utf8)), .changedOnDisk)
        // A single byte appended.
        XCTAssertEqual(verdict(Data("x".utf8), Data("x\n".utf8)), .changedOnDisk)
    }

    /// The hole in the previous version. Dates were compared at whole-second
    /// resolution, so a rewrite landing in the same second as the read and
    /// producing content of the same length looked untouched and was silently
    /// overwritten — which is exactly what an agent rewriting its report in a
    /// tight loop produces. Content comparison has no such window.
    func testSameSecondSameLengthRewriteIsStillDetected() {
        XCTAssertEqual(verdict(Data("recall 0.712\n".utf8),
                               Data("recall 0.849\n".utf8)),
                       .changedOnDisk)
    }

    /// Not knowing must fail toward asking, never toward overwriting.
    func testUnreadableBytesAreTreatedAsChanged() {
        XCTAssertEqual(verdict(nil, Data()), .changedOnDisk)
        XCTAssertEqual(verdict(Data(), nil), .changedOnDisk)
    }

    func testMissingFileIsItsOwnAnswer() {
        let bytes = Data("x".utf8)
        XCTAssertEqual(verdict(bytes, bytes, exists: false), .missing)
        XCTAssertEqual(verdict(nil, nil, exists: false), .missing)
    }

    func testEmptyFileIsSafeAgainstItself() {
        XCTAssertEqual(verdict(Data(), Data()), .safe)
    }

    // MARK: - Against a real file

    func testARealRewriteIsSeen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentia-save-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }

        try "# One\n".write(to: url, atomically: true, encoding: .utf8)
        let snapshot = try DocumentRenderer.read(contentsOf: url)

        var now = DocumentSaving.currentBytes(of: url)
        XCTAssertEqual(verdict(snapshot.bytesOnDisk, now.bytes, exists: now.exists), .safe)

        // Rewritten immediately — no sleep, because content comparison does not
        // depend on the clock. The old metadata check needed a full second's
        // delay to notice this at all.
        try "# One\n\nRewritten.\n".write(to: url, atomically: true, encoding: .utf8)
        now = DocumentSaving.currentBytes(of: url)
        XCTAssertEqual(verdict(snapshot.bytesOnDisk, now.bytes, exists: now.exists),
                       .changedOnDisk)
    }

    /// `URL` caches resource values, and the metadata version of this check was
    /// defeated by exactly that: the same URL instance reported the file's old
    /// state, the verdict came back safe, and the rewrite was overwritten.
    func testAnImmediateRewriteThroughTheSameURLIsSeen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentia-cache-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }

        try "original".write(to: url, atomically: true, encoding: .utf8)
        let first = DocumentSaving.currentBytes(of: url)
        try "replaced".write(to: url, atomically: true, encoding: .utf8)
        let second = DocumentSaving.currentBytes(of: url)

        XCTAssertNotEqual(first.bytes, second.bytes,
                          "a cached read would report the old bytes here")
    }

    func testMissingFileReportsItself() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentia-gone-\(UUID().uuidString).md")
        XCTAssertFalse(DocumentSaving.currentBytes(of: url).exists)
    }

    /// The snapshot has to carry the bytes, or the save has nothing to compare.
    func testSnapshotKeepsTheBytesItRead() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentia-snap-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        try "# Report\n".write(to: url, atomically: true, encoding: .utf8)

        let snapshot = try DocumentRenderer.read(contentsOf: url)
        XCTAssertEqual(snapshot.bytesOnDisk, Data("# Report\n".utf8))
    }
}
