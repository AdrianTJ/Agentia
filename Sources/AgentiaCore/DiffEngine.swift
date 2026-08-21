import Foundation

/// A run of source lines that changed between two versions of a document.
///
/// Line numbers are 1-based and refer to the **new** text, because that is what
/// cmark's `data-sourcepos` attributes index and therefore what the shell
/// script needs in order to decorate rendered blocks.
public struct DiffRange: Sendable, Equatable, Codable {

    public enum Kind: String, Sendable, Codable {
        /// New lines with nothing corresponding in the old text.
        case added
        /// New lines that replaced old ones.
        case modified
    }

    public let start: Int
    public let end: Int
    public let kind: Kind

    public init(start: Int, end: Int, kind: Kind) {
        self.start = start
        self.end = end
        self.kind = kind
    }
}

/// Line-level diff between two revisions of a document.
///
/// Agent artifacts are usually rewritten wholesale but change in a few places,
/// so the interesting output is "which blocks are new or different", not a
/// character-level patch.
public enum DiffEngine {

    /// Above this many differing lines on either side, the quadratic stage is
    /// skipped and the whole differing region is reported as modified. Keeps a
    /// pathological rewrite from stalling the render.
    public static let quadraticLimit = 2_000

    /// Compare two documents and return the changed ranges in `new`.
    public static func changes(from old: String, to new: String) -> [DiffRange] {
        changes(from: lines(of: old), to: lines(of: new))
    }

    /// Split on newlines the way a line diff expects.
    ///
    /// `\r\n` is normalised so a file rewritten with different line endings
    /// does not report as entirely changed. A trailing newline does not create
    /// a final empty line.
    static func lines(of text: String) -> [String] {
        if text.isEmpty { return [] }
        var normalised = text.replacingOccurrences(of: "\r\n", with: "\n")
        normalised = normalised.replacingOccurrences(of: "\r", with: "\n")
        if normalised.hasSuffix("\n") { normalised.removeLast() }
        return normalised.components(separatedBy: "\n")
    }

    static func changes(from old: [String], to new: [String]) -> [DiffRange] {
        if old.isEmpty && new.isEmpty { return [] }
        // A brand-new document is not a diff worth showing; treating every line
        // as "added" would tint the entire page on first open.
        if old.isEmpty { return [] }
        if new.isEmpty { return [] }

        // Trim the matching head and tail. This alone resolves the common case
        // of an agent appending or rewriting one section, and it keeps the
        // quadratic stage small.
        var head = 0
        let maxHead = min(old.count, new.count)
        while head < maxHead && old[head] == new[head] { head += 1 }

        var tail = 0
        while tail < (maxHead - head)
            && old[old.count - 1 - tail] == new[new.count - 1 - tail] {
            tail += 1
        }

        let oldMiddle = Array(old[head..<(old.count - tail)])
        let newMiddle = Array(new[head..<(new.count - tail)])

        if oldMiddle.isEmpty && newMiddle.isEmpty { return [] }

        // Pure insertion: nothing was replaced, so the new lines are additions.
        if oldMiddle.isEmpty {
            return [DiffRange(start: head + 1, end: head + newMiddle.count, kind: .added)]
        }
        // Pure deletion: there is nothing in the new text to decorate.
        if newMiddle.isEmpty { return [] }

        if oldMiddle.count > quadraticLimit || newMiddle.count > quadraticLimit {
            return [DiffRange(start: head + 1,
                              end: head + newMiddle.count,
                              kind: .modified)]
        }

        let script = editScript(oldMiddle, newMiddle)
        return coalesce(script, offset: head)
    }

    // MARK: - Longest common subsequence

    private enum Edit {
        case keep
        case insert  // present only in new
        case delete  // present only in old
    }

    /// Classic LCS table walk. Bounded by `quadraticLimit` at the call site.
    private static func editScript(_ old: [String], _ new: [String]) -> [Edit] {
        let n = old.count
        let m = new.count

        // table[i * stride + j] = LCS length of old[i...] and new[j...].
        // Flat rather than nested: at the 2000-line limit an array of arrays is
        // ~32 MB spread over 2001 separate heap buffers, and every access pays
        // a second bounds check and a retain.
        let rowStride = m + 1
        var table = [Int](repeating: 0, count: (n + 1) * rowStride)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                let row = i * rowStride
                let nextRow = row + rowStride
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[row + j] = old[i] == new[j]
                        ? table[nextRow + j + 1] + 1
                        : max(table[nextRow + j], table[row + j + 1])
                }
            }
        }

        var script: [Edit] = []
        var i = 0, j = 0
        while i < n && j < m {
            if old[i] == new[j] {
                script.append(.keep); i += 1; j += 1
            } else if table[(i + 1) * rowStride + j] >= table[i * rowStride + j + 1] {
                script.append(.delete); i += 1
            } else {
                script.append(.insert); j += 1
            }
        }
        while i < n { script.append(.delete); i += 1 }
        while j < m { script.append(.insert); j += 1 }
        return script
    }

    /// Turn the edit script into ranges over the new text.
    ///
    /// An insertion run that sits next to a deletion run is a replacement and
    /// reports as `.modified`; an insertion with no deletion beside it is
    /// `.added`. Deletion-only runs produce nothing, since there is no new text
    /// to decorate.
    private static func coalesce(_ script: [Edit], offset: Int) -> [DiffRange] {
        var ranges: [DiffRange] = []
        var newLine = offset          // 0-based index into the new document
        var runStart: Int? = nil      // 0-based start of the current insert run
        var runHadDeletion = false
        var pendingDeletion = false

        func closeRun() {
            guard let start = runStart else { return }
            ranges.append(DiffRange(start: start + 1,
                                    end: newLine,
                                    kind: runHadDeletion ? .modified : .added))
            runStart = nil
            runHadDeletion = false
        }

        for edit in script {
            switch edit {
            case .keep:
                closeRun()
                pendingDeletion = false
                newLine += 1

            case .insert:
                if runStart == nil {
                    runStart = newLine
                    // A deletion immediately before this run makes it a
                    // replacement rather than a pure addition.
                    runHadDeletion = pendingDeletion
                }
                pendingDeletion = false
                newLine += 1

            case .delete:
                // A deletion inside an open insert run also makes it a
                // replacement.
                if runStart != nil { runHadDeletion = true }
                pendingDeletion = true
            }
        }
        closeRun()

        return ranges
    }
}
