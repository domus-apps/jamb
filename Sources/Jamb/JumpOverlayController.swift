import AppKit
import Carbon

/* The jump session: label chips over every input field, one overlay panel
   per screen, populated incrementally as per-app scan batches stream in —
   the overlay never waits for the slowest app. Labels come from a
   prefix-free allocator, so early labels never become ambiguous when more
   chips arrive. The key panel is nonactivating (the target app stays
   frontmost); typing a chip's label performs the jump, Escape or clicking
   away cancels. */
final class JumpOverlayController: NSObject, NSWindowDelegate {
    private struct Target {
        let label: String
        let field: InputField
        let chip: ChipView
        let highlight: FieldHighlightView
    }

    private var panelsByScreen: [(screenFrame: NSRect, panel: JumpPanel)] = []
    private var targets: [Target] = []
    private var labels = JumpLabels.Allocator()
    private var typed = ""
    private var sessionActive = false
    private var appNames: [pid_t: String] = [:]
    private var involvedPIDs = Set<pid_t>()

    /* Panels count too: should any teardown path ever leave a panel on
       screen, the hotkey toggle must still be able to clear it. */
    var isActive: Bool { sessionActive || !panelsByScreen.isEmpty }
    var hasTargets: Bool { !targets.isEmpty }

    func beginSession() {
        cancel()
        sessionActive = true
    }

    /* One scan batch. Chips join the live session mid-flight: they adopt
       the already-typed prefix so a fast typist never races the scanner. */
    func add(fields: [InputField]) {
        guard sessionActive else { return }
        /* Chips within one batch cascade with a slight stagger instead of
           popping in as a block; batches themselves are already staggered
           by scan timing. */
        /* App names earn their pixels only when they disambiguate: chips
           carry them once the session spans two or more apps. The moment a
           second app's batch arrives, the already-shown chips grow their
           names retroactively. */
        let hadMultipleApps = involvedPIDs.count >= 2
        for field in fields {
            involvedPIDs.insert(field.appPID)
        }
        let multipleApps = involvedPIDs.count >= 2
        if multipleApps, !hadMultipleApps {
            /* The chip grows and the name fades in with the growth (see
               draw), so the retrofit reads as one motion, not a pop. */
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(
                    controlPoints: 0.22, 1, 0.36, 1)
                for target in targets {
                    target.chip.showsAppName = true
                    target.chip.animator().setFrameSize(target.chip.fittingChipSize)
                }
            }
        }

