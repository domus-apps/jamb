import AppKit

/* Chromium browsers ship with their web-content accessibility tree off,
   and no external signal can turn it on (AXManualAccessibility is
   Electron-only; modern Chromium ignores AXEnhancedUserInterface). The
   tell is unambiguous: with the tree on, every window contains an
   AXWebArea. When a scan runs into a known Chromium browser without one,
   this walks the user through the browser-side switch — once per browser.

   Safari (WebKit) exposes web content by default and Electron apps answer
   AXManualAccessibility, so neither belongs here. */
enum BrowserOnboarding {
    private static let chromiumBrowsers: [String: String] = [
        "com.brave.Browser": "brave://accessibility",
        "com.google.Chrome": "chrome://accessibility",
        "com.microsoft.edgemac": "edge://accessibility",
        "company.thebrowser.Browser": "arc://accessibility",
        "com.vivaldi.Vivaldi": "vivaldi://accessibility",
        "org.chromium.Chromium": "chrome://accessibility",
    ]

    static func isChromiumBrowser(pid: pid_t) -> Bool {
        guard let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        else { return false }
        return chromiumBrowsers[bundleID] != nil
    }

    /* Main thread. Shows the walkthrough once per browser; the settings
       address goes to the clipboard because chrome:// URLs can't be opened
       from outside the browser. */
    static func offerIfNeeded(forPID pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid),
            let bundleID = app.bundleIdentifier,
            let address = chromiumBrowsers[bundleID]
        else { return }
        let shownKey = "onboarding.webAccessibility.\(bundleID)"
        guard !UserDefaults.standard.bool(forKey: shownKey) else { return }
        UserDefaults.standard.set(true, forKey: shownKey)

        let name = app.localizedName ?? "This browser"
        let alert = NSAlert()
        alert.messageText = "Enable web accessibility in \(name)"
        alert.informativeText = """
            \(name) doesn't expose web pages to accessibility tools by \
            default, so Jamb can only label its address bar — not inputs \
            inside pages.

            1. Open \(address) (the button below copies it — paste it into \
            the address bar)
            2. Check BOTH “Native accessibility API support” and \
            “Web accessibility”
            3. Reload the tab

            To make it permanent, launch \(name) with \
            --force-renderer-accessibility.
            """
        alert.addButton(withTitle: "Copy Address")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(address, forType: .string)
        }
    }
}
