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

    /// Compare what we recorded at read time against what is on disk now.
    ///
    /// Modification date and size together, not a content hash: hashing a file
    /// on every save costs the whole file, and this check runs on the main
    /// thread in front of the reader. The pair catches every case that matters
    /// here — an agent rewriting a report changes both, and a same-size,
    /// same-second rewrite is not a scenario worth making saves slower for.
    ///
    /// A missing modification date is treated as `changedOnDisk` rather than
    /// `safe`: not knowing must fail toward asking, never toward overwriting.
    public static func verdict(
        recordedModification: Date?,
        recordedSize: Int?,
        currentModification: Date?,
        currentSize: Int?,
        fileExists: Bool
    ) -> Verdict {
        guard fileExists else { return .missing }

        guard let recordedModification, let currentModification,
              let recordedSize, let currentSize else {
            return .changedOnDisk
        }

        // Compared at whole-second resolution: some filesystems store only
        // that, so a sub-second difference is noise rather than a rewrite.
        let sameTime = Int(recordedModification.timeIntervalSince1970)
            == Int(currentModification.timeIntervalSince1970)
        return sameTime && recordedSize == currentSize ? .safe : .changedOnDisk
    }

    /// What the file looks like right now, for the comparison above.
    ///
    /// Deliberately stats a *freshly constructed* URL. `URL` caches resource
    /// values, and asking the same instance twice returns what it saw the first
    /// time — so a file rewritten between the read and the save reported its
    /// old date and size, and the verdict came back `.safe`. That is the one
    /// direction this must never fail in: it would have silently overwritten
    /// the agent's work. Caught by a test that rewrote a real file on disk;
    /// every in-memory case passed happily.
    public static func fingerprint(of url: URL) -> (modified: Date?, size: Int?, exists: Bool) {
        let uncached = URL(fileURLWithPath: url.path)
        let values = try? uncached.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey])
        let exists = FileManager.default.fileExists(atPath: uncached.path)
        return (values?.contentModificationDate, values?.fileSize, exists)
    }
}
