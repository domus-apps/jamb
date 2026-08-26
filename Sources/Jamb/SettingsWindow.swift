import AppKit
import Carbon.HIToolbox
import ServiceManagement

extension Notification.Name {
    /* Recording captures key events locally, so the app must drop its global
       hotkeys for the duration — otherwise pressing a currently-registered
       combination triggers the action instead of recording it. */
    static let shortcutRecordingBegan = Notification.Name("Jamb.RecordingBegan")
    static let shortcutRecordingEnded = Notification.Name("Jamb.RecordingEnded")
}

// MARK: - Window

enum SettingsPane: Int, CaseIterable {
    case general
    case shortcuts

    var title: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "keyboard"
        }
    }
}

/* System Settings-style window: full-height sidebar on the left, panes on
   the right. The style mask keeps all three traffic lights live (zoom stays
   disabled by macOS itself while the window is not resizable-by-content,
   matching native settings windows). */
final class SettingsWindowController: NSWindowController {
    private let splitViewController: SettingsSplitViewController

    init(store: ShortcutStore, updater: UpdaterController) {
        splitViewController = SettingsSplitViewController(store: store, updater: updater)

        let window = NSWindow(contentViewController: splitViewController)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        /* A toolbar (even an empty one) is required for the full-height
           sidebar look. The tall unified style centers the traffic lights
           in a roomier title bar (like Xcode's settings window) instead of
           pinning them to the top-left corner. */
        window.toolbarStyle = .unified
        let toolbar = NSToolbar()
        /* An empty toolbar defaults to .iconAndLabel, which inflates the
           unified title bar to 66pt; .iconOnly gives the standard 52pt that
           Xcode's settings window uses. */
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 640, height: 360))
        window.center()

        super.init(window: window)
        splitViewController.onPaneChange = { [weak window] pane in
            window?.title = pane.title
        }
        splitViewController.show(.general)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

final class SettingsSplitViewController: NSSplitViewController {
    var onPaneChange: ((SettingsPane) -> Void)?

    private let sidebar = SettingsSidebarViewController()
    private let paneContainer = NSViewController()
    private let generalPane: GeneralPaneViewController
    private let shortcutsPane: ShortcutsPaneViewController
    private var currentPane: NSViewController?

