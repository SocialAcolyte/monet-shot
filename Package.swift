// swift-tools-version: 6.2
import PackageDescription

// Three targets:
// - MonetShotKit: logic with no UI (models, store, shell, log). Public API.
// - MonetShot: the menu bar app (AppKit + SwiftUI) on top of MonetShotKit.
// - MonetShotChecks: tests as a plain executable (`swift run MonetShotChecks`),
//   because XCTest and Swift Testing's macros ship only with full Xcode.
let package = Package(
    name: "MonetShot",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "MonetShotKit",
            path: "Sources/MonetShotKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MonetShot",
            dependencies: ["MonetShotKit"],
            path: "Sources/MonetShot",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MonetShotChecks",
            dependencies: ["MonetShotKit"],
            path: "Sources/MonetShotChecks",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