        var entranceDelay: TimeInterval = 0
        for field in fields {
            /* Re-checked every iteration: a cancel can land mid-batch (via
               a resign notification fired from window work inside this very
               loop), and continuing would rebuild panels outside the dead
               session — unclosable leftovers. */
            guard sessionActive, let label = labels.next() else { return }
            let chip = ChipView(label: label, appName: appName(for: field.appPID))
            chip.showsAppName = multipleApps
            let highlight = FieldHighlightView()
            targets.append(
                Target(label: label, field: field, chip: chip, highlight: highlight))

            guard
                let screen = NSScreen.screens.first(where: {
                    $0.frame.intersects(field.frame)
                })
            else { continue }
            let panel = panel(for: screen)
            /* A faint wash over the whole input marks the jumpable area;
               the chip overlaps its leading edge, vertically centered —
               visible without covering much of the text. Highlight first,
               chip on top. */
            highlight.frame = NSRect(
                x: field.frame.minX - screen.frame.minX,
                y: field.frame.minY - screen.frame.minY,
                width: field.frame.width, height: field.frame.height)
            let size = chip.fittingChipSize
            chip.frame = NSRect(
                x: field.frame.minX - screen.frame.minX - 2,
                y: field.frame.midY - screen.frame.minY - size.height / 2,
                width: size.width, height: size.height)
            panel.contentView?.addSubview(highlight)
            panel.contentView?.addSubview(chip)
            if !typed.isEmpty {
                let matches = label.hasPrefix(typed)
                chip.update(typedCount: typed.count, matches: matches)
                highlight.update(matches: matches)
            }
            highlight.animateEntrance(after: entranceDelay, scaleFrom: 0.94)
            chip.animateEntrance(after: entranceDelay, scaleFrom: 0.4)
            entranceDelay = min(entranceDelay + 0.02, 0.25)
        }
    }

    func cancel() {
        for entry in panelsByScreen {
            entry.panel.delegate = nil
            entry.panel.close()
        }
        panelsByScreen = []
        targets = []
        labels = JumpLabels.Allocator()
        typed = ""
        sessionActive = false
        appNames = [:]
        involvedPIDs = []
    }

    private func appName(for pid: pid_t) -> String {
        if let cached = appNames[pid] { return cached }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
        appNames[pid] = name
        return name
    }

    private func panel(for screen: NSScreen) -> JumpPanel {
        if let existing = panelsByScreen.first(where: { $0.screenFrame == screen.frame }) {
            return existing.panel
        }
        let panel = JumpPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        /* Click-through, twice over: clicks land in the apps below (and the
           resulting key loss dismisses the session, the click-away idiom),
           and the window server's AX hit-testing skips the panel — the
           scanner's visibility hit-tests keep working while earlier batches
           are already on screen. */
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.onKeyEvent = { [weak self] event in self?.handle(event) }
        panel.delegate = self
        panel.contentView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        panelsByScreen.append((screen.frame, panel))

        /* Key capture lives on the session's FIRST panel, permanently: key
           events reach the key window no matter which screen it's on, and
           handing key between our own panels mid-session fires a resign
           notification in a window where neither panel is key yet — which
           used to read as "the user clicked away" and tore the session
           down while its labels were still appearing. */
        if panelsByScreen.count == 1 {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        return panel
    }

    private func handle(_ event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            cancel()
            return
        }
        guard
            let characters = (Self.latinCharacters(for: event)
                ?? event.charactersIgnoringModifiers)?.lowercased(),
            !characters.isEmpty
        else { return }
        typed += characters

        if let hit = targets.first(where: { $0.label == typed }) {
            let field = hit.field
            /* Close first, jump a beat later: the overlay panel holds key
               focus, and an AX focus write is silently dropped by some apps
               until key has settled back on the target window. */
            cancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                FieldScanner.jumpToEnd(of: field)
            }
            return
        }
        let stillMatching = targets.filter { $0.label.hasPrefix(typed) }
        guard !stillMatching.isEmpty else {
            /* A stray key dismisses, like clicking outside a menu. */
            cancel()
            return
        }
        for target in targets {
            let matches = target.label.hasPrefix(typed)
            target.chip.update(typedCount: typed.count, matches: matches)
            target.highlight.update(matches: matches)
        }
    }

    /* Label keys must match by keyboard POSITION, not produced character:
       with a Korean (or any non-Latin) input source active, the event's
       characters are jamo and would never match a label. Translate the key
       code through the user's Latin-capable layout instead — which also
       keeps Dvorak and friends working as their users expect. */
    private static func latinCharacters(for event: NSEvent) -> String? {
        guard
            let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?
                .takeRetainedValue(),
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
                layout, event.keyCode, UInt16(kUCKeyActionDown), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState, characters.count, &length, &characters)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }

    /* Clicking anywhere else (or switching apps) ends the session, like a
       menu. Checked a runloop turn later: mid-handoff, resign fires while
       NO window is key yet — deciding immediately would tear down a live
       session. After the turn, either one of ours is key (keep going) or
       the focus genuinely left (dismiss). */
    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sessionActive,
                !self.panelsByScreen.contains(where: { $0.panel.isKeyWindow })
            else { return }
            self.cancel()
        }
    }
}

/* A nonactivating panel that swallows key events for the session instead
   of dispatching them anywhere. */
private final class JumpPanel: NSPanel {
    var onKeyEvent: ((NSEvent) -> Void)?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            onKeyEvent?(event)
            return
        }
        super.sendEvent(event)
    }
}

/* Shared entrance for the session's overlay views: a quick fade riding a
   scale-up from the view's center on a strongly decelerating curve — no
   overshoot. `fillMode = .backwards` keeps a delayed view invisible until
   its turn in the cascade. */
extension NSView {
    fileprivate func animateEntrance(after delay: TimeInterval, scaleFrom: CGFloat) {
        guard let layer else { return }
        let start = CACurrentMediaTime() + delay
        let easing = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)

