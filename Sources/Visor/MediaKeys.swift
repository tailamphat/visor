import AppKit
import ApplicationServices

/// The keyboard's play/pause, next and previous keys. macOS sends them to
/// whatever is playing (the "Now Playing" app), so they control a browser tab
/// even when the browser can't be scripted. Posting key events needs the
/// Accessibility permission, which macOS asks for once.
enum MediaKeys {
    // NX_KEYTYPE_* from IOKit/hidsystem/ev_keymap.h
    private static let play: Int32 = 16
    private static let next: Int32 = 17
    private static let previous: Int32 = 18

    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Opens the Accessibility permission prompt when it hasn't been granted.
    @discardableResult
    static func requestPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Returns false when the permission is missing (and asks for it).
    @discardableResult
    static func send(_ command: MusicCommand) -> Bool {
        guard isAllowed else {
            requestPermission()
            return false
        }
        let key: Int32
        switch command {
        case .playPause: key = play
        case .next: key = next
        case .previous: key = previous
        }
        for down in [true, false] {
            let state: Int32 = down ? 0xA : 0xB
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                           modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state) << 8),
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           subtype: 8, data1: Int((key << 16) | (state << 8)), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
        return true
    }
}
