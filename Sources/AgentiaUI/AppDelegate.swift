import AppKit
import WebKit
import os
import AgentiaCore

/// Launch instrumentation for the Phase 0 measurement.
///
/// The whole architecture rests on a number nobody has published: how long a
/// WKWebView-backed app takes from a Finder double-click to first paint on
/// modern macOS. These signposts are how that gets measured rather than
/// assumed. View with Instruments, or:
///
///     log stream --predicate 'subsystem == "app.agentia"' --style compact
enum Launch {
    static let log = OSLog(subsystem: "app.agentia", category: .pointsOfInterest)
    static let signposter = OSSignposter(logHandle: log)

    static var processStart = Date()
    static var didLogFirstPaint = false

    static func mark(_ name: StaticString) {
        os_signpost(.event, log: log, name: name)
    }

    /// Reports milliseconds from process start, once, on first paint.
    ///
    /// This fires from the page's `ready` message, which the page only sends
    /// once its inline script runs. WebKit throttles the script of a fully
    /// occluded window, so a document opened straight into the background (for
    /// example `open -g`) may not report until the window is first shown — at
    /// which point WebKit un-throttles and everything runs. So a missing
    /// signpost after a background launch is expected, not a regression, and
    /// the measurement is only meaningful for a foreground open anyway.
    static func reportFirstPaint() {
        guard !didLogFirstPaint else { return }
        didLogFirstPaint = true
        let ms = Date().timeIntervalSince(processStart) * 1000
        os_signpost(.event, log: log, name: "firstPaint")
        NSLog("Agentia launch → first paint: %.1f ms", ms)
    }
}

/// The app's entry point, and the only thing the executable target imports.
///
/// `@main` used to sit on `AppDelegate` in an executable target, which is
/// precisely what a test bundle cannot import — so the window, its layout and
/// the view-mode machinery had no tests at all, and shipped with the sidebar
/// drawn under the traffic lights.
public enum AgentiaApp {
    public static func main() {
        AppDelegate.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var webView: HardenedWebView!
    private var windowController: DocumentWindowController!

    /// application(_:open:) is delivered after applicationWillFinishLaunching
    /// and before applicationDidFinishLaunching, so by the time the empty state
    /// would be shown a document may already be on screen.
    private var hasOpenedDocument = false

    /// NSApplication.delegate is weak, and Swift only guarantees a local's
    /// lifetime up to its last use — under -O the delegate could be released
    /// immediately after assignment, leaving the app with no delegate and no
    /// explanation. Debug builds usually mask it, which is the worst case.
    private static var retainedDelegate: AppDelegate?

    /// NSMenu holds its delegate weakly, so without this the Open With submenu
    /// would populate itself exactly once and then silently stop.
    private var openWithMenuDelegate: OpenWithMenu?
    private var themeMenuDelegate: ThemeMenu?

    static func main() {
        Launch.processStart = Date()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.retainedDelegate = delegate
        app.delegate = delegate
        // A document viewer is a regular app: it needs a Dock icon and a menu.
        app.setActivationPolicy(.regular)
        app.run()
    }

    // MARK: - Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        Launch.mark("willFinishLaunching")

        // Create the web view as early as possible so WebKit's WebContent and
        // Networking processes spawn while the file is still being read and
        // parsed, rather than after. This is the single biggest lever on the
        // double-click-to-paint number, and it is why the app uses the AppKit
        // lifecycle instead of the SwiftUI App struct: `application(_:open:)`
        // arrives after this, so there is a real window in which to overlap.
        webView = HardenedWebView()

        windowController = DocumentWindowController(webView: webView)

        Launch.mark("webViewCreated")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Launch.mark("didFinishLaunching")
        installMenu()

        windowController.showWindow(nil)

        // Restore the sidebar if it was open. Done here rather than in the
        // window controller's init so it stays off the path to first paint —
        // it reads a folder listing, and nothing about the document needs it.
        if Preferences.sidebarVisible {
            windowController.setSidebarVisible(true, animated: false)
        }

        if !hasOpenedDocument {
            // Launched with no document: open a scratch file to write in
            // rather than a page explaining how to open one. Still guarded, or
            // the most important flow in the app — double clicking a .md in
            // Finder — would render that document and then immediately replace
            // it with the scratchpad.
            windowController.openScratchDocument()
        }
    }

    /// Finder double-click, `open` on the command line, and drag-onto-icon all
    /// land here.
    func application(_ application: NSApplication, open urls: [URL]) {
        Launch.mark("openURLs")

        for url in urls {
            windowController.open(url)
            hasOpenedDocument = true
        }
        windowController.showWindow(nil)

        // Deliberately NOT ignoringOtherApps. That variant interrupts whatever
        // the user is doing and redirects their in-flight keystrokes and clicks
        // to this app — which cost a window here more than once: a click meant
        // for another app landed on the close button, and since closing the
        // only window used to quit the app, Agentia simply vanished.
        //
        // Launch Services already activates an app it launched to open a file,
        // so the double-click path does not need the hammer. This only brings
        // the window forward when the app was already running.
        NSApp.activate(ignoringOtherApps: false)
    }

