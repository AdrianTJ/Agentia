// agentia-render-cli — Markdown on stdin (or a file argument), HTML on stdout.
//
// Exists so the browser test suite drives the same code the app links against,
// rather than a JavaScript reimplementation that could drift.
//
//   agentia-render-cli [--no-sourcepos] [--safe] [--smart] [file.md]
//   agentia-render-cli --artifact [file.html]
//
// --artifact emits the raw-document page an HTML artifact is served as, so the
// browser suite exercises the real injection logic rather than a mirror of it.
//
// Replaces tools/cli/agentia_render_cli.c, and keeps its exact contract —
// including exit codes — so the harness did not have to change shape when the
// C shim moved to Swift.

import Foundation
import AgentiaCore

var options = MarkdownRenderer.Options.default
var path: String?
var asArtifact = false

for argument in CommandLine.arguments.dropFirst() {
    switch argument {
    case "--artifact":
        asArtifact = true
    case "--no-sourcepos":
        options.remove(.sourcePositions)
    case "--safe":
        options.remove(.rawHTML)
    case "--smart":
        options.insert(.smartPunctuation)
    case "--version":
        print(MarkdownRenderer.cmarkVersion)
        exit(0)
    default:
        path = argument
    }
}

let source: Data
if let path {
    guard let contents = FileManager.default.contents(atPath: path) else {
        FileHandle.standardError.write(
            Data("agentia-render-cli: cannot open \(path)\n".utf8))
        exit(2)
    }
    source = contents
} else {
    source = FileHandle.standardInput.readDataToEndOfFile()
}

if asArtifact {
    let page = RawArtifact.page(
        html: String(decoding: source, as: UTF8.self),
        csp: RenderShell.contentSecurityPolicy(profile: .htmlArtifact, scriptHash: "")
    )
    FileHandle.standardOutput.write(Data(page.utf8))
    exit(0)
}

do {
    let html = try MarkdownRenderer.renderHTML(source, options: options)
    FileHandle.standardOutput.write(Data(html.utf8))
} catch {
    FileHandle.standardError.write(Data("agentia-render-cli: render failed\n".utf8))
    exit(1)
}
