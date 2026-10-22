import AppKit
import Carbon
import Foundation

/// A key combination for the global hotkey (Carbon key code + Carbon modifier mask).
struct HotKeyCombo: Equatable {
    var keyCode: UInt32
    var carbonMods: UInt32

    static let defaultCombo = HotKeyCombo(keyCode: UInt32(kVK_ANSI_M), carbonMods: UInt32(optionKey))

    init(keyCode: UInt32, carbonMods: UInt32) { self.keyCode = keyCode; self.carbonMods = carbonMods }

    init?(event: NSEvent) {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        // Require at least one of ⌘ ⌥ ⌃ so plain typing is never swallowed.
        guard m & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), carbonMods: m)
    }

    var display: String {
        var s = ""
        if carbonMods & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonMods & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonMods & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonMods & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: break
        }
        let fkeys: [Int: String] = [kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                                    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        if let f = fkeys[Int(code)] { return f }
        // Character for this key on the current keyboard layout.
        if let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var len = 0
            let r = data.withUnsafeBytes { raw -> OSStatus in
                guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
                return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                      OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
            }
            if r == noErr, len > 0 { return String(utf16CodeUnits: chars, count: len).uppercased() }
        }
        return "#\(code)"
    }

    /// Is this combo also bound to an enabled macOS system shortcut (System Settings → Keyboard Shortcuts)?
    var conflictsWithSystemShortcut: Bool {
        var arr: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&arr) == noErr, let list = arr?.takeRetainedValue() as? [[String: Any]] else { return false }
        let relevant = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        for d in list {
            guard (d[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = (d[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value,
                  let mods = (d[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value else { continue }
            if code == keyCode && (mods & relevant) == (carbonMods & relevant) { return true }
        }
        return false
    }
}

/// User preferences for the global hotkey (local UserDefaults only).
enum HotKeyPrefs {
    private static let d = UserDefaults.standard
    static var enabled: Bool {
        get { d.object(forKey: "hotKeyEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "hotKeyEnabled") }
    }
    static var combo: HotKeyCombo {
        get {
            guard let k = d.object(forKey: "hotKeyCode") as? Int, let m = d.object(forKey: "hotKeyMods") as? Int
            else { return .defaultCombo }
            return HotKeyCombo(keyCode: UInt32(k), carbonMods: UInt32(m))
        }
        set { d.set(Int(newValue.keyCode), forKey: "hotKeyCode"); d.set(Int(newValue.carbonMods), forKey: "hotKeyMods") }
    }
}

/// Global hotkey via Carbon RegisterEventHotKey (no Accessibility permission needed).
enum HotKey {
    enum Result: Equatable { case ok, disabled, taken, systemConflict, failed(OSStatus) }

    static var handler: (() -> Void)?
    static var hotKeyRef: EventHotKeyRef?
    static var handlerRef: EventHandlerRef?
    private(set) static var lastResult: Result = .disabled

    static func setHandler(_ action: @escaping () -> Void) {
        handler = action
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { HotKey.handler?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        if status != noErr { NSLog("Musecube: InstallEventHandler failed \(status)") }
    }

    static func unregister() {
        if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
    }

    /// (Re)registers the saved combo. Disabled → nothing is registered, so no combo can summon the window.
    @discardableResult
    static func apply() -> Result {
        unregister()
        guard HotKeyPrefs.enabled else { lastResult = .disabled; return .disabled }
        let c = HotKeyPrefs.combo
        lastResult = register(c)
        return lastResult
    }

    static func register(_ c: HotKeyCombo) -> Result {
        let id = EventHotKeyID(signature: OSType(0x5754_4258), id: 1) // 'WTBX'
        var ref: EventHotKeyRef?
        let r = RegisterEventHotKey(c.keyCode, c.carbonMods, id, GetApplicationEventTarget(),
                                    OptionBits(kEventHotKeyExclusive), &ref)
        if r == noErr {
            hotKeyRef = ref
            // Registration can succeed even when macOS itself uses the combo (e.g. input source switching).
            return c.conflictsWithSystemShortcut ? .systemConflict : .ok
        }
        NSLog("Musecube: RegisterEventHotKey failed \(r) for \(c.display)")
        return r == OSStatus(eventHotKeyExistsErr) ? .taken : .failed(r)
    }

    /// Test a combo without keeping it (used by the recorder before saving).
    static func probe(_ c: HotKeyCombo) -> Result {
        let id = EventHotKeyID(signature: OSType(0x5754_4258), id: 2)
        var ref: EventHotKeyRef?
        let r = RegisterEventHotKey(c.keyCode, c.carbonMods, id, GetApplicationEventTarget(),
                                    OptionBits(kEventHotKeyExclusive), &ref)
        if r == noErr, let ref = ref { UnregisterEventHotKey(ref); return c.conflictsWithSystemShortcut ? .systemConflict : .ok }
        return r == OSStatus(eventHotKeyExistsErr) ? .taken : .failed(r)
    }
}
