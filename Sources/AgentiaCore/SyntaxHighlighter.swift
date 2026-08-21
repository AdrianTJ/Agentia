import Foundation

/// Colours fenced code blocks, in Swift, at render time.
///
/// It has to happen here rather than in the page. The Markdown profile pins
/// `script-src` to the hash of `shell.js`, so shipping highlight.js would mean
/// either a second hash or loosening the policy — and the whole reason Markdown
/// renders with scripting effectively off is that no document-derived thing can
/// execute. Highlighting is a rendering concern; it belongs on the render side.
///
/// ## Why not tree-sitter
///
/// `docs/technical-proposal.html` names tree-sitter, and for an editor it would
/// be right: real parse trees, error recovery, incremental reparsing. None of
/// that pays here. Agentia highlights a fenced block once, never edits it, and
/// never needs a tree — only spans. Against that, tree-sitter means the
/// tree-sitter runtime plus a separate C grammar per language, which is a lot
/// of vendored C to re-acquire in a project that just finished removing all of
/// its own.
///
/// So this is a spec-driven lexer: one tokeniser, and a small table per
/// language. It is deliberately *lexical* — it knows keywords, strings,
/// comments and numbers, and does not know scope, types or semantics. For
/// reading an artifact that is the whole job, and the failure mode is a word
/// that should have been coloured and was not, rather than a wrong parse.
///
/// `Language.spec(for:)` is the only thing a tree-sitter backend would have to
/// replace if that trade ever changes.
public enum SyntaxHighlighter {

    /// What a token is, which is also the CSS class it gets.
    ///
    /// Every case here must be emitted by `tokenise` and have a matching
    /// `.tok-*` rule in base.css. A `punctuation` case was declared and never
    /// emitted, with no CSS behind it — a class that looks supported and
    /// silently is not.
    public enum Token: String, Sendable, CaseIterable {
        case keyword, string, comment, number, type, function

        var cssClass: String { "tok-" + rawValue }
    }

    /// The lexical shape of a language.
    public struct Spec: Sendable {
        public var keywords: Set<String>
        /// Recognised as types when capitalised, e.g. Swift's `String`.
        public var capitalisedWordsAreTypes: Bool
        public var lineComments: [String]
        /// Paired block comment delimiters.
        public var blockComments: [(open: String, close: String)]
        public var stringDelimiters: [Character]
        /// Delimiters that survive a newline, e.g. Python's `"""`.
        public var rawStringDelimiters: [String]
        /// Whether a backslash escapes inside a string.
        public var escapesInStrings: Bool

        public init(
            keywords: Set<String>,
            capitalisedWordsAreTypes: Bool = false,
            lineComments: [String] = ["//"],
            blockComments: [(open: String, close: String)] = [("/*", "*/")],
            stringDelimiters: [Character] = ["\"", "'"],
            rawStringDelimiters: [String] = [],
            escapesInStrings: Bool = true
        ) {
            self.keywords = keywords
            self.capitalisedWordsAreTypes = capitalisedWordsAreTypes
            self.lineComments = lineComments
            self.blockComments = blockComments
            self.stringDelimiters = stringDelimiters
            self.rawStringDelimiters = rawStringDelimiters
            self.escapesInStrings = escapesInStrings
        }
    }

    /// Highlight `code`, or nil when the language is unknown or the result
    /// would exceed `maxOutputBytes`.
    ///
    /// Returning nil rather than a best guess is deliberate: an unknown
    /// language renders as plain code, which is correct, whereas guessing
    /// produces confidently wrong colours. The size bound matters because each
    /// token adds ~30 bytes of `<span>` wrapper, so dense short-token code
    /// (a data literal, a minified line) can inflate an order of magnitude —
    /// the caller degrades such a block to plain text rather than hand the
    /// layout engine hundreds of megabytes.
    public static func highlight(
        _ code: String,
        language: String,
        maxOutputBytes: Int = .max
    ) -> String? {
        guard let spec = Language.spec(for: language) else { return nil }
        return render(tokenise(code, with: spec), of: code, maxOutputBytes: maxOutputBytes)
    }

    // MARK: - Tokenising

    struct Span: Equatable {
        var range: Range<String.Index>
        var token: Token
    }

