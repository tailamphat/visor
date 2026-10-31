// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Notchboard",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Notchboard", targets: ["Notchboard"]),
    ],
    targets: [
        // Pure logic: pricing, transcript usage, subscription limits, agent state. No AppKit.
        .target(name: "NotchboardCore"),
        // The macOS app: notch window, SwiftUI views, hook server, music.
        .executableTarget(name: "Notchboard", dependencies: ["NotchboardCore"]),
        // Unit tests for NotchboardCore: `swift test` (Swift Testing; XCTest
        // isn't available with the Command Line Tools).
        .testTarget(name: "NotchboardCoreTests", dependencies: ["NotchboardCore"]),
    ],
    // The app predates Swift 6's strict concurrency checking.
    swiftLanguageModes: [.v5]
)
