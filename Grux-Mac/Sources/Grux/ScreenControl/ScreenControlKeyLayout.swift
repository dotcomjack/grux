import Carbon.HIToolbox
import CoreGraphics
import Foundation

// What a key combo ACTUALLY types, asked of the operating system rather than
// asserted from a table.
//
// This exists because of a defect that a keycode test could not have caught.
// `namedKeyCodes` maps both "plus" and "equals" to 0x18, which is correct: they
// are the same physical key. What was missing is that "+" is the SHIFTED face of
// it, and `pressKey` only set flags from the modifier tokens in the combo. So
// `keys="plus"` posted an unshifted 0x18 and typed "=".
//
// A test asserting `keyCode(for: "plus") == 0x18` passes on the broken code and
// on the fixed code, because the keycode was never the wrong part. The only
// check that separates them is asking what CHARACTER the (keycode, flags) pair
// produces, and the only authority on that is the keyboard layout the user is
// actually running.
//
// `UCKeyTranslate` is that authority. Measured 2026-08-23, the obvious
// alternative does NOT work: `CGEvent.keyboardGetUnicodeString` ignores the
// event's `flags` and returns "=" for a shifted 0x18 as readily as for a bare
// one, so a test written on it would have passed against the bug.
//
// The layout dependency is a FEATURE of this check, not a caveat. `keyCode(for:)`
// is documented as a US-layout table, and on a layout where that is untrue this
// reports the real character rather than the one we hoped for.
extension ScreenControlEngine {

    /// The character `pressKey(combo:)` would actually type on THIS machine's
    /// current keyboard layout. Nil when the combo does not resolve to a key, or
    /// when the key produces no character (return, tab, the arrows, F-keys).
    ///
    /// Reads the same `(flags, keyCode)` pair `pressKey` posts, so it cannot
    /// drift from the thing it describes.
    static func producedCharacter(for combo: String) -> String? {
        guard let (flags, name) = parseCombo(combo), let code = keyCode(for: name) else { return nil }
        return character(forKeyCode: code, flags: flags)
    }

    /// The name of the keyboard layout the answers above are relative to, so a
    /// failure says "you are on AZERTY" instead of just "expected + got =".
    static func currentKeyboardLayoutName() -> String? {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(src, kTISPropertyLocalizedName) else { return nil }
        return (Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String)
    }

    /// Translate a hardware keycode plus modifier flags into the character the
    /// active layout maps them to.
    static func character(forKeyCode code: CGKeyCode, flags: CGEventFlags) -> String? {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data

        // UCKeyTranslate wants Carbon modifiers in the high byte's position.
        var carbon: UInt32 = 0
        if flags.contains(.maskShift)     { carbon |= UInt32(shiftKey >> 8) }
        if flags.contains(.maskAlternate) { carbon |= UInt32(optionKey >> 8) }
        if flags.contains(.maskCommand)   { carbon |= UInt32(cmdKey >> 8) }
        if flags.contains(.maskControl)   { carbon |= UInt32(controlKey >> 8) }

        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        let status = data.withUnsafeBytes { buf -> OSStatus in
            guard let layout = buf.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), carbon,
                                  UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                  &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length)

        // A key that types NOTHING must report nothing, and the layout does not
        // say so by returning an empty string. macOS maps the function keys, the
        // arrows and the navigation keys into the Unicode private use area
        // (U+F700 to U+F8FF), and "return" and "tab" translate to control
        // characters. Measured: `f5` came back as a non-empty, unprintable
        // U+F700-block string, so a plain length check calls it a character.
        guard let first = s.unicodeScalars.first else { return nil }
        let isFunctionKey = (0xF700...0xF8FF).contains(first.value)
        let isControl = first.value < 0x20 || first.value == 0x7F
        return (isFunctionKey || isControl) ? nil : s
    }
}
