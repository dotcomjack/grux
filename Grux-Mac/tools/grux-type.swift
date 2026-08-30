#!/usr/bin/env swift
// grux-type.swift, type a string into the frontmost app via CGEvent + press Return.
//
// Usage:
//   grux-type <text>
//
// Posts each character as a synthetic keyboard event using CGEvent (Quartz),
// then posts a Return key event. Works around the System-Events automation
// permission denial, CGEvent only needs Accessibility, which Grux already
// has, and the Swift binary inherits the calling chain's permission grant.
//
// On first run, macOS may prompt "<binary> wants to control your computer
// using accessibility features", Jack approves, future runs are silent.

import Foundation
import CoreGraphics

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("usage: grux-type <text>\n".data(using: .utf8)!)
    exit(2)
}

let text = CommandLine.arguments.dropFirst().joined(separator: " ")

// CGEvent supports Unicode string injection via `keyboardSetUnicodeString`,
// avoids per-character key-code translation, handles all printable Unicode
// (incl. emoji, accented chars) in one event. Pair down/up events are required
// for the OS to register the input cleanly.
func postUnicodeBatch(_ s: String) {
    var utf16 = Array(s.utf16)
    let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
    down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
    down.post(tap: .cghidEventTap)
    let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)!
    up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
    up.post(tap: .cghidEventTap)
}

// Long strings: chunk to avoid Unicode buffer overflow + slow huge inputs.
// 200 UTF-16 units per chunk, ~5ms gap.
let CHUNK = 200
var idx = text.startIndex
while idx < text.endIndex {
    let end = text.index(idx, offsetBy: CHUNK, limitedBy: text.endIndex) ?? text.endIndex
    postUnicodeBatch(String(text[idx..<end]))
    idx = end
    if idx < text.endIndex {
        usleep(5_000) // 5ms between chunks
    }
}

// Brief settle so the typed text is fully drained from the event queue
// before the Return key event lands. 80ms is empirically generous.
usleep(80_000)

// Press Return (key code 36).
let returnDown = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true)!
returnDown.post(tap: .cghidEventTap)
let returnUp = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false)!
returnUp.post(tap: .cghidEventTap)
