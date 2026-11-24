import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import SwiftUI
import VisorCore

/// Holds off sleep with a macOS power assertion when `KeepAwake` says so: while
/// agents work (Auto), always (On), never (Off). Re-checks only when something
/// changes (agents, the mode, the battery) and once when Auto's grace ends.
@MainActor
final class AwakeService {
    private let model: AppModel
    private var assertion: IOPMAssertionID = 0
    private var holding: (screen: Bool, on: Bool) = (false, false)
    private var lastWorked: Date?
    private var graceCheck: DispatchWorkItem?
    private var powerSource: CFRunLoopSource?

    init(model: AppModel) { self.model = model }

    func start() {
        // Battery changes re-check (plugged in, unplugged, the percent).
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let service = Unmanaged<AwakeService>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { service.update() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
        update()
    }

    /// Call when agents change, or the mode or a setting does.
    func update() {
        let working = model.board.working
        if working > 0 { lastWorked = Date() }
        let hold = KeepAwake.shouldHold(mode: model.awakeMode, working: working, lastWorked: lastWorked, now: Date(),
                                        battery: Self.battery(), batteryLimit: model.awakeBatteryLimit)
        set(hold: hold, screen: model.awakeScreen)
        if model.keepingAwake != hold { model.keepingAwake = hold }
        // Auto with no agent working: look again when the grace runs out.
        graceCheck?.cancel()
        if hold, model.awakeMode == .auto, working == 0, let lastWorked {
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.update() } }
            graceCheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(1, KeepAwake.graceEnds(lastWorked: lastWorked).timeIntervalSinceNow + 1), execute: work)
        }
    }

    private func set(hold: Bool, screen: Bool) {
        guard hold != holding.on || (hold && screen != holding.screen) else { return }
        if holding.on { IOPMAssertionRelease(assertion); assertion = 0 }
        holding = (screen, hold)
        guard hold else { return }
        let type = (screen ? kIOPMAssertPreventUserIdleDisplaySleep : kIOPMAssertPreventUserIdleSystemSleep) as CFString
        IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Visor: agents are working" as CFString, &assertion)
    }

    /// Plugged in, or the battery's percent.
    private static func battery() -> KeepAwake.Battery {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return .pluggedIn }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            if description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue { return .pluggedIn }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 100, maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
            return .battery(percent: maximum > 0 ? current * 100 / maximum : 100)
        }
        return .pluggedIn
    }
}

/// The keep-awake cup in the Agents tab's bar: Auto (outlined, "auto"), On
/// (filled), Off (grey). A click moves to the next.
struct AwakeCup: View {
    let model: AppModel

    var body: some View {
        let mode = model.awakeMode
        Button { model.awakeMode = mode.next } label: {
            HStack(spacing: 2) {
                Image(systemName: mode == .on ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(DS.font(.sm, .semibold))
                if mode == .auto { Text("auto").font(DS.font(.xs, .semibold)) }
            }
            .foregroundStyle(mode == .off ? Theme.textMuted : AwakeCup.amber)
            .padding(.horizontal, 6).frame(height: 20)
            .background(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .fill(mode == .on ? AwakeCup.amber.opacity(DS.Fill.Opacity.strong)
                      : mode == .auto ? AwakeCup.amber.opacity(DS.Fill.Opacity.subtle) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Self.help(mode, holding: model.keepingAwake))
    }

    /// The cup's own amber, never an approval's (the closed notch shows it too).
    static let amber = Theme.awake

    static func help(_ mode: KeepAwake.Mode, holding: Bool) -> String {
        switch mode {
        case .auto: return "Keep awake while agents work" + (holding ? " (keeping your Mac awake now)" : "") + ". Click to keep it awake always."
        case .on: return "Keeping your Mac awake until you click again. Click to turn off."
        case .off: return "Your Mac sleeps as usual. Click for Auto: awake while agents work."
        }
    }
}
