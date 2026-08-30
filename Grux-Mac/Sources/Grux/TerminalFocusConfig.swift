import Foundation

// Persisted configuration for the Terminal Focus overlay.
//
// Stored at ~/Library/Application Support/Grux/terminal-focus.json via
// Persistence's generic load/save. Touched by:
//   * Settings UI (slot mapping dropdowns + hotkey recorder)
//   * State layer (overlayVisible flips when the user toggles the overlay)
//   * Lifecycle (GruxApp reads hotkey at launch to register Carbon hotkey)
struct TerminalFocusConfig: Codable, Equatable {
    var slotMapping: SlotMapping
    var hotkey: HotkeyConfig
    var overlayVisible: Bool

    static let `default` = TerminalFocusConfig(
        slotMapping: .empty,
        hotkey: .defaultTerminalFocus,
        overlayVisible: false
    )

    static func load() -> TerminalFocusConfig {
        Persistence.load(
            TerminalFocusConfig.self,
            from: Persistence.terminalFocusConfigURL,
            fallback: .default
        )
    }

    func save() {
        Persistence.save(self, to: Persistence.terminalFocusConfigURL)
    }
}

// Carbon-style hotkey config. keyCode is a Carbon virtual key code
// (kVK_ANSI_T == 17 for 'T'); modifiers is the bitwise-OR of Carbon
// modifier masks (cmdKey = 256, optionKey = 2048, shiftKey = 512,
// controlKey = 4096).
struct HotkeyConfig: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    // ⌥⌘T = optionKey | cmdKey = 2304; keyCode 17 = ANSI T.
    static let defaultTerminalFocus = HotkeyConfig(keyCode: 17, modifiers: 256 | 2048)

    // Pretty-print for the Settings row. Order matches Apple's menu
    // convention: ctrl opt shift cmd.
    var displayString: String {
        var s = ""
        if modifiers & 4096 != 0 { s += "⌃" }
        if modifiers & 2048 != 0 { s += "⌥" }
        if modifiers & 512  != 0 { s += "⇧" }
        if modifiers & 256  != 0 { s += "⌘" }
        s += HotkeyConfig.keyCodeName(keyCode)
        return s
    }

    // Minimal map covering the letters + common keys a user is likely to
    // assign. Unmapped codes render as "?" - we still register them, this
    // is just for display.
    static func keyCodeName(_ code: UInt32) -> String {
        switch code {
        case 0: return "A"; case 11: return "B"; case 8: return "C"
        case 2: return "D"; case 14: return "E"; case 3: return "F"
        case 5: return "G"; case 4: return "H"; case 34: return "I"
        case 38: return "J"; case 40: return "K"; case 37: return "L"
        case 46: return "M"; case 45: return "N"; case 31: return "O"
        case 35: return "P"; case 12: return "Q"; case 15: return "R"
        case 1: return "S"; case 17: return "T"; case 32: return "U"
        case 9: return "V"; case 13: return "W"; case 7: return "X"
        case 16: return "Y"; case 6: return "Z"
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 53: return "Esc"
        default: return "?"
        }
    }
}
