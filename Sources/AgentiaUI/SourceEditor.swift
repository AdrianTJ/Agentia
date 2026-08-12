import AppKit
import AgentiaCore

/// The editable view.
///
/// A real `NSTextView` rather than a `contenteditable` region in the web view.
/// The text view brings undo, find, spell-check and every native keybinding
/// with it; doing this in the page would mean reimplementing all of that inside
/// a document whose CSP pins scripting to a single hash — the one place in the
/// app where running more script is most expensive.
///
/// ## Styled, not rendered
///
/// The text here *is* the Markdown, and the file written back is byte-for-byte
/// what was typed. What changes is only how it is drawn: headings at heading
/// size, `**bold**` actually bold, code in a monospace face, and the markers
/// themselves dimmed so they recede without disappearing.
///
/// The alternative — making the rendered HTML editable — was considered and
/// rejected. It requires converting HTML back to Markdown on every save, and
/// that conversion rewrites the whole document rather than the part that was
/// edited: list markers, heading style and line wrapping all get normalised. In
/// an app built to show what an agent changed, a save that reformats every line
/// makes the diff worthless. This keeps the diff honest and still gives up the
/// monospace wall of text, which was the actual complaint.
///
/// Markers stay visible rather than being hidden once the caret leaves them.
/// Hiding them means the text reflows as the caret moves, and it makes the
/// document impossible to edit precisely — you cannot delete a `**` you cannot
/// see.
final class SourceEditor: NSView {

    /// Called on the first keystroke after the buffer was clean.
    private let onDirty: () -> Void

    private let textView = NSTextView()
    private let scrollView = NSScrollView()

    private var typography = EditorTypography(scale: 1.0)

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
        // Still not rich text: this holds Markdown, and the attributes below are
        // applied by the app, never by the reader. Paste stays plain, so pasting
        // from a browser brings the text and not its formatting.
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        // Every one of those would silently rewrite the file: curly quotes and
        // em dashes inside a fenced code block are a corrupted document, not a
        // typographic improvement.

        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.textStorage?.delegate = self

