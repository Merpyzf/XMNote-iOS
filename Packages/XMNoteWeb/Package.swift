// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "XMNoteWeb",
    platforms: [
        .iOS("26.0"),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "XMNoteWeb",
            targets: ["XMNoteWeb"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/hummingbird-project/hummingbird.git",
            exact: "2.22.0"
        )
    ],
    targets: [
        .target(
            name: "XMNoteWeb",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird")
            ],
            resources: [
                .copy("Resources/DesktopWebSite")
            ]
        ),
        .testTarget(
            name: "XMNoteWebTests",
            dependencies: [
                "XMNoteWeb",
                .product(name: "HummingbirdTesting", package: "hummingbird")
            ],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
