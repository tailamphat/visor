import Foundation
import Testing
@testable import VisorCore

private func onScale(_ value: Double, _ steps: [DesignScale.Step]) -> Bool {
    steps.contains { abs($0.value - value) < 1e-9 }
}

@Suite("Design components")
struct DesignComponentTests {
    private typealias C = DesignComponents

    /// Values that are the component's own, not a token. Listed by name so a
    /// new literal can't slip in unnoticed.
    static let namedConstants: Set<String> = ["Banner.strokeOpacity", "CardButton.pressedOpacity", "SectionHeader.tracking"]

    @Test func everyComponentValueIsATokenStep() {
        var constants = Set<String>()
        for measurement in C.measurements {
            if let scale = measurement.scale {
                #expect(onScale(measurement.value, scale), "\(measurement.name) = \(measurement.value) is not a token step")
            } else {
                constants.insert(measurement.name)
            }
        }
        #expect(constants == Self.namedConstants)
        #expect(Set(C.measurements.map(\.name)).count == C.measurements.count)
    }

    /// Every static measurement in DesignComponents.swift is in `measurements`,
    /// so a new value can't skip the scale check.
    @Test func everyMeasurementIsListed() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/VisorCore/DesignComponents.swift").standardized
        let source = try String(contentsOf: file, encoding: .utf8)
        var group = ""
        var declared = Set<String>()
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("public enum ") {
                group = String(trimmed.dropFirst("public enum ".count).prefix { $0.isLetter })
            } else if trimmed.hasPrefix("public static let "), line.hasPrefix("        ") {
                let name = trimmed.dropFirst("public static let ".count).prefix { $0.isLetter || $0.isNumber }
                declared.insert(group + "." + name)
            }
        }
        #expect(!declared.isEmpty)
        #expect(declared == Set(C.measurements.map(\.name)))
    }

    @Test func cardButtonMatchesTheCardsToday() {
        #expect(C.CardButton.height == 18)
        #expect(C.CardButton.radius == 5)
        #expect(C.CardButton.type == 11)
        #expect(C.CardButton.secondaryFill == 0.12)
        // Today's 9 pt snapped onto the scale (mockup option A).
        #expect(C.CardButton.padding == 8)
        #expect(C.CardButton.padding == DesignScale.snap(9, to: DesignScale.space).value)
    }

    @Test(arguments: [(1, 74.0), (2, 91.0), (3, 108.0)])
    func bannerHeightKeepsStuckAndHandoffHeights(targets: Int, height: Double) {
        #expect(C.Banner.height(rows: [16, 15, 18], spacing: 3) == 75)
        let rows = [16.0] + Array(repeating: 14.0, count: targets) + [18.0]
        #expect(C.Banner.height(rows: rows, spacing: 3) == height)
    }

    @Test func bannerHeightOfNoRowsIsTheInset() {
        #expect(C.Banner.height(rows: [], spacing: 3) == 2 * C.Banner.inset)
    }

    @Test func badgeHeaderAndDismissUseTheScale() {
        #expect(C.Badge.type == 10)
        #expect(C.Badge.paddingX == 6)
        #expect(C.Badge.paddingY == 1)
        #expect(C.SectionHeader.type == 10)
        #expect(C.DismissButton.size == 18)
        #expect(C.DismissButton.type == DesignTokens.TypeScale.sm)
    }
}
