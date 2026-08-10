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
    ],
    dependencies: [
        // Apple's fork of cmark-gfm. Note: its gfm branch has a malformed
        // footnote backref that CAgentiaMarkdown repairs — see the workaround
        // comment in agentia_markdown.c.
        .package(url: "https://github.com/swiftlang/swift-cmark.git", branch: "gfm"),
    ],
    targets: [
        .target(
            name: "CAgentiaMarkdown",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ]
        ),
        .target(
            name: "AgentiaCore",
            dependencies: ["CAgentiaMarkdown"],
            resources: [
                .copy("Resources/shell"),
                .copy("Resources/themes"),
            ]
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
