import AppKit
import Carbon

/// A global keyboard shortcut (design_code.md §8.1 "Shortcut", §9 `hotkey`): a virtual key code, Carbon
/// modifier flags (`controlKey | optionKey`…) and the key's label as recorded ("G", "Space", "F5").
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var key: String

    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(controlKey | optionKey), key: "G")

    /// Keycap glyphs in the system order ⌃ ⌥ ⇧ ⌘, then the key: ["⌃", "⌥", "G"].
    var glyphs: [String] {
        var g: [String] = []
        if modifiers & UInt32(controlKey) != 0 { g.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { g.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { g.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { g.append("⌘") }
        g.append(key)
        return g
    }

    /// "⌃⌥G".
    var display: String { glyphs.joined() }

    /// The shortcut as an `NSMenuItem` key equivalent, when the key is a plain character.
    var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard key.count == 1, let c = key.lowercased().unicodeScalars.first, c.value < 0xF700,
              CharacterSet.alphanumerics.union(.punctuationCharacters).union(.symbols).contains(c) else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return (key.lowercased(), flags)
    }

    /// Why a key press can't become the shortcut.
    enum RecordError: Error, Equatable {
        /// None of ⌃ ⌥ ⌘ held (⇧ alone isn't enough: it would take a capital letter from every app).
        case needsModifier
        /// A modifier key on its own, or a key with no usable label.
        case notAKey
    }

    /// The shortcut a key-down event records.
    static func record(_ event: NSEvent) -> Result<Shortcut, RecordError> {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.control, .option, .command]).isEmpty else { return .failure(.needsModifier) }
        guard let key = label(for: event) else { return .failure(.notAKey) }
        var mods = 0
        if flags.contains(.control) { mods |= controlKey }
        if flags.contains(.option) { mods |= optionKey }
        if flags.contains(.shift) { mods |= shiftKey }
        if flags.contains(.command) { mods |= cmdKey }
        return .success(Shortcut(keyCode: UInt32(event.keyCode), modifiers: UInt32(mods), key: key))
    }

    /// The key's label: a glyph or name for special keys, else the character the key types with no modifiers.
    private static func label(for event: NSEvent) -> String? {
        if let named = named[Int(event.keyCode)] { return named }
        guard let chars = event.characters(byApplyingModifiers: []), let c = chars.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(c), c.value < 0xF700 else { return nil }
        return chars.uppercased()
    }

    private static let named: [Int: String] = {
        var m: [Int: String] = [
            kVK_Return: "⏎", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑",
            kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        ]
        let f = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                 kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (i, code) in f.enumerated() { m[code] = "F\(i + 1)" }
        return m
    }()

    /// True when an enabled macOS shortcut (System Settings › Keyboard › Keyboard Shortcuts) uses this
    /// key and these modifiers.
    var isSystemShortcut: Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let list = unmanaged?.takeRetainedValue() as? [[String: Any]]
        else { return false }
        let relevant = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        return list.contains { entry in
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value,
                  let mods = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value
            else { return false }
            return code == keyCode && mods & relevant == modifiers & relevant
        }
    }
}
