// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "XMNoteUILint",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "XMNoteUILintCore", targets: ["XMNoteUILintCore"]),
        .executable(name: "XMNoteUILint", targets: ["XMNoteUILint"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-syntax.git",
            exact: "603.0.2"
        )
    ],
    targets: [
        .target(
            name: "XMNoteUILintCore",
            dependencies: [
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax")
            ]
        ),
        .executableTarget(
            name: "XMNoteUILint",
            dependencies: ["XMNoteUILintCore"]
        ),
        .testTarget(
            name: "XMNoteUILintCoreTests",
            dependencies: ["XMNoteUILintCore"]
        )
    ]
)
