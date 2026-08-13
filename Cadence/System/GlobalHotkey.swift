import AppKit
import Carbon.HIToolbox

/// System-wide hotkeys: quick capture, and starting or stopping the timer.
///
/// Carbon's `RegisterEventHotKey` is still the only way to get a global hotkey
/// without requesting Accessibility permission, so it is what this uses. One
/// event handler serves every hotkey and dispatches on the id it carries —
/// installing a second handler would have both of them see every press.
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    /// What a registered key does. The raw value is the id Carbon hands back
    /// when the key fires, so these must stay distinct and stable.
    enum Action: UInt32, CaseIterable {
        case quickCapture = 1
        case toggleTimer = 2
    }

    /// Carbon's modifier masks, so callers need not import Carbon themselves.
    enum Modifiers {
        static let option = UInt32(optionKey)
        static let optionShift = UInt32(optionKey | shiftKey)
    }

    private var refs: [Action: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = 0x4341_4443 /* 'CADC' */

    private init() {}

    /// ⌥Space for capture, ⌥⇧Space for the timer.
    func register(
        _ action: Action,
        keyCode: UInt32 = UInt32(kVK_Space),
        modifiers: UInt32 = Modifiers.option,
        onFire: @escaping () -> Void
    ) {
        installHandlerIfNeeded()
        unregister(action)
        actions[action.rawValue] = onFire

        var ref: EventHotKeyRef?
        RegisterEventHotKey(
            keyCode,
            modifiers,
            EventHotKeyID(signature: signature, id: action.rawValue),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        refs[action] = ref
    }

    func unregister(_ action: Action) {
        if let ref = refs.removeValue(forKey: action) {
            UnregisterEventHotKey(ref)
        }
        actions[action.rawValue] = nil
    }

    func unregisterAll() {
        for action in Action.allCases { unregister(action) }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }

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
                let id = firedID.id
                DispatchQueue.main.async { GlobalHotkey.shared.actions[id]?() }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handlerRef
        )
    }
}
