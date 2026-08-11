import XCTest
@testable import AgentiaCore

final class FolderScannerTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentia-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func write(_ name: String, modified: Date? = nil) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try "content".write(to: url, atomically: true, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified],
                                                  ofItemAtPath: url.path)
        }
        return url
    }

    func testListsMarkdownAndHTMLOnly() throws {
        try write("report.md")
        try write("dashboard.html")
        try write("notes.txt")
        try write("data.json")
        try write("image.png")

        let names = FolderScanner.documents(in: directory).map(\.lastPathComponent)
        XCTAssertEqual(Set(names), ["report.md", "dashboard.html"],
                       "txt, json and binaries are the litter of a working directory")
    }

    func testNewestFirst() throws {
        let now = Date()
        try write("old.md", modified: now.addingTimeInterval(-3600))
        try write("newest.md", modified: now)
        try write("middle.md", modified: now.addingTimeInterval(-60))

        XCTAssertEqual(FolderScanner.documents(in: directory).map(\.lastPathComponent),
                       ["newest.md", "middle.md", "old.md"],
                       "the file just written is the one being looked for")
    }

    /// Two files written in the same second must not swap places between
    /// reveals — a list that reorders itself when nothing changed is worse
    /// than one in the wrong order.
    func testOrderIsStableForIdenticalTimestamps() throws {
        let stamp = Date()
        try write("b.md", modified: stamp)
        try write("a.md", modified: stamp)
        try write("c.md", modified: stamp)

        let first = FolderScanner.documents(in: directory).map(\.lastPathComponent)
        XCTAssertEqual(first, ["a.md", "b.md", "c.md"])
        XCTAssertEqual(FolderScanner.documents(in: directory).map(\.lastPathComponent),
                       first, "repeated scans agree")
    }

    func testHiddenFilesAreSkipped() throws {
        try write("visible.md")
        try write(".hidden.md")
        XCTAssertEqual(FolderScanner.documents(in: directory).map(\.lastPathComponent),
                       ["visible.md"])
    }

    func testSubdirectoriesAreNotDescendedInto() throws {
        try write("top.md")
        let nested = directory.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "x".write(to: nested.appendingPathComponent("deep.md"),
                      atomically: true, encoding: .utf8)

        XCTAssertEqual(FolderScanner.documents(in: directory).map(\.lastPathComponent),
                       ["top.md"])
    }

    func testEntryCountIsCapped() throws {
        for i in 0..<(FolderScanner.maximumEntries + 25) {
            try write(String(format: "f%04d.md", i))
        }
        XCTAssertEqual(FolderScanner.documents(in: directory).count,
                       FolderScanner.maximumEntries)
    }

    func testUnreadableDirectoryYieldsNothingRatherThanThrowing() {
        let missing = directory.appendingPathComponent("does-not-exist")
        XCTAssertEqual(FolderScanner.documents(in: missing), [])
    }

    func testEmptyDirectory() {
        XCTAssertEqual(FolderScanner.documents(in: directory), [])
    }

    func testAllMarkdownExtensionsAreRecognised() throws {
        for ext in ["md", "markdown", "mdown", "mkd", "qmd"] {
            try write("doc.\(ext)")
        }
        try write("page.htm")
        XCTAssertEqual(FolderScanner.documents(in: directory).count, 6)
    }
}
