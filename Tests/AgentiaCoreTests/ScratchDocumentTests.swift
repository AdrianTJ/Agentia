import XCTest
@testable import AgentiaCore

/// The document the app opens when launched with nothing to show.
final class ScratchDocumentTests: XCTestCase {

    private var support: URL!

    override func setUpWithError() throws {
        support = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentia-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: support)
    }

    func testLivesUnderTheAppsOwnFolder() throws {
        let url = try XCTUnwrap(ScratchDocument.url(inSupportDirectory: support))
        XCTAssertEqual(url.lastPathComponent, "Scratch.md")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Agentia",
                       "kept in the app's own folder, not loose in Application Support")
    }

    /// The real one has to resolve, or launching with no file falls back to the
    /// old "open a file to begin" message.
    func testResolvesWithoutAnExplicitDirectory() {
        XCTAssertNotNil(ScratchDocument.url())
    }

    func testCreatesTheFileAndItsFolder() throws {
        let url = try XCTUnwrap(ScratchDocument.url(inSupportDirectory: support))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        try ScratchDocument.ensure(at: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: url), Data(),
                       "a scratch file starts empty — boilerplate is just "
                       + "something to delete before you can type")
    }

    /// This runs on every launch that has no document. A scratchpad that
    /// empties itself when you reopen the app is not a scratchpad.
    func testExistingNotesAreNeverOverwritten() throws {
        let url = try XCTUnwrap(ScratchDocument.url(inSupportDirectory: support))
        try ScratchDocument.ensure(at: url)
        try "# Notes\n\nsomething I wrote\n".write(to: url, atomically: true,
                                                   encoding: .utf8)

        for _ in 0..<3 { try ScratchDocument.ensure(at: url) }

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8),
                       "# Notes\n\nsomething I wrote\n")
    }

    /// It is an ordinary Markdown document, so everything else in the app —
    /// rendering, saving, the outline, Reveal in Finder — works on it unchanged.
    func testItIsJustAMarkdownDocument() throws {
        let url = try XCTUnwrap(ScratchDocument.url(inSupportDirectory: support))
        try ScratchDocument.ensure(at: url)
        try "# Jot\n".write(to: url, atomically: true, encoding: .utf8)

        let snapshot = try DocumentRenderer.read(contentsOf: url)
        XCTAssertEqual(snapshot.kind, .markdown)
        XCTAssertEqual(snapshot.source, "# Jot\n")
        XCTAssertEqual(snapshot.bytesOnDisk, Data("# Jot\n".utf8),
                       "it saves through the same conflict-checked path")
    }

    func testEnsureIsSafeOnAnEmptyExistingFile() throws {
        let url = try XCTUnwrap(ScratchDocument.url(inSupportDirectory: support))
        try ScratchDocument.ensure(at: url)
        try ScratchDocument.ensure(at: url)
        XCTAssertEqual(try Data(contentsOf: url), Data())
    }
}
