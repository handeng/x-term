// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XTerm",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "XTerm", targets: ["XTerm"])
    ],
    targets: [
        .executableTarget(
            name: "XTerm",
            path: "Sources/XTerm",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "XTermTests",
            dependencies: ["XTerm"],
            path: "Tests/XTermTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
