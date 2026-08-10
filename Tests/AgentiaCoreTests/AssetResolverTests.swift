import XCTest
@testable import AgentiaCore

/// The resolver is the only place a string from an untrusted document becomes a
/// filesystem read, so these tests lean heavily on the refusal cases.
final class AssetResolverTests: XCTestCase {

    private var root: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentia-assets-\(UUID().uuidString)")

        root = base.appendingPathComponent("docs")
        outside = base.appendingPathComponent("private")

        try FileManager.default.createDirectory(at: root.appendingPathComponent("img"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside,
                                                withIntermediateDirectories: true)

        try "png".write(to: root.appendingPathComponent("img/diagram.png"),
                        atomically: true, encoding: .utf8)
        try "top".write(to: root.appendingPathComponent("cover.png"),
                        atomically: true, encoding: .utf8)
        try "with space".write(to: root.appendingPathComponent("my file.png"),
                               atomically: true, encoding: .utf8)
        try "secret".write(to: outside.appendingPathComponent("secrets.txt"),
                           atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        let base = root.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: base)
    }

    private var resolver: AssetResolver { AssetResolver(root: root) }

    // MARK: - Accepts

    func testResolvesFileInRoot() throws {
        let url = try resolver.resolve("cover.png")
        XCTAssertEqual(url.lastPathComponent, "cover.png")
    }

    func testResolvesNestedFile() throws {
        let url = try resolver.resolve("img/diagram.png")
        XCTAssertEqual(url.lastPathComponent, "diagram.png")
    }

    func testResolvesPercentEncodedName() throws {
        let url = try resolver.resolve("my%20file.png")
        XCTAssertEqual(url.lastPathComponent, "my file.png")
    }

    func testIgnoresQueryAndFragment() throws {
        XCTAssertEqual(try resolver.resolve("cover.png?v=2").lastPathComponent, "cover.png")
        XCTAssertEqual(try resolver.resolve("cover.png#top").lastPathComponent, "cover.png")
        XCTAssertEqual(try resolver.resolve("cover.png?v=2#top").lastPathComponent, "cover.png")
    }

    func testLeadingDotSlashIsAccepted() throws {
        XCTAssertEqual(try resolver.resolve("./cover.png").lastPathComponent, "cover.png")
    }

    // MARK: - Refuses

    func testRejectsParentTraversal() {
        for attempt in ["../private/secrets.txt",
                        "img/../../private/secrets.txt",
                        "..",
                        "../",
                        "a/../../b"] {
            XCTAssertThrowsError(try resolver.resolve(attempt), "should reject \(attempt)") {
                XCTAssertEqual($0 as? AssetResolver.Failure,
                               .outsideRoot(attempt), "for \(attempt)")
            }
        }
    }

    func testRejectsEncodedParentTraversal() {
        // %2e%2e decodes to "..", so the check must run after decoding.
        for attempt in ["%2e%2e/private/secrets.txt", "img/%2E%2E/%2E%2E/private/secrets.txt"] {
            XCTAssertThrowsError(try resolver.resolve(attempt), "should reject \(attempt)")
        }
    }

    func testRejectsAbsolutePaths() {
        XCTAssertThrowsError(try resolver.resolve("/etc/passwd")) {
            XCTAssertEqual($0 as? AssetResolver.Failure, .absolutePath("/etc/passwd"))
        }
    }

    func testRejectsTildeExpansion() {
        XCTAssertThrowsError(try resolver.resolve("~/.ssh/id_rsa")) {
            XCTAssertEqual($0 as? AssetResolver.Failure, .outsideRoot("~/.ssh/id_rsa"))
        }
    }

    func testRejectsEmptyAndMalformed() {
        XCTAssertThrowsError(try resolver.resolve(""))
        XCTAssertThrowsError(try resolver.resolve("?onlyquery"))
        XCTAssertThrowsError(try resolver.resolve("#onlyfragment"))
        XCTAssertThrowsError(try resolver.resolve("bad\0name.png"))
    }

    func testRejectsMissingFile() {
        XCTAssertThrowsError(try resolver.resolve("nope.png")) {
            XCTAssertEqual($0 as? AssetResolver.Failure, .notFound("nope.png"))
        }
    }

    func testRejectsDirectory() {
        XCTAssertThrowsError(try resolver.resolve("img")) {
            XCTAssertEqual($0 as? AssetResolver.Failure, .notAFile("img"))
        }
    }

    func testRejectsSymlinkEscapingRoot() throws {
        // A symlink inside the folder can still point outside it, which is why
        // containment is re-checked after resolution.
        let link = root.appendingPathComponent("escape.txt")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: outside.appendingPathComponent("secrets.txt")
        )

        XCTAssertThrowsError(try resolver.resolve("escape.txt")) {
            XCTAssertEqual($0 as? AssetResolver.Failure, .outsideRoot("escape.txt"))
        }
    }

    func testAllowsSymlinkStayingInsideRoot() throws {
        let link = root.appendingPathComponent("alias.png")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: root.appendingPathComponent("cover.png")
        )
        XCTAssertEqual(try resolver.resolve("alias.png").lastPathComponent, "cover.png")
    }

    // MARK: - Containment helper

    func testContainmentComparesPathComponentsNotPrefixes() {
        let base = URL(fileURLWithPath: "/tmp/docs")

        XCTAssertTrue(AssetResolver.isContained(URL(fileURLWithPath: "/tmp/docs/a.png"), in: base))
        XCTAssertTrue(AssetResolver.isContained(base, in: base))
        // The case a naive string-prefix check gets wrong.
        XCTAssertFalse(AssetResolver.isContained(URL(fileURLWithPath: "/tmp/docs-evil/a.png"),
                                                 in: base))
        XCTAssertFalse(AssetResolver.isContained(URL(fileURLWithPath: "/tmp"), in: base))
    }

    // MARK: - MIME types

    func testMIMETypes() {
        XCTAssertEqual(AssetResolver.mimeType(for: URL(fileURLWithPath: "a.png")), "image/png")
        XCTAssertEqual(AssetResolver.mimeType(for: URL(fileURLWithPath: "a.SVG")),
                       "image/svg+xml")
        XCTAssertEqual(AssetResolver.mimeType(for: URL(fileURLWithPath: "a.woff2")), "font/woff2")
        // Unknown types are served as binary rather than guessed, so an
        // unexpected file cannot be coerced into being treated as markup.
        XCTAssertEqual(AssetResolver.mimeType(for: URL(fileURLWithPath: "a.exe")),
                       "application/octet-stream")
        XCTAssertEqual(AssetResolver.mimeType(for: URL(fileURLWithPath: "noext")),
                       "application/octet-stream")
    }
}
