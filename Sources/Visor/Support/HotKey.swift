import Carbon.HIToolbox
import Foundation

/// A global keyboard shortcut (⌘⇧V for clipboard history). Uses the Carbon
/// hot key API, which needs no permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    private static var all: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        let id = Self.nextID
        Self.nextID += 1
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            HotKey.all[hotKeyID.id]?.action()
            return noErr
        }, 1, &spec, nil, &handler)
        guard status == noErr else { return nil }
        let hotKeyID = EventHotKeyID(signature: OSType(0x5649_5352), id: id) // "VISR"
        guard RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr else { return nil }
        Self.all[id] = self
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// ⌘⇧V
    static func clipboard(_ action: @escaping () -> Void) -> HotKey? {
        HotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey), action: action)
    }
}
