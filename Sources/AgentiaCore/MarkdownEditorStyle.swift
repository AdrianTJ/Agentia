import Foundation

/// Where the styling goes when Markdown is being *edited* rather than read.
///
/// The editor used to be plain monospace text, which made it the one part of
/// the app you would rather do somewhere else. This is the alternative to
/// editing the rendered HTML: the reader still types Markdown, and the file
/// written back is byte-for-byte what they typed, but headings look like
/// headings and `**bold**` is actually bold.
///
/// That distinction is the whole reason for this approach. Editing rendered
/// HTML means converting it back to Markdown on every save, and that conversion
/// rewrites the *entire* document — list markers, heading style, line wrapping —
/// not just the part that was touched. In an app whose premise is showing what
/// an agent changed, a save that reformats every line makes the diff useless.
/// Nothing here touches the text at all; it only says which ranges are what.
///
/// ## Not a parser
///
/// This does not have to agree with cmark on every edge case, and it must never
/// be asked to. It runs on each keystroke, on text that is usually mid-sentence
/// and frequently not valid Markdown yet. Being fast and stable while someone
/// types matters more than resolving an ambiguity they are still in the middle
/// of creating. The rendered view is the source of truth for what the document
/// *means*; this only decides what it looks like while being written.
///
/// Offsets are UTF-16 code units, because that is what `NSTextStorage` indexes
/// by. The scan runs over the UTF-16 units directly rather than over Characters:
/// every marker in Markdown is ASCII, and no ASCII value can appear as a unit of
/// a non-ASCII character, so the comparisons are safe and the offsets are exact
/// even in a document full of emoji.
public enum MarkdownEditorStyle {

    public enum Role: Equatable, Sendable {
        case heading(level: Int)
        case bold
        case italic
        case boldItalic
        case strikethrough
        case inlineCode
        case codeBlock
        case blockQuote
        case listMarker
        case link
        case thematicBreak
        /// The markers themselves — `##`, `**`, the backticks, the brackets of a
        /// link. Dimmed rather than hidden: hiding them makes the text jump
        /// around as the caret moves, and you cannot edit what you cannot see.
        case syntax
    }

    public struct Span: Equatable, Sendable {
        public let location: Int
        public let length: Int
        public let role: Role

        public init(location: Int, length: Int, role: Role) {
            self.location = location
            self.length = length
            self.role = role
        }
    }

    /// Above this, the document is left unstyled.
    ///
    /// Styling is recomputed on every keystroke, and a reader who opens a
    /// multi-megabyte log does not want each character to cost a full rescan.
    /// Plain text that keeps up beats pretty text that stutters.
    public static let maximumStyledUnits = 512_000

    /// The ranges to style, in application order.
    ///
    /// Later spans refine earlier ones rather than replacing them: the block
    /// role comes first, then inline emphasis, then `.syntax` last. A heading
    /// containing bold text needs both, so a caller applies these cumulatively —
    /// adding a bold trait to whatever font the heading already set — instead of
    /// overwriting. `.syntax` comes last so a marker always dims, whatever it
    /// sits inside.
    public static func spans(in text: String) -> [Span] {
        let units = Array(text.utf16)
        guard units.count <= maximumStyledUnits else { return [] }

        var scanner = Scanner(units: units)
        scanner.run()
        return scanner.blocks + scanner.inlines + scanner.syntax
    }
}

// MARK: - The scan

private let space = UInt16(UInt8(ascii: " "))
private let tab = UInt16(UInt8(ascii: "\t"))
private let newline = UInt16(UInt8(ascii: "\n"))
private let hash = UInt16(UInt8(ascii: "#"))
private let backtick = UInt16(UInt8(ascii: "`"))
private let tilde = UInt16(UInt8(ascii: "~"))
private let greater = UInt16(UInt8(ascii: ">"))
private let star = UInt16(UInt8(ascii: "*"))
private let underscore = UInt16(UInt8(ascii: "_"))
private let dash = UInt16(UInt8(ascii: "-"))
private let plus = UInt16(UInt8(ascii: "+"))
private let equals = UInt16(UInt8(ascii: "="))
private let openBracket = UInt16(UInt8(ascii: "["))
private let closeBracket = UInt16(UInt8(ascii: "]"))
private let openParen = UInt16(UInt8(ascii: "("))
private let closeParen = UInt16(UInt8(ascii: ")"))
private let bang = UInt16(UInt8(ascii: "!"))
private let period = UInt16(UInt8(ascii: "."))
private let zero = UInt16(UInt8(ascii: "0"))
private let nine = UInt16(UInt8(ascii: "9"))

