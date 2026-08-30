import Carbon
import AppKit

// Thin Carbon wrapper around RegisterEventHotKey / UnregisterEventHotKey /
// InstallEventHandler. Owns a single registration at a time - `register`
// replaces whatever was previously registered. Designed to be called from
// the main actor; the handler closure runs on the main thread.
//
// Caller passes modifiers as a pre-ORed Carbon mask
// (cmdKey=256, shiftKey=512, optionKey=2048, controlKey=4096) so the
// persisted HotkeyConfig.modifiers value can be forwarded verbatim.
@MainActor
final class GlobalHotkey {
    static let shared = GlobalHotkey()
    private init() {}

    private var hotKeyRef: EventHotKeyRef?
    private var handler: (() -> Void)?
    private var eventHandlerInstalled = false
    private let signature: OSType = fourCharCode("GRUX")

    // Replace any existing registration. `handler` runs on the main thread
    // when the user presses the combo. Silently no-ops the registration if
    // Carbon reports a non-noErr status (prints for diagnostics).
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        // Drop any prior registration before taking a new one. We reuse the
        // installed event handler - only the hot-key slot gets replaced.
        unregister()
        self.handler = handler

        installEventHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &newRef
        )
        if status != noErr {
            print("GlobalHotkey: register failed status=\(status)")
            return
        }
        hotKeyRef = newRef
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        // Keep `handler` and the event handler installed - a subsequent
        // register() will reuse them. Clearing the handler on unregister
        // would race with an in-flight dispatched invocation.
    }

    private func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let callback: EventHandlerUPP = { _, eventRef, userData in
            guard let eventRef, let userData else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID(signature: 0, id: 0)
            let getStatus = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID
            )
            guard getStatus == noErr else { return OSStatus(eventNotHandledErr) }
            let instance = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
            // Only fire for our own signature - guards against cross-talk
            // if another Carbon hotkey owner shares the same process.
            guard hkID.signature == instance.signature else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async {
                instance.handler?()
            }
            return noErr
        }

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            selfPtr,
            nil
        )
        if status != noErr {
            print("GlobalHotkey: InstallEventHandler failed status=\(status)")
            return
        }
        eventHandlerInstalled = true
    }
}

// Pack a 4-character ASCII string into an OSType (FourCharCode). Shorter
// strings get padded with spaces; longer strings are truncated to 4. Used
// for the Carbon EventHotKeyID signature.
private func fourCharCode(_ s: String) -> OSType {
    var result: OSType = 0
    let bytes = Array(s.utf8.prefix(4))
    for i in 0..<4 {
        let byte: UInt8 = i < bytes.count ? bytes[i] : 0x20  // pad with space
        result = (result << 8) | OSType(byte)
    }
    return result
}
