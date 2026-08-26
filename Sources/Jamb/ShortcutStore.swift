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
        return symbols + keyLabel
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
        switch Int(event.keyCode) {
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
            return event.charactersIgnoringModifiers?.uppercased() ?? "?"
        }
    }
}

enum ShortcutAction: String, CaseIterable {
    case jump

    var title: String {
        switch self {
        case .jump: "Jump to Input"
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
