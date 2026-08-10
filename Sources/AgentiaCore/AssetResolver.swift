import Foundation

/// Resolves `artifact://` asset requests to files on disk, refusing anything
/// that would escape the document's own folder.
///
/// This is the only part of the app that turns a string chosen by an untrusted
/// document into a filesystem read, so it is deliberately strict: resolve
/// symlinks on both sides, compare by path component, and default to refusing.
public struct AssetResolver: Sendable {

    public enum Failure: Swift.Error, Equatable {
        /// The path escaped the document directory, or tried to.
        case outsideRoot(String)
        /// Absolute paths are never accepted from a document.
        case absolutePath(String)
        /// Percent-decoding failed, or the path was empty.
        case malformed(String)
        /// Resolved inside the root but nothing is there.
        case notFound(String)
        /// Resolved to something that is not a regular file.
        case notAFile(String)
    }

    /// The directory a document may read from: the folder containing it.
    public let root: URL

    public init(root: URL) {
        // Resolving once up front means every later comparison is between two
        // fully resolved paths, which is what makes the containment check sound
        // on a machine where /tmp is a symlink to /private/tmp.
        self.root = URL(fileURLWithPath: root.path).resolvingSymlinksInPath()
    }

    /// Resolve a relative reference from a document to a readable file.
    ///
    /// - Parameter reference: the path as it appeared in the document, possibly
    ///   percent-encoded and possibly hostile.
    public func resolve(_ reference: String) throws -> URL {
        guard !reference.isEmpty else { throw Failure.malformed(reference) }

        // Strip any query or fragment: "diagram.png?v=2#top" is a request for
        // diagram.png.
        var path = reference
        if let hash = path.firstIndex(of: "#") { path = String(path[path.startIndex..<hash]) }
        if let query = path.firstIndex(of: "?") { path = String(path[path.startIndex..<query]) }

        guard let decoded = path.removingPercentEncoding else {
            throw Failure.malformed(reference)
        }
        guard !decoded.isEmpty else { throw Failure.malformed(reference) }

        // A NUL byte can truncate the path inside a C API further down.
        guard !decoded.contains("\0") else { throw Failure.malformed(reference) }

        guard !decoded.hasPrefix("/") else { throw Failure.absolutePath(reference) }
        // "~/secrets" must not expand.
        guard !decoded.hasPrefix("~") else { throw Failure.outsideRoot(reference) }

        // Reject traversal before touching the filesystem, so a probe cannot be
        // used to test for the existence of files outside the root.
        let rawComponents = decoded.split(separator: "/", omittingEmptySubsequences: true)
        guard !rawComponents.isEmpty else { throw Failure.malformed(reference) }
        for component in rawComponents where component == ".." {
            throw Failure.outsideRoot(reference)
        }

        // "./diagram.png" is a normal relative reference; drop the no-op
        // components rather than appending them and relying on later
        // standardisation to undo it.
        let components = rawComponents.filter { $0 != "." }
        guard !components.isEmpty else { throw Failure.malformed(reference) }

        let candidate = components.reduce(root) { partial, component in
            partial.appendingPathComponent(String(component))
        }

        // Resolve symlinks and re-check containment: a symlink inside the
        // folder can still point outside it.
        let resolved = candidate.resolvingSymlinksInPath()
        guard Self.isContained(resolved, in: root) else {
            throw Failure.outsideRoot(reference)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path,
                                             isDirectory: &isDirectory) else {
            throw Failure.notFound(reference)
        }
        guard !isDirectory.boolValue else { throw Failure.notAFile(reference) }

        return resolved
    }

    /// Containment by path component, not by string prefix.
    ///
    /// A prefix test would accept `/tmp/docs-evil` as being inside `/tmp/docs`.
    static func isContained(_ url: URL, in root: URL) -> Bool {
        let rootParts = root.standardized.pathComponents
        let urlParts = url.standardized.pathComponents
        guard urlParts.count >= rootParts.count else { return false }
        return Array(urlParts.prefix(rootParts.count)) == rootParts
    }

    /// A conservative content type for a resolved asset, for the scheme
    /// handler's response. Unknown types are served as binary rather than
    /// guessed, so an unexpected file cannot be coerced into being treated as
    /// markup.
    public static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png":            return "image/png"
        case "jpg", "jpeg":    return "image/jpeg"
        case "gif":            return "image/gif"
        case "webp":           return "image/webp"
        case "avif":           return "image/avif"
        case "svg":            return "image/svg+xml"
        case "bmp":            return "image/bmp"
        case "ico":            return "image/vnd.microsoft.icon"
        case "woff":           return "font/woff"
        case "woff2":          return "font/woff2"
        case "ttf":            return "font/ttf"
        case "otf":            return "font/otf"
        case "css":            return "text/css; charset=utf-8"
        case "mp4":            return "video/mp4"
        case "webm":           return "video/webm"
        case "mp3":            return "audio/mpeg"
        case "wav":            return "audio/wav"
        default:               return "application/octet-stream"
        }
    }
}
