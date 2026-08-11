import AppKit
import UniformTypeIdentifiers
import AgentiaCore

// MARK: - Preferences

/// Small, boring, and deliberately not a database. Reading these must never be
/// on the launch critical path for anything but a couple of scalars.
enum Preferences {
    private static let defaults = UserDefaults.standard

    static var themeID: String {
        get { defaults.string(forKey: "theme") ?? "manuscript" }
        set { defaults.set(newValue, forKey: "theme") }
    }

    /// Follows the system unless the user pinned one.
    static var appearance: RenderShell.Appearance {
        if let pinned = defaults.string(forKey: "appearance") {
            return pinned == "dark" ? .dark : .light
        }
        let name = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        return name == .darkAqua ? .dark : .light
    }

    /// Body text multiplier. 1.0 is whatever the theme chose.
    static var fontScale: Double {
        get {
            let stored = defaults.double(forKey: "fontScale")
            // A missing key reads as 0, which is not a scale anyone asked for.
            guard stored > 0 else { return 1.0 }
            return min(max(stored, RenderShell.Display.range.lowerBound),
                       RenderShell.Display.range.upperBound)
        }
        set {
            defaults.set(min(max(newValue, RenderShell.Display.range.lowerBound),
                             RenderShell.Display.range.upperBound),
                         forKey: "fontScale")
        }
    }

    /// The steps ⌘+ and ⌘− move through.
    ///
    /// Multiplicative rather than a fixed increment, so each press is the same
    /// perceptual change at any size — +0.1 is a big jump at 0.8 and barely
    /// visible at 2.0.
    static let fontScaleSteps: [Double] = [0.7, 0.8, 0.9, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0]

    static func pinAppearance(_ appearance: RenderShell.Appearance?) {
        if let appearance {
            defaults.set(appearance.rawValue, forKey: "appearance")
        } else {
            defaults.removeObject(forKey: "appearance")
        }
    }
}

// MARK: - Document types

enum DocumentTypes {
    /// Types the open panel accepts. Registered UTIs live in Info.plist; this
    /// list only affects the panel.
    static var openable: [UTType] {
        var types: [UTType] = [.html, .plainText]
        if let markdown = UTType("net.daringfireball.markdown") {
            types.insert(markdown, at: 0)
        }
        return types
    }
}

// MARK: - Clipboard

/// Writes several representations at once so the destination picks the right
/// one: paste into a terminal and get source, paste into Mail and get
/// formatting. This is the highest-value item on the toolbar and the cheapest.
enum Clipboard {