        var from = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        from = CATransform3DScale(from, scaleFrom, scaleFrom, 1)
        from = CATransform3DTranslate(from, -bounds.midX, -bounds.midY, 0)
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = NSValue(caTransform3D: from)
        scale.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        scale.duration = 0.22

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.16

        for animation in [scale, fade] {
            animation.beginTime = start
            animation.fillMode = .backwards
            animation.timingFunction = easing
            layer.add(animation, forKey: animation.keyPath)
        }
    }
}

/* The faint wash marking a jumpable input's whole area — recognition aid
   under the chip's addressing. Dims to a trace when the typed prefix
   rules its field out. */
private final class FieldHighlightView: NSView {
    private var matches = true

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(matches: Bool) {
        self.matches = matches
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        NSColor.systemYellow.withAlphaComponent(matches ? 0.13 : 0.03).setFill()
        path.fill()
        NSColor.systemYellow.withAlphaComponent(matches ? 0.55 : 0.12).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/* One label chip: a small rounded tag showing the keys to type, plus the
   owning app's name in a small secondary style — the disambiguator when
   windows of several apps interleave. Typed letters dim; chips that can no
   longer match fade almost out. */
private final class ChipView: NSView {
    private static let labelFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
    private static let nameFont = NSFont.systemFont(ofSize: 9, weight: .medium)
    private let label: String
    private let appName: String
    private var typedCount = 0
    private var matches = true

    /* Off while the session spans a single app — the name adds nothing
       there. Flipping it changes fittingChipSize; the owner resizes. */
    var showsAppName = false {
        didSet { needsDisplay = true }
    }

    init(label: String, appName: String) {
        self.label = label
        self.appName = appName.count > 14 ? "\(appName.prefix(13))…" : appName
        super.init(frame: .zero)
        wantsLayer = true
        /* Re-render at every intermediate size while the frame animates, so
           the name reveal below tracks the growth instead of stretching. */
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var labelText: NSAttributedString {
        let text = NSMutableAttributedString()
        for (index, character) in label.enumerated() {
            let dimmed = matches && index < typedCount
            text.append(
                NSAttributedString(
                    string: String(character),
                    attributes: [
                        .font: Self.labelFont,
                        .foregroundColor: NSColor.black.withAlphaComponent(
                            dimmed ? 0.3 : (matches ? 0.9 : 0.4)),
                    ]))
        }
        return text
    }

    private func nameText(alpha: CGFloat) -> NSAttributedString {
        NSAttributedString(
            string: "  \(appName)",
            attributes: [
                .font: Self.nameFont,
                .foregroundColor: NSColor.black.withAlphaComponent(alpha),
            ])
    }

    var fittingChipSize: NSSize {
        var width = labelText.size().width + 10
        if showsAppName, !appName.isEmpty {
            width += nameText(alpha: 1).size().width
        }
        return NSSize(width: width, height: 17)
    }

    func update(typedCount: Int, matches: Bool) {
        self.typedCount = typedCount
        self.matches = matches
        needsDisplay = true
    }

    /* Left-anchored: the label letters never move, and during the retrofit
       width animation the app name fades in proportionally to how far the
       chip has grown — the reveal rides the growth. */
    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        (matches ? NSColor.systemYellow : NSColor.systemYellow.withAlphaComponent(0.15))
            .setFill()
        background.fill()

        let labelText = self.labelText
        let labelSize = labelText.size()
        labelText.draw(at: NSPoint(x: 5, y: (bounds.height - labelSize.height) / 2))

        guard showsAppName, !appName.isEmpty else { return }
        let bareWidth = labelSize.width + 10
        let fullWidth = fittingChipSize.width
        let reveal =
            fullWidth > bareWidth
            ? max(0, min(1, (bounds.width - bareWidth) / (fullWidth - bareWidth)))
            : 1
        guard reveal > 0 else { return }
        let name = nameText(alpha: (matches ? 0.55 : 0.25) * reveal)
        name.draw(
            at: NSPoint(
                x: 5 + labelSize.width, y: (bounds.height - name.size().height) / 2))
    }
}
