import XCTest
@testable import AgentiaCore

/// Whether it is safe to write a document back.
///
/// This app's whole premise makes the collision likely rather than exotic: it
/// opens files an agent is actively rewriting, and watches them so a new run
/// appears immediately. Once the reader can edit, both sides can move between
/// the read and the save.
final class DocumentSavingTests: XCTestCase {

    private let then = Date(timeIntervalSince1970: 1_700_000_000)

    private func verdict(
        recorded: Date?, recordedSize: Int?,
        current: Date?, currentSize: Int?,
        exists: Bool = true
    ) -> DocumentSaving.Verdict {
        DocumentSaving.verdict(
            recordedModification: recorded, recordedSize: recordedSize,
            currentModification: current, currentSize: currentSize,
            fileExists: exists)
    }

    func testUntouchedFileIsSafeToWrite() {
        XCTAssertEqual(verdict(recorded: then, recordedSize: 100,
                               current: then, currentSize: 100), .safe)
    }

    func testARewriteIsDetected() {
        // Same size, later timestamp — an agent rewriting a report to the same
        // length is entirely ordinary.
        XCTAssertEqual(verdict(recorded: then, recordedSize: 100,
                               current: then.addingTimeInterval(60), currentSize: 100),
                       .changedOnDisk)

        // Same timestamp, different size — a filesystem with coarse timestamps
        // must not be able to hide a rewrite.
        XCTAssertEqual(verdict(recorded: then, recordedSize: 100,
                               current: then, currentSize: 240),
                       .changedOnDisk)
    }

    /// Not knowing must fail toward asking, never toward overwriting.
    func testUnknownFingerprintIsTreatedAsChanged() {
        XCTAssertEqual(verdict(recorded: nil, recordedSize: 100,
                               current: then, currentSize: 100), .changedOnDisk)
        XCTAssertEqual(verdict(recorded: then, recordedSize: 100,
                               current: nil, currentSize: nil), .changedOnDisk)
        XCTAssertEqual(verdict(recorded: then, recordedSize: nil,
                               current: then, currentSize: 100), .changedOnDisk)
    }

    func testMissingFileIsItsOwnAnswer() {
        XCTAssertEqual(verdict(recorded: then, recordedSize: 100,
                               current: then, currentSize: 100, exists: false),
                       .missing)
        // Missing wins over everything else — recreating a deleted file is a
        // decision, not a side effect of saving.
        XCTAssertEqual(verdict(recorded: nil, recordedSize: nil,
                               current: nil, currentSize: nil, exists: false),
                       .missing)
    }

    /// Some filesystems store whole seconds only, so a sub-second difference is
    /// noise rather than evidence of a rewrite — and treating it as a conflict
    /// would make every save prompt.
    func testSubSecondJitterIsNotARewrite() {
        XCTAssertEqual(verdict(recorded: then, recordedSize: 100,
                               current: then.addingTimeInterval(0.4), currentSize: 100),
                       .safe)
        XCTAssertEqual(verdict(recorded: then, recordedSize: 100,
                               current: then.addingTimeInterval(1.6), currentSize: 100),
                       .changedOnDisk)
    }

    // MARK: - Against a real file

    func testFingerprintTracksARealRewrite() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentia-save-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }

        try "# One\n".write(to: url, atomically: true, encoding: .utf8)
        let first = DocumentSaving.fingerprint(of: url)
        XCTAssertTrue(first.exists)

        XCTAssertEqual(verdict(recorded: first.modified, recordedSize: first.size,
                               current: first.modified, currentSize: first.size),
                       .safe)

        // Rewrite it the way an agent would, and confirm the change is seen.
        Thread.sleep(forTimeInterval: 1.1)
        try "# One\n\nA whole new paragraph.\n".write(to: url, atomically: true,
                                                      encoding: .utf8)
        let second = DocumentSaving.fingerprint(of: url)

        XCTAssertEqual(verdict(recorded: first.modified, recordedSize: first.size,
                               current: second.modified, currentSize: second.size),
                       .changedOnDisk)
    }

    func testFingerprintOfAMissingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentia-not-here-\(UUID().uuidString).md")
        XCTAssertFalse(DocumentSaving.fingerprint(of: url).exists)
    }

    /// A snapshot records what it read, so the save can compare against it.
    func testSnapshotCapturesTheFingerprintItRead() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentia-snap-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        try "# Report\n".write(to: url, atomically: true, encoding: .utf8)

        let snapshot = try DocumentRenderer.read(contentsOf: url)
        XCTAssertNotNil(snapshot.modifiedOnDisk)
        XCTAssertEqual(snapshot.sizeOnDisk, "# Report\n".utf8.count)

        let now = DocumentSaving.fingerprint(of: url)
        XCTAssertEqual(verdict(recorded: snapshot.modifiedOnDisk,
                               recordedSize: snapshot.sizeOnDisk,
                               current: now.modified, currentSize: now.size),
                       .safe, "a file nobody touched must be safe to save")
    }
}