    static func writePlain(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func write(source: String, kind: DocumentKind) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // Order matters: the first type is what a plain-text destination takes.
        pasteboard.setString(source, forType: .string)

        guard kind == .markdown,
              let html = try? MarkdownRenderer.renderHTML(source, options: MarkdownRenderer.Options.default)
        else { return }

        pasteboard.setString(html, forType: .html)

        // Rich text, for Mail and Notes. Built from the HTML so it carries the
        // structure the reader saw.
        //
        // The HTML is stripped of remote references first. NSAttributedString's
        // HTML importer drives a legacy WebKit parser that performs synchronous
        // network loads for external subresources — so copying a hostile
        // document would phone home from the main thread, completely outside
        // the CSP, the content rule list and the navigation delegate. tagfilter
        // removes <script> but says nothing about <img src="https://tracker/">.
        let safe = strippingRemoteReferences(from: html)

        if let data = Data(safe.utf8) as Data?,
           let attributed = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.html,
                         .characterEncoding: String.Encoding.utf8.rawValue],
               documentAttributes: nil),
           let rtf = try? attributed.data(
               from: NSRange(location: 0, length: attributed.length),
               documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            pasteboard.setData(rtf, forType: .rtf)
        }
    }

    /// Removes any attribute or `url()` that points off the machine, so the
    /// HTML importer has nothing to fetch.
    ///
    /// The dangerous cases are matched by the *value*, not the attribute name.
    /// A name blocklist was tried first and a security review walked straight
    /// past it with `<object data="http://…">` and SVG `<image xlink:href=…>` —
    /// neither `data` nor `xlink:href` was in the list, and both make the
    /// legacy importer perform a synchronous network load on the main thread,
    /// outside the CSP, the rule list and the navigation delegate. So the first
    /// two patterns strip *any* attribute whose value carries a remote scheme
    /// or is protocol-relative; `data:`, `#fragment` and `artifact:` values
    /// contain no `//` and so are left in place.
    static func strippingRemoteReferences(from html: String) -> String {
        let patterns = [
            // Any attribute whose value is a remote or protocol-relative URL.
            #"(?i)\s[\w:.-]+\s*=\s*"(?:[a-z][a-z0-9+.-]*:)?//[^"]*""#,
            #"(?i)\s[\w:.-]+\s*=\s*'(?:[a-z][a-z0-9+.-]*:)?//[^']*'"#,
            // The name-based strip is kept for the reference-carrying
            // attributes whose value is not itself a URL with `//`.
            #"(?i)\s(src|href|poster|srcset|background|data|xlink:href)\s*=\s*"[^"]*""#,
            #"(?i)\s(src|href|poster|srcset|background|data|xlink:href)\s*=\s*'[^']*'"#,
            #"(?i)url\(\s*['"]?[^)]*\)"#,
        ]

        var out = html
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let full = NSRange(out.startIndex..., in: out)

            var result = ""
            var last = out.startIndex
            regex.enumerateMatches(in: out, range: full) { match, _, _ in
                guard let match, let range = Range(match.range, in: out) else { return }
                let text = String(out[range])
                // Keep local references: an inline data: image or an
                // in-document anchor is harmless and worth preserving.
                let lowered = text.lowercased()
                let isLocal = lowered.contains("\"#") || lowered.contains("'#")
                    || lowered.contains("data:") || lowered.contains("artifact:")
                result += out[last..<range.lowerBound]
                result += isLocal ? text : ""
                last = range.upperBound
            }
            result += out[last...]
            out = result
        }
        return out
    }
}

// MARK: - Toolbar

/// The toolbar, capped at the controls that shorten the loop between an agent
/// writing a file and the reader doing something with it. Anything new has to
/// displace something old.
final class DocumentToolbar: NSObject, NSToolbarDelegate {

    private weak var target: DocumentWindowController?
    private weak var toolbar: NSToolbar?

    init(target: DocumentWindowController) {
        self.target = target
    }

