# Jamb

Jump the text cursor into any input field on screen, keyboard-only — in the
spirit of VSCode's Jumpy, but system-wide.

Press ⌃⌥J and Jamb walks every window visible on screen — all apps, not
just the active one — through the Accessibility API, finds every visible
text input (fields, text areas, search fields, combo boxes — never
password fields), and overlays each one with a short label chip. Type a
chip's letters and the caret lands at the end of that field's text, ready
for typing — activating that app first if the field lives in a background
window. Escape or a click anywhere dismisses.

## Status

Prototype. Current scope is field-level jumping (caret to end of text)
across the windows of the current Space. The fuller Jumpy treatment —
labels at word positions *inside* each field via `AXBoundsForRange` — is
the planned next step.

## Browsers

Web-page inputs work once the browser exposes its web-content
accessibility tree:

- **Safari/WebKit** exposes it by default — no setup.
- **Chromium** (Chrome, Brave, …) keeps it dormant, and no external signal
  wakes it (`AXManualAccessibility` is Electron-only; modern Chromium
  ignores `AXEnhancedUserInterface`). Enable it in the browser itself: on
  `chrome://accessibility` / `brave://accessibility` check BOTH “Native
  accessibility API support” AND “Web accessibility” (they are separate
  mode bits; one alone does nothing), then reload the tab. For a permanent
  switch launch with `--force-renderer-accessibility`.
- **Electron** apps wake theirs via `AXManualAccessibility`, which Jamb
  sends automatically.

## Requirements

Jamb is built on the Accessibility API, so macOS will prompt for
Accessibility access on first launch (System Settings → Privacy & Security
→ Accessibility). Until granted, the hotkey just beeps.

## Development

```sh
swift run Jamb   # requires granting Accessibility to the built binary
swift test
```