    init(store: ShortcutStore, updater: UpdaterController) {
        generalPane = GeneralPaneViewController(updater: updater)
        shortcutsPane = ShortcutsPaneViewController(store: store)
        super.init(nibName: nil, bundle: nil)

        paneContainer.view = NSView()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 160
        sidebarItem.maximumThickness = 160
        sidebarItem.canCollapse = false
        addSplitViewItem(sidebarItem)
        addSplitViewItem(NSSplitViewItem(viewController: paneContainer))

        sidebar.onSelect = { [weak self] pane in
            self?.show(pane)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ pane: SettingsPane) {
        let next: NSViewController =
            switch pane {
            case .general: generalPane
            case .shortcuts: shortcutsPane
            }
        guard next !== currentPane else { return }

        if let currentPane {
            currentPane.view.removeFromSuperview()
            currentPane.removeFromParent()
        }
        paneContainer.addChild(next)
        next.view.translatesAutoresizingMaskIntoConstraints = false
        paneContainer.view.addSubview(next.view)
        NSLayoutConstraint.activate([
            next.view.topAnchor.constraint(equalTo: paneContainer.view.topAnchor),
            next.view.bottomAnchor.constraint(equalTo: paneContainer.view.bottomAnchor),
            next.view.leadingAnchor.constraint(equalTo: paneContainer.view.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: paneContainer.view.trailingAnchor),
        ])
        currentPane = next

        sidebar.select(pane)
        onPaneChange?(pane)
    }
}

// MARK: - Sidebar

final class SettingsSidebarViewController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate
{
    var onSelect: ((SettingsPane) -> Void)?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    /* Extra top inset below the safe area. Zero, like Xcode's settings
       sidebar: the first row sits flush against the title bar boundary. */
    private static let scrollEdgeFadeClearance: CGFloat = 0

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pane"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowSizeStyle = .default
        tableView.allowsEmptySelection = false
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        /* Managed manually in viewDidLayout: the automatic inset stops at
           the safe area, which leaves the first row inside the fade. */
        scrollView.automaticallyAdjustsContentInsets = false
        view = scrollView

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.updateScrollEdgeFade()
        }
    }

    /* The soft scroll-edge fade (macOS 26) is not scroll-aware: its gradient
       backdrop hangs ~10pt below the title bar at all times, dimming a first
       row that sits flush against the boundary even when nothing is scrolled
       under the bar. Mirror Xcode's settings sidebar instead: fade only while
       content is actually scrolled under. The pocket is a private AppKit view
       (NSScrollPocket), so this is a defensive class-name lookup — if AppKit
       renames it, the system's default behavior simply returns. */
    private func updateScrollEdgeFade() {
        let restTop = -scrollView.contentInsets.top
        let atRest = scrollView.contentView.bounds.minY <= restTop + 0.5
        for subview in scrollView.subviews
        where String(describing: type(of: subview)) == "NSScrollPocket" {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                subview.animator().alphaValue = atRest ? 0 : 1
            }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        /* The pocket can appear after the first layout pass, so re-evaluate
           on every layout, not only when the inset changes. */
        defer { updateScrollEdgeFade() }
        let top = view.safeAreaInsets.top + Self.scrollEdgeFadeClearance
        guard scrollView.contentInsets.top != top else { return }
        let wasAtTop = scrollView.contentView.bounds.minY <= -scrollView.contentInsets.top
        scrollView.contentInsets = NSEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
        if wasAtTop {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: -top))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    func select(_ pane: SettingsPane) {
        guard tableView.selectedRow != pane.rawValue else { return }
        tableView.selectRowIndexes(IndexSet(integer: pane.rawValue), byExtendingSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        SettingsPane.allCases.count
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let pane = SettingsPane(rawValue: row) else { return nil }

        let cell = NSTableCellView()
        let imageView = NSImageView(
            image: NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: nil)
                ?? NSImage())
        let textField = NSTextField(labelWithString: pane.title)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(imageView)
        cell.addSubview(textField)
        cell.imageView = imageView
        cell.textField = textField
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let pane = SettingsPane(rawValue: tableView.selectedRow) else { return }
        onSelect?(pane)
    }
}

// MARK: - General pane

final class GeneralPaneViewController: NSViewController {
    private let updater: UpdaterController

    init(updater: UpdaterController) {
        self.updater = updater
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private lazy var launchAtLoginCheckbox = NSButton(
        checkboxWithTitle: "Launch at login", target: self,
        action: #selector(toggleLaunchAtLogin))

    /* SMAppService needs a real app bundle; a bare `swift run` binary has no
       bundle identifier to register. */
    private var isBundledApp: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    private func note(_ text: String) -> NSTextField {
        let note = NSTextField(wrappingLabelWithString: text)
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        return note
    }

    override func loadView() {
        var views: [NSView] = [launchAtLoginCheckbox]
        if isBundledApp {
            launchAtLoginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            launchAtLoginCheckbox.isEnabled = false
            views.append(note("Available in the bundled app only."))
        }

        /* Jamb is built on the Accessibility API; without the permission the
           hotkey can only beep. Surface the state and the way to fix it. */
        let axGranted = AXIsProcessTrusted()
        let axButton = NSButton(
            title: "Open Accessibility Settings…", target: self,
            action: #selector(openAccessibilitySettings))
        views.append(axButton)
        views.append(note(
            axGranted
                ? "Accessibility access is granted."
                : "Accessibility access is NOT granted — Jamb can't see any "
                    + "inputs until it is (System Settings → Privacy & Security "
                    + "→ Accessibility)."))

        /* Updates. The menu bar's Check for Updates item has a twin here so
           the settings window is self-sufficient. */
        views.append(updater.makeCheckButton())
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            let build =
                (Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
                .map { " (\($0))" } ?? ""
            views.append(note("Version \(version)\(build)"))
        }

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(20, after: views[1])
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(
                equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: container.trailingAnchor, constant: -24),
        ])
        view = container
    }

    @objc private func openAccessibilitySettings() {
        guard
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security"
                    + "?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if launchAtLoginCheckbox.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginCheckbox.state = launchAtLoginCheckbox.state == .on ? .off : .on
            NSLog("Jamb: launch-at-login change failed: \(error)")
        }
    }
}

