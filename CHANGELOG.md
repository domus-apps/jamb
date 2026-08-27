# Changelog

All notable changes to Jamb are documented here. The release workflow publishes each version's section as the GitHub release notes and embeds it in the Sparkle appcast, so the in-app update dialog shows the same notes. A release fails early if its version has no section here.

Keep each bullet on a single line: release notes render line breaks literally (both on GitHub and in the update dialog), so wrapped lines would break mid-sentence.

## 1.0.1

- Fixed: installing by COPYING the app (instead of Finder-moving it) left it running from Gatekeeper's translocated read-only path, which blocked Sparkle updates — the app now detects this at launch, clears the quarantine flag, and relaunches itself from its real location.

## 1.0.0

- Initial release: press ⌃⌥J and every text input visible on screen — across all apps and windows — gets a label chip and a highlight; type the label and the caret jumps there, ready to type.
- Cross-app jumps activate the target app and raise its window; fields in background apps work the same as the active one.
- Works with native apps, Electron apps (their accessibility tree is woken automatically), and web pages — Safari out of the box, Chromium browsers after enabling web accessibility (Jamb shows a one-time walkthrough per browser).
- Label keys match by keyboard position, so non-Latin input sources (e.g. Korean) and alternative Latin layouts (Dvorak) both work.
- First-run onboarding gates on the Accessibility permission; a customizable global shortcut lives in Settings, and Sparkle keeps the app up to date.
