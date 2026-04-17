// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Shiro",
    platforms: [.macOS(.v14)],
    dependencies: [
        // SQLite ORM
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.0.0"),
        // Markdown rendering
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.0.2"),
        // Keyboard shortcuts
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Shiro",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources",
            resources: [
                .process("../Resources"),
            ],
            swiftSettings: [
                .unsafeFlags(["-enable-actor-data-race-checks"]),
            ]
        ),
    ]
)
