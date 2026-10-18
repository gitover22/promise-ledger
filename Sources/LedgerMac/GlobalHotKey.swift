import AppKit
import Carbon
import LedgerCore

@MainActor public final class GlobalHotKey {
    public static let display = "⌃ ⌥ L"
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    public init() {}

    public func register(action: @escaping () -> Void) throws {
        unregister()
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in owner.action?() }
            return noErr
        }, 1, &eventType, context, &handler)
        guard installStatus == noErr else { throw LedgerError.message("全局快捷键监听失败，可继续使用菜单栏的截图按钮。") }
        let identifier = EventHotKeyID(signature: 0x504C4544, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(controlKey | optionKey), identifier,
                                         GetApplicationEventTarget(), 0, &reference)
        guard status == noErr else {
            unregister()
            throw LedgerError.message("⌃⌥L 快捷键已被其他应用占用，可继续使用菜单栏截图。")
        }
    }

    public func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil; handler = nil
    }
}
