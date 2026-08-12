import AppKit
import WebKit
import AgentiaCore

/// Exports the rendered document to PDF.
///
/// Uses `printOperation(with:)` rather than `createPDF(configuration:)`. Both
/// are supported since macOS 11, but the print pipeline is where `NSPrintInfo`
/// supplies paper size, margins and running heads, and where the theme's
/// `@page` and break rules are honoured. `createPDF` stays available for a
/// quick unpaginated dump.
///
/// Running heads deliberately come from `NSPrintInfo`, not CSS: no shipping
/// browser engine implements CSS `@page` margin boxes, so a header written in
/// print.css would silently do nothing.
enum PDFExporter {

    struct Settings {
        var paperSize: NSSize
        var margins: NSEdgeInsets
        var showsHeader: Bool
        var showsFooter: Bool
        /// Shown in the running header alongside the date.
        var documentName: String

        static func letter(documentName: String) -> Settings {
            Settings(
                paperSize: NSSize(width: 612, height: 792), // 8.5 × 11 in points
                margins: NSEdgeInsets(top: 72, left: 72, bottom: 72, right: 72),
                showsHeader: true,
                showsFooter: true,
                documentName: documentName
            )
        }

        /// Build from a theme manifest so the export matches the reading view.
        static func from(theme: Theme, documentName: String) -> Settings {
            var settings = Settings.letter(documentName: documentName)

            if theme.manifest.page.size.lowercased() == "a4" {
                settings.paperSize = NSSize(width: 595, height: 842)
            }
            if let inset = points(from: theme.manifest.page.margin) {
                settings.margins = NSEdgeInsets(top: inset, left: inset,
                                                bottom: inset, right: inset)
            }
            return settings
        }

        /// Parse a CSS length into PostScript points. Only the units a theme
        /// manifest is allowed to use are supported; anything else falls back
        /// to the caller's default rather than guessing.
        static func points(from css: String) -> CGFloat? {
            let trimmed = css.trimmingCharacters(in: .whitespaces).lowercased()
            let pairs: [(String, CGFloat)] = [
                ("in", 72), ("cm", 72.0 / 2.54), ("mm", 72.0 / 25.4),
                ("pt", 1), ("px", 0.75),
            ]
            for (suffix, factor) in pairs where trimmed.hasSuffix(suffix) {
                let number = trimmed.dropLast(suffix.count)
                guard let value = Double(number) else { return nil }
                return CGFloat(value) * factor
            }
            return nil
        }
    }

    static func printInfo(from settings: Settings) -> NSPrintInfo {
        let info = NSPrintInfo(dictionary: [:])
        info.paperSize = settings.paperSize
        info.topMargin = settings.margins.top
        info.bottomMargin = settings.margins.bottom
        info.leftMargin = settings.margins.left
        info.rightMargin = settings.margins.right
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.orientation = .portrait
        return info
    }

    /// Present the standard save panel and write a PDF.
    @MainActor
    static func export(
        from webView: WKWebView,
        settings: Settings,
        suggestedName: String,
        in window: NSWindow?,
        completion: @escaping (Result<URL, Swift.Error>) -> Void
    ) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true

        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else {
                completion(.failure(Failure.cancelled))
                return
            }
            // Collapsed <details> print as just their summary, so any log or
            // stack trace an author folded away is silently missing from the
            // export. shell.js opens them on beforeprint for Markdown, but an
            // HTML artifact runs no shell script — so this is done host-side,
            // where it holds for both.
            //
            // It has to set the `open` attribute: the UA hides the slot rather
            // than the children, so no amount of print CSS can reveal a closed
            // <details>.
            expandDetails(in: webView) {
                write(from: webView, settings: settings, to: url) { result in
                    restoreDetails(in: webView)
                    completion(result)
                }
            }
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }

    /// Marker left on the elements this opened, so only those are closed again.
    /// A `<details open>` the author wrote must stay open afterwards.
    private static let reopenedMarker = "data-agentia-print-opened"

    private static func expandDetails(in webView: WKWebView, then body: @escaping () -> Void) {
        let script = """
        (function () {
          var closed = document.querySelectorAll('details:not([open])');
          for (var i = 0; i < closed.length; i++) {
            closed[i].setAttribute('\(reopenedMarker)', '');
            closed[i].open = true;
          }
          return closed.length;
        })();
        """
        // A failure here must not block the export — a document with no
        // <details> is the common case, and a broken script is no reason to
        // refuse to produce a PDF.
        webView.evaluateJavaScript(script) { _, _ in body() }
    }

    private static func restoreDetails(in webView: WKWebView) {
        let script = """
        (function () {
          var opened = document.querySelectorAll('[\(reopenedMarker)]');
          for (var i = 0; i < opened.length; i++) {
            opened[i].open = false;
            opened[i].removeAttribute('\(reopenedMarker)');
          }
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Write a PDF without any UI. Used by the save panel path and by tests.
    @MainActor
    static func write(
        from webView: WKWebView,
        settings: Settings,
        to url: URL,
        completion: @escaping (Result<URL, Swift.Error>) -> Void
    ) {
        let info = printInfo(from: settings)
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.jobTitle = settings.documentName

        // The web view must be in the view hierarchy and sized, or WebKit
        // paginates against a zero rect and produces a blank document.
        operation.view?.frame = NSRect(
            origin: .zero,
            size: NSSize(width: settings.paperSize.width
                         - settings.margins.left - settings.margins.right,
                         height: settings.paperSize.height
                         - settings.margins.top - settings.margins.bottom)
        )

        if operation.run() {
            completion(.success(url))
        } else {
            completion(.failure(Failure.printOperationFailed))
        }
    }

    enum Failure: Swift.Error, Equatable {
        case cancelled
        case printOperationFailed
    }
}
