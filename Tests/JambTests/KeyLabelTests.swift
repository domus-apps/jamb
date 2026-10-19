import Carbon.HIToolbox
import Testing
@testable import Jamb

/* Labels come from the key code, never from what the active input source
   types. Assertions avoid the letter itself: it depends on the machine's
   Latin layout (K on ABC, T on Dvorak). On the main actor because the
   layout lookup is main-thread only (off it, the stored label stands). */

@MainActor @Test func functionKeysAreNamed() {
    #expect(ShortcutSpec.keyLabel(forKeyCode: UInt32(kVK_F1)) == "F1")
    #expect(ShortcutSpec.keyLabel(forKeyCode: UInt32(kVK_F13)) == "F13")
    #expect(ShortcutSpec.keyLabel(forKeyCode: UInt32(kVK_F20)) == "F20")
}

@MainActor @Test func letterKeysReadAsLatinLetters() throws {
    let label = try #require(ShortcutSpec.keyLabel(forKeyCode: UInt32(kVK_ANSI_K)))
    #expect(label.count == 1)
    #expect(label.unicodeScalars.allSatisfy { $0.isASCII && $0.properties.isUppercase })
}

@MainActor @Test func storedHangulLabelIsRederived() {
    // Recorded by an older build with Korean input on.
    let spec = ShortcutSpec(
        keyCode: UInt32(kVK_ANSI_K), carbonModifiers: UInt32(controlKey), keyLabel: "ㅏ")
    #expect(!spec.displayString.contains("ㅏ"))
    #expect(spec.displayString.hasPrefix("⌃"))
}
