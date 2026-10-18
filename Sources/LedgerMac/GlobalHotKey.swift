import AppKit
import Carbon
import LedgerCore

@MainActor public final class GlobalHotKey {
    public static let display = "⌃ ⌥ L"
    private static let identifier = EventHotKeyID(signature: 0x504C4544, id: 1)
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?
    private var generation: UInt64 = 0

    public init() {}

    public func register(action: @escaping () -> Void) throws {
        unregister()
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                var identifier = EventHotKeyID(signature: 0, id: 0)
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                guard status == noErr, identifier.signature == GlobalHotKey.identifier.signature,
                      identifier.id == GlobalHotKey.identifier.id else { return OSStatus(eventNotHandledErr) }
                let owner = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
                let generation = owner.generation
                Task { @MainActor [weak owner] in
                    guard let owner, owner.generation == generation else { return }
                    owner.action?()
                }
                return noErr
            }
        }, 1, &eventType, context, &handler)
        guard installStatus == noErr else {
            unregister()
            throw LedgerError.message("全局快捷键监听失败，可继续使用菜单栏的截图按钮。")
        }
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(controlKey | optionKey), Self.identifier,
                                         GetApplicationEventTarget(), 0, &reference)
        guard status == noErr else {
            unregister()
            throw LedgerError.message("⌃⌥L 快捷键已被其他应用占用，可继续使用菜单栏截图。")
        }
    }

    public func unregister() {
        generation &+= 1
        action = nil
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil; handler = nil
    }
}
