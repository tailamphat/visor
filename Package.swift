// swift-tools-version:5.10
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
        // Assertion runner for NotchboardCore. Command Line Tools ship without a
        // working XCTest/Swift Testing, so `swift run NotchboardChecks` stands in.
        .executableTarget(name: "NotchboardChecks", dependencies: ["NotchboardCore"]),
    ]
)