    private enum ItemID {
        static let sidebar = NSToolbarItem.Identifier("sidebar")
        static let viewMode = NSToolbarItem.Identifier("viewMode")
        static let copy = NSToolbarItem.Identifier("copy")
        static let pdf = NSToolbarItem.Identifier("pdf")
        static let reveal = NSToolbarItem.Identifier("reveal")
        static let share = NSToolbarItem.Identifier("share")
        static let blocked = NSToolbarItem.Identifier("blocked")
    }

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "AgentiaDocumentToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        self.toolbar = toolbar
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.sidebar, .flexibleSpace, ItemID.blocked, ItemID.viewMode,
         ItemID.copy, ItemID.share, ItemID.pdf, ItemID.reveal]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.flexibleSpace, .space]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case ItemID.sidebar:
            return button(identifier, symbol: "sidebar.left", label: "Documents",
                          action: #selector(DocumentWindowController.toggleSidebar(_:)))
        case ItemID.viewMode:
            return button(identifier, symbol: "chevron.left.forwardslash.chevron.right",
                          label: "Source",
                          action: #selector(DocumentWindowController.toggleSource(_:)))
        case ItemID.copy:
            return button(identifier, symbol: "doc.on.doc", label: "Copy",
                          action: #selector(DocumentWindowController.copyAll(_:)))
        case ItemID.pdf:
            return button(identifier, symbol: "arrow.down.doc", label: "Export PDF",
                          action: #selector(DocumentWindowController.exportPDF(_:)))
        case ItemID.share:
            // View-based, unlike the others: the share popover anchors to the
            // control it was launched from, and a system-rendered toolbar item
            // exposes no `view` to anchor to — so the picker would pop from the
            // window content, nowhere near the button. A real NSButton is that
            // anchor, and it reaches shareDocument(_:) with itself as sender.
            return viewButton(identifier, symbol: "square.and.arrow.up", label: "Share",
                              action: #selector(DocumentWindowController.shareDocument(_:)))
        case ItemID.reveal:
            return button(identifier, symbol: "folder", label: "Reveal in Finder",
                          action: #selector(DocumentWindowController.revealInFinder(_:)))
        case ItemID.blocked:
            // Not created in `toolbarDefaultItemIdentifiers`, so this is only
            // asked for when updateBlockedCount inserts it.
            return button(identifier, symbol: "exclamationmark.shield",
                          label: "Blocked requests",
                          action: #selector(DocumentWindowController.allowNetworkForDocument(_:)))
        default:
            return nil
        }
    }

    private func button(
        _ identifier: NSToolbarItem.Identifier,
        symbol: String,
        label: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = target
        item.action = action
        item.isBordered = true
        return item
    }

    /// A toolbar item backed by a real NSButton, for the one control that needs
    /// a view to anchor a popover to.
    private func viewButton(
        _ identifier: NSToolbarItem.Identifier,
        symbol: String,
        label: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.toolTip = label

        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)
                ?? NSImage(),
            target: target, action: action)
        button.bezelStyle = .texturedRounded
        button.setAccessibilityLabel(label)
        item.view = button
        return item
    }

    /// Shows how many remote requests the document tried to make. The item is
    /// removed from the toolbar when there were none, so a clean document has
    /// no chrome for it.
    ///
    /// `NSToolbarItem.isHidden` would be simpler but is macOS 15+; remove and
    /// re-insert keeps the macOS 13 floor declared in Package.swift.
    func updateBlockedCount(_ count: Int) {
        guard let toolbar else { return }
        let identifier = ItemID.blocked
        let present = toolbar.items.contains { $0.itemIdentifier == identifier }

        if count == 0, present {
            if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == identifier }) {
                toolbar.removeItem(at: index)
            }
        } else if count > 0, !present {
            // Insert before the view-mode item; if it is gone for any reason,
            // fall back to the end of the toolbar.
            let index = toolbar.items.firstIndex {
                $0.itemIdentifier == ItemID.viewMode
            } ?? toolbar.items.count
            toolbar.insertItem(withItemIdentifier: identifier, at: index)
        }

        guard let item = toolbar.items.first(where: { $0.itemIdentifier == identifier }) else {
            return
        }
        item.label = count == 1 ? "1 request blocked" : "\(count) requests blocked"
        item.toolTip = item.label + " — click to allow for this document"
    }
}

// MARK: - Find bar

/// The in-page find strip.
///
/// Search itself is `WKWebView.find`, which highlights inside the rendered page
/// rather than the source — what a reader wants when looking for a phrase they
/// can see. This is only the chrome around it.
final class FindBar: NSView {

    static let preferredHeight: CGFloat = 36

    /// Called with the query and a direction; nil query means "dismissed".
    private let onSearch: (String, Bool) -> Void
    private let onDismiss: () -> Void

    private let field = NSSearchField()
    private let status = NSTextField(labelWithString: "")