        applyTypography()

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
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
        restyle()
    }

    /// Mark the buffer saved without touching its contents.
    func markSaved() {
        isDirty = false
    }

    // MARK: - Narrow access to the text view
    //
    // The text view itself stays private. Handing it out — even inside the
    // module — hands out a mutable object, and setting `.string` on it directly
    // would bypass `load()`, skip the delegate callback, and leave `isDirty`
    // claiming the buffer is clean while it is not. Saving, the unsaved-changes
    // prompt and the hold on sudden termination all trust that flag.

    /// Insert text at the caret, exactly as typing does.
    ///
    /// Goes through the text system, so the delegate fires and the buffer
    /// becomes dirty the same way it would for a person at the keyboard. Used by
    /// the tests, where a hook that assigned the string directly would skip the
    /// very callback under test.
    func insertText(_ text: String) {
        textView.insertText(text, replacementRange: textView.selectedRange())
    }

    /// The styling attribute in force at a position, for asserting on what the
    /// reader would see.
    func attribute(_ key: NSAttributedString.Key, at location: Int) -> Any? {
        guard let storage = textView.textStorage,
              location < storage.length else { return nil }
        return storage.attribute(key, at: location, effectiveRange: nil)
    }

    /// The margins the text is currently laid out with. See `updateInsets`.
    var textInsets: NSSize {
        textView.textContainerInset
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

    /// Match the reader's chosen text size, so editing and reading are set at
    /// the same size.
    func applyFontScale(_ scale: Double) {
        guard scale != typography.scale else { return }
        typography = EditorTypography(scale: scale)
        applyTypography()
        restyle()
    }

    private func applyTypography() {
        textView.font = typography.body
        textView.textColor = typography.text
        textView.typingAttributes = [
            .font: typography.body,
            .foregroundColor: typography.text,
            .paragraphStyle: typography.paragraph,
        ]
        updateInsets()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        updateInsets()
    }

    /// Centre the text in a fixed measure, the way the rendered view does.
    ///
    /// Done with the container inset rather than a constraint so the text view
    /// still fills the scroll view — clicking in the margin should put the caret
    /// on the nearest line, not miss the editor entirely.
    private func updateInsets() {
        let available = bounds.width
        guard available > 0 else { return }

        let measure = min(typography.measure, available - 48)
        let horizontal = max(24, (available - measure) / 2)
        let inset = NSSize(width: horizontal, height: typography.size * 1.6)

        guard textView.textContainerInset != inset else { return }
        textView.textContainerInset = inset
    }

    // MARK: - Styling

    /// Set while attributes are being applied, so the text storage's own
    /// callback does not recurse back into this.
    private var isStyling = false

    /// Redraw the whole document's styling.
    ///
    /// Whole-document rather than incremental, because Markdown is not local: an
    /// opening fence changes how every line below it is drawn, and so does
    /// deleting one. `MarkdownEditorStyle` caps the size it will scan, and above
    /// that this leaves the text plain rather than making the caret lag.
    private func restyle() {
        guard let storage = textView.textStorage else { return }
        guard !isStyling else { return }
        isStyling = true
        defer { isStyling = false }

        let source = storage.string
        let full = NSRange(location: 0, length: (source as NSString).length)

        storage.beginEditing()
        defer { storage.endEditing() }

        // Back to plain first, or a marker deleted a moment ago would leave its
        // styling behind on text that is no longer inside anything.
        storage.setAttributes([
            .font: typography.body,
            .foregroundColor: typography.text,
            .paragraphStyle: typography.paragraph,
        ], range: full)

        for span in MarkdownEditorStyle.spans(in: source) {
            let range = NSRange(location: span.location, length: span.length)
            // Defensive: the spans are asserted to be in bounds in
            // AgentiaCore's tests, and an out-of-range attribute here would be
            // an exception rather than a cosmetic problem.
            guard NSMaxRange(range) <= full.length else { continue }
            apply(span.role, to: range, in: storage)
        }
    }

    private func apply(_ role: MarkdownEditorStyle.Role,
                       to range: NSRange,
                       in storage: NSTextStorage) {
        /// Refine the font already there rather than replacing it, so emphasis
        /// inside a heading keeps the heading's size.
        func addTraits(_ traits: NSFontDescriptor.SymbolicTraits) {
            storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let current = (value as? NSFont) ?? typography.body
                storage.addAttribute(.font, value: typography.adding(traits, to: current),
                                     range: subrange)
            }
        }

        switch role {
        case .heading(let level):
            storage.addAttribute(.font, value: typography.heading(level: level), range: range)
            storage.addAttribute(.paragraphStyle,
                                 value: typography.headingParagraph(level: level), range: range)

        case .bold:
            addTraits(.bold)
        case .italic:
            addTraits(.italic)
        case .boldItalic:
            addTraits([.bold, .italic])

        case .strikethrough:
            storage.addAttribute(.strikethroughStyle,
                                 value: NSUnderlineStyle.single.rawValue, range: range)
            storage.addAttribute(.foregroundColor, value: typography.syntax, range: range)

        case .inlineCode, .codeBlock:
            storage.addAttribute(.font, value: typography.monospace, range: range)
            storage.addAttribute(.foregroundColor, value: typography.code, range: range)
            storage.addAttribute(.backgroundColor, value: typography.codeBackground, range: range)

        case .blockQuote:
            storage.addAttribute(.foregroundColor, value: typography.quote, range: range)
            storage.addAttribute(.paragraphStyle, value: typography.quoteParagraph, range: range)

        case .listMarker:
            storage.addAttribute(.foregroundColor, value: typography.listMarker, range: range)

        case .link:
            storage.addAttribute(.foregroundColor, value: typography.link, range: range)

        case .thematicBreak:
            storage.addAttribute(.foregroundColor, value: typography.syntax, range: range)

        case .syntax:
            // Colour only, and applied last: a marker keeps the size of
            // whatever it belongs to and simply recedes.
            storage.addAttribute(.foregroundColor, value: typography.syntax, range: range)
        }
    }
}

extension SourceEditor: NSTextStorageDelegate {

    /// Restyle after every edit, including ones the reader did not make —
    /// undo, redo, paste and Find & Replace all arrive here and nowhere else.
    func textStorage(_ textStorage: NSTextStorage,
                     didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange,
                     changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !isStyling else { return }
        // Attributes cannot be changed inside this callback, so it is deferred
        // to the next turn of the run loop — by which point the layout manager
        // has finished with the edit that triggered it.
        DispatchQueue.main.async { [weak self] in self?.restyle() }
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
