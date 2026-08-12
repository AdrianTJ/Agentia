import AppKit
import AgentiaCore

/// The editable source view.
///
/// A real `NSTextView` rather than a `contenteditable` region in the web view.
/// The text view brings undo, find, spell-check and every native keybinding
/// with it; doing this in the page would mean reimplementing all of that inside
/// a document whose CSP pins scripting to a single hash — the one place in the
/// app where running more script is most expensive.
///
/// It only ever holds the source, never the rendered document. Editing rendered
/// HTML and mapping it back to Markdown is a different and much larger feature,
/// and the proposal argues explicitly against it.
final class SourceEditor: NSView {

    /// Called on the first keystroke after the buffer was clean.
    private let onDirty: () -> Void

    private let textView = NSTextView()
    private let scrollView = NSScrollView()

    /// True once the reader has typed something not yet saved.
    private(set) var isDirty = false

    var text: String {
        textView.string
    }

    init(onDirty: @escaping () -> Void) {
        self.onDirty = onDirty
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        textView.isRichText = false            // it is Markdown, not prose
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        // Every one of those would silently rewrite the file: curly quotes and
        // em dashes inside a fenced code block are a corrupted document, not a
        // typographic improvement.

        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Load a document into the editor, discarding any undo history from the
    /// previous one — undoing across two different files would be nonsense.
    func load(_ source: String) {
        textView.string = source
        textView.undoManager?.removeAllActions()
        isDirty = false
    }

    /// Mark the buffer saved without touching its contents.
    func markSaved() {
        isDirty = false
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    /// Search the buffer, wrapping, and select the match.
    ///
    /// The find bar drives `WKWebView.find` for the rendered document, which
    /// searches a hidden — and possibly stale — web view while source mode is
    /// showing. In source mode the text the reader is looking at is here.
    func find(_ query: String, forward: Bool) -> Bool {
        guard !query.isEmpty else { return true }

        let text = textView.string as NSString
        let selection = textView.selectedRange()
        let options: NSString.CompareOptions = forward
            ? [.caseInsensitive]
            : [.caseInsensitive, .backwards]

        // Search from just past the current match, so repeated presses advance
        // rather than finding the same one.
        let after = NSRange(location: NSMaxRange(selection),
                            length: text.length - NSMaxRange(selection))
        let before = NSRange(location: 0, length: selection.location)
        let (first, wrapped) = forward
            ? (after, NSRange(location: 0, length: text.length))
            : (before, NSRange(location: 0, length: text.length))

        var found = text.range(of: query, options: options, range: first)
        if found.location == NSNotFound {
            // Wrap, matching the rendered view's behaviour.
            found = text.range(of: query, options: options, range: wrapped)
        }
        guard found.location != NSNotFound else { return false }

        textView.setSelectedRange(found)
        textView.scrollRangeToVisible(found)
        textView.showFindIndicator(for: found)
        return true
    }

    /// Match the reader's chosen text size, so source view is legible at the
    /// same setting the rendered view uses.
    func applyFontScale(_ scale: Double) {
        textView.font = .monospacedSystemFont(ofSize: 13 * scale, weight: .regular)
    }
}

extension SourceEditor: NSTextViewDelegate {

    func textDidChange(_ notification: Notification) {
        guard !isDirty else { return }
        isDirty = true
        // Announced once, on the transition. The controller uses it to stop
        // watching the file, so an agent rewriting underneath cannot reload
        // over unsaved edits.
        onDirty()
    }
}
