import Foundation
import Testing
@testable import VisorCore

@Suite("Keep awake")
struct KeepAwakeTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func hold(_ mode: KeepAwake.Mode, working: Int = 0, lastWork: Date? = nil, battery: KeepAwake.Battery = .pluggedIn, limit: Bool = true) -> Bool {
        KeepAwake.shouldHold(mode: mode, working: working, lastWorked: lastWork, now: now, battery: battery, batteryLimit: limit)
    }

    /// Auto: awake while an agent works, and for two minutes after the last one stops.
    @Test func autoFollowsTheAgents() {
        #expect(hold(.auto, working: 2))
        #expect(!hold(.auto))
        #expect(hold(.auto, lastWork: now.addingTimeInterval(-90)), "a short pause between turns")
        #expect(!hold(.auto, lastWork: now.addingTimeInterval(-121)))
        #expect(KeepAwake.graceEnds(lastWorked: now) == now.addingTimeInterval(120))
    }

    /// On holds whatever the agents do; Off never does.
    @Test func onAndOff() {
        #expect(hold(.on))
        #expect(!hold(.off, working: 3))
    }

    /// On battery below 20% it lets go, unless the limit is switched off; plugged in it never does.
    @Test func battery() {
        #expect(!hold(.on, battery: .battery(percent: 19)))
        #expect(hold(.on, battery: .battery(percent: 20)))
        #expect(hold(.on, battery: .battery(percent: 5), limit: false))
        #expect(hold(.auto, working: 1, battery: .pluggedIn))
    }

    /// The mode a click moves to, and its saved name.
    @Test func cycleAndSave() {
        #expect(KeepAwake.Mode.auto.next == .on && KeepAwake.Mode.on.next == .off && KeepAwake.Mode.off.next == .auto)
        #expect(KeepAwake.Mode(saved: nil) == .on, "the cup starts enabled")
        #expect(KeepAwake.Mode(saved: "auto") == .auto && KeepAwake.Mode(saved: "x") == .on)
    }
}
