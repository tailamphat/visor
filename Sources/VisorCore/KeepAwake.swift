import Foundation

/// Whether Visor holds off sleep: on Auto while agents work (and a short grace
/// after), always when On, never when Off; and not on a low battery.
public enum KeepAwake {
    public enum Mode: String, CaseIterable, Sendable {
        case auto, on, off

        /// From the saved setting; anything missing or unknown is On (the cup starts enabled).
        public init(saved: String?) { self = saved.flatMap(Mode.init(rawValue:)) ?? .on }

        /// What a click on the cup moves to.
        public var next: Mode {
            switch self {
            case .auto: return .on
            case .on: return .off
            case .off: return .auto
            }
        }
    }

    public enum Battery: Equatable, Sendable {
        case pluggedIn
        case battery(percent: Int)
    }

    /// How long Auto keeps holding after the last agent stops, so pauses between turns don't count.
    public static let grace: TimeInterval = 120
    /// Below this, on battery, sleep wins.
    public static let lowBattery = 20

    public static func shouldHold(mode: Mode, working: Int, lastWorked: Date?, now: Date, battery: Battery, batteryLimit: Bool) -> Bool {
        if batteryLimit, case .battery(let percent) = battery, percent < lowBattery { return false }
        switch mode {
        case .off: return false
        case .on: return true
        case .auto:
            if working > 0 { return true }
            guard let lastWorked else { return false }
            return now.timeIntervalSince(lastWorked) <= grace
        }
    }

    /// When Auto's grace runs out, to check again then (no polling).
    public static func graceEnds(lastWorked: Date) -> Date { lastWorked.addingTimeInterval(grace) }
}