    static func tokenise(_ code: String, with spec: Spec) -> [Span] {
        var spans: [Span] = []
        var i = code.startIndex

        func peek(_ text: String, at index: String.Index) -> Bool {
            code[index...].hasPrefix(text)
        }

        while i < code.endIndex {
            let character = code[i]

            // Comments first: everything else can appear inside one.
            if let opener = spec.lineComments.first(where: { peek($0, at: i) }) {
                _ = opener
                let end = code[i...].firstIndex(of: "\n") ?? code.endIndex
                spans.append(Span(range: i..<end, token: .comment))
                i = end
                continue
            }

            if let block = spec.blockComments.first(where: { peek($0.open, at: i) }) {
                let after = code.index(i, offsetBy: block.open.count)
                let end = code.range(of: block.close, range: after..<code.endIndex)?
                    .upperBound ?? code.endIndex
                spans.append(Span(range: i..<end, token: .comment))
                i = end
                continue
            }

            if let raw = spec.rawStringDelimiters.first(where: { peek($0, at: i) }) {
                let after = code.index(i, offsetBy: raw.count)
                let end = code.range(of: raw, range: after..<code.endIndex)?
                    .upperBound ?? code.endIndex
                spans.append(Span(range: i..<end, token: .string))
                i = end
                continue
            }

            if spec.stringDelimiters.contains(character) {
                let end = endOfString(in: code, from: i,
                                      delimiter: character,
                                      escapes: spec.escapesInStrings)
                spans.append(Span(range: i..<end, token: .string))
                i = end
                continue
            }

            if character.isNumber {
                var end = i
                while end < code.endIndex,
                      code[end].isHexDigit || code[end] == "." || code[end] == "x"
                        || code[end] == "_" || code[end] == "b" || code[end] == "o" {
                    end = code.index(after: end)
                }
                spans.append(Span(range: i..<end, token: .number))
                i = end
                continue
            }

            if character.isLetter || character == "_" || character == "@"
                || character == "#" || character == "$" {
                var end = i
                while end < code.endIndex,
                      code[end].isLetter || code[end].isNumber || code[end] == "_"
                        || code[end] == "@" || code[end] == "#" || code[end] == "$" {
                    end = code.index(after: end)
                }
                let word = String(code[i..<end])

                if spec.keywords.contains(word) {
                    spans.append(Span(range: i..<end, token: .keyword))
                } else if isCallSite(code, after: end) {
                    spans.append(Span(range: i..<end, token: .function))
                } else if spec.capitalisedWordsAreTypes,
                          let first = word.first, first.isUppercase {
                    spans.append(Span(range: i..<end, token: .type))
                }
                i = end
                continue
            }

            i = code.index(after: i)
        }

        return spans
    }

    /// A word immediately followed by `(` is being called. Cheap, and right far
    /// more often than not in the languages here.
    private static func isCallSite(_ code: String, after index: String.Index) -> Bool {
        var cursor = index
        while cursor < code.endIndex, code[cursor] == " " {
            cursor = code.index(after: cursor)
        }
        return cursor < code.endIndex && code[cursor] == "("
    }

    /// End of a string literal, past the closing delimiter.
    ///
    /// An unterminated literal ends at the newline rather than swallowing the
    /// rest of the block — a stray apostrophe in a shell comment should not
    /// paint everything after it as a string.
    private static func endOfString(
        in code: String,
        from start: String.Index,
        delimiter: Character,
        escapes: Bool
    ) -> String.Index {
        var i = code.index(after: start)
        while i < code.endIndex {
            let character = code[i]
            if character == "\n" { return i }
            if escapes, character == "\\" {
                i = code.index(after: i)
                if i < code.endIndex { i = code.index(after: i) }
                continue
            }
            i = code.index(after: i)
            if character == delimiter { return i }
        }
        return code.endIndex
    }

    // MARK: - Rendering

    /// Wrap each span in a `<span>`, escaping everything else.
    ///
    /// The output is assembled here rather than by splicing into cmark's
    /// already-escaped HTML, so every character of the original passes through
    /// exactly one escaping step. Double-escaping shows up as `&amp;lt;` on
    /// screen; missing one is an injection.
    static func render(_ spans: [Span], of code: String, maxOutputBytes: Int = .max) -> String? {
        var out = ""
        out.reserveCapacity(code.count + spans.count * 24)

        // Tracked as a running total rather than reading out.utf8.count each
        // step, which would make the whole pass quadratic.
        var bytes = 0
        func emit(_ piece: String) -> Bool {
            bytes += piece.utf8.count
            if bytes > maxOutputBytes { return false }
            out += piece
            return true
        }

        var cursor = code.startIndex
        for span in spans where span.range.lowerBound >= cursor {
            guard emit(escape(String(code[cursor..<span.range.lowerBound]))),
                  emit("<span class=\"\(span.token.cssClass)\">"),
                  emit(escape(String(code[span.range]))),
                  emit("</span>")
            else { return nil }
            cursor = span.range.upperBound
        }
        guard emit(escape(String(code[cursor...]))) else { return nil }
        return out
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }
}

// MARK: - Languages

extension SyntaxHighlighter {

    enum Language {

