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

    private(set) var mode: ViewMode = .rendered
    private var lastScrollFraction: Double = 0
    private var blockedCount = 0

    /// Every document opened this session, newest first — the sidebar list.
    private(set) var openDocuments: [URL] = []

    private var sidebarView: SidebarView?
    /// Collapsed to zero rather than hidden, so showing it is one animation.
    private var sidebarWidth: NSLayoutConstraint?
    /// Read-only outside this type: the tests reach the editor through it, and
    /// the editor itself only exposes narrow accessors rather than its text view.
    private(set) var sourceEditor: SourceEditor?
    private var findBar: FindBar?
    private var findBarHeight: NSLayoutConstraint?
    /// Bumped on every search so a stale async result cannot overwrite the
    /// status of a newer one.
    private var findGeneration = 0
    private var toolbarController: DocumentToolbar?
    /// Built the first time Settings is opened, then kept — it is cheap to hold
    /// and reopening should not lose the window's position.
    private var settingsController: SettingsWindowController?

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
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Deliberately NOT .fullSizeContentView.
        //
        // That flag extends the content view up behind the titlebar, and every
        // subview here is pinned to the content view's own top — so the
        // sidebar's Files/Outline control was laid out underneath the traffic
        // lights, overlapping the close and minimise buttons. The titlebar is
        // opaque (below), so nothing was gained by reaching under it in the
        // first place: content up there is simply hidden.
        //
        // Without the flag the content view already starts below the titlebar
        // and toolbar, which is what every constraint in makeContentView()
        // assumes. The alternative — keeping the flag and pinning to the
        // window's contentLayoutGuide — is the same layout with an extra
        // ordering hazard, since those constraints are only valid once the view
        // is installed in the window.
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

        window.delegate = self
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

        // Sits exactly where the web view does and is shown instead of it in
        // source mode, so nothing has to move when the reader toggles.
        let editor = SourceEditor(onDirty: { [weak self] in self?.bufferBecameDirty() })
        editor.translatesAutoresizingMaskIntoConstraints = false
        editor.isHidden = true
        sourceEditor = editor

        webView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(sidebar)
        container.addSubview(find)
        container.addSubview(webView)
        container.addSubview(editor)

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

            editor.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            editor.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            editor.topAnchor.constraint(equalTo: find.bottomAnchor),
            editor.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    /// Open the scratch document and put the caret in it.
    ///
    /// What launching with no file does now. The old behaviour was a page
    /// reading "Open a Markdown or HTML file to begin", which is accurate and
    /// does nothing for someone who opened the app to write something down.
    ///
    /// Falls back to that message only if the scratch file cannot be created —
    /// a full disk, or a sandbox that denies Application Support.
    @objc func openScratchDocument() {
        guard let url = ScratchDocument.url(),
              let ready = try? ScratchDocument.ensure(at: url)
        else {
            showEmptyState()
            return
        }

        open(ready)
        // Straight into the editor: the point is to type, and a blank rendered
        // page would just say the document is empty.
        mode = .source
        render()
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
        // Unsaved edits belong to the document that is open now, so switching
        // has to settle them first.
        //
        // Without this the editor kept the old document's text while `snapshot`
        // became the new one — and a later ⌘S wrote the *old* file's edits into
        // the *new* file's path, destroying a third document that was never
        // touched. The conflict check could not catch it either: it compares
        // the new file against its own fingerprint, which nothing had changed.
        //
        // Guarded here rather than at the call sites, because there are three —
        // the sidebar, ⌘O, and a Finder open while already running — and a
        // fourth would have inherited the bug.
        guard !canSave || url == snapshot?.url else {
            confirmDiscardingEdits { [weak self] proceed in
                guard proceed else { return }
                self?.discardEdits()
                self?.open(url)
            }
            return
        }

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

            // Clear the outline before the new document loads. Its headings
            // arrive asynchronously with the page's own "ready", so until then
            // the pane would still be showing the previous document's — and
            // because synthetic ids are positional (agentia-h0, h1, …), a click
            // in that window would not fail, it would silently jump to an
            // unrelated heading that happens to sit at the same index.
            sidebarView?.setOutline([])

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

    /// The text the reader is actually looking at.
    ///
    /// `snapshot.source` is the bytes that were read from disk. The moment the
    /// editor holds unsaved changes those are two different documents, and
    /// everything downstream — the rendered page, the outline, the diff — wants
    /// this one.
    ///
    /// Rendering the disk copy instead is what showed a scratchpad the reader
    /// had just typed into as "This document is empty.": the file was still the
    /// empty one `ScratchDocument.ensure` created, and their text only existed
    /// in the editor. Switching to the rendered view is how you check what you
    /// wrote, so this made the feature useless exactly when it was wanted.
    ///
    /// Safe to read unconditionally: `isDirty` is cleared on load, on save and
    /// on discard, and `open(_:)` refuses to switch documents while it is set,
    /// so a dirty buffer always belongs to `snapshot`.
    var currentSource: String {
        if let sourceEditor, sourceEditor.isDirty { return sourceEditor.text }
        return snapshot?.source ?? ""
    }

    private func render() {
        guard let snapshot, let shell, let theme else { return }
        // Read once: it copies the editor's buffer, and the diff below wants the
        // same text the page is about to be built from.
        let source = currentSource

        let bootstrap = RenderShell.Bootstrap(
            diffRanges: diffRanges(against: source),
            scrollFraction: lastScrollFraction,
            diffSince: mode == .diff ? baselineTakenAt : nil,
            // The host decides whether the page may render math: the
            // document must contain math-shaped delimiters and the user
            // must not have switched rendering off.
            math: Preferences.renderMath && MathDetection.present(in: source)
        )

        let content: String
        let profile: RenderProfile

        switch mode {
        case .source:
            // Source mode is a real editor, not a rendered page — see
            // SourceEditor. Loading only when the buffer is clean is what stops
            // an unrelated re-render (a theme change, a text-size step) from
            // throwing away what the reader has typed.
            if let sourceEditor {
                if !sourceEditor.isDirty { sourceEditor.load(snapshot.source) }
                sourceEditor.applyFontScale(Preferences.fontScale)
                showEditor(true)
            }
            return

        case .rendered, .diff:
            showEditor(false)

            // An HTML artifact is served as its own document: no shell, no
            // theme, no injected script. Nothing below applies to it, so this
            // returns rather than falling through — and it asks AgentiaCore
            // rather than deciding here, so the app and the core renderer
            // cannot disagree about which documents are served raw.
            if let standalone = DocumentRenderer.standalonePage(for: snapshot,
                                                               source: source) {
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
                if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    content = emptyState("This document is empty.")
                } else {
                    content = (try? MarkdownRenderer.renderHTML(source))
                        ?? emptyState("This document could not be rendered.")
                }
            case .html:
                content = source
            case .plainText:
                content = "<pre><code>" + escapeHTML(source) + "</code></pre>"
            }
            profile = snapshot.kind.renderProfile
        }

        guard let page = try? shell.page(
            content: content,
            theme: theme,
            title: snapshot.displayName,
            appearance: Preferences.appearance,
            profile: profile,
            bootstrap: bootstrap,
            display: RenderShell.Display(fontScale: Preferences.fontScale)
        ) else { return }

        webView.load(page: page, assetRoot: snapshot.assetRoot, profile: profile)
    }

    private func emptyState(_ message: String) -> String {
        "<p class=\"agentia-empty\">\(escapeHTML(message))</p>"
    }

    /// Takes the text rather than reading `currentSource` again: the caller has
    /// it, and reading it once more copies the whole editor buffer for nothing.
    private func diffRanges(against source: String) -> [DiffRange]? {
        guard mode == .diff,
              snapshot != nil,
              let previous = previousSource else { return nil }
        // Against the editor's text when it is dirty, for the same reason the
        // rendered view uses it: a diff that ignores what the reader just typed
        // is a diff of a document nobody is looking at.
        let ranges = DiffEngine.changes(from: previous, to: source)
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
        setSidebarVisible(!isSidebarShowing)
    }

    /// Show or hide the sidebar.
    ///
    /// `animated: false` exists for the tests, which lay the window out and read
    /// frames back synchronously — an in-flight animation would have them
    /// measuring a sidebar that is part-way open.
    func setSidebarVisible(_ visible: Bool, animated: Bool = true) {
        guard let sidebarWidth, let sidebarView else { return }
        guard visible != isSidebarShowing else { return }
        let willShow = visible
        Preferences.sidebarVisible = willShow

        if willShow {
            // Populate only on the way in — a reader who never opens it pays
            // nothing — and unhide before animating so it fades in with width.
            refreshSidebar()
            sidebarView.isHidden = false
        }

        let target = willShow ? SidebarView.preferredWidth : 0

        // Hidden once collapsed, not merely zero-width. A zero-width table stays
        // in the key-view loop, so a Tab could focus it and its arrow keys would
        // swap the document with no visible sidebar to explain why.
        let settle = { [weak self] in
            if !willShow { self?.sidebarView?.isHidden = true }
        }

        guard animated else {
            sidebarWidth.constant = target
            window?.contentView?.layoutSubtreeIfNeeded()
            settle()
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.allowsImplicitAnimation = true
            sidebarWidth.animator().constant = target
            window?.contentView?.layoutSubtreeIfNeeded()
        }, completionHandler: settle)
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

        // A PDF is always of the rendered document — that is what the themes
        // and the print CSS are for. Exporting from source mode used to print
        // the hidden web view, which could still be showing the pre-edit page.
        if mode != .rendered {
            mode = .rendered
            render()
        }
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

    private func showEditor(_ editing: Bool) {
        sourceEditor?.isHidden = !editing
        webView.isHidden = editing
        if editing { sourceEditor?.focus() }
    }

    /// The reader has typed something. Stop watching the file.
    ///
    /// The watcher exists so a rerun by an agent appears immediately, and that
    /// is exactly wrong once there are unsaved edits: reloading would discard
    /// them with no way back. Watching resumes after a save, when the buffer
    /// and the file agree again.
    private func bufferBecameDirty() {
        watcher?.stop()
        watcher = nil
        updateSaveState()
    }

    /// Whether ⌘S has anything to do.
    var canSave: Bool { sourceEditor?.isDirty == true && snapshot != nil }

    private func updateSaveState() {
        let dirty = sourceEditor?.isDirty == true
        // The dot in the close button, the way every document app shows it.
        window?.isDocumentEdited = dirty
        holdTermination(dirty)
    }

    /// Whether the process is currently holding off termination. Both
    /// ProcessInfo calls are counted, so this has to be balanced exactly.
    private(set) var isHoldingTermination = false

    /// Stop macOS from killing the process outright while there are unsaved
    /// edits.
    ///
    /// Info.plist opts into both sudden and automatic termination — which was
    /// free when this app could only display documents, and is not now that it
    /// holds text that exists nowhere else. Sudden termination is a promise that
    /// the process can be SIGKILLed at any moment; nothing runs when it is
    /// taken up, so `applicationShouldTerminate` never asks about unsaved edits
    /// and the buffer is simply gone. The reader's evidence would be an app that
    /// vanished, with no crash report, because from the system's point of view
    /// nothing went wrong.
    ///
    /// These two calls are the API for exactly this, and the keys stay on: a
    /// viewer with nothing unsaved *should* be cheap for the system to reclaim.
    private func holdTermination(_ hold: Bool) {
        guard hold != isHoldingTermination else { return }
        isHoldingTermination = hold

        let process = ProcessInfo.processInfo
        if hold {
            process.disableSuddenTermination()
            process.disableAutomaticTermination(Self.terminationReason)
        } else {
            process.enableSuddenTermination()
            process.enableAutomaticTermination(Self.terminationReason)
        }
    }

    private static let terminationReason = "unsaved edits"

    @objc func saveDocument(_ sender: Any?) {
        guard let snapshot, let sourceEditor, sourceEditor.isDirty else { return }

        // Has anything rewritten the file since it was read? The decision lives
        // in AgentiaCore so it can be tested; this is only the wiring.
        let now = DocumentSaving.currentBytes(of: snapshot.url)
        let verdict = DocumentSaving.verdict(
            recordedBytes: snapshot.bytesOnDisk,
            currentBytes: now.bytes,
            fileExists: now.exists
        )

        switch verdict {
        case .safe:
            write(sourceEditor.text, to: snapshot.url)

        case .changedOnDisk:
            // The case this app makes likely: an agent rewrote the report while
            // it was open. Neither side is obviously right, so ask — and make
            // the destructive option the one that has to be chosen.
            confirm(
                title: "This file changed on disk",
                message: """
                \(snapshot.displayName) was rewritten after you opened it — \
                probably by whatever produced it.

                Saving replaces those changes with what is in the editor.
                """,
                destructive: "Overwrite",
                alternative: "Reload and Lose My Edits"
            ) { [weak self] choice in
                guard let self else { return }
                switch choice {
                case .destructive: self.write(sourceEditor.text, to: snapshot.url)
                case .alternative: self.reloadDiscardingEdits()
                case .cancel: break
                }
            }

        case .missing:
            confirm(
                title: "This file no longer exists",
                message: """
                \(snapshot.displayName) was moved or deleted. Saving writes it \
                back to where it was.
                """,
                destructive: "Save Anyway",
                alternative: nil
            ) { [weak self] choice in
                if choice == .destructive {
                    self?.write(sourceEditor.text, to: snapshot.url)
                }
            }
        }
    }

    private func write(_ text: String, to url: URL) {
        // Named `current` so it does not shadow the `snapshot` property, which
        // the re-read below reassigns.
        guard let current = snapshot else { return }

        // Written back in the encoding it was read in, BOM included. Saving an
        // untouched Latin-1 file as UTF-8, or dropping a BOM, rewrites a file
        // the reader never edited — and the text on screen looks identical
        // either way, so nothing would tell them.
        guard let data = current.format.encode(text) else {
            let alert = NSAlert()
            alert.messageText = "Can't save as \(current.format.displayName)"
            alert.informativeText = """
            This document contains characters that \(current.format.displayName) \
            cannot represent — most likely something typed or pasted just now.

            Saving would silently drop them.
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        }

        // Resolve symlinks first. An atomic write is a write-then-rename, and
        // renaming over a symlink replaces the *link* with a regular file:
        // measured, the link stopped pointing anywhere and the real file kept
        // its old contents, so the edits went somewhere nothing referenced.
        // Resolving keeps both the atomicity and the link.
        let destination = URL(fileURLWithPath:
            (url.path as NSString).resolvingSymlinksInPath)

        // An atomic write is a write-then-rename, which needs permission on the
        // *directory*, not the file — so a file the reader deliberately marked
        // read-only saved anyway, silently. Checked explicitly rather than left
        // to fail, because it never fails.
        if FileManager.default.fileExists(atPath: destination.path),
           !FileManager.default.isWritableFile(atPath: destination.path) {
            confirm(
                title: "This file is marked read-only",
                message: """
                \(destination.lastPathComponent) has its permissions set to \
                read-only. Saving changes it anyway.
                """,
                destructive: "Save Anyway",
                alternative: nil
            ) { [weak self] choice in
                guard choice == .destructive else { return }
                self?.performWrite(data, to: destination, url: url)
            }
            return
        }

        performWrite(data, to: destination, url: url)
    }

    private func performWrite(_ data: Data, to destination: URL, url: URL) {
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            presentError(error, whileOpening: destination)
            return
        }

        // Re-read rather than patching the snapshot by hand: this picks up the
        // new modification date and size, so the next save compares against
        // what was actually written.
        if let fresh = try? DocumentRenderer.read(contentsOf: url) {
            // The diff baseline is cleared, not advanced. Diff means "what
            // changed since the last run", and the reader's own edit is not
            // that — arming it here showed them their own typing as though an
            // agent had rewritten the file, with a timestamp to match. It comes
            // back on the next external write, which is what it is for.
            previousSource = nil
            baselineTakenAt = nil
            if mode == .diff { mode = .rendered }
            snapshot = fresh
        }

        sourceEditor?.markSaved()
        updateSaveState()
        startWatching(url)   // safe to watch again: buffer and file agree

        // Re-render, or the rendered view keeps showing the pre-edit document
        // after a save made from it. Skipped in source mode: the editor already
        // holds exactly what was written, and reloading it there would throw
        // away the caret and scroll position for no visible gain.
        if mode != .source { render() }
    }

    /// Ask before losing unsaved edits, and report whether it is safe to go on.
    ///
    /// Called from the two places edits can be discarded without meaning to:
    /// closing the window and quitting. `completion(true)` means proceed.
    func confirmDiscardingEdits(completion: @escaping (Bool) -> Void) {
        guard canSave, let snapshot else {
            completion(true)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Save changes to \(snapshot.displayName)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        // Destructive, so it does not sit under the return key.
        alert.buttons[1].hasDestructiveAction = true

        let route: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else {
                completion(false)
                return
            }
            switch response {
            case .alertFirstButtonReturn:
                self.saveDocument(nil)
                // Only proceed if the save actually finished. A save that hit a
                // conflict has put its own sheet up and the buffer is still
                // dirty; closing now would discard the edits the reader just
                // asked to keep. They resolve that sheet and close again.
                completion(!self.canSave)
            case .alertSecondButtonReturn:
                completion(true)   // Don't Save
            default:
                completion(false)  // Cancel
            }
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: route)
        } else {
            route(alert.runModal())
        }
    }

    private func reloadDiscardingEdits() {
        guard let url = snapshot?.url else { return }
        sourceEditor?.markSaved()
        updateSaveState()
        open(url)
    }

    private enum ConfirmChoice { case destructive, alternative, cancel }

    private func confirm(
        title: String,
        message: String,
        destructive: String,
        alternative: String?,
        then handle: @escaping (ConfirmChoice) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: destructive)
        if let alternative { alert.addButton(withTitle: alternative) }
        alert.addButton(withTitle: "Cancel")

        let route: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn: handle(.destructive)
            case .alertSecondButtonReturn: handle(alternative == nil ? .cancel : .alternative)
            default: handle(.cancel)
            }
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: route)
        } else {
            route(alert.runModal())
        }
    }

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
        // Source mode is a text view, not the web view — searching the latter
        // would search something hidden, and possibly stale.
        if mode == .source, let sourceEditor {
            findBar?.report(found: sourceEditor.find(query, forward: forward))
            return
        }

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

    /// Scroll the document to a heading the outline names.
    ///
    /// The script is built in AgentiaCore.PageScript, where its escaping is
    /// tested — the id comes from the document, and this runs with the host's
    /// authority.
    func scrollToHeading(id: String) {
        // The outline describes the rendered document, so jumping to a heading
        // means going back to it. Previously this ran against a hidden web view
        // and appeared to do nothing.
        if mode != .rendered {
            mode = .rendered
            render()
        }
        guard let script = PageScript.scrollToElement(id: id) else { return }
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Every theme in the bundle, for the menu and the Settings window.
    var availableThemes: [Theme] { themes }
    var currentThemeID: String? { theme?.id }

    @objc func showSettings(_ sender: Any?) {
        if settingsController == nil {
            settingsController = SettingsWindowController(
                themes: themes,
                onChange: { [weak self] themeID, _ in
                    // Both preferences are already stored; re-render picks up
                    // the font scale, and selectTheme swaps the stylesheet.
                    self?.selectTheme(id: themeID)
                }
            )
        }
        settingsController?.syncFromPreferences()
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Steps the reader's text size, keeping to the same ladder the Settings
    /// slider snaps to so the two cannot disagree.
    @objc func increaseFontSize(_ sender: Any?) { stepFontSize(by: +1) }
    @objc func decreaseFontSize(_ sender: Any?) { stepFontSize(by: -1) }

    @objc func resetFontSize(_ sender: Any?) {
        Preferences.fontScale = 1.0
        settingsController?.syncFromPreferences()
        render()
    }

    private func stepFontSize(by delta: Int) {
        let steps = Preferences.fontScaleSteps
        let current = Preferences.fontScale
        let index = steps.enumerated()
            .min { abs($0.element - current) < abs($1.element - current) }?.offset ?? 3
        let next = min(max(index + delta, 0), steps.count - 1)
        guard steps[next] != current else { return }

        Preferences.fontScale = steps[next]
        settingsController?.syncFromPreferences()
        render()
    }

    @objc func selectThemeFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        selectTheme(id: id)
        settingsController?.syncFromPreferences()
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

// MARK: - Closing

extension DocumentWindowController: NSWindowDelegate {

    /// Closing with unsaved edits asks first.
    ///
    /// Returns false and closes later: the prompt is a sheet, so the answer
    /// arrives after this method has already had to return.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard canSave else { return true }
        confirmDiscardingEdits { [weak sender] proceed in
            guard proceed, let sender else { return }
            // markSaved first, or this returns false again and loops.
            self.discardEdits()
            sender.close()
        }
        return false
    }

    /// Drop unsaved edits without writing them, for the paths where the reader
    /// has explicitly chosen to lose them.
    func discardEdits() {
        sourceEditor?.markSaved()
        updateSaveState()
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
        case #selector(saveDocument(_:)):
            // Nothing to save unless the reader has actually edited something.
            return canSave
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
        case .ready(let outline, _):
            Launch.reportFirstPaint()
            // The page has always sent this; it used to be discarded.
            sidebarView?.setOutline(outline)

        case .scroll(let fraction):
            // Remembered so a live reload lands where the reader was.
            lastScrollFraction = fraction

        case .copy(let text):
            Clipboard.writePlain(text)

        case .openExternal(let url):
            // Every producer now routes through NavigationPolicy before emitting
            // this, so the scheme is already an allowlisted one. Re-checked here
            // anyway: this is the single call to NSWorkspace.open, and it must
            // never be reached by a file:// or smb:// URL regardless of how the
            // message was produced.
            guard let scheme = url.scheme?.lowercased(),
                  NavigationPolicy.externallyOpenableSchemes.contains(scheme) else { return }
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
