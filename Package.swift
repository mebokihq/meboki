// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Meboki",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Meboki", targets: ["Meboki"]),
        .library(name: "MebokiCore", targets: ["MebokiCore"]),
    ],
    dependencies: [
        // Updates of official builds (MIT). App target only; the core package stays free of it.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        // Pure Swift: prompt, LLM client, post-filters, diff. No AppKit, unit-tested.
        .target(name: "MebokiCore", path: "Packages/Core/Sources/MebokiCore"),
        .testTarget(
            name: "MebokiCoreTests",
            dependencies: ["MebokiCore"],
            path: "Packages/Core/Tests/MebokiCoreTests"
        ),
        // eval/: scores the settings' post-filters on recorded model replies with the real Core code
        // (`eval/settings_report.py` runs it). Not part of the app.
        .executableTarget(
            name: "meboki-eval-filter",
            dependencies: ["MebokiCore"],
            path: "eval/filter"
        ),
        // Menu-bar app: accessibility, hotkey, panel, model download, llama-server process.
        .executableTarget(
            name: "Meboki",
            dependencies: ["MebokiCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "App/Sources/Meboki"
        ),
    ],
    swiftLanguageModes: [.v5]
)