// MARK: - Shortcuts pane

final class ShortcutsPaneViewController: NSViewController {
    private let store: ShortcutStore
    private var recorderButtons: [ShortcutAction: ShortcutRecorderButton] = [:]

    init(store: ShortcutStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let grid = NSGridView()
        grid.rowSpacing = 10
        grid.columnSpacing = 16
        /* Labels and buttons have different intrinsic heights; align their
           text baselines (the standard look for label + control rows). */
        grid.rowAlignment = .firstBaseline

        for action in ShortcutAction.allCases {
            let label = NSTextField(labelWithString: action.title)
            let button = ShortcutRecorderButton(spec: store.spec(for: action))
            button.onChange = { [store] spec in
                store.set(spec, for: action)
            }
            recorderButtons[action] = button
            grid.addRow(with: [label, button])
        }
        grid.column(at: 0).xPlacement = .trailing

        let resetButton = NSButton(
            title: "Reset to Defaults", target: self, action: #selector(resetToDefaults))

        let stack = NSStackView(views: [grid, resetButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(
                equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: container.bottomAnchor, constant: -20),
        ])
        view = container
    }

    @objc private func resetToDefaults() {
        store.resetAll()
        for (action, button) in recorderButtons {
            button.spec = store.spec(for: action)
        }
    }
}

// MARK: - Recorder button

/* Click to record: the button captures the next key press with a local event
   monitor. Esc cancels; combinations without ⌘/⌃/⌥ are rejected so plain
   typing can't become a global shortcut. */
final class ShortcutRecorderButton: NSButton {
    var spec: ShortcutSpec {
        didSet { title = spec.displayString }
    }
    var onChange: ((ShortcutSpec) -> Void)?

    private var eventMonitor: Any?
    private var isRecording = false

    init(spec: ShortcutSpec) {
        self.spec = spec
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        title = spec.displayString
        target = self
        action = #selector(toggleRecording)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func toggleRecording() {
        isRecording ? finishRecording(with: nil) : beginRecording()
    }

    private func beginRecording() {
        isRecording = true
        title = "Type shortcut…"
        NotificationCenter.default.post(name: .shortcutRecordingBegan, object: self)

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if Int(event.keyCode) == kVK_Escape {
                self.finishRecording(with: nil)
                return nil
            }
            let modifiers = ShortcutSpec.carbonModifiers(from: event.modifierFlags)
            let required = UInt32(cmdKey) | UInt32(controlKey) | UInt32(optionKey)
            guard modifiers & required != 0 else {
                NSSound.beep()
                return nil
            }
            self.finishRecording(
                with: ShortcutSpec(
                    keyCode: UInt32(event.keyCode),
                    carbonModifiers: modifiers,
                    keyLabel: ShortcutSpec.keyLabel(for: event)
                ))
            return nil
        }
    }

    private func finishRecording(with newSpec: ShortcutSpec?) {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        isRecording = false
        if let newSpec {
            spec = newSpec
            onChange?(newSpec)
        } else {
            title = spec.displayString
        }
        NotificationCenter.default.post(name: .shortcutRecordingEnded, object: self)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, isRecording {
            finishRecording(with: nil)
        }
    }
}