    init(onSearch: @escaping (String, Bool) -> Void, onDismiss: @escaping () -> Void) {
        self.onSearch = onSearch
        self.onDismiss = onDismiss
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: Self.preferredHeight))
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        wantsLayer = true

        field.placeholderString = "Find in document"
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = false
        field.target = self
        field.action = #selector(searchChanged)

        // Titles as the fallback rather than force-unwrapping the symbol: a
        // missing SF Symbol must not be able to crash the app on launch.
        let previous = Self.button(symbol: "chevron.up", title: "Previous",
                                   target: self, action: #selector(findPrevious))
        let next = Self.button(symbol: "chevron.down", title: "Next",
                               target: self, action: #selector(findNext))
        let done = NSButton(title: "Done", target: self, action: #selector(dismiss))
        done.bezelStyle = .rounded

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [field, status, previous, next, done])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
    }

    private static func button(
        symbol: String, title: String, target: AnyObject, action: Selector
    ) -> NSButton {
        let button: NSButton
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            button = NSButton(image: image, target: target, action: action)
        } else {
            button = NSButton(title: title, target: target, action: action)
        }
        button.bezelStyle = .rounded
        button.setAccessibilityLabel(title)
        return button
    }

    var query: String { field.stringValue }

    func focus() {
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    /// WKWebView's find API reports only whether there was a match, never how
    /// many, so the status line says what is actually known rather than
    /// inventing "3 of 12".
    func report(found: Bool) {
        status.stringValue = field.stringValue.isEmpty ? ""
            : (found ? "" : "Not found")
    }

    @objc private func searchChanged() { onSearch(field.stringValue, true) }
    @objc private func findNext() { onSearch(field.stringValue, true) }
    @objc private func findPrevious() { onSearch(field.stringValue, false) }
    @objc private func dismiss() { onDismiss() }

    /// Esc closes the bar, the way every other find bar on the platform does.
    override func cancelOperation(_ sender: Any?) { onDismiss() }
}

// MARK: - Sidebar

/// The vertical document list: every file opened this session, newest first.
///
/// Hidden by default, and built the first time it is revealed rather than at
/// launch — the whole point of the AppKit lifecycle here is that nothing
/// optional runs before first paint.
final class SidebarView: NSView {

    static let preferredWidth: CGFloat = 228

    /// What the list is showing. Two things are worth navigating from here —
    /// the other files of the run, and the headings of this one — and a
    /// segmented control is cheaper than two panes for a 228pt column.
    enum Mode: Int {
        case documents, outline
    }

    private weak var controller: DocumentWindowController?
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let modeControl = NSSegmentedControl()
    private var documents: [URL] = []
    private var outline: [OutlineItem] = []
    private var mode: Mode = .documents

    /// Set while the table's selection is being changed programmatically, so
    /// reloading the list does not read as the reader picking a document and
    /// reopen the file underneath them.
    private var isSyncingSelection = false