private struct Scanner {

    let units: [UInt16]
    var blocks: [MarkdownEditorStyle.Span] = []
    var inlines: [MarkdownEditorStyle.Span] = []
    var syntax: [MarkdownEditorStyle.Span] = []

    init(units: [UInt16]) {
        self.units = units
    }

    private mutating func block(_ location: Int, _ length: Int, _ role: MarkdownEditorStyle.Role) {
        guard length > 0 else { return }
        blocks.append(.init(location: location, length: length, role: role))
    }

    private mutating func inline(_ location: Int, _ length: Int, _ role: MarkdownEditorStyle.Role) {
        guard length > 0 else { return }
        inlines.append(.init(location: location, length: length, role: role))
    }

    private mutating func marker(_ location: Int, _ length: Int) {
        guard length > 0 else { return }
        syntax.append(.init(location: location, length: length, role: .syntax))
    }

    // MARK: Lines

    /// Line ranges, computed up front so a paragraph can look at the line below
    /// it — which is what distinguishes a setext heading's underline from a
    /// thematic break.
    private func lineRanges() -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        var index = 0
        while index < units.count {
            if units[index] == newline {
                ranges.append(start..<index)
                start = index + 1
            }
            index += 1
        }
        ranges.append(start..<units.count)
        return ranges
    }

    mutating func run() {
        let lines = lineRanges()

        var openFence: (character: UInt16, length: Int)?
        var previousWasParagraph = false
        // Set when a line has already been consumed as the underline of the
        // paragraph above it.
        var skipNext = false

        for (index, line) in lines.enumerated() {
            // Cleared for every line up front, and set again only by the
            // paragraph branch at the bottom. Each branch used to reset it
            // before its own `continue`, which put the same statement in eight
            // places and made "remember to reset it" a precondition for adding
            // a ninth.
            //
            // Captured first because the current line still needs the previous
            // line's answer: an indented line only starts a code block when it
            // does not continue a paragraph.
            let afterParagraph = previousWasParagraph
            previousWasParagraph = false

            if skipNext {
                skipNext = false
                continue
            }

            let contentStart = indexAfterIndent(in: line)
            let indent = indentWidth(in: line)

            // Inside a fence, nothing is Markdown — that is what a fence is for.
            if let fence = openFence {
                block(line.lowerBound, line.count, .codeBlock)
                if closesFence(line: line, from: contentStart, fence: fence) {
                    marker(line.lowerBound, line.count)
                    openFence = nil
                }
                continue
            }

            if indent < 4, let fence = fenceOpening(line: line, from: contentStart) {
                marker(line.lowerBound, line.count)
                openFence = fence
                continue
            }

            // Blank.
            if contentStart == line.upperBound {
                continue
            }

            // An indented code block, but only where one can actually start: a
            // continuation line of a list is also indented, and styling it as
            // code would be wrong far more often than right.
            if indent >= 4, !afterParagraph {
                block(line.lowerBound, line.count, .codeBlock)
                continue
            }

            if indent < 4, isThematicBreak(line: line, from: contentStart) {
                block(line.lowerBound, line.count, .thematicBreak)
                marker(line.lowerBound, line.count)
                continue
            }

            if indent < 4, let level = atxHeading(line: line, from: contentStart) {
                styleATXHeading(line: line, from: contentStart, level: level)
                continue
            }

            // A paragraph underlined by === or --- is a setext heading. Checked
            // by looking ahead rather than back, so the heading's own inline
            // styling is emitted in the right order.
            if indent < 4,
               index + 1 < lines.count,
               let level = setextLevel(of: lines[index + 1]) {
                block(line.lowerBound, line.count, .heading(level: level))
                styleInline(in: contentStart..<line.upperBound)
                block(lines[index + 1].lowerBound, lines[index + 1].count,
                      .heading(level: level))
                marker(lines[index + 1].lowerBound, lines[index + 1].count)
                skipNext = true
                continue
            }

            var bodyStart = contentStart

            if indent < 4, units[contentStart] == greater {
                var end = contentStart
                while end < line.upperBound, units[end] == greater || units[end] == space {
                    end += 1
                }
                marker(contentStart, end - contentStart)
                block(line.lowerBound, line.count, .blockQuote)
                bodyStart = end
            } else if let markerEnd = listMarker(line: line, from: contentStart) {
                block(contentStart, markerEnd - contentStart, .listMarker)
                bodyStart = markerEnd
            }

            styleInline(in: bodyStart..<line.upperBound)
            previousWasParagraph = true
        }
    }

    // MARK: Line shapes

    private func indexAfterIndent(in line: Range<Int>) -> Int {
        var index = line.lowerBound
        while index < line.upperBound, units[index] == space || units[index] == tab {
            index += 1
        }
        return index
    }

    private func indentWidth(in line: Range<Int>) -> Int {
        var width = 0
        var index = line.lowerBound
        while index < line.upperBound, units[index] == space || units[index] == tab {
            width += units[index] == tab ? 4 : 1
            index += 1
        }
        return width
    }

    private func fenceOpening(line: Range<Int>, from start: Int) -> (character: UInt16, length: Int)? {
        guard start < line.upperBound else { return nil }
        let character = units[start]
        guard character == backtick || character == tilde else { return nil }

        var length = 0
        var index = start
        while index < line.upperBound, units[index] == character {
            length += 1
            index += 1
        }
        guard length >= 3 else { return nil }

        // A ``` fence's info string cannot itself contain a backtick, which is
        // what keeps `` `a` `` on a line of its own from opening one.
        if character == backtick {
            var rest = index
            while rest < line.upperBound {
                if units[rest] == backtick { return nil }
                rest += 1
            }
        }
        return (character, length)
    }

    private func closesFence(line: Range<Int>, from start: Int,
                             fence: (character: UInt16, length: Int)) -> Bool {
        var index = start
        var length = 0
        while index < line.upperBound, units[index] == fence.character {
            length += 1
            index += 1
        }
        guard length >= fence.length else { return false }
        // Only whitespace may follow a closing fence.
        while index < line.upperBound {
            guard units[index] == space || units[index] == tab else { return false }
            index += 1
        }
        return true
    }

    private func isThematicBreak(line: Range<Int>, from start: Int) -> Bool {
        guard start < line.upperBound else { return false }
        let character = units[start]
        guard character == dash || character == star || character == underscore else {
            return false
        }
        var count = 0
        var index = start
        while index < line.upperBound {
            let unit = units[index]
            if unit == character {
                count += 1
            } else if unit != space && unit != tab {
                return false
            }
            index += 1
        }
        return count >= 3
    }

    private func atxHeading(line: Range<Int>, from start: Int) -> Int? {
        var level = 0
        var index = start
        while index < line.upperBound, units[index] == hash {
            level += 1
            index += 1
        }
        guard (1...6).contains(level) else { return nil }
        // `#hashtag` is not a heading; the marker has to be followed by space.
        guard index == line.upperBound || units[index] == space || units[index] == tab else {
            return nil
        }
        return level
    }

    private mutating func styleATXHeading(line: Range<Int>, from start: Int, level: Int) {
        var index = start
        while index < line.upperBound, units[index] == hash { index += 1 }
        marker(start, index - start)

        block(line.lowerBound, line.count, .heading(level: level))

        while index < line.upperBound, units[index] == space || units[index] == tab {
            index += 1
        }
        styleInline(in: index..<line.upperBound)
    }

    /// `===` or `---` under a paragraph. The thematic-break check runs first, so
    /// a `---` on its own after a blank line has already been claimed.
    private func setextLevel(of line: Range<Int>) -> Int? {
        let start = indexAfterIndent(in: line)
        guard start < line.upperBound else { return nil }
        let character = units[start]
        guard character == equals || character == dash else { return nil }

        var index = start
        while index < line.upperBound, units[index] == character { index += 1 }
        while index < line.upperBound, units[index] == space || units[index] == tab {
            index += 1
        }
        guard index == line.upperBound else { return nil }
        return character == equals ? 1 : 2
    }

    /// The end of a list marker — `- `, `* `, `1. ` — or nil.
    private func listMarker(line: Range<Int>, from start: Int) -> Int? {
        guard start < line.upperBound else { return nil }
        var index = start

        if units[index] == dash || units[index] == star || units[index] == plus {
            index += 1
        } else if units[index] >= zero && units[index] <= nine {
            var digits = 0
            while index < line.upperBound, units[index] >= zero, units[index] <= nine {
                digits += 1
                index += 1
            }
            guard digits <= 9, index < line.upperBound,
                  units[index] == period || units[index] == closeParen else { return nil }
            index += 1
        } else {
            return nil
        }

        // A marker needs a space after it, or `-` alone would make every stray
        // dash a bullet and `*text*` at the start of a line would lose its
        // opening delimiter to the list.
        guard index < line.upperBound, units[index] == space || units[index] == tab else {
            return nil
        }
        while index < line.upperBound, units[index] == space || units[index] == tab {
            index += 1
        }
        return index
    }

    // MARK: Inline

    private mutating func styleInline(in range: Range<Int>) {
        guard !range.isEmpty else { return }

        // Marks the units already claimed, so a `*` inside `code` or inside a
        // link's URL is not read as emphasis.
        var taken = [Bool](repeating: false, count: range.count)
        func claim(_ span: Range<Int>) {
            for index in span where range.contains(index) {
                taken[index - range.lowerBound] = true
            }
        }
        func isFree(_ span: Range<Int>) -> Bool {
            span.allSatisfy { !taken[$0 - range.lowerBound] }
        }

        // Code first, and with no `isFree` check: nothing has been claimed yet,
        // so everything is free by construction.
        styleCodeSpans(in: range, claim: claim)
        styleLinks(in: range, claim: claim, isFree: isFree)

        // Longest delimiters first: *** would otherwise be eaten as ** plus a
        // stray *.
        for (delimiter, length, role) in [
            (star, 3, MarkdownEditorStyle.Role.boldItalic),
            (star, 2, .bold),
            (star, 1, .italic),
            (underscore, 3, .boldItalic),
            (underscore, 2, .bold),
            (underscore, 1, .italic),
            (tilde, 2, .strikethrough),
        ] {
            styleEmphasis(in: range, delimiter: delimiter, length: length, role: role,
                          claim: claim, isFree: isFree)
        }
    }

    private mutating func styleCodeSpans(in range: Range<Int>,
                                         claim: (Range<Int>) -> Void) {
        var index = range.lowerBound
        while index < range.upperBound {
            guard units[index] == backtick else {
                index += 1
                continue
            }
            var openLength = 0
            while index + openLength < range.upperBound, units[index + openLength] == backtick {
                openLength += 1
            }

            guard let close = closingBacktickRun(after: index + openLength,
                                                 length: openLength,
                                                 limit: range.upperBound) else {
                index += openLength
                continue
            }

            marker(index, openLength)
            inline(index + openLength, close - (index + openLength), .inlineCode)
            marker(close, openLength)
            claim(index..<(close + openLength))
            index = close + openLength
        }
    }

    private func closingBacktickRun(after start: Int, length: Int, limit: Int) -> Int? {
        var index = start
        while index < limit {
            guard units[index] == backtick else {
                index += 1
                continue
            }
            var run = 0
            while index + run < limit, units[index + run] == backtick { run += 1 }
            if run == length { return index }
            index += run
        }
        return nil
    }

    /// `[text](url)`, and `![alt](url)` for images.
    ///
    /// Bracket pairs are matched in one linear pass with a stack, rather than
    /// each `[` scanning forward for its own partner. The scanning version was
    /// quadratic on a line with many unmatched `[`, which a raw regex character
    /// class or a JSON array produces easily: 100,000 of them took 4.7 seconds,
    /// on a scan that runs on every keystroke. The stack gives the same pairs —
    /// innermost `]` closes the nearest open `[`, exactly as depth counting did.
    private mutating func styleLinks(in range: Range<Int>,
                                     claim: (Range<Int>) -> Void,
                                     isFree: (Range<Int>) -> Bool) {
        let partner = bracketPairs(in: range)

        // The last `)` in the range. Past it no URL can be closed, so a run of
        // trailing `[a](` costs nothing instead of a rescan each.
        var lastCloseParen: Int?
        var scan = range.upperBound - 1
        while scan >= range.lowerBound {
            if units[scan] == closeParen { lastCloseParen = scan; break }
            scan -= 1
        }

        var index = range.lowerBound
        while index < range.upperBound {
            guard units[index] == openBracket, isFree(index..<(index + 1)),
                  let textEnd = partner[index - range.lowerBound],
                  textEnd + 1 < range.upperBound,
                  units[textEnd + 1] == openParen,
                  let lastCloseParen, textEnd + 2 <= lastCloseParen else {
                index += 1
                continue
            }

            var urlEnd = textEnd + 2
            while urlEnd < range.upperBound, units[urlEnd] != closeParen { urlEnd += 1 }
            guard urlEnd < range.upperBound else {
                index += 1
                continue
            }

            // An image's leading `!` belongs to the marker, not the text.
            let start = (index > range.lowerBound && units[index - 1] == bang)
                ? index - 1 : index

            marker(start, index + 1 - start)
            inline(index + 1, textEnd - index - 1, .link)
            marker(textEnd, urlEnd + 1 - textEnd)
            claim(start..<(urlEnd + 1))
            index = urlEnd + 1
        }
    }

    /// For each `[` in the range, the index of the `]` that closes it.
    ///
    /// Indexed relative to `range.lowerBound`. Unmatched brackets get nil, which
    /// is what makes a line of nothing but `[` cheap.
    private func bracketPairs(in range: Range<Int>) -> [Int?] {
        var partner = [Int?](repeating: nil, count: range.count)
        var open: [Int] = []

        for index in range {
            if units[index] == openBracket {
                open.append(index)
            } else if units[index] == closeBracket, let start = open.popLast() {
                partner[start - range.lowerBound] = index
            }
        }
        return partner
    }

    private mutating func styleEmphasis(in range: Range<Int>,
                                        delimiter: UInt16,
                                        length: Int,
                                        role: MarkdownEditorStyle.Role,
                                        claim: (Range<Int>) -> Void,
                                        isFree: (Range<Int>) -> Bool) {
        var index = range.lowerBound
        while index + length * 2 <= range.upperBound {
            guard runLength(of: delimiter, at: index, limit: range.upperBound) == length,
                  isFree(index..<(index + length)),
                  canOpen(delimiter: delimiter, at: index, in: range, length: length) else {
                index += 1
                continue
            }

            var close = index + length
            var found: Int?
            while close + length <= range.upperBound {
                if runLength(of: delimiter, at: close, limit: range.upperBound) == length,
                   isFree(close..<(close + length)),
                   canClose(delimiter: delimiter, at: close, in: range, length: length) {
                    found = close
                    break
                }
                close += 1
            }

            guard let closeStart = found, closeStart > index + length else {
                // Nothing after this opener can close it — so nothing can close
                // any *later* opener either, since each one searches a subset of
                // what just failed, and every test applied is either positional
                // or a claim that only ever grows. Retrying from the next
                // character rescanned the rest of the line for each of them,
                // which made a line of `*a *a *a …` quadratic: 100,000 of them
                // took 30 seconds, on a scan that runs on every keystroke.
                return
            }

            marker(index, length)
            inline(index + length, closeStart - index - length, role)
            marker(closeStart, length)
            claim(index..<(closeStart + length))
            index = closeStart + length
        }
    }

    private func runLength(of delimiter: UInt16, at index: Int, limit: Int) -> Int {
        guard index < limit, units[index] == delimiter else { return 0 }
        var length = 0
        while index + length < limit, units[index + length] == delimiter { length += 1 }
        return length
    }

    /// `_` may not open or close inside a word.
    ///
    /// Without this, `some_variable_name` reads as emphasis — and identifiers
    /// like that are all over the documents this app is for. CommonMark makes
    /// the same exception, and for the same reason. `*` has no such rule.
    private func canOpen(delimiter: UInt16, at index: Int, in range: Range<Int>,
                         length: Int) -> Bool {
        // Nothing may follow the opener but content.
        let after = index + length
        guard after < range.upperBound,
              units[after] != space, units[after] != tab else { return false }

        guard delimiter == underscore else { return true }
        guard index > range.lowerBound else { return true }
        return !isWordUnit(units[index - 1])
    }

    private func canClose(delimiter: UInt16, at index: Int, in range: Range<Int>,
                          length: Int) -> Bool {
        // Nothing may precede the closer but content.
        guard index > range.lowerBound,
              units[index - 1] != space, units[index - 1] != tab else { return false }

        guard delimiter == underscore else { return true }
        let after = index + length
        guard after < range.upperBound else { return true }
        return !isWordUnit(units[after])
    }

    private func isWordUnit(_ unit: UInt16) -> Bool {
        // Anything above ASCII counts as a word character: an accented letter
        // must not turn `_` into a delimiter where a plain one would not.
        if unit > 127 { return true }
        if unit >= zero && unit <= nine { return true }
        let lowerA = UInt16(UInt8(ascii: "a")), lowerZ = UInt16(UInt8(ascii: "z"))
        let upperA = UInt16(UInt8(ascii: "A")), upperZ = UInt16(UInt8(ascii: "Z"))
        if unit >= lowerA && unit <= lowerZ { return true }
        if unit >= upperA && unit <= upperZ { return true }
        return unit == underscore
    }
}
