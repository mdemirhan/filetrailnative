// Port of the key names of tools/capture/electron/driver.ts (DOM `KeyboardEvent.key`); no TypeScript source.
#if DEBUG
    import AppKit

    /// Turns a scenario's `key` step (DOM key names, modifiers `cmd`, `shift`, `option`, `ctrl`) into
    /// AppKit key events.
    enum KeyEvents {
        struct Key: Equatable {
            var keyCode: UInt16
            var characters: String
            var isFunctionKey = false
        }

        static func modifiers(_ names: [String]) -> NSEvent.ModifierFlags? {
            var flags: NSEvent.ModifierFlags = []
            for name in names {
                switch name.lowercased() {
                case "cmd", "command", "meta": flags.insert(.command)
                case "shift": flags.insert(.shift)
                case "option", "alt": flags.insert(.option)
                case "ctrl", "control": flags.insert(.control)
                default: return nil
                }
            }
            return flags
        }

        static func key(named name: String) -> Key? {
            if let named = namedKeys[name] { return named }
            guard name.count == 1, let code = characterCodes[name.lowercased()] else { return nil }
            return Key(keyCode: code, characters: name)
        }

        private static func function(_ code: UInt16, _ scalar: Int) -> Key {
            Key(keyCode: code, characters: String(utf16CodeUnits: [UInt16(scalar)], count: 1), isFunctionKey: true)
        }

        private static let namedKeys: [String: Key] = [
            "Enter": Key(keyCode: 36, characters: "\r"),
            "Return": Key(keyCode: 36, characters: "\r"),
            "Escape": Key(keyCode: 53, characters: "\u{1b}"),
            "Tab": Key(keyCode: 48, characters: "\t"),
            "Backspace": Key(keyCode: 51, characters: "\u{7f}"),
            "Space": Key(keyCode: 49, characters: " "),
            " ": Key(keyCode: 49, characters: " "),
            "Delete": function(117, NSDeleteFunctionKey),
            "ArrowUp": function(126, NSUpArrowFunctionKey),
            "ArrowDown": function(125, NSDownArrowFunctionKey),
            "ArrowLeft": function(123, NSLeftArrowFunctionKey),
            "ArrowRight": function(124, NSRightArrowFunctionKey),
            "Home": function(115, NSHomeFunctionKey),
            "End": function(119, NSEndFunctionKey),
            "PageUp": function(116, NSPageUpFunctionKey),
            "PageDown": function(121, NSPageDownFunctionKey),
            "F2": function(120, NSF2FunctionKey),
        ]

        /// ANSI key codes.
        private static let characterCodes: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
            "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
            ".": 47, "`": 50,
        ]

        /// Key down and key up events for `window`.
        @MainActor
        static func events(_ key: Key, modifiers: NSEvent.ModifierFlags, window: NSWindow) -> [NSEvent] {
            var flags = modifiers
            if key.isFunctionKey { flags.formUnion([.function, .numericPad]) }
            let characters = modifiers.contains(.shift) ? key.characters.uppercased() : key.characters
            return [NSEvent.EventType.keyDown, .keyUp].compactMap { type in
                NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    characters: characters,
                    charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.keyCode)
            }
        }
    }
#endif
