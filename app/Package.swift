// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Gauge",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Sparkle: signed, opt-in update checks (the only network request Gauge makes).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        // Shared by the app and the `gauge` command: the local API's types, its Unix socket, and the MCP server.
        .target(
            name: "GaugeKit",
            path: "Sources/GaugeKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Gauge",
            dependencies: ["GaugeKit", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Gauge",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreAudio"),
                .linkedLibrary("sqlite3"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        // The `gauge` command-line tool. build.sh copies it into Gauge.app/Contents/Helpers/gauge
        // (Contents/MacOS/gauge would collide with Contents/MacOS/Gauge on a case-insensitive disk).
        .executableTarget(
            name: "GaugeCLI",
            dependencies: ["GaugeKit"],
            path: "Sources/GaugeCLI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GaugeTests",
            dependencies: ["Gauge", "GaugeKit"],
            path: "Tests/GaugeTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
