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
    private var watcher: FileWatcher?

    private var mode: ViewMode = .rendered
    private var lastScrollFraction: Double = 0
    private var blockedCount = 0

    /// Every document opened this session, newest first — the sidebar list.
    private(set) var openDocuments: [URL] = []

    private var sidebarView: NSView?
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

        webView.autoresizingMask = [.width, .height]
        window.contentView = webView

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
                lastScrollFraction = 0
                mode = .rendered
            }

            self.snapshot = snapshot
            if !openDocuments.contains(url) {
                openDocuments.insert(url, at: 0)
            }

            startWatching(url)
            render()

            window?.title = snapshot.displayName
            window?.representedURL = url

        } catch {
            presentError(error, whileOpening: url)
        }
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
        snapshot = fresh
        render()
    }

    // MARK: - Rendering

    private func render() {
        guard let snapshot, let shell, let theme else { return }

        let bootstrap = RenderShell.Bootstrap(
            diffRanges: diffRangesForCurrentMode(),
            scrollFraction: lastScrollFraction
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
        guard previousSource != nil else {
            NSSound.beep() // nothing to compare against yet
            return
        }
        mode = (mode == .diff) ? .rendered : .diff
        render()
    }

    @objc func toggleSidebar(_ sender: Any?) {
        // Built lazily: hidden by default means it must not cost anything at
        // launch.
        if sidebarView == nil {
            sidebarView = SidebarView(controller: self)
        }
        sidebarView?.isHidden.toggle()
    }

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

    @objc func revealInFinder(_ sender: Any?) {
        guard let url = snapshot?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// In-page find. WKWebView's own implementation highlights inside the
    /// rendered page rather than the source, which is what a reader wants.
    ///
    /// Not yet wired to a find bar — this is the plumbing, and the UI lands
    /// with the sidebar in Phase 3.
    @objc func performFind(_ sender: Any?) {
        window?.makeFirstResponder(webView)
    }

    func find(_ query: String, forward: Bool = true) {
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.caseSensitive = false
        configuration.wraps = true
        webView.find(query, configuration: configuration) { _ in }
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
            // An artifact never navigates itself; links go to the browser.
            guard let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" || scheme == "mailto" else { return }
            NSWorkspace.shared.open(url)
        }
    }

    func webView(_ view: HardenedWebView, didBlockRequestCountChange count: Int) {
        blockedCount = count
        toolbarController?.updateBlockedCount(count)
    }
}
