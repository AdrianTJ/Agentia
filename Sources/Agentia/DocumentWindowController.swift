import AppKit
import WebKit
import AgentiaCore

/// The single document window: toolbar, hidden-by-default sidebar, web view.
///
/// Deliberately not SwiftUI. The sidebar is hidden by default, so its hosting
/// view is only built the first time it is shown and never touches the launch
/// path.
final class DocumentWindowController: NSWindowController {

    enum ViewMode {
        case rendered
        case source
        case diff
    }

    private let webView: HardenedWebView
    private var shell: RenderShell?
    private var themes: [Theme] = []
    private var theme: Theme?

    private var snapshot: DocumentSnapshot?
    /// The contents as of the previous write, kept in memory so "what changed"
    /// costs nothing extra — the watcher is already running.
    private var previousSource: String?
    /// Formatted time the baseline was captured, for the diff banner.
    private var baselineTakenAt: String?
    private var watcher: FileWatcher?

    private var mode: ViewMode = .rendered
    private var lastScrollFraction: Double = 0
    private var blockedCount = 0

    /// Every document opened this session, newest first — the sidebar list.
    private(set) var openDocuments: [URL] = []

    private var sidebarView: SidebarView?
    /// Collapsed to zero rather than hidden, so showing it is one animation.
    private var sidebarWidth: NSLayoutConstraint?
    private var findBar: FindBar?
    private var findBarHeight: NSLayoutConstraint?
    /// Bumped on every search so a stale async result cannot overwrite the
    /// status of a newer one.
    private var findGeneration = 0
    private var toolbarController: DocumentToolbar?

    init(webView: HardenedWebView) {
        self.webView = webView
        super.init(window: nil)
        webView.pageDelegate = self

        // Resource loading is cheap but not free; do it once, off the critical
        // path of each open.
        shell = try? RenderShell.bundled()
        themes = (try? ThemeStore.bundled().loadAll()) ?? []
        theme = themes.first { $0.id == Preferences.themeID } ?? themes.first

        // Built here rather than in a loadWindow() override, because
        // NSWindowController.init(window:) marks the window as already loaded —
        // even when what it was handed is nil. The nib-loading path is then
        // never entered: loadWindow() is not called, loadWindowIfNeeded() sees
        // a loaded controller and returns, `window` stays nil forever, and
        // showWindow(_:) silently does nothing. The app launched, rendered, and
        // reported first paint with no window on screen — while still taking
        // over the menu bar as the frontmost app.
        //
        // The window has to be assigned after super.init in any case, because
        // the toolbar delegate needs self.
        self.window = makeWindow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Window

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 520, height: 380)

        // The app now outlives its window (see
        // applicationShouldTerminateAfterLastWindowClosed), so closing must not
        // deallocate it — the Dock-icon reopen path shows this same window
        // again, with the document still loaded in the web view.
        window.isReleasedWhenClosed = false

        // A single-window viewer that manages and autosaves its own frame has
        // no use for macOS state restoration, and leaving it on would let the
        // system restore a window on relaunch that then fights this app's own
        // frame autosave and Dock-icon reopen. (Note: there is also a 500×500
        // off-screen window in the process — that one is a WebKit-internal host
        // window, not restoration, and is not removed by this. It is invisible
        // and unlisted, so it is left alone.)
        window.isRestorable = false

        window.contentView = makeContentView()

        let toolbar = DocumentToolbar(target: self)
        window.toolbar = toolbar.makeToolbar()
        toolbarController = toolbar

        // Centre before adopting the autosave name, so the first-ever launch
        // opens in the middle of the screen rather than in the bottom-left
        // corner the contentRect above would otherwise put it in. Once a frame
        // has been saved, setFrameAutosaveName restores it and this is a no-op.
        window.center()
        window.setFrameAutosaveName("AgentiaDocumentWindow")

