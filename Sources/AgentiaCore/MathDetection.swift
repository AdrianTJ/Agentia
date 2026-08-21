import Foundation

/// Decides whether a Markdown source plausibly contains math worth rendering.
///
/// Deliberately coarse: it matches the delimiters KaTeX's auto-render extension
/// enables by default (`$$…$$`, `\(…\)`, `\[…\]`, `\begin{…}`), skipping fenced
/// code blocks because auto-render ignores those anyway. A stray true positive
/// only means KaTeX is injected and finds nothing; a false negative means math
/// stays literal text, which is the pre-feature behaviour.
///
/// Single-`$` currency is intentionally NOT a trigger — that is the same
/// delimiter auto-render leaves off by default, so `$100 and $200` never
/// becomes math.
public enum MathDetection {

    public static func present(in markdown: String) -> Bool {
        var inFence = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            guard !inFence else { continue }
            if trimmed.contains("$$")
                || trimmed.contains("\\(")
                || trimmed.contains("\\[")
                || trimmed.contains("\\begin{") {
                return true
            }
        }
        return false
    }
}