        /// Aliases are the names agents actually write in a fence.
        static func spec(for language: String) -> Spec? {
            switch language.lowercased() {
            case "swift": return swift
            case "python", "py": return python
            case "javascript", "js", "jsx", "typescript", "ts", "tsx": return javascript
            case "json": return json
            case "bash", "sh", "shell", "zsh", "console": return shell
            case "c", "h", "cpp", "c++", "objc", "go", "rust", "rs", "java", "kotlin":
                return cLike
            case "yaml", "yml": return yaml
            case "sql": return sql
            case "html", "xml", "css": return markup
            default: return nil
            }
        }

        static let swift = Spec(
            keywords: [
                "func", "let", "var", "if", "else", "guard", "return", "for", "while",
                "in", "switch", "case", "default", "break", "continue", "struct",
                "class", "enum", "protocol", "extension", "import", "init", "deinit",
                "self", "super", "nil", "true", "false", "throws", "throw", "try",
                "catch", "do", "defer", "public", "private", "internal", "fileprivate",
                "static", "final", "override", "mutating", "lazy", "weak", "unowned",
                "async", "await", "actor", "some", "any", "where", "as", "is", "typealias",
            ],
            capitalisedWordsAreTypes: true,
            rawStringDelimiters: ["\"\"\""]
        )

        static let python = Spec(
            keywords: [
                "def", "class", "if", "elif", "else", "for", "while", "in", "return",
                "import", "from", "as", "try", "except", "finally", "raise", "with",
                "lambda", "yield", "pass", "break", "continue", "global", "nonlocal",
                "assert", "del", "and", "or", "not", "is", "None", "True", "False",
                "async", "await", "self",
            ],
            capitalisedWordsAreTypes: true,
            lineComments: ["#"],
            blockComments: [],
            rawStringDelimiters: ["\"\"\"", "'''"]
        )

        static let javascript = Spec(
            keywords: [
                "function", "const", "let", "var", "if", "else", "for", "while", "do",
                "return", "class", "extends", "new", "this", "super", "import", "export",
                "from", "default", "try", "catch", "finally", "throw", "switch", "case",
                "break", "continue", "typeof", "instanceof", "in", "of", "delete", "void",
                "null", "undefined", "true", "false", "async", "await", "yield",
                "interface", "type", "enum", "implements", "public", "private", "readonly",
            ],
            capitalisedWordsAreTypes: true,
            stringDelimiters: ["\"", "'", "`"]
        )

        static let json = Spec(
            keywords: ["true", "false", "null"],
            lineComments: [],
            blockComments: [],
            stringDelimiters: ["\""]
        )

        static let shell = Spec(
            keywords: [
                "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case",
                "esac", "function", "return", "export", "local", "readonly", "source",
                "echo", "cd", "set", "unset", "trap", "exit", "shift", "eval", "exec",
            ],
            lineComments: ["#"],
            blockComments: []
        )

        static let cLike = Spec(
            keywords: [
                "if", "else", "for", "while", "do", "return", "struct", "class", "enum",
                "union", "typedef", "const", "static", "extern", "void", "int", "char",
                "float", "double", "long", "short", "unsigned", "signed", "sizeof",
                "switch", "case", "break", "continue", "default", "goto", "func", "package",
                "import", "type", "interface", "map", "chan", "go", "defer", "fn", "let",
                "mut", "impl", "pub", "use", "match", "trait", "public", "private",
                "protected", "final", "new", "delete", "this", "null", "nullptr", "true",
                "false", "namespace", "template", "typename", "auto",
            ],
            capitalisedWordsAreTypes: true
        )

        static let yaml = Spec(
            keywords: ["true", "false", "null", "yes", "no", "on", "off"],
            lineComments: ["#"],
            blockComments: []
        )

        static let sql = Spec(
            keywords: [
                "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET",
                "DELETE", "CREATE", "TABLE", "INDEX", "DROP", "ALTER", "JOIN", "LEFT",
                "RIGHT", "INNER", "OUTER", "ON", "GROUP", "BY", "ORDER", "HAVING",
                "LIMIT", "OFFSET", "AS", "AND", "OR", "NOT", "NULL", "DISTINCT", "UNION",
                "select", "from", "where", "insert", "into", "values", "update", "set",
                "delete", "create", "table", "join", "on", "group", "by", "order",
                "limit", "as", "and", "or", "not", "null", "distinct",
            ],
            lineComments: ["--"],
            stringDelimiters: ["'", "\""]
        )

        static let markup = Spec(
            keywords: [],
            lineComments: [],
            blockComments: [("<!--", "-->"), ("/*", "*/")],
            stringDelimiters: ["\"", "'"]
        )
    }
}
