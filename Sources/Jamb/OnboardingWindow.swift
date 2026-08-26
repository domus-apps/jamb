import AppKit
import Carbon.HIToolbox

/* First-run onboarding: what Jamb is, what it looks like in action, the
   default shortcut, and the Accessibility permission gate. The window has
   no close button and refuses every close attempt — the only way out is
   granting access and clicking Start, and completion is persisted only at
   that click, so quitting (or force-quitting) mid-onboarding brings the
   onboarding back on the next launch. */
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let onComplete: () -> Void
    private var pollTimer: Timer?

    private let statusLabel = NSTextField(labelWithString: "")
    private lazy var requestButton = NSButton(
        title: "Request Accessibility Access", target: self,
        action: #selector(requestAccess))
    private lazy var settingsLink = NSButton(
        title: "Open Privacy & Security Settings…", target: self,
        action: #selector(openSystemSettings))
    private lazy var startButton = NSButton(
        title: "Start Using Jamb", target: self, action: #selector(start))

    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete

        /* No .closable: the traffic-light close button never appears. */
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 596),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        window.center()

        refreshPermissionState()
        /* Permission grants don't notify; polling once a second is the
           standard idiom (the System Settings toggle takes effect live). */
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in
            self?.refreshPermissionState()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /* The gate: no closing until onboarding is completed via start(). */
    func windowShouldClose(_ sender: NSWindow) -> Bool { false }

    // MARK: - Content

    private func makeContent() -> NSView {
        let title = NSTextField(labelWithString: "Welcome to Jamb")
        title.font = .systemFont(ofSize: 30, weight: .bold)

        let intro = NSTextField(
            wrappingLabelWithString:
                "Jamb jumps your text cursor into any input on screen — across every "
                + "app and window — without touching the mouse. Press the shortcut, "
                + "type the label shown on an input, and the caret lands there, "
                + "ready to type.")
        intro.font = .systemFont(ofSize: 14)
        intro.textColor = .secondaryLabelColor
        intro.alignment = .center
        intro.preferredMaxLayoutWidth = 470

        let illustration = OnboardingIllustrationView()
        illustration.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            illustration.widthAnchor.constraint(equalToConstant: 480),
            illustration.heightAnchor.constraint(equalToConstant: 220),
        ])

        let shortcutRow = NSStackView(
            views: [
                labelView("Press"),
                keycap("⌃"), keycap("⌥"), keycap("J"),
                labelView("to start a jump"),
            ])
        shortcutRow.orientation = .horizontal
        shortcutRow.spacing = 6

        statusLabel.font = .systemFont(ofSize: 13)
        requestButton.bezelStyle = .rounded
        requestButton.keyEquivalent = "\r"
        settingsLink.isBordered = false
        settingsLink.contentTintColor = .linkColor
        settingsLink.font = .systemFont(ofSize: 12)

        let permissionBox = NSStackView(
            views: [statusLabel, requestButton, settingsLink])
        permissionBox.orientation = .vertical
        permissionBox.alignment = .centerX
        permissionBox.spacing = 8

        startButton.bezelStyle = .rounded
        startButton.controlSize = .large

        let stack = NSStackView(
            views: [title, intro, illustration, shortcutRow, permissionBox, startButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.setCustomSpacing(10, after: title)
        stack.setCustomSpacing(22, after: intro)
        stack.setCustomSpacing(24, after: shortcutRow)
        stack.setCustomSpacing(20, after: permissionBox)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 44),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: container.bottomAnchor, constant: -32),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 500),
        ])
        return container
    }

    private func labelView(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func keycap(_ symbol: String) -> NSView {
        KeycapView(symbol: symbol)
    }

    // MARK: - Permission gate

    private func refreshPermissionState() {
        let trusted = AXIsProcessTrusted()
        statusLabel.stringValue =
            trusted
            ? "✓ Accessibility access granted"
            : "Jamb needs Accessibility access to find inputs and move the cursor."
        statusLabel.textColor = trusted ? .systemGreen : .labelColor
        requestButton.isHidden = trusted
        settingsLink.isHidden = trusted
        startButton.isEnabled = trusted
        startButton.keyEquivalent = trusted ? "\r" : ""
    }

    @objc private func requestAccess() {
        /* The system prompt appears only on the very first ask; afterwards
           macOS stays silent, so the settings link below is the fallback. */
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    @objc private func openSystemSettings() {
        guard
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security"
                    + "?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func start() {
        guard AXIsProcessTrusted() else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        window?.delegate = nil
        onComplete()
        close()
    }
}

/* One keyboard key, drawn as a keycap. */
private final class KeycapView: NSView {
    private let symbol: String

    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 34),
            heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        NSColor.quaternarySystemFill.setFill()
        body.fill()
        NSColor.separatorColor.setStroke()
        body.lineWidth = 1
        body.stroke()

        let text = NSAttributedString(
            string: symbol,
            attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ])
        let size = text.size()
        text.draw(
            at: NSPoint(
                x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

/* A drawn "screenshot" of Jamb in action: two overlapping windows, their
   inputs washed in the highlight tint, label chips on the leading edges,
   and the caret landed in the frontmost field. Drawn (not a bundled image)
   so it stays crisp at any backing scale and needs no resource plumbing. */
private final class OnboardingIllustrationView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let canvas = bounds

        // Desktop backdrop, in the app's teal
        let backdrop = NSBezierPath(roundedRect: canvas, xRadius: 12, yRadius: 12)
        NSGradient(
            starting: NSColor(srgbRed: 0.07, green: 0.21, blue: 0.21, alpha: 1),
            ending: NSColor(srgbRed: 0.04, green: 0.11, blue: 0.11, alpha: 1)
        )?.draw(in: backdrop, angle: -90)

        // Back window with one field, front window with two — the multi-app
        // scene Jamb is for.
        drawWindow(
            NSRect(x: 26, y: 74, width: 240, height: 122),
            fields: [(NSRect(x: 46, y: 96, width: 180, height: 30), "s", false)])
        drawWindow(
            NSRect(x: 210, y: 18, width: 244, height: 140),
            fields: [
                (NSRect(x: 230, y: 92, width: 190, height: 30), "a", true),
                (NSRect(x: 230, y: 40, width: 150, height: 30), "d", false),
            ])
    }

    private func drawWindow(_ frame: NSRect, fields: [(NSRect, String, Bool)]) {
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)

        NSGraphicsContext.current?.saveGraphicsState()
        shadow.set()
        let body = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
        NSColor(srgbRed: 0.93, green: 0.95, blue: 0.95, alpha: 1).setFill()
        body.fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        // Traffic lights
        for (index, tint) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            let dot = NSRect(
                x: frame.minX + 10 + CGFloat(index) * 12, y: frame.maxY - 14,
                width: 7, height: 7)
            tint.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: dot).fill()
        }

        for (fieldRect, label, hasCaret) in fields {
            drawField(fieldRect, label: label, hasCaret: hasCaret)
        }
    }

    private func drawField(_ rect: NSRect, label: String, hasCaret: Bool) {
        // The input itself
        let field = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.white.setFill()
        field.fill()

        // Jamb's highlight wash + border
        NSColor.systemYellow.withAlphaComponent(0.16).setFill()
        field.fill()
        NSColor.systemYellow.withAlphaComponent(0.7).setStroke()
        field.lineWidth = 1
        field.stroke()

        if hasCaret {
            let caret = NSRect(x: rect.minX + 46, y: rect.minY + 7, width: 2, height: 16)
            NSColor.controlAccentColor.setFill()
            caret.fill()
        }

        // The label chip on the leading edge
        let chip = NSRect(x: rect.minX - 8, y: rect.midY - 9, width: 22, height: 18)
        let chipPath = NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4)
        NSColor.systemYellow.setFill()
        chipPath.fill()
        let text = NSAttributedString(
            string: label,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.black.withAlphaComponent(0.85),
            ])
        let size = text.size()
        text.draw(
            at: NSPoint(x: chip.midX - size.width / 2, y: chip.midY - size.height / 2))
    }
}
