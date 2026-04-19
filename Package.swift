// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Shiro",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.0.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.0.2"),
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
            // Info.plist is consumed by Xcode (INFOPLIST_FILE) — exclude it
            // from the SwiftPM resource scan so SPM doesn't warn about an
            // unhandled / duplicate resource.
            exclude: ["App/Info.plist"]
            // Add .process("App/Assets.xcassets") here when you add an asset catalog.
        ),
    ]
)
