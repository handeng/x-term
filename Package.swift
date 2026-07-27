// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XTerm",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "XTerm", targets: ["XTerm"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.15.0")
    ],
    targets: [
        .executableTarget(
            name: "XTerm",
            dependencies: ["SwiftTerm"],
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