        return window
    }

    /// The window's content: an optional sidebar beside the document.
    ///
    /// Auto Layout with a collapsible width constraint rather than an
    /// NSSplitView. A split view brings a divider the reader can drag to zero,
    /// a delegate to keep it from doing so, and autosaved positions that then
    /// disagree with the toolbar button's idea of whether the sidebar is
    /// showing. One constraint has none of that.
    private func makeContentView() -> NSView {
        let container = NSView()

        let sidebar = SidebarView(controller: self)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebarView = sidebar

        let find = FindBar(
            onSearch: { [weak self] query, forward in
                self?.runFind(query, forward: forward)
            },
            onDismiss: { [weak self] in self?.hideFindBar() }
        )
        find.translatesAutoresizingMaskIntoConstraints = false
        findBar = find

        webView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(sidebar)
        container.addSubview(find)
        container.addSubview(webView)

        let findHeight = find.heightAnchor.constraint(equalToConstant: 0)
        findBarHeight = findHeight
        // clipsToBounds defaults differ by macOS version (NO on 14+, YES
        // before), so both collapsible panes pin it rather than rely on the
        // default. Hidden as well as zero-sized, so nothing inside them is in
        // the key-view loop while collapsed — a Tab must not reach a control in
        // a pane the reader cannot see.
        find.clipsToBounds = true
        find.isHidden = true
        sidebar.clipsToBounds = true
        sidebar.isHidden = true

        NSLayoutConstraint.activate([
            find.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            find.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            find.topAnchor.constraint(equalTo: container.topAnchor),
            findHeight,
        ])

        // Hidden at launch: zero width, and clipped so its contents cannot
        // paint outside it while collapsed.
        let width = sidebar.widthAnchor.constraint(equalToConstant: 0)
        sidebarWidth = width

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: container.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            width,

            webView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: find.bottomAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    func showEmptyState() {
        guard let shell, let theme else { return }
        let body = """
        <p class="agentia-empty">Open a Markdown or HTML file to begin.</p>
        """
        if let page = try? shell.page(content: body, theme: theme,
                                      title: "Agentia",
                                      appearance: Preferences.appearance) {
            webView.load(page: page,
                         assetRoot: FileManager.default.temporaryDirectory,
                         profile: .markdown)
        }
    }

    // MARK: - Opening

    func open(_ url: URL) {
        do {
            let snapshot = try DocumentRenderer.read(contentsOf: url)

            // Opening a different document resets the diff baseline: a diff
            // against an unrelated file is noise.
            if self.snapshot?.url != url {
                previousSource = nil
                baselineTakenAt = nil
                lastScrollFraction = 0
                mode = .rendered
            }

            self.snapshot = snapshot
            // Canonicalised before the membership test: the same file reached
            // by a symlink, an alias, or a case-differing path on a
            // case-insensitive volume is one document, not two, and must not
            // produce two rows.
            if !openDocuments.contains(where: { sameFile($0, url) }) {
                openDocuments.insert(url, at: 0)
            }
            // Only costs anything once the reader has opened the sidebar.
            if isSidebarShowing { refreshSidebar() }

            startWatching(url)
            render()

            window?.title = snapshot.displayName
            window?.representedURL = url

        } catch {
            // The sidebar may already have moved its selection to the row the
            // reader clicked — a file since deleted or renamed. Drop it and put
            // the highlight back on the document actually showing, so the list
            // never points at something that is not on screen.
            openDocuments.removeAll { sameFile($0, url) }
            if isSidebarShowing { refreshSidebar() }
            presentError(error, whileOpening: url)
        }
    }

    private var isSidebarShowing: Bool { (sidebarWidth?.constant ?? 0) > 0 }

    private func sameFile(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL
            == b.resolvingSymlinksInPath().standardizedFileURL
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = DocumentTypes.openable
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    private func startWatching(_ url: URL) {
        watcher?.stop()
        watcher = FileWatcher(fileURL: url) { [weak self] in
            self?.reloadFromDisk()
        }
        watcher?.start()
    }

    /// Re-read after the file changed on disk, holding scroll position and
    /// remembering the previous text so the diff view has a baseline.
    private func reloadFromDisk() {
        guard let current = snapshot else { return }
        guard let fresh = try? DocumentRenderer.read(contentsOf: current.url) else { return }

        // No-op writes are common — an agent rewriting an unchanged file, or a
        // touch. Re-rendering for those would flicker for no reason.
        guard fresh.source != current.source else { return }

        previousSource = current.source
        baselineTakenAt = Self.clockFormatter.string(from: current.readAt)
        snapshot = fresh
        render()
    }

    /// Wall-clock time only. The baseline is always from this session — the app
    /// has to be open to have seen the previous write — so a date would be
    /// noise, and "14:22:07" is what a reader matches against their own memory
    /// of when the agent last ran.
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    // MARK: - Rendering

    private func render() {
        guard let snapshot, let shell, let theme else { return }

        let bootstrap = RenderShell.Bootstrap(
            diffRanges: diffRangesForCurrentMode(),
            scrollFraction: lastScrollFraction,
            diffSince: mode == .diff ? baselineTakenAt : nil
        )

        let content: String
        let profile: RenderProfile

        switch mode {
        case .source:
            // Source view is always shown as inert text, whatever the file is.
            content = "<pre><code>"
                + escapeHTML(snapshot.source)
                + "</code></pre>"
            profile = .markdown

        case .rendered, .diff:
            // An HTML artifact is served as its own document: no shell, no
            // theme, no injected script. Nothing below applies to it, so this
            // returns rather than falling through — and it asks AgentiaCore
            // rather than deciding here, so the app and the core renderer
            // cannot disagree about which documents are served raw.
            if let standalone = DocumentRenderer.standalonePage(for: snapshot) {
                webView.load(page: standalone,
                             assetRoot: snapshot.assetRoot,
                             profile: snapshot.kind.renderProfile)
                return
            }

            switch snapshot.kind {
            case .markdown:
                // A whitespace-only file is indistinguishable from an empty
                // one after parsing, so catch it before rendering and show the
                // empty state rather than a blank page. A render failure (an
                // oversized input, a nesting bomb) must say so rather than
                // silently blanking the window.
                if snapshot.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    content = emptyState("This document is empty.")
                } else {
                    content = (try? MarkdownRenderer.renderHTML(snapshot.source))
                        ?? emptyState("This document could not be rendered.")
                }
            case .html:
                content = snapshot.source
            case .plainText:
                content = "<pre><code>" + escapeHTML(snapshot.source) + "</code></pre>"
            }
            profile = snapshot.kind.renderProfile
        }

        guard let page = try? shell.page(
            content: content,
            theme: theme,
            title: snapshot.displayName,
            appearance: Preferences.appearance,
            profile: profile,
            bootstrap: bootstrap
        ) else { return }

        webView.load(page: page, assetRoot: snapshot.assetRoot, profile: profile)
    }

    private func emptyState(_ message: String) -> String {
        "<p class=\"agentia-empty\">\(escapeHTML(message))</p>"
    }

    private func diffRangesForCurrentMode() -> [DiffRange]? {
        guard mode == .diff,
              let snapshot,
              let previous = previousSource else { return nil }
        let ranges = DiffEngine.changes(from: previous, to: snapshot.source)
        return ranges.isEmpty ? nil : ranges
    }

    private func escapeHTML(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default:  out.append(character)
            }
        }
        return out
    }

    // MARK: - Actions

    @objc func toggleSource(_ sender: Any?) {
        mode = (mode == .source) ? .rendered : .source
        render()
    }

    @objc func toggleDiff(_ sender: Any?) {
        // Unreachable without a baseline: the menu item and toolbar button are
        // disabled until the file has been rewritten once. It used to beep
        // instead, which told the reader they had done something wrong rather
        // than that the feature was not available yet.
        guard canShowDiff else { return }
        mode = (mode == .diff) ? .rendered : .diff
        render()
    }

    /// A diff needs something to compare against, which only exists once the
    /// file has changed on disk while open.
    var canShowDiff: Bool {
        previousSource != nil && snapshot?.kind != .html
    }

    @objc func toggleSidebar(_ sender: Any?) {
        guard let sidebarWidth, let sidebarView else { return }
        let willShow = sidebarWidth.constant == 0

        if willShow {
            // Populate only on the way in — a reader who never opens it pays
            // nothing — and unhide before animating so it fades in with width.
            refreshSidebar()
            sidebarView.isHidden = false
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.allowsImplicitAnimation = true
            sidebarWidth.animator().constant = willShow ? SidebarView.preferredWidth : 0
            window?.contentView?.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            // Hidden once collapsed, not merely zero-width. A zero-width table
            // stays in the key-view loop, so a Tab could focus it and its
            // arrow keys would swap the document with no visible sidebar to
            // explain why.
            if !willShow { self?.sidebarView?.isHidden = true }
        })
    }

    /// Keep the list in step with what has been opened.
    ///
    /// Only called when the sidebar is about to be shown or is already showing,
    /// so a reader who never opens it pays nothing.
    private func refreshSidebar() {
        guard let sidebarView, sidebarWidth != nil else { return }

        // The folder the current document lives in, not the session's history.
        // An agent writes a run — report, summary, dashboard — into one
        // directory, and moving between those is the navigation this is for;
        // the history is a list of things already read. Falls back to the
        // history when nothing is open.
        let documents: [URL]
        if let root = snapshot?.assetRoot {
            let folder = FolderScanner.documents(in: root)
            documents = folder.isEmpty ? openDocuments : folder
        } else {
            documents = openDocuments
        }

        sidebarView.reload(documents: documents, selected: snapshot?.url)
    }

    var isSidebarImplemented: Bool { true }

    @objc func copyAll(_ sender: Any?) {
        guard let snapshot else { return }
        Clipboard.write(source: snapshot.source, kind: snapshot.kind)
    }

    @objc func exportPDF(_ sender: Any?) {
        guard let snapshot, let theme else { return }
        let settings = PDFExporter.Settings.from(theme: theme,
                                                 documentName: snapshot.displayName)
        let suggested = snapshot.url.deletingPathExtension().lastPathComponent + ".pdf"

        PDFExporter.export(from: webView, settings: settings,
                           suggestedName: suggested, in: window) { [weak self] result in
            if case .failure(let error) = result,
               (error as? PDFExporter.Failure) != .cancelled {
                self?.presentError(error, whileOpening: nil)
            }
        }
    }

    /// The document on disk, for the routes that hand a file to another app.
    var documentURL: URL? { snapshot?.url }

    /// The system share sheet: Mail, Messages, AirDrop, Notes and every
    /// installed share extension, without Agentia knowing about any of them.
    ///
    /// Shares the file rather than the rendered text, so the recipient gets
    /// something they can open — and so nothing has to decide which of the
    /// document's representations to send.
    @objc func shareDocument(_ sender: Any?) {
        guard let url = documentURL else { return }

        let picker = NSSharingServicePicker(items: [url])
        let anchor: NSView? = (sender as? NSView)
            ?? (sender as? NSToolbarItem)?.view
            ?? window?.contentView

        guard let anchor else { return }
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let url = snapshot?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// In-page find. WKWebView's own implementation highlights inside the
    /// rendered page rather than the source, which is what a reader wants.
    @objc func performFind(_ sender: Any?) {
        guard let findBarHeight, let findBar else { return }
        findBar.isHidden = false
        findBarHeight.constant = FindBar.preferredHeight
        window?.contentView?.layoutSubtreeIfNeeded()
        findBar.focus()
    }

    private func hideFindBar() {
        guard let findBarHeight else { return }
        findBarHeight.constant = 0
        findBar?.isHidden = true
        window?.contentView?.layoutSubtreeIfNeeded()
        // Clearing the highlight matters: leaving the page speckled with
        // matches after the bar is gone looks like rendering damage.
        webView.find("", configuration: WKFindConfiguration()) { _ in }
        window?.makeFirstResponder(webView)
    }

    private func runFind(_ query: String, forward: Bool) {
        // Clearing the field must clear the highlight, not just the status.
        // Otherwise backspacing a matched query to empty leaves the document
        // speckled with matches until the bar is dismissed — the same "looks
        // like rendering damage" the dismiss path already guards against.
        guard !query.isEmpty else {
            webView.find("", configuration: WKFindConfiguration()) { _ in }
            findBar?.report(found: true)
            return
        }

        // WKWebView.find is async and fired per keystroke, so a slow older
        // search can resolve after a newer one and paint a stale "Not found"
        // for a query the reader has already moved past. Only the newest
        // request is allowed to touch the status line.
        findGeneration += 1
        let generation = findGeneration
        find(query, forward: forward) { [weak self] found in
            guard let self, generation == self.findGeneration else { return }
            self.findBar?.report(found: found)
        }
    }

    func find(
        _ query: String,
        forward: Bool = true,
        completion: ((Bool) -> Void)? = nil
    ) {
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.caseSensitive = false
        configuration.wraps = true
        webView.find(query, configuration: configuration) { result in
            completion?(result.matchFound)
        }
    }

    @objc func allowNetworkForDocument(_ sender: Any?) {
        webView.allowNetworkForCurrentDocument()
    }

    func selectTheme(id: String) {
        guard let picked = themes.first(where: { $0.id == id }) else { return }
        theme = picked
        Preferences.themeID = id
        render()
    }

    // MARK: - Errors

    private func presentError(_ error: Swift.Error, whileOpening url: URL?) {
        let alert = NSAlert()
        alert.messageText = url.map { "Could not open \($0.lastPathComponent)" }
            ?? "Something went wrong"
        alert.informativeText = String(describing: error)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - Enabling and disabling commands

/// One place decides whether a command is available, and both the menu and the
/// toolbar ask it. Without this the app offered every command at all times:
/// Export PDF with no document open, Toggle Diff with nothing to compare
/// against, and a Documents button wired to a sidebar that does not exist yet.
extension DocumentWindowController: NSMenuItemValidation, NSToolbarItemValidation {

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        isEnabled(item.action)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        isEnabled(item.action)
    }

    private func isEnabled(_ action: Selector?) -> Bool {
        switch action {
        case #selector(toggleSidebar(_:)):
            return isSidebarImplemented
        case #selector(toggleDiff(_:)):
            return canShowDiff
        case #selector(exportPDF(_:)), #selector(copyAll(_:)),
             #selector(revealInFinder(_:)), #selector(performFind(_:)),
             #selector(shareDocument(_:)):
            return snapshot != nil
        case #selector(toggleSource(_:)):
            // Source view works for anything, including an HTML artifact — it
            // is the one way to read an artifact's markup rather than run it.
            return snapshot != nil
        default:
            // Open, Close, Quit and anything else the responder chain handles.
            return true
        }
    }
}

// MARK: - Page messages

extension DocumentWindowController: HardenedWebViewDelegate {

    func webView(_ view: HardenedWebView, didReceive message: PageMessage) {
        switch message {
        case .ready:
            Launch.reportFirstPaint()

        case .scroll(let fraction):
            // Remembered so a live reload lands where the reader was.
            lastScrollFraction = fraction

        case .copy(let text):
            Clipboard.writePlain(text)

        case .openExternal(let url):
            // Scheme filtering happened in NavigationPolicy; by here the URL is
            // one a browser should get.
            NSWorkspace.shared.open(url)

        case .confirmOpenExternal(let url):
            confirmOpenExternal(url)
        }
    }

    /// Show the reader where a link goes before leaving the app.
    ///
    /// Only artifacts reach here, and only because they can script: WebKit
    /// classifies `anchor.click()` from a document's own code as a link
    /// activation, indistinguishable from a real one. Opening it silently would
    /// let an artifact put document text in a query string and hand it to the
    /// browser — an exfiltration channel that never touches the web view, so
    /// neither `connect-src 'none'` nor the content rule list would see it.
    ///
    /// The whole URL is shown, not a shortened form: the query string is the
    /// part worth reading.
    private func confirmOpenExternal(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Open this link in your browser?"
        alert.informativeText = """
        This document asked to open:

        \(url.absoluteString)

        It can run its own code, so this may not have come from your click.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")

        let open: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            NSWorkspace.shared.open(url)
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: open)
        } else {
            open(alert.runModal())
        }
    }

    func webView(_ view: HardenedWebView, didBlockRequestCountChange count: Int) {
        blockedCount = count
        toolbarController?.updateBlockedCount(count)
    }
}
