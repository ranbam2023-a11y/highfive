//
//  Shortcut.swift — parse and post a keyboard shortcut.
//
//  Shortcuts are written as text ("cmd+shift+4", "option+f", "⌥F") so they can
//  live in the settings JSON. Posting a key event to another app needs the
//  Accessibility permission; see HighFiveAugment's requirement.
//

import Foundation
import AppKit
import ApplicationServices

struct KeyCombo: Equatable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags

    /// Human-readable form, e.g. "⌥F".
    var display: String {
        var text = ""
        if flags.contains(.maskControl) { text += "⌃" }
        if flags.contains(.maskAlternate) { text += "⌥" }
        if flags.contains(.maskShift) { text += "⇧" }
        if flags.contains(.maskCommand) { text += "⌘" }
        return text + (ShortcutParser.names[keyCode] ?? "?")
    }
}

enum ShortcutParser {

    /// ANSI virtual key codes (Carbon's kVK_* values, hard-coded so we don't
    /// need the Carbon module).
    static let keyCodes: [String: CGKeyCode] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "o": 0x1F,
        "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28,
        "n": 0x2D, "m": 0x2E,

        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17,
        "9": 0x19, "7": 0x1A, "8": 0x1C, "0": 0x1D,

        "=": 0x18, "-": 0x1B, "]": 0x1E, "[": 0x21, "'": 0x27, ";": 0x29,
        "\\": 0x2A, ",": 0x2B, "/": 0x2C, ".": 0x2F, "`": 0x32,

        "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31,
        "delete": 0x33, "backspace": 0x33, "escape": 0x35, "esc": 0x35,
        "forwarddelete": 0x75,

        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,

        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
        "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F
    ]

    static let names: [CGKeyCode: String] = {
        var map: [CGKeyCode: String] = [:]
        for (name, code) in keyCodes where map[code] == nil { map[code] = name.uppercased() }
        return map
    }()

    private static let modifierSymbols: [(Character, CGEventFlags)] = [
        ("⌘", .maskCommand),
        ("⌥", .maskAlternate),
        ("⌃", .maskControl),
        ("⇧", .maskShift)
    ]

    static func parse(_ text: String) -> KeyCombo? {
        var flags: CGEventFlags = []
        var work = text.trimmingCharacters(in: .whitespaces)
        guard !work.isEmpty else { return nil }

        // Compact form, e.g. "⌥F" or "⌘⇧4".
        var scanning = true
        while scanning {
            scanning = false
            for (symbol, flag) in modifierSymbols where work.first == symbol {
                flags.insert(flag)
                work.removeFirst()
                scanning = true
            }
        }

        let tokens: [String]
        if work.contains("+") {
            tokens = work.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        } else {
            tokens = [work.lowercased()]
        }

        var keyToken: String?
        for token in tokens {
            switch token {
            case "", "cmd", "command", "⌘": if token != "" { flags.insert(.maskCommand) }
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "shift", "⇧": flags.insert(.maskShift)
            case "fn": flags.insert(.maskSecondaryFn)
            default: keyToken = token
            }
        }

        guard let key = keyToken, let code = keyCodes[key] else { return nil }
        return KeyCombo(keyCode: code, flags: flags)
    }
}

enum ShortcutPoster {
    @discardableResult
    static func post(_ combo: KeyCombo) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: false)
        else { return false }

        down.flags = combo.flags
        up.flags = combo.flags
        down.post(tap: .cghidEventTap)
        usleep(15_000)
        up.post(tap: .cghidEventTap)

        log("posted \(combo.display) keyCode=\(combo.keyCode) flags=\(combo.flags.rawValue)")
        return true
    }

    static var hasPermission: Bool { AXIsProcessTrusted() }

    static func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
