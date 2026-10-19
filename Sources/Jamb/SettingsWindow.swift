import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement
import SwiftUI

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
        case .general: L("General")
        case .shortcuts: L("Shortcuts")
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

        let window = SettingsWindow(contentViewController: splitViewController)
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
        window.setContentSize(NSSize(width: 640, height: 500))
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

/* macOS 27.2 (26B5086k, measured 2026-09-18): clicking a SwiftUI switch
   Toggle in this window twice leaves the window undraggable by its title bar
   until the app relaunches. `isMovable` still reads true and the app still
   receives the title-bar mouse events; the window server just stops moving
   the window. It is the hosted NSSwitch (SwiftUI's Toggle, or any NSSwitch
   inside an NSHostingView) — a bare AppKit NSSwitch and a checkbox Toggle
   are fine. Re-asserting `isMovable` resyncs whatever the window server
   dropped, and it has to happen before the drag's mouse-down (the server
   decides at that moment; resetting inside the mouse-down is too late), so
   every click in the window ends with a reset. The setter is cheap, and a
   no-op when nothing is wrong. Verified 6/6 against a deterministic repro
   in Keystone; the shell is shared, so every Domus app carries it. */
final class SettingsWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        if event.type == .leftMouseUp, isMovable {
            isMovable = false
            isMovable = true
        }
    }
}

final class SettingsSplitViewController: NSSplitViewController {
    var onPaneChange: ((SettingsPane) -> Void)?

    private let sidebar = SettingsSidebarViewController()
    private let paneContainer = NSViewController()
    private let generalPane: NSViewController
    private let shortcutsPane: NSViewController
    private var currentPane: NSViewController?

    init(store: ShortcutStore, updater: UpdaterController) {
        /* The panes are SwiftUI grouped Forms — the exact section-header +
           rounded-box arrangement Xcode's settings use — hosted inside the
           AppKit split chrome. */
        let model = SettingsModel(store: store, updater: updater)
        generalPane = NSHostingController(rootView: GeneralSettingsView(model: model))
        shortcutsPane = NSHostingController(rootView: ShortcutSettingsView(model: model))
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
        let target: CGFloat = atRest ? 0 : 1
        /* Only when the value changes. The animator sets the model value at
           once, so a pocket already at the target is skipped. Starting an
           animation on every layout pass dirtied the view for the next
           commit, which laid the sidebar out again, which started another
           animation: a loop that kept each app near 7% CPU for as long as
           it ran, the closed (retained) Settings window included. */
        for subview in scrollView.subviews
        where String(describing: type(of: subview)) == "NSScrollPocket"
            && subview.alphaValue != target {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                subview.animator().alphaValue = target
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

// MARK: - SwiftUI bridge

/* One shared model for both panes: the shortcut lives in UserDefaults (via
   ShortcutStore); this object just republishes its change notification so
   SwiftUI re-reads, and carries the pieces that aren't preferences
   (SMAppService, the updater). */
final class SettingsModel: ObservableObject {
    let store: ShortcutStore
    let updater: UpdaterController

    init(store: ShortcutStore, updater: UpdaterController) {
        self.store = store
        self.updater = updater
        NotificationCenter.default.addObserver(
            forName: ShortcutStore.changed, object: nil, queue: .main
        ) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /* SMAppService needs a real app bundle; a bare `swift run` binary has
       no bundle identifier to register. */
    var isBundledApp: Bool { Bundle.main.bundleIdentifier != nil }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Jamb: launch-at-login change failed: \(error)")
            }
            objectWillChange.send()
        }
    }

    var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = (info?["CFBundleVersion"] as? String).map { " (\($0))" } ?? ""
        return version + build
    }

    var shortcutsAreDefault: Bool {
        ShortcutAction.allCases.allSatisfy { store.spec(for: $0) == $0.defaultSpec }
    }

    func binding<Value>(
        _ get: @escaping () -> Value, _ set: @escaping (Value) -> Void
    ) -> Binding<Value> {
        Binding(get: get, set: set)
    }
}

// MARK: - General pane

struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    Toggle(
                        L("Launch at login"),
                        isOn: model.binding({ model.launchAtLogin }, { model.launchAtLogin = $0 })
                    )
                    .disabled(!model.isBundledApp)
                    if !model.isBundledApp {
                        Text(L("Available in the bundled app only (Scripts/bundle.sh)."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                AccessibilityRow()
            }

            Section(L("Updates")) {
                LabeledContent(L("Version"), value: model.versionLabel)
                Button(L("Check for Updates…")) {
                    model.updater.checkForUpdates()
                }
                .disabled(!model.updater.canCheckForUpdates)
            }
        }
        .formStyle(.grouped)
    }
}

/* Jamb is built on the Accessibility API; without the permission the
   hotkey can only beep. The row shows the state and the way to fix it.
   Access isn't announced, so it's looked at again every second while the
   row is on screen (the System Settings switch takes effect live). */
private struct AccessibilityRow: View {
    @State private var isGranted = AXIsProcessTrusted()
    private let recheck = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent(L("Accessibility")) {
                if isGranted {
                    Label(L("Granted"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                } else {
                    /* Straight to the pane: the system's own prompt
                       appears only on the very first ask. */
                    Button(L("Open Accessibility Settings…")) {
                        guard
                            let url = URL(
                                string:
                                    "x-apple.systempreferences:com.apple.preference.security"
                                    + "?Privacy_Accessibility")
                        else { return }
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Text(L("Jamb finds the inputs on screen through Accessibility. Without it, the shortcut has nothing to jump to."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onReceive(recheck) { _ in isGranted = AXIsProcessTrusted() }
    }
}

// MARK: - Shortcuts pane

struct ShortcutSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    LabeledContent(action.title) {
                        ShortcutRecorder(spec: model.store.spec(for: action)) {
                            model.store.set($0, for: action)
                        }
                        .fixedSize()
                    }
                }
                Button(L("Reset to Default")) {
                    ShortcutRecorderButton.cancelActiveRecording()
                    model.store.resetAll()
                }
                .disabled(model.shortcutsAreDefault)
            } header: {
                Text(L("Global shortcut"))
            } footer: {
                Text(L("The shortcut works everywhere, no matter which app is in front."))
            }
        }
        .formStyle(.grouped)
    }
}

/* The AppKit recorder button, bridged: recording needs a local key-event
   monitor and first-responder plumbing that SwiftUI has no vocabulary for. */
private struct ShortcutRecorder: NSViewRepresentable {
    /* Passed in by value: a representable whose inputs never change is
       skipped by SwiftUI's updateNSView, so Reset to Default would leave
       the button showing the old shortcut. */
    let spec: ShortcutSpec
    let onChange: (ShortcutSpec) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton(spec: spec)
        button.onChange = onChange
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.onChange = onChange
        /* Never stomp the "Type shortcut…" prompt mid-recording. */
        if !button.isRecording, button.spec != spec {
            button.spec = spec
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
    private var endObservers: [NSObjectProtocol] = []
    private(set) var isRecording = false

    /* One recording at a time, app-wide. Starting another recorder (or
       resetting) ends the current one first, so the hotkeys suspended for
       it come back before the next suspension, never after, and a reset
       can't land behind the "Type shortcut…" prompt only to be painted
       over with the old shortcut when the prompt is cancelled. */
    private static weak var activeRecorder: ShortcutRecorderButton?

    static func cancelActiveRecording() {
        activeRecorder?.finishRecording(with: nil)
    }

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
        Self.cancelActiveRecording()
        isRecording = true
        Self.activeRecorder = self
        title = L("Type shortcut…")
        NotificationCenter.default.post(name: .shortcutRecordingBegan, object: self)

        /* Closing Settings (the window is kept, so the button never leaves
           it) or switching to another app would otherwise leave the hotkeys
           suspended until the recorder is clicked again. */
        let center = NotificationCenter.default
        endObservers = [
            center.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in self?.finishRecording(with: nil) },
            center.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.finishRecording(with: nil) },
        ]

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
        endObservers.forEach(NotificationCenter.default.removeObserver)
        endObservers = []
        isRecording = false
        if Self.activeRecorder === self { Self.activeRecorder = nil }
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
