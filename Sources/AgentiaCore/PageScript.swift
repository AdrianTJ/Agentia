import Foundation

/// JavaScript the *host* runs inside a loaded document.
///
/// This is not the page's own script — it is `evaluateJavaScript`, which runs
/// with the host's authority and outside the page's CSP. Anything a document
/// supplies and that ends up in one of these strings is therefore code the
/// document has talked the host into running, which makes escaping the whole
/// job of this type.
///
/// It lives in AgentiaCore so it can be tested. The same reasoning moved
/// `NavigationPolicy` here: a security decision that only exists inside an
/// AppKit delegate is a security decision nothing verifies.
public enum PageScript {

    /// Scroll the element with `id` into view.
    ///
    /// The id arrives from the page's own outline, so it is document-controlled.
    /// It is emitted as a JSON string literal rather than interpolated: an id
    /// of `"); doStuff(" would otherwise close the call and append statements
    /// that run with the host's authority. JSON's escaping covers quotes,
    /// backslashes, newlines and control characters in one step, and its output
    /// is a valid JavaScript string literal by construction.
    public static func scrollToElement(id: String) -> String? {
        guard let literal = jsonStringLiteral(id) else { return nil }
        return """
        (function () {
          var target = document.getElementById(\(literal));
          if (target) target.scrollIntoView({ block: "start", behavior: "smooth" });
        })();
        """
    }

    /// A JavaScript string literal for `value`.
    ///
    /// Built by encoding a one-element array and taking what is between the
    /// brackets, because `JSONSerialization` refuses a bare string as a
    /// top-level value. `U+2028` and `U+2029` are escaped afterwards: both are
    /// legal inside a JSON string but terminate a line in JavaScript, so a JSON
    /// encoder can hand back something that is valid JSON and a syntax error as
    /// source.
    static func jsonStringLiteral(_ value: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let wrapped = String(data: data, encoding: .utf8),
              wrapped.count >= 2
        else { return nil }

        let literal = String(wrapped.dropFirst().dropLast())
        return literal
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
