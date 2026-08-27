import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let hotKeys = HotKeyCenter()
    private let overlay = JumpOverlayController()
    private let shortcutStore = ShortcutStore()
    private let updater = UpdaterController()
    private var settingsWindowController: SettingsWindowController?
    private var onboardingController: OnboardingWindowController?
    private var jumpMenuItem: NSMenuItem?

    private static let onboardingCompletedKey = "onboarding.completed"

    func applicationDidFinishLaunching(_ notification: Notification) {
        /* A translocated launch relaunches itself from the real bundle —
           nothing else must start in this doomed instance. */
        if TranslocationHealer.healIfNeeded() { return }

        setUpMainMenu()
        setUpStatusItem()
        applyShortcuts()
        observeShortcutChanges()

        /* The Accessibility ask lives inside onboarding — no launch-time
           prompt. Completion is only recorded when onboarding is finished
           properly, so an interrupted (or force-quit) run shows it again. */
        if !UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey)
            || CommandLine.arguments.contains("--onboarding")
        {
            showOnboarding()
        }

        if CommandLine.arguments.contains("--settings") {
            openSettings()
        }
        /* Same report as the menu's Copy Diagnostics, to stdout — twice, so
           the second pass shows the warm field-cache timings. */
        if CommandLine.arguments.contains("--diagnose") {
            let screens = NSScreen.screens.map(\.frame)
            DispatchQueue.global(qos: .userInitiated).async {
                print("— cold —")
                print(FieldScanner.diagnostics(screens: screens))
                print("— warm —")
                print(FieldScanner.diagnostics(screens: screens))
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }

    private func showOnboarding() {
        if onboardingController == nil {
            onboardingController = OnboardingWindowController { [weak self] in
                UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
                self?.onboardingController = nil
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingController?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Shortcuts

    private func applyShortcuts() {
        hotKeys.unregisterAll()
        for action in ShortcutAction.allCases {
            let spec = shortcutStore.spec(for: action)
            hotKeys.register(keyCode: spec.keyCode, modifiers: spec.carbonModifiers) {
                [weak self] in
                self?.perform(action)
            }
        }
        jumpMenuItem?.title =
            "\(ShortcutAction.jump.title)  \(shortcutStore.spec(for: .jump).displayString)"
    }

    private func perform(_ action: ShortcutAction) {
        switch action {
        case .jump: toggleJump()
        }
    }

    private func observeShortcutChanges() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: ShortcutStore.changed, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyShortcuts()
        }
        center.addObserver(
            forName: .shortcutRecordingBegan, object: nil, queue: .main
        ) { [weak self] _ in
            self?.hotKeys.unregisterAll()
        }
        center.addObserver(
            forName: .shortcutRecordingEnded, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyShortcuts()
        }
    }

    private var isScanning = false

    private func toggleJump() {
        if overlay.isActive {
            overlay.cancel()
            return
        }
        guard AXIsProcessTrusted() else {
            NSSound.beep()
            /* Mid-onboarding the permission story is already on screen —
               surface it rather than System Settings. */
            if onboardingController != nil {
                showOnboarding()
            } else {
                openAccessibilitySettings()
            }
            return
        }
        /* A fresh session can't start while batches from the previous scan
           may still be in flight — they would land under the new session's
           labels. The window is at most maxScanBudget. */
        guard !isScanning else { return }
        isScanning = true
        overlay.beginSession()

        /* Screen geometry is captured here, where AppKit wants it; the
           blocking AX work happens off-main inside the scanner, streaming
           each app's fields to the overlay the moment they're found. */
        let screens = NSScreen.screens.map(\.frame)
        let started = CFAbsoluteTimeGetCurrent()
        FieldScanner.scanVisibleFields(
            screens: screens,
            onBatch: { [weak self] batch in
                self?.overlay.add(fields: batch)
            },
            onCompletion: { [weak self] in
                guard let self else { return }
                self.isScanning = false
                if ProcessInfo.processInfo.environment["JAMB_DEBUG_TIMING"] == "1" {
                    NSLog(
                        "Jamb: full scan %.0f ms",
                        (CFAbsoluteTimeGetCurrent() - started) * 1000)
                }
                if self.overlay.isActive, !self.overlay.hasTargets {
                    self.overlay.cancel()
                    NSSound.beep()
                }
            })
    }

    private func openAccessibilitySettings() {
        guard
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security"
                    + "?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /* An accessory app has no visible menu bar, but ⌘-key equivalents are
       still dispatched through the main menu — without one, ⌘W/⌘Q do
       nothing in the settings window. */
    private func setUpMainMenu() {
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(updater.makeMenuItem())
        appMenu.addItem(.separator())
        appMenu.addItem(
            NSMenuItem(
                title: "Quit Jamb",
                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            NSMenuItem(
                title: "Close Window",
                action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(
            NSMenuItem(
                title: "Minimize",
                action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))

        let mainMenu = NSMenu()
        for submenu in [appMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        NSApp.mainMenu = mainMenu
    }

    private func setUpStatusItem() {
        /* A fixed length instead of squareLength: square items are as wide
           as the menu bar is tall, which pads a ~18pt symbol with a lot of
           dead space. 20pt hugs the icon while keeping its natural size —
           the same width every Domus app uses. */
        let item = NSStatusBar.system.statusItem(withLength: 20)
        item.button?.image = NSImage(
            systemSymbolName: "character.cursor.ibeam", accessibilityDescription: "Jamb")

        let menu = NSMenu()
        let version =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let about = NSMenuItem(title: "Jamb \(version)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        /* Informational; applyShortcuts keeps the title current with the
           recorded shortcut. */
        let jumpItem = NSMenuItem(title: ShortcutAction.jump.title, action: nil, keyEquivalent: "")
        jumpMenuItem = jumpItem
        menu.addItem(jumpItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(updater.makeMenuItem())
        /* Remote-debugging aid: one click copies a scan report (per-app
           field counts and timings on THIS machine) for pasting back. */
        let diagnosticsItem = NSMenuItem(
            title: "Copy Diagnostics", action: #selector(copyDiagnostics), keyEquivalent: "")
        diagnosticsItem.target = self
        menu.addItem(diagnosticsItem)
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit Jamb",
                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func copyDiagnostics() {
        let screens = NSScreen.screens.map(\.frame)
        DispatchQueue.global(qos: .userInitiated).async {
            let report = FieldScanner.diagnostics(screens: screens)
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
                NSSound(named: "Glass")?.play()
            }
        }
    }

    /* Accessory apps don't come forward on their own — activate first or
       the window opens behind the current app. */
    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                store: shortcutStore, updater: updater)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }
}
