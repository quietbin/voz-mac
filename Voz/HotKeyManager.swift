//
//  HotKeyManager.swift
//  Voz
//
//  Global hotkey handling. Two mechanisms:
//
//  1. Carbon `RegisterEventHotKey` — a true system-wide hotkey (default:
//     Option+Space). This needs NO special permission and works even when Voz
//     is in the background. This is the recommended / default trigger.
//
//  2. Fn key double-tap — implemented with an NSEvent global monitor on
//     `.flagsChanged`. This requires "Input Monitoring" permission
//     (System Settings → Privacy & Security → Input Monitoring). Offered as an
//     option in Preferences.
//
//  ───────────────────────────────────────────────────────────────────────────
//  HOW TO CHANGE THE DEFAULT HOTKEY: edit `HotKey.defaultHotKey` below. Key
//  codes are the virtual keycodes from Carbon (`kVK_*`). Modifier masks use the
//  Carbon constants (cmdKey, optionKey, controlKey, shiftKey). Or just record a
//  new combo at runtime in Preferences.
//  ───────────────────────────────────────────────────────────────────────────
//

import AppKit
import Carbon.HIToolbox

/// A key combo expressed with Carbon virtual keycode + Carbon modifier mask.
struct HotKey: Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// DEFAULT HOTKEY = Option+Space. Change here if you like.
    static let defaultHotKey = HotKey(keyCode: UInt32(kVK_Space),
                                      carbonModifiers: UInt32(optionKey))

    /// Human-readable form for menus / preferences, e.g. "⌥Space".
    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += HotKey.keyName(for: keyCode)
        return s
    }

    static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Escape: return "Esc"
        case kVK_Tab: return "Tab"
        case kVK_F1: return "F1"; case kVK_F2: return "F2"; case kVK_F3: return "F3"
        case kVK_F4: return "F4"; case kVK_F5: return "F5"; case kVK_F6: return "F6"
        case kVK_F7: return "F7"; case kVK_F8: return "F8"; case kVK_F9: return "F9"
        case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        default:
            // Best-effort: translate the keycode to its character via the current layout.
            if let ch = charForKeyCode(keyCode) { return ch.uppercased() }
            return "Key\(keyCode)"
        }
    }

    /// Convert Cocoa modifier flags (from an NSEvent) to Carbon modifier mask.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        return m
    }

    private static func charForKeyCode(_ keyCode: UInt32) -> String? {
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        guard let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = unsafeBitCast(layoutData, to: CFData.self)
        let keyLayout = unsafeBitCast(CFDataGetBytePtr(data), to: UnsafePointer<UCKeyboardLayout>.self)
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let err = UCKeyTranslate(keyLayout,
                                 UInt16(keyCode),
                                 UInt16(kUCKeyActionDisplay),
                                 0, UInt32(LMGetKbdType()),
                                 UInt32(kUCKeyTranslateNoDeadKeysBit),
                                 &deadKeyState,
                                 chars.count, &length, &chars)
        guard err == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}

final class HotKeyManager {
    /// Called (on the main thread) whenever the configured trigger fires.
    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var fnMonitor: Any?
    private var fnLocalMonitor: Any?
    private var lastFnTap: TimeInterval = 0
    private let hotKeyID = EventHotKeyID(signature: OSType(0x564F5A21 /* 'VOZ!' */), id: 1)

    // Singleton-ish reference so the C event handler can find us.
    fileprivate static weak var active: HotKeyManager?

    /// Called when a shortcut could not be registered, with a human-readable
    /// reason. Wired to the UI so a combo macOS has already claimed says so
    /// instead of appearing to work.
    var onRegistrationFailed: ((String) -> Void)?

    @discardableResult
    func start() -> Bool {
        HotKeyManager.active = self
        stop() // clear any previous registration
        switch Settings.shared.triggerMode {
        case .hotKey:      return registerCarbonHotKey()
        case .fnDoubleTap: installFnMonitor(); return true
        }
    }

    @discardableResult
    func restart() -> Bool { start() }

    func stop() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let handler = eventHandlerRef { RemoveEventHandler(handler); eventHandlerRef = nil }
        if let m = fnMonitor { NSEvent.removeMonitor(m); fnMonitor = nil }
        if let m = fnLocalMonitor { NSEvent.removeMonitor(m); fnLocalMonitor = nil }
    }

    // MARK: - Carbon hotkey

    @discardableResult
    private func registerCarbonHotKey() -> Bool {
        // Install a single application-level handler for hotkey-pressed events.
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if hkID.id == 1 {
                DispatchQueue.main.async { HotKeyManager.active?.onTrigger?() }
            }
            return noErr
        }, 1, &eventType, nil, &eventHandlerRef)

        // RegisterEventHotKey's OSStatus used to be discarded here, and that was
        // a real bug: macOS refuses a combination another app already owns
        // system-wide (Cmd-Space is Spotlight, and it is the first thing people
        // try). The registration failed, Settings had already stored the new
        // shortcut, and the UI showed it as set — so the app looked like it had
        // accepted a hotkey that could never fire, with nothing reported
        // anywhere. Report it instead, and let the caller put the old one back.
        let hk = Settings.shared.hotKey
        let status = RegisterEventHotKey(hk.keyCode, hk.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            hotKeyRef = nil
            NSLog("Voz: could not register hotkey %@ (OSStatus %d)", hk.displayString, status)
            onRegistrationFailed?(Self.failureReason(status, for: hk))
            return false
        }
        return true
    }

    /// eventHotKeyExistsErr is the case worth naming precisely, because the fix
    /// is "pick another combination" rather than anything the user can debug.
    private static func failureReason(_ status: OSStatus, for hk: HotKey) -> String {
        if status == OSStatus(eventHotKeyExistsErr) {
            return "\(hk.displayString) is already used by macOS or another app. Pick a different combination."
        }
        return "Couldn't set \(hk.displayString) as the shortcut. Pick a different combination."
    }

    // MARK: - Fn double-tap

    private func installFnMonitor() {
        // Global monitor sees flag changes system-wide (needs Input Monitoring perm).
        fnMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlags(event)
        }
        // Also add a local monitor so it works when Voz's own windows are focused.
        // Keep the returned token so stop() can remove it — otherwise every
        // start()/restart() leaks another monitor onto our own events.
        fnLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlags(event)
            return event
        }
    }

    private func handleFlags(_ event: NSEvent) {
        // Fire only on the *press* of the Fn key (when .function becomes active).
        guard event.modifierFlags.contains(.function) else { return }
        let now = event.timestamp
        if now - lastFnTap < 0.4 {   // double-tap window: 400 ms
            lastFnTap = 0
            onTrigger?()
        } else {
            lastFnTap = now
        }
    }
}
