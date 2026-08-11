import Foundation

/// Deciding whether it is safe to write a document back to disk.
///
/// The hazard is specific to what this app is for. Agentia opens files that an
/// agent is actively rewriting, and it watches them so a new run appears
/// immediately. The moment the reader can edit, those two meet: the buffer on
/// screen and the bytes on disk can both move, independently, between the read
/// and the save.
///
/// Nothing here writes anything. It answers one question — is the file still
/// the one we read? — so the answer can be tested without a filesystem.
public enum DocumentSaving {

    public enum Verdict: Equatable, Sendable {
        /// The file is untouched since it was read. Writing is safe.
        case safe
        /// Something rewrote it after we read it. Writing would discard that.
        case changedOnDisk
        /// The file is gone. Writing recreates it, which is a decision the
        /// reader should make rather than a thing that silently happens.
        case missing
    }

    /// Is the file still the one we read?
    ///
    /// Compares the *bytes* on disk against the bytes the document was read
    /// from, rather than a modification date and size.
    ///
    /// The metadata version had a real hole: dates were compared at whole-second
    /// resolution, because some filesystems store only that. So a rewrite
    /// landing in the same second as the read, producing content of the same
    /// length, was indistinguishable from no rewrite at all and got silently
    /// overwritten — and an agent rewriting its report in a tight loop is
    /// exactly how that happens. Comparing content has no such window: it is
    /// the actual question, asked directly.
    ///
    /// The cost is reading the file once per save. It was already read once to
    /// open it, and these are documents a person is reading.
    ///
    /// Unreadable bytes count as changed: not knowing must fail toward asking,
    /// never toward overwriting.
    public static func verdict(recordedBytes: Data?, currentBytes: Data?, fileExists: Bool) -> Verdict {
        guard fileExists else { return .missing }
        guard let recordedBytes, let currentBytes else { return .changedOnDisk }
        return recordedBytes == currentBytes ? .safe : .changedOnDisk
    }

    /// The bytes on disk right now, and whether the file is there at all.
    ///
    /// Reads through a freshly constructed URL. `URL` caches resource values,
    /// and the metadata version of this check was defeated by exactly that: a
    /// file rewritten between the read and the save reported its old date and
    /// size, so the verdict came back `.safe` and the agent's work was
    /// overwritten silently. Content is read directly and cannot go stale, but
    /// the fresh URL is kept so nothing here depends on cache behaviour.
    public static func currentBytes(of url: URL) -> (bytes: Data?, exists: Bool) {
        let fresh = URL(fileURLWithPath: url.path)
        let exists = FileManager.default.fileExists(atPath: fresh.path)
        return (try? Data(contentsOf: fresh), exists)
    }
}