    init(controller: DocumentWindowController) {
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: Self.preferredWidth, height: 400))
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        wantsLayer = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("document"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 34
        tableView.style = .inset
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        modeControl.segmentStyle = .texturedRounded
        modeControl.segmentCount = 2
        modeControl.setLabel("Files", forSegment: 0)
        modeControl.setLabel("Outline", forSegment: 1)
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.translatesAutoresizingMaskIntoConstraints = false

        addSubview(modeControl)
        addSubview(scrollView)

        // Contents keep a fixed width and are anchored to the leading edge,
        // rather than stretching between both edges.
        //
        // The sidebar collapses by clipping — its width constraint goes to 0
        // while clipsToBounds hides what overflows. Pinning a control to both
        // edges instead asks it to be -20pt wide when collapsed, which is
        // unsatisfiable: AppKit logged a conflict on every single launch and
        // recovered by permanently breaking the trailing constraint, so the
        // control's right edge no longer tracked the sidebar once expanded.
        // Fixed width has no such conflict to resolve.
        NSLayoutConstraint.activate([
            modeControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            modeControl.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            modeControl.widthAnchor.constraint(
                equalToConstant: Self.preferredWidth - 20),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.widthAnchor.constraint(equalToConstant: Self.preferredWidth),
            scrollView.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func modeChanged() {
        mode = Mode(rawValue: modeControl.selectedSegment) ?? .documents
        tableView.reloadData()
        syncSelection()
    }

    /// The headings of the document on screen, as `shell.js` found them.
    ///
    /// The page has always sent this on every load and the host has always
    /// thrown it away.
    func setOutline(_ items: [OutlineItem]) {
        let wasShowingOutline = mode == .outline
        outline = items

        // An empty outline would make the segment a dead end, so it is disabled
        // rather than offering a blank list — a document with no headings is
        // ordinary, not an error.
        modeControl.setEnabled(!items.isEmpty, forSegment: 1)
        if items.isEmpty, wasShowingOutline {
            mode = .documents
            modeControl.selectedSegment = 0
        }

        // Reload if the outline is showing *or* was a moment ago. Testing the
        // mode after the fallback above had already changed it meant the one
        // case that most needs a redraw — outline mode, new document with no
        // headings — was the one case that skipped it, leaving the previous
        // document's headings on screen under a list that had switched to
        // Files.
        if wasShowingOutline || mode == .outline {
            tableView.reloadData()
            syncSelection()
        }
    }

    /// Show `documents`, with `selected` highlighted.
    func reload(documents: [URL], selected: URL?) {
        self.documents = documents
        self.selectedDocument = selected
        tableView.reloadData()
        syncSelection()
    }

    private var selectedDocument: URL?

    /// Highlight the row matching the current state, without letting that read
    /// as the reader picking something.
    private func syncSelection() {
        isSyncingSelection = true
        defer { isSyncingSelection = false }

        guard mode == .documents,
              let selectedDocument,
              let row = documents.firstIndex(of: selectedDocument)
        else {
            // Outline rows are jump targets, not a selection: nothing in the
            // document is "selected" just because it is on screen.
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
    }
}

extension SidebarView: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        mode == .documents ? documents.count : outline.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        if mode == .outline {
            return outlineRow(row)
        }

        let url = documents[row]

        let title = NSTextField(labelWithString: url.lastPathComponent)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle

        // The containing folder, because agents write the same handful of names
        // — report.md, summary.md — into different runs, and the file name
        // alone often cannot tell two entries apart.
        let subtitle = NSTextField(labelWithString:
            url.deletingLastPathComponent().lastPathComponent)
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle

        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        return stack
    }

    /// One row of the outline, indented by heading level.
    ///
    /// Indentation rather than a disclosure tree: an outline is read at a
    /// glance to find a section, and a tree adds twist-downs to collapse the
    /// very structure you opened it to see.
    private func outlineRow(_ row: Int) -> NSView {
        let item = outline[row]

        let title = NSTextField(labelWithString: item.title)
        title.lineBreakMode = .byTruncatingTail
        // Top-level headings carry the weight; deeper ones recede, so the shape
        // of the document is legible without reading any of it.
        title.font = .systemFont(ofSize: item.level <= 2 ? 12 : 11,
                                 weight: item.level <= 2 ? .medium : .regular)
        title.textColor = item.level <= 2 ? .labelColor : .secondaryLabelColor

        let stack = NSStackView(views: [title])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        // h1 sits flush; each level indents. Clamped so a stray h6 in a deeply
        // nested document does not push its text off the column entirely.
        let depth = CGFloat(min(max(item.level - 1, 0), 3))
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 8 + depth * 13,
                                        bottom: 2, right: 8)
        return stack
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else { return }
        let row = tableView.selectedRow

        if mode == .outline {
            guard outline.indices.contains(row) else { return }
            controller?.scrollToHeading(id: outline[row].id)

            // Drop the highlight straight away. An outline row is a jump, not a
            // selection: leaving it lit claims the reader is "in" that section,
            // which stops being true the moment they scroll. syncSelection()
            // already said so but only ran on mode changes and list reloads,
            // never on the click itself, so the highlight stuck indefinitely.
            isSyncingSelection = true
            tableView.deselectAll(nil)
            isSyncingSelection = false
            return
        }

        guard documents.indices.contains(row) else { return }
        controller?.open(documents[row])
    }
}
