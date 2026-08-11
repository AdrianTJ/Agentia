import Foundation

/// Lists the documents sitting beside the one being read.
///
/// Agents do not write one file, they write a run: a report, a summary, a diff,
/// an HTML dashboard, all into the same directory. Navigating that directory is
/// the movement this app is for, and it is why the sidebar shows the folder
/// rather than a history of what has been opened — the history is a list of
/// things already seen, which is the less useful half.
///
/// Sorted newest first, because the thing just written is the thing being
/// looked for.
public enum FolderScanner {

    /// Hard cap on entries.
    ///
    /// A sidebar is a navigation aid, not a file browser, and a directory with
    /// ten thousand files should not cost ten thousand stat calls on every
    /// reveal. Past this the list is truncated rather than paged: someone
    /// working in a directory that large is not finding their file by scrolling.
    public static let maximumEntries = 200

    /// Readable documents in `directory`, newest first.
    ///
    /// Plain text is excluded even though the app will open it: `.txt`, `.log`
    /// and `.json` are the ambient litter of a working directory, and including
    /// them buries the two or three files worth reading.
    public static func documents(in directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        let readable = entries.filter { url in
            switch DocumentKind.forURL(url) {
            case .markdown, .html: return true
            case .plainText: return false
            }
        }

        // One stat per candidate, after filtering rather than before, so a
        // directory full of images costs nothing extra.
        let dated = readable.map { url -> (url: URL, modified: Date) in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            return (url, values?.contentModificationDate ?? .distantPast)
        }

        return dated
            .sorted {
                // Name as the tie-break so the order is stable: two files
                // written in the same second must not swap places between
                // reveals.
                $0.modified == $1.modified
                    ? $0.url.lastPathComponent < $1.url.lastPathComponent
                    : $0.modified > $1.modified
            }
            .prefix(maximumEntries)
            .map(\.url)
    }
}
