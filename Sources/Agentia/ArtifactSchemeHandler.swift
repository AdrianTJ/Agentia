import Foundation
import WebKit
import AgentiaCore

/// Serves the `artifact://` scheme, which is how a rendered document and its
/// local images reach the web view.
///
/// Using a custom scheme instead of `file://` buys three things: the page has a
/// stable origin so the CSP applies predictably, WebKit's file-URL access rules
/// stop being a factor, and every read is funnelled through one place that can
/// enforce the document's folder boundary.
///
/// URL shape:
///   `artifact://doc/`            the generated page
///   `artifact://asset/<relpath>` a file beside the document
final class ArtifactSchemeHandler: NSObject, WKURLSchemeHandler {

    static let scheme = "artifact"
    static let documentURL = URL(string: "artifact://doc/")!

    /// Largest asset served inline. An artifact referencing a huge local file
    /// should fail visibly rather than pulling it into memory.
    static let maximumAssetBytes = 64 * 1024 * 1024

    private struct Payload {
        let html: String
        let resolver: AssetResolver
    }

    /// Guards `payload`. The handler is called on the main thread by WebKit,
    /// but the document can be replaced from a file-watch callback.
    private let lock = NSLock()
    private var payload: Payload?

    /// Point the handler at a new document. Call before triggering a load.
    func setDocument(html: String, assetRoot: URL) {
        lock.lock()
        defer { lock.unlock() }
        payload = Payload(html: html, resolver: AssetResolver(root: assetRoot))
    }

    private func currentPayload() -> Payload? {
        lock.lock()
        defer { lock.unlock() }
        return payload
    }

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(Failure.badRequest)
            return
        }

        guard let payload = currentPayload() else {
            task.didFailWithError(Failure.noDocument)
            return
        }

        switch url.host {
        case "doc":
            serveDocument(payload.html, to: task, url: url)

        case "asset":
            // `URL.path` is already percent-decoded; AssetResolver re-checks
            // and does its own decoding, so pass the raw form when available.
            let reference = String(url.path.dropFirst()) // strip leading "/"
            serveAsset(reference, resolver: payload.resolver, to: task, url: url)

        default:
            task.didFailWithError(Failure.unknownHost)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // Every response is delivered synchronously inside start, so there is
        // nothing in flight to cancel.
    }

    // MARK: - Responses

    private func serveDocument(_ html: String, to task: WKURLSchemeTask, url: URL) {
        let data = Data(html.utf8)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "text/html; charset=utf-8",
                "Content-Length": String(data.count),
                // The page carries its own CSP meta tag; sending it as a header
                // as well means a document that strips the tag still cannot
                // widen its own policy.
                "Cache-Control": "no-store",
            ]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func serveAsset(
        _ reference: String,
        resolver: AssetResolver,
        to task: WKURLSchemeTask,
        url: URL
    ) {
        do {
            let fileURL = try resolver.resolve(reference)

            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= Self.maximumAssetBytes else {
                task.didFailWithError(Failure.assetTooLarge)
                return
            }

            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": AssetResolver.mimeType(for: fileURL),
                    "Content-Length": String(data.count),
                    // An asset must never be sniffed into something executable.
                    "X-Content-Type-Options": "nosniff",
                    "Cache-Control": "no-store",
                ]
            )!
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()

        } catch {
            // Deliberately uniform: a document must not be able to tell "denied"
            // from "missing" and use the handler to probe the filesystem.
            task.didFailWithError(Failure.assetUnavailable)
        }
    }

    enum Failure {
        static let domain = "app.agentia.scheme"

        static let badRequest = NSError(domain: domain, code: 1)
        static let noDocument = NSError(domain: domain, code: 2)
        static let unknownHost = NSError(domain: domain, code: 3)
        static let assetUnavailable = NSError(domain: domain, code: 4)
        static let assetTooLarge = NSError(domain: domain, code: 5)
    }
}
