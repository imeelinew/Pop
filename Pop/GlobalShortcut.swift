import AppKit
import Carbon

@MainActor
final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var current: Configuration.Shortcut?
    var onPress: (() -> Void)?

    init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue().onPress?()
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        precondition(status == noErr, "Cannot install hot key handler")
    }

    func register(_ shortcut: Configuration.Shortcut) throws {
        if current?.key == shortcut.key, current?.modifiers == shortcut.modifiers { return }
        guard let keyCode = Self.keys[shortcut.key.lowercased()], !shortcut.modifiers.isEmpty else {
            throw PopError.message("Invalid shortcut key or modifiers.")
        }
        let masks: [String: UInt32] = ["command": UInt32(cmdKey), "option": UInt32(optionKey),
                                       "control": UInt32(controlKey), "shift": UInt32(shiftKey)]
        var modifiers: UInt32 = 0
        for modifier in shortcut.modifiers {
            guard let mask = masks[modifier.lowercased()] else {
                throw PopError.message("Invalid shortcut modifier.")
            }
            modifiers |= mask
        }
        var next: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers,
                                        EventHotKeyID(signature: 0x506F7020, id: 1),
                                        GetApplicationEventTarget(), 0, &next)
        guard status == noErr else {
            throw PopError.message("Shortcut unavailable. Choose another in config.toml.")
        }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = next
        current = shortcut
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }

    private static let keys: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
        "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "return": 36,
        "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, "tab": 48, "space": 49,
        "escape": 53, "f17": 64, "f18": 79, "f19": 80, "f20": 90, "f5": 96,
        "f6": 97, "f7": 98, "f3": 99, "f8": 100, "f9": 101, "f11": 103,
        "f13": 105, "f16": 106, "f14": 107, "f10": 109, "f12": 111, "f15": 113,
        "f4": 118, "f2": 120, "f1": 122, "left": 123, "right": 124, "down": 125, "up": 126
    ]
}
