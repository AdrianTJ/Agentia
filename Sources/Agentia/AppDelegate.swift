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
    static func reportFirstPaint() {
        guard !didLogFirstPaint else { return }
        didLogFirstPaint = true
        let ms = Date().timeIntervalSince(processStart) * 1000
        os_signpost(.event, log: log, name: "firstPaint")
        NSLog("Agentia launch → first paint: %.1f ms", ms)
    }
}

@main
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
        if !hasOpenedDocument {
            // Launched with no document: an empty state rather than a blank
            // page. Guarded, or the most important flow in the app — double
            // clicking a .md in Finder — would render the document and then
            // immediately overwrite it with "Open a file to begin".
            windowController.showEmptyState()
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

    /// Built in code because the app ships without a nib — one less thing to
    /// load before first paint.
    private func installMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Agentia",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: nil, keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Agentia",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Agentia",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
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
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Export as PDF…",
                         action: #selector(DocumentWindowController.exportPDF(_:)),
                         keyEquivalent: "p")
        fileMenu.addItem(withTitle: "Reveal in Finder",
                         action: #selector(DocumentWindowController.revealInFinder(_:)),
                         keyEquivalent: "r")
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
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        NSApp.mainMenu = mainMenu
    }
}
