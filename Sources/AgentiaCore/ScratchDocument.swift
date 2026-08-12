import Foundation

/// The document the app opens when it is launched with nothing to show.
///
/// Opening with no file used to mean "Open a Markdown or HTML file to begin" —
/// accurate and useless. Launching the app is often the moment you want to
/// write something down, and the app can already edit, so it opens a scratch
/// document instead and puts the caret in it.
///
/// ## Why a real file rather than an untitled buffer
///
/// Every part of the save path — conflict detection, encoding preservation, the
/// file watcher, the diff baseline, Reveal in Finder — is built on a document
/// having a URL. An untitled buffer would need all of that to handle "no URL
/// yet" plus a Save As panel, which is a lot of new behaviour in the exact code
/// a dogfooding round just found data-loss bugs in.
///
/// A real file also matches what a scratchpad is for: notes survive relaunches,
/// and because it is an ordinary file, Reveal in Finder and Open With work on
/// it like any other document.
public enum ScratchDocument {

    public static let fileName = "Scratch.md"

    /// `~/Library/Application Support/Agentia/Scratch.md`.
    ///
    /// Application Support rather than Documents: this is a file the app
    /// created and manages, and dropping it into someone's Documents folder
    /// uninvited is the kind of thing that makes people distrust an app. It is
    /// still an ordinary file, and Reveal in Finder will show it.
    public static func url(inSupportDirectory directory: URL? = nil) -> URL? {
        let base: URL?
        if let directory {
            base = directory
        } else {
            base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil,
                                                create: true)
        }
        return base?
            .appendingPathComponent("Agentia", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// Create the file if it is not there, and return it ready to open.
    ///
    /// Existing content is never touched: this runs on every launch that has no
    /// document, and a scratchpad that empties itself when you reopen the app
    /// is not a scratchpad.
    @discardableResult
    public static func ensure(at url: URL) throws -> URL {
        let folder = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder,
                                                    withIntermediateDirectories: true)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            // Genuinely empty. Boilerplate in a scratch file is something to
            // delete before you can start, and the reader is here to type.
            try Data().write(to: url)
        }
        return url
    }
}
