import AppKit
import Carbon
import LedgerMac

private struct TestFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw TestFailure(message: message) }
}

/// Creates only a Carbon event addressed to this process; never synthesizes a keyboard press.
@MainActor @discardableResult private func send(_ identifier: EventHotKeyID?) throws -> OSStatus {
    var event: EventRef?
    let created = CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                              GetCurrentEventTime(), EventAttributes(kEventAttributeNone), &event)
    guard created == noErr, let event else { throw TestFailure(message: "CreateEvent failed: \(created)") }
    defer { ReleaseEvent(event) }
    if var identifier {
        let status = SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       MemoryLayout<EventHotKeyID>.size, &identifier)
        guard status == noErr else { throw TestFailure(message: "SetEventParameter failed: \(status)") }
    }
    return SendEventToEventTarget(event, GetApplicationEventTarget())
}

/// Registers a counting action, never the screenshot service, and always unregisters before exit.
@main struct LedgerHotKeyTests {
    @MainActor static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let hotKey = GlobalHotKey()
        defer { hotKey.unregister() }
        var count = 0
        do { try hotKey.register { count += 1 } }
        catch {
            if error.localizedDescription.contains("占用") {
                print("SKIP: Control + Option + L is unavailable; no hotkey was taken over.")
                return
            }
            print("FAIL: hotkey registration: \(error.localizedDescription)")
            hotKey.unregister()
            exit(1)
        }

        let own = EventHotKeyID(signature: 0x504C4544, id: 1)
        var failures = 0
        var total = 0
        func run(_ name: String, _ operation: () async throws -> Void) async {
            total += 1
            do { try await operation(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error.localizedDescription)") }
        }

        await run("registered Carbon event invokes the counting action once") {
            let before = count
            let status = try send(own)
            try await Task.sleep(for: .milliseconds(30))
            try expect(status == noErr && count == before + 1, "Own hotkey did not invoke exactly one callback")
        }
        await run("another hotkey signature is ignored") {
            let before = count
            try send(EventHotKeyID(signature: 0x54455354, id: own.id))
            try await Task.sleep(for: .milliseconds(30))
            try expect(count == before, "A different hotkey signature invoked our action")
        }
        await run("another hotkey ID is ignored") {
            let before = count
            try send(EventHotKeyID(signature: own.signature, id: 999))
            try await Task.sleep(for: .milliseconds(30))
            try expect(count == before, "A different hotkey ID invoked our action")
        }
        await run("a hotkey event without an ID is ignored") {
            let before = count
            try send(nil)
            try await Task.sleep(for: .milliseconds(30))
            try expect(count == before, "A malformed hotkey event invoked our action")
        }
        await run("same-process registration conflict leaves the first hotkey working") {
            let conflicting = GlobalHotKey()
            defer { conflicting.unregister() }
            var conflictingCount = 0
            var rejected = false
            do { try conflicting.register { conflictingCount += 1 } }
            catch { rejected = true }
            let before = count
            try send(own)
            try await Task.sleep(for: .milliseconds(30))
            try expect(rejected && conflictingCount == 0 && count == before + 1,
                       "Conflicting registration replaced or disabled the original callback")
        }
        await run("re-register does not deliver an older event to the replacement action") {
            let before = count
            var replacementCount = 0
            try send(own)
            try hotKey.register { replacementCount += 1 }
            try await Task.sleep(for: .milliseconds(30))
            try expect(count == before && replacementCount == 0, "An old event crossed into a new registration")
            try send(own)
            try await Task.sleep(for: .milliseconds(30))
            try expect(replacementCount == 1, "Re-registered hotkey did not invoke its new action")
            try hotKey.register { count += 1 }
        }
        await run("unregister discards a callback queued before unregister") {
            let before = count
            try send(own)
            hotKey.unregister()
            try await Task.sleep(for: .milliseconds(30))
            try expect(count == before, "A queued callback still ran after unregister")
        }
        await run("an event sent after unregister invokes no action") {
            let before = count
            let status = try send(own)
            try await Task.sleep(for: .milliseconds(30))
            try expect(status == eventNotHandledErr && count == before,
                       "Unregistered hotkey still handled an event")
        }
        hotKey.unregister()
        print("\(total - failures)/\(total) Carbon hotkey tests passed. Process-local events only; no screenshot, AI, credentials or user ledger used.")
        if failures > 0 { exit(1) }
    }
}
