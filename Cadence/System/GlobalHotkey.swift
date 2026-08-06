import AppKit
import Carbon.HIToolbox

/// A single system-wide hotkey (⌥Space by default) for quick capture.
///
/// Carbon's `RegisterEventHotKey` is still the only way to get a global hotkey
/// without requesting Accessibility permission, so it is what this uses.
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    var onFire: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let identifier = EventHotKeyID(signature: 0x4341_4443 /* 'CADC' */, id: 1)

    private init() {}

    /// Defaults to ⌥Space.
    func register(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(optionKey)) {
        unregister()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var firedID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &firedID
                )
                guard firedID.id == GlobalHotkey.shared.identifier.id else { return noErr }
                DispatchQueue.main.async { GlobalHotkey.shared.onFire?() }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handlerRef
        )

        RegisterEventHotKey(
            keyCode,
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }
}
