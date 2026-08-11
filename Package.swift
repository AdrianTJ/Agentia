// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Agentia",
    platforms: [
        // AppKit and WebKit APIs the app layer uses are available from 13;
        // AgentiaCore itself only needs Foundation.
        .macOS(.v13)
    ],
    products: [
        .library(name: "AgentiaCore", targets: ["AgentiaCore"]),
        // Built as a plain executable rather than an Xcode app target so the
        // Phase 0 launch measurement can be run with `swift run`.
        // tools/make-app.sh wraps it into a double-clickable .app.
        .executable(name: "Agentia", targets: ["Agentia"]),
        // Drives AgentiaCore's renderer from the command line so the browser
        // suite tests the same code the app links, not a JS reimplementation.
        .executable(name: "agentia-render-cli", targets: ["agentia-render-cli"]),
    ],
    dependencies: [
        // Apple's fork of cmark-gfm. Note: its gfm branch has a malformed
        // footnote backref that AgentiaCore repairs — see the workaround
        // comment on FootnoteBackref in MarkdownPostProcessing.swift.
        .package(url: "https://github.com/swiftlang/swift-cmark.git", branch: "gfm"),
    ],
    targets: [
        .target(
            name: "AgentiaCore",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ],
            resources: [
                .copy("Resources/shell"),
                .copy("Resources/themes"),
            ]
        ),
        .executableTarget(
            name: "Agentia",
            dependencies: ["AgentiaCore"],
            // Consumed by tools/make-app.sh when assembling the bundle, not
            // SwiftPM resources.
            exclude: ["Info.plist", "Agentia.icns"]
        ),
        .executableTarget(
            name: "agentia-render-cli",
            dependencies: ["AgentiaCore"]
        ),
        .testTarget(
            name: "AgentiaCoreTests",
            dependencies: ["AgentiaCore"],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
