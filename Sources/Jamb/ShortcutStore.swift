import AppKit
import Carbon.HIToolbox

/* One recordable shortcut: a Carbon-compatible key code + modifier mask,
   plus the key's display label captured at record time (deriving labels
   from key codes needs layout-aware translation; capturing is simpler). */
struct ShortcutSpec: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var keyLabel: String

    var displayString: String {
        var symbols = ""
        if carbonModifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        /* Derived from the key code where it can be, so a label stored by an
           older build (recorded while Korean input was on: "ㅏ") or under
           another layout still reads right. */
        return symbols + (Self.keyLabel(forKeyCode: keyCode) ?? keyLabel)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        return modifiers
    }

    static func keyLabel(for event: NSEvent) -> String {
        keyLabel(forKeyCode: UInt32(event.keyCode))
            ?? event.charactersIgnoringModifiers?.uppercased() ?? "?"
    }

    static func keyLabel(forKeyCode keyCode: UInt32) -> String? {
        switch Int(keyCode) {
        case kVK_Return: return "↩"
        case kVK_ANSI_KeypadEnter: return "⌤"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default:
            if let name = functionKeyNames[Int(keyCode)] { return name }
            return latinCharacters(forKeyCode: UInt16(truncatingIfNeeded: keyCode))?
                .uppercased()
        }
    }

    /* F-keys translate to control characters (F1 is U+0010), which would
       leave the keycap blank. */
    private static let functionKeyNames: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14",
        kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
    ]

    static func latinCharacters(for event: NSEvent) -> String? {
        latinCharacters(forKeyCode: event.keyCode)
    }

    /* The key's character on the ASCII-capable layout, so a shortcut
       recorded with Korean (or any non-Latin) input active reads "K", not
       "ㅏ". The user's own Latin layout is used, which keeps Dvorak and
       friends labeled as their users expect. Control characters (Help,
       Clear, …) and AppKit's private-use function-key glyphs aren't
       labels, so those come back nil. */
    static func latinCharacters(forKeyCode keyCode: UInt16) -> String? {
        /* TIS is main-thread only: HIToolbox aborts the process on
           concurrent calls. Anywhere else the caller's fallback (the
           stored label) stands. */
        guard Thread.isMainThread,
            let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?
                .takeRetainedValue()
        else { return nil }
        /* The layout data is borrowed from the source; keep the source
           alive until the translation is done. */
        let translated: String? = withExtendedLifetime(source) {
            guard
                let layoutPointer = TISGetInputSourceProperty(
                    source, kTISPropertyUnicodeKeyLayoutData)
            else { return nil }
            let layoutData =
                Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
            return layoutData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> String? in
                guard
                    let layout = bytes.baseAddress?.assumingMemoryBound(
                        to: UCKeyboardLayout.self)
                else { return nil }
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, keyCode, UInt16(kUCKeyActionDown), 0,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                    &deadKeyState, characters.count, &length, &characters)
                guard status == noErr, length > 0 else { return nil }
                return String(utf16CodeUnits: characters, count: length)
            }
        }
        guard let translated, let scalar = translated.unicodeScalars.first,
            scalar.value >= 0x20, scalar.value != 0x7F,
            !(0xF700...0xF8FF).contains(scalar.value)
        else { return nil }
        return translated
    }
}

enum ShortcutAction: String, CaseIterable {
    case jump

    var title: String {
        switch self {
        case .jump: L("Jump to Input")
        }
    }

    var defaultSpec: ShortcutSpec {
        switch self {
        case .jump:
            return ShortcutSpec(
                keyCode: UInt32(kVK_ANSI_J),
                carbonModifiers: UInt32(controlKey) | UInt32(optionKey),
                keyLabel: "J")
        }
    }
}

/* Persists user-recorded shortcuts in UserDefaults and broadcasts changes so
   the app re-registers its hotkeys. Note: an unbundled `swift run` process
   and the bundled app use different defaults domains, so recordings made in
   one do not appear in the other. */
final class ShortcutStore {
    static let changed = Notification.Name("Jamb.ShortcutStoreChanged")

    private let defaults = UserDefaults.standard

    func spec(for action: ShortcutAction) -> ShortcutSpec {
        guard let data = defaults.data(forKey: key(for: action)),
            let spec = try? JSONDecoder().decode(ShortcutSpec.self, from: data)
        else { return action.defaultSpec }
        return spec
    }

    func set(_ spec: ShortcutSpec, for action: ShortcutAction) {
        guard let data = try? JSONEncoder().encode(spec) else { return }
        defaults.set(data, forKey: key(for: action))
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    func resetAll() {
        for action in ShortcutAction.allCases {
            defaults.removeObject(forKey: key(for: action))
        }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    private func key(for action: ShortcutAction) -> String {
        "shortcut.\(action.rawValue)"
    }
}
