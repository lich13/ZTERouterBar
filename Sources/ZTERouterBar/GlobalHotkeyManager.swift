import Carbon
import Foundation

@MainActor
final class GlobalHotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var callback: (@MainActor () -> Void)?

    private static weak var activeInstance: GlobalHotkeyManager?

    func register(enabled: Bool, onTrigger: @escaping @MainActor () -> Void) {
        unregister()
        guard enabled else { return }
        self.callback = onTrigger
        Self.activeInstance = self

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                Task { @MainActor in
                    GlobalHotkeyManager.activeInstance?.callback?()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handlerRef
        )

        guard status == noErr else { return }

        // Control + Option + W (kVK_ANSI_W = 13)
        let hotKeyID = EventHotKeyID(signature: OSType(0x5A544557), id: 1) // 'ZTEW'
        let modifiers = UInt32(controlKey | optionKey)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_W),
            modifiers,
            hotKeyID,
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
        callback = nil
    }
}
