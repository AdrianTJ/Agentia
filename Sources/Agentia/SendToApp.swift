import AppKit
import AgentiaCore

/// Getting the document out of Agentia and into whatever comes next.
///
/// The ranking is from `docs/technical-proposal.html` §08, by how often each
/// route actually works rather than by how impressive it sounds:
///
///  1. The multi-representation clipboard — already built, see `Clipboard`.
///     Markdown, HTML and RTF go on the pasteboard together and the
///     destination picks: a terminal takes the source, Mail takes the
///     formatting.
///  2. A real Open With menu. Every app on the machine, no per-app
///     integration, nothing to keep working as those apps change.
///  3. The system share sheet: Mail, Messages, AirDrop, Notes and every
///     installed share extension, for free.
///
/// What is deliberately *not* here is a set of hand-written per-app
/// integrations. A URL scheme like `obsidian://new?content=…` breaks on long
/// artifacts — exactly the documents this app exists to read — and every such
/// target is a separate thing to maintain. The file-first approach the proposal
/// describes for Obsidian (write into the vault folder, then open it) is worth
/// building, but it needs somewhere to keep the vault path, so it waits for a
/// settings surface rather than being bolted on here.
enum SendToApp {

    /// Applications that can open this document, best handler first.
    ///
    /// Agentia is excluded: an Open With menu whose first entry reopens the
    /// document in the app you are already reading it in is noise.
    static func handlers(for url: URL) -> [URL] {
        let all = NSWorkspace.shared.urlsForApplications(toOpen: url)
        // Resolve symlinks, not just `.`/`..`: an install where
        // /Applications/Agentia.app is a symlink (a Homebrew Cask layout, say)
        // makes Launch Services' resolved handler disagree with
        // Bundle.main.bundleURL, and Agentia would list itself in its own Open
        // With menu — the noise this exclusion exists to remove.
        let ourselves = Bundle.main.bundleURL.resolvingSymlinksInPath()
        return all.filter { $0.resolvingSymlinksInPath() != ourselves }
    }

    static func displayName(of application: URL) -> String {
        FileManager.default.displayName(atPath: application.path)
    }

    static func open(_ document: URL, with application: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([document], withApplicationAt: application,
                                configuration: configuration) { _, error in
            if let error {
                NSLog("Agentia: could not open with %@: %@",
                      application.lastPathComponent, String(describing: error))
            }
        }
    }
}

/// Fills the File ▸ Open With submenu on demand.
///
/// Built when the menu opens rather than at launch: the handler list depends on
/// the document, which changes, and asking Launch Services is not free.
final class OpenWithMenu: NSObject, NSMenuDelegate {

    private weak var controller: DocumentWindowController?

    init(controller: DocumentWindowController) {
        self.controller = controller
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        guard let url = controller?.documentURL else {
            menu.addItem(disabled: "No Document Open")
            return
        }

        let handlers = SendToApp.handlers(for: url)
        guard !handlers.isEmpty else {
            menu.addItem(disabled: "No Other Applications")
            return
        }

        for application in handlers {
            let item = NSMenuItem(title: SendToApp.displayName(of: application),
                                  action: #selector(openWith(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = application
            item.image = icon(for: application)
            menu.addItem(item)
        }
    }

    private func icon(for application: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: application.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func openWith(_ sender: NSMenuItem) {
        guard let application = sender.representedObject as? URL,
              let document = controller?.documentURL else { return }
        SendToApp.open(document, with: application)
    }
}

private extension NSMenu {
    /// A greyed placeholder, so an empty submenu explains itself rather than
    /// opening onto nothing.
    func addItem(disabled title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }
}
