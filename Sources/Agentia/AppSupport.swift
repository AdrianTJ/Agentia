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

    /// Removes any `src`/`href`/`url()` whose scheme is not local, so the HTML
    /// importer has nothing to fetch.
    static func strippingRemoteReferences(from html: String) -> String {
        let patterns = [
            #"(?i)\s(src|href|poster|srcset|background)\s*=\s*"[^"]*""#,
            #"(?i)\s(src|href|poster|srcset|background)\s*=\s*'[^']*'"#,
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
    private var blockedItem: NSToolbarItem?

    init(target: DocumentWindowController) {
        self.target = target
    }

    private enum ItemID {
        static let sidebar = NSToolbarItem.Identifier("sidebar")
        static let viewMode = NSToolbarItem.Identifier("viewMode")
        static let copy = NSToolbarItem.Identifier("copy")
        static let pdf = NSToolbarItem.Identifier("pdf")
        static let reveal = NSToolbarItem.Identifier("reveal")
        static let blocked = NSToolbarItem.Identifier("blocked")
    }

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "AgentiaDocumentToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.sidebar, .flexibleSpace, ItemID.blocked, ItemID.viewMode,
         ItemID.copy, ItemID.pdf, ItemID.reveal]
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
        case ItemID.reveal:
            return button(identifier, symbol: "folder", label: "Reveal in Finder",
                          action: #selector(DocumentWindowController.revealInFinder(_:)))
        case ItemID.blocked:
            let item = button(identifier, symbol: "exclamationmark.shield",
                              label: "Blocked requests",
                              action: #selector(DocumentWindowController.allowNetworkForDocument(_:)))
            item.isHidden = true
            blockedItem = item
            return item
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

    /// Shows how many remote requests the document tried to make. Hidden when
    /// there were none, so a clean document has no chrome for it.
    func updateBlockedCount(_ count: Int) {
        guard let blockedItem else { return }
        blockedItem.isHidden = count == 0
        blockedItem.label = count == 1 ? "1 request blocked" : "\(count) requests blocked"
        blockedItem.toolTip = blockedItem.label + " — click to allow for this document"
    }
}

// MARK: - Sidebar

/// The vertical document list. Hidden by default, so it is constructed the
/// first time it is revealed and never during launch.
final class SidebarView: NSView {

    private weak var controller: DocumentWindowController?

    init(controller: DocumentWindowController) {
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: 228, height: 400))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }
}
