// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Visor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Visor", targets: ["Visor"]),
        .executable(name: "visor-bridge", targets: ["VisorBridge"]),
    ],
    targets: [
        // Pure logic: pricing, transcript usage, subscription limits, agent state. No AppKit.
        .target(name: "VisorCore"),
        // The macOS app: notch window, SwiftUI views, hook server, music.
        .executableTarget(name: "Visor", dependencies: ["VisorCore"]),
        // Started by browsers for the Visor Media extension (native messaging).
        .executableTarget(name: "VisorBridge", dependencies: ["VisorCore"]),
        // Unit tests for VisorCore: `swift test` (Swift Testing; XCTest
        // isn't available with the Command Line Tools).
        .testTarget(name: "VisorCoreTests", dependencies: ["VisorCore"]),
    ],
    // The app predates Swift 6's strict concurrency checking.
    swiftLanguageModes: [.v5]
)