    /// A viewer should survive closing its window, the way Preview and TextEdit
    /// do — clicking the close button is not a request to end the session.
    /// Reopening is handled below, so the app cannot become an unreachable Dock
    /// icon.
    ///
    /// Note there is still no Close item in the File menu, so ⌘W does nothing;
    /// the red button is the only way to close. Worth adding, but it is a
    /// separate change from making the close survivable.
    /// Quitting with unsaved edits asks first, the same as closing.
    ///
    /// ⌘Q is the other way to lose a buffer, and it bypasses windowShouldClose
    /// entirely.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard windowController?.canSave == true else { return .terminateNow }
        windowController.confirmDiscardingEdits { proceed in
            if proceed { self.windowController.discardEdits() }
            NSApp.reply(toApplicationShouldTerminate: proceed)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon with no window open brings the document back,
    /// still showing whatever was last open.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        guard !hasVisibleWindows else { return true }
        windowController.showWindow(nil)
        return true
    }

    // MARK: - Menu

    /// The standard About panel, with the commit this build came from.
    ///
    /// An installed copy keeps running the code it was built from, so a build
    /// that was never reinstalled looks exactly like one that ignored your
    /// changes. `AGBuildRevision` is stamped by `tools/make-app.sh`; showing it
    /// here means the app can answer "is this current?" without hashing the
    /// binary. A build made outside that script has no stamp, and then this is
    /// the plain system panel.
    @objc private func showAbout(_ sender: Any?) {
        let info = Bundle.main.infoDictionary
        guard let revision = info?["AGBuildRevision"] as? String else {
            NSApp.orderFrontStandardAboutPanel(sender)
            return
        }
        let build = info?["CFBundleVersion"] as? String ?? "?"
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: "\(revision) · build \(build)"
        ])
    }

    /// Built in code because the app ships without a nib — one less thing to
    /// load before first paint.
    private func installMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Agentia",
                        action: #selector(showAbout),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…",
                        action: #selector(DocumentWindowController.showSettings(_:)),
                        keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Agentia",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Agentia",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        // Reachable after opening something else, so the scratchpad is not a
        // launch-only accident.
        fileMenu.addItem(withTitle: "Scratchpad",
                         action: #selector(DocumentWindowController.openScratchDocument),
                         keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Open…",
                         action: #selector(DocumentWindowController.openDocument(_:)),
                         keyEquivalent: "o")
        // Targets nil so it travels the responder chain to the key window,
        // which is what makes ⌘W close the front window rather than a
        // particular one. The app survives it — see
        // applicationShouldTerminateAfterLastWindowClosed.
        fileMenu.addItem(withTitle: "Close",
                         action: #selector(NSWindow.performClose(_:)),
                         keyEquivalent: "w")
        fileMenu.addItem(withTitle: "Save",
                         action: #selector(DocumentWindowController.saveDocument(_:)),
                         keyEquivalent: "s")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Export as PDF…",
                         action: #selector(DocumentWindowController.exportPDF(_:)),
                         keyEquivalent: "p")
        fileMenu.addItem(withTitle: "Reveal in Finder",
                         action: #selector(DocumentWindowController.revealInFinder(_:)),
                         keyEquivalent: "r")
        fileMenu.addItem(.separator())

        // Populated when the submenu opens: the handler list depends on the
        // document, and asking Launch Services is not free.
        let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        let openWithMenu = NSMenu(title: "Open With")
        let openWithDelegate = OpenWithMenu(controller: windowController)
        openWithMenu.delegate = openWithDelegate
        openWithMenuDelegate = openWithDelegate
        openWith.submenu = openWithMenu
        fileMenu.addItem(openWith)

        fileMenu.addItem(withTitle: "Share…",
                         action: #selector(DocumentWindowController.shareDocument(_:)),
                         keyEquivalent: "")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Copy All as Markdown",
                         action: #selector(DocumentWindowController.copyAll(_:)),
                         keyEquivalent: "C")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Find…",
                         action: #selector(DocumentWindowController.performFind(_:)),
                         keyEquivalent: "f")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle Sidebar",
                         action: #selector(DocumentWindowController.toggleSidebar(_:)),
                         keyEquivalent: "e")
        viewMenu.addItem(withTitle: "Toggle Source",
                         action: #selector(DocumentWindowController.toggleSource(_:)),
                         keyEquivalent: "u")
        viewMenu.addItem(withTitle: "Toggle Diff",
                         action: #selector(DocumentWindowController.toggleDiff(_:)),
                         keyEquivalent: "d")
        viewMenu.addItem(.separator())

        // The themes have shipped in the bundle from the start with no way to
        // pick one. Here as well as in Settings, because switching theme while
        // reading is a view decision, not a configuration one.
        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu(title: "Theme")
        let themeDelegate = ThemeMenu(controller: windowController)
        themeMenu.delegate = themeDelegate
        themeMenuDelegate = themeDelegate
        themeItem.submenu = themeMenu
        viewMenu.addItem(themeItem)

        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Bigger Text",
                         action: #selector(DocumentWindowController.increaseFontSize(_:)),
                         keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Smaller Text",
                         action: #selector(DocumentWindowController.decreaseFontSize(_:)),
                         keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size",
                         action: #selector(DocumentWindowController.resetFontSize(_:)),
                         keyEquivalent: "0")
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        NSApp.mainMenu = mainMenu
    }
}
