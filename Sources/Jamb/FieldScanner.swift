import AppKit
import ApplicationServices

/* Private but long-stable (window managers build on it): the CGWindowID
   behind an AX window. Exact identity beats frame matching — two stacked
   same-size windows are indistinguishable by geometry. */
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(
    _ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>
) -> AXError

/* A text input the overlay can jump to. */
struct InputField {
    let element: AXUIElement
    /* Jumps into a background app must activate it first — typing follows
       app activation, not AX focus. */
    let appPID: pid_t
    /* AppKit screen coordinates (bottom-left origin), ready for overlay
       windows. */
    let frame: NSRect
}

/* Finds the text inputs in every window visible on screen — not just the
   active app's — by walking each app's accessibility tree, and performs
   the jump itself.

   Every AX message is a blocking IPC round trip into the target app, so
   the walk is engineered around call count: one batched fetch per element
   (role, subrole, geometry, and children together), subtrees that can't
   contain inputs pruned, hard visit caps, and a 0.1s per-message timeout
   so one busy process can't hang the scan for the several-second default.
   Apps scan in parallel (AX serializes per target app, but different apps
   are independent), so the wall clock is the slowest single app. Callers
   run the scan off the main thread. */
enum FieldScanner {
    private static let textRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
    ]
    /* Subtrees that never contain a text input. Web-content trees
       (browsers, Electron) are dominated by exactly these — VSCode's
       workbench is ~40% static text and leaf controls — so pruning them is
       what makes deep inputs reachable at all. */
    private static let prunedRoles: Set<String> = [
        kAXStaticTextRole, kAXImageRole, kAXMenuBarRole, kAXMenuRole,
        kAXScrollBarRole, kAXButtonRole, "AXLink", "AXHeading",
        "AXListMarker", kAXCheckBoxRole, kAXRadioButtonRole,
        kAXPopUpButtonRole, kAXSliderRole, kAXMenuItemRole,
        kAXDisclosureTriangleRole, kAXValueIndicatorRole,
    ]
    /* Generous: batching makes visits cheap (~0.04ms each), and Electron
       apps bury their inputs past visit 10,000 (VSCode's chat input sits at
       ~#8,600, depth 24). The time budget is the real limiter. */
    private static let maxVisitedElementsPerApp = 25000
    /* Adaptive latency bounds, per WINDOW — expiry moves on to the app's
       next window instead of abandoning the app. (KakaoTalk answers AX at
       ~17ms per element; with an app-wide grace, the first window's slow
       tail swallowed the whole budget and its other windows never got
       scanned.) Once a window yields something, its scan continues as long
       as new fields keep arriving and stops trailingGrace after the last
       one — a fixed post-first-find cutoff proved wrong (VSCode's inputs
       trickle in between visits ~8,000 and ~14,000). A window that yields
       nothing gets emptyWindowBudget before its turn ends. The overall
       per-app cap is the give-up point. */
    /* Sized for the slowest AX responders in the wild (KakaoTalk answers at
       ~17ms per element, and where its input lands in BFS order varies by
       machine): a window gets a generous empty-handed allowance before its
       turn ends, and streaming keeps fast apps' labels instant regardless. */
    /* Grace sized from measurement: VSCode (the sparsest field layout seen)
       finds successive fields at most ~70ms apart, and KakaoTalk chat
       windows find theirs within the first ~25 visits. */
    private static let trailingGrace: TimeInterval = 0.15
    private static let emptyWindowBudget: TimeInterval = 0.8
    private static let maxScanBudget: TimeInterval = 3.0
    /* Front-to-back cap on how many distinct apps get scanned. Generous:
       apps scan in parallel so wall time barely grows, and a tight cap
       silently drops apps that sit low in the GLOBAL z-order despite being
       fully visible — on multi-display setups an app on the second screen
       can rank below six windows from the first, making its inputs appear
       and disappear with unrelated z-order changes. */
    private static let maxApps = 16

    /* One IPC round trip per element instead of up to five. */
    private static let batchAttributes =
        [
            kAXRoleAttribute, kAXSubroleAttribute, kAXPositionAttribute,
            kAXSizeAttribute, kAXChildrenAttribute,
        ] as CFArray

    private static let systemWide = AXUIElementCreateSystemWide()

    /* Process-wide, once: bounds how long any single AX message may block. */
    private static let messagingTimeoutConfigured: Bool = {
        AXUIElementSetMessagingTimeout(systemWide, 0.1)
        return true
    }()

    // MARK: - Scan

    /* Streams results so the overlay never waits for the slowest app: each
       app's fields arrive in one batch the moment its scan finishes — the
       fast native app the user is looking at labels in tens of
       milliseconds while a web-content tree is still being dug through.
       Both callbacks arrive on the main thread; onCompletion fires after
       every app has reported. */
    static func scanVisibleFields(
        screens: [NSRect],
        onBatch: @escaping ([InputField]) -> Void,
        onCompletion: @escaping () -> Void
    ) {
        DispatchQueue.global(qos: .userInteractive).async {
            _ = messagingTimeoutConfigured
            let primaryHeight = screens.first?.maxY ?? 0

            let windows = onScreenWindows(primaryHeight: primaryHeight)
            pruneCache(keeping: Set(windows.map(\.windowID)))
            var appPIDs: [pid_t] = []
            for window in windows where !appPIDs.contains(window.pid) {
                appPIDs.append(window.pid)
            }
            guard !appPIDs.isEmpty else {
                DispatchQueue.main.async(execute: onCompletion)
                return
            }

            let group = DispatchGroup()
            for pid in appPIDs.prefix(Self.maxApps) {
                let appWindows = windows.filter { $0.pid == pid }
                group.enter()
                DispatchQueue.global(qos: .userInteractive).async {
                    scanApp(
                        pid: pid, appWindows: appWindows,
                        screens: screens, primaryHeight: primaryHeight
                    ) { windowFields in
                        /* Occlusion: a field in a window covered by another
                           would get a label floating over unrelated content.
                           Decided by asking the window server what actually
                           sits at the field's center — NOT by CGWindowList
                           order, which arrives back-to-front on some
                           systems and then inverts the whole filter
                           (background apps labeled, visible ones not). */
                        let visible = windowFields.filter { entry in
                            isUnoccluded(entry.field, primaryHeight: primaryHeight)
                        }.map(\.field)
                        if !visible.isEmpty {
                            DispatchQueue.main.async { onBatch(visible) }
                        }
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main, execute: onCompletion)
        }
    }

    /* The window server's list of what is actually on screen in the current
       Space, front to back. Layer 0 keeps it to standard windows — no menu
       bar, status items, or overlay panels (including Jamb's own). */
    private struct OnScreenWindow {
        let pid: pid_t
        let windowID: CGWindowID
        let frame: NSRect
        let order: Int
    }

    private static func onScreenWindows(primaryHeight: CGFloat) -> [OnScreenWindow] {
        guard
            let rows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result: [OnScreenWindow] = []
        for row in rows {
            guard (row[kCGWindowLayer as String] as? Int) == 0,
                (row[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                let pid = row[kCGWindowOwnerPID as String] as? pid_t,
                pid != ownPID,
                let windowID = row[kCGWindowNumber as String] as? Int,
                let boundsDict = row[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDict),
                bounds.width >= 50, bounds.height >= 50
            else { continue }
            result.append(
                OnScreenWindow(
                    pid: pid,
                    windowID: CGWindowID(windowID),
                    frame: NSRect(
                        x: bounds.minX,
                        y: primaryHeight - bounds.minY - bounds.height,
                        width: bounds.width, height: bounds.height),
                    order: result.count))
        }
        return result
    }

    /* Scans the app window by window, front first, calling `emit` for each
       field THE MOMENT it is found — not when its window finishes. In slow
       AX responders (KakaoTalk: ~15ms per element) the input is typically
       found within the window's first few visits, and per-window batching
       made its label wait out the rest of the traversal plus the trailing
       grace; per-field streaming shows it immediately while the scan keeps
       digging in the background. */
    private static func scanApp(
        pid: pid_t, appWindows: [OnScreenWindow],
        screens: [NSRect], primaryHeight: CGFloat,
        emit: ([(field: InputField, windowOrder: Int)]) -> Void
    ) {
        let axApp = AXUIElementCreateApplication(pid)
        /* Electron apps keep their accessibility tree dormant until an
           assistive client announces itself; this attribute is their
           documented wake-up call. Harmless everywhere else. (The first
           press after the tree wakes may still come up empty.) */
        AXUIElementSetAttributeValue(
            axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let axWindows = value(axApp, kAXWindowsAttribute) as? [AXUIElement]
        else { return }

        /* Match the app's AX windows to what the window server says is on
           screen — AX also lists windows on other Spaces and minimized
           ones. Exact CGWindowID identity first: frame matching mis-assigns
           stacked same-size windows (two maximized editors), handing the
           covered one the front one's z-order and defeating the occlusion
           filter. Frames remain as the fallback if the private call ever
           vanishes. */
        var targets: [(window: AXUIElement, frame: NSRect, order: Int, id: CGWindowID)] = []
        for axWindow in axWindows {
            guard let frame = node(axWindow, primaryHeight: primaryHeight)?.frame
            else { continue }
            var windowID = CGWindowID(0)
            var match: OnScreenWindow?
            if _AXUIElementGetWindow(axWindow, &windowID) == .success, windowID != 0 {
                match = appWindows.first { $0.windowID == windowID }
            } else {
                match = appWindows.first {
                    abs($0.frame.midX - frame.midX) < 4
                        && abs($0.frame.midY - frame.midY) < 4
                        && abs($0.frame.width - frame.width) < 8
                }
            }
            guard let match else { continue }
            targets.append((axWindow, frame, match.order, match.windowID))
        }
        /* Front windows first: they get the shortest labels and the first
           slice of the budget. */
        targets.sort { $0.order < $1.order }

        let deadline = CFAbsoluteTimeGetCurrent() + Self.maxScanBudget
        /* With web accessibility on, every browser window carries an
           AXWebArea; its absence in a Chromium browser means the switch is
           off — worth onboarding the user through, once. */
        let isChromium = BrowserOnboarding.isChromiumBrowser(pid: pid)
        let sawWebContent = LockedFlag()

        /* Windows scan CONCURRENTLY. AX requests into one app serialize on
           its main thread, but round trips still overlap ~2x — and, more
           importantly, a big window with no inputs (KakaoTalk's main window
           burns its whole empty budget) no longer stalls the windows queued
           behind it. */
        DispatchQueue.concurrentPerform(iterations: targets.count) { index in
            scanWindow(
                targets[index], pid: pid, screens: screens,
                primaryHeight: primaryHeight, deadline: deadline,
                watchWebContent: isChromium ? sawWebContent : nil, emit: emit)
        }

        if isChromium, !sawWebContent.isSet {
            DispatchQueue.main.async {
                BrowserOnboarding.offerIfNeeded(forPID: pid)
            }
        }
    }

    private static func scanWindow(
        _ target: (window: AXUIElement, frame: NSRect, order: Int, id: CGWindowID),
        pid: pid_t, screens: [NSRect], primaryHeight: CGFloat,
        deadline: CFAbsoluteTime, watchWebContent: LockedFlag?,
        emit: ([(field: InputField, windowOrder: Int)]) -> Void
    ) {
        let windowStarted = CFAbsoluteTimeGetCurrent()
        var lastFound = windowStarted
        var visited = 0
        var foundInWindow = 0
        /* Stacked phantoms (hidden tabs, background webviews) report the
           same frame as the visible input; the first one found claims the
           spot and same-frame followers are skipped. If the claimer happens
           to be the phantom, the jump's focus verification and click
           fallback still land the caret in the real one. */
        var emittedFrames: [NSRect] = []
        var emittedElements: [AXUIElement] = []

        /* Cross-invocation cache first: last time's fields, revalidated with
           one batched fetch each and emitted immediately. This is what makes
           repeat invocations instant in apps that bury their inputs — VSCode
           parks them past visit 8,000, ~300ms into a cold traversal. The
           full traversal below still runs and refreshes the cache; re-found
           elements are skipped by the frame dedupe. */
        /* Deliberately NOT counted toward foundInWindow/lastFound: cache
           hits must not flip the traversal into (or keep resetting) the
           short trailing-grace mode, or the full sweep would stop early and
           a NEWLY created deep input could never be discovered. */
        for element in cachedFields(for: target.id) {
            guard CFAbsoluteTimeGetCurrent() < deadline else { break }
            guard let node = node(element, primaryHeight: primaryHeight),
                let role = node.role, textRoles.contains(role),
                let frame = node.frame
            else { continue }
            let visible = frame.intersection(target.frame)
            guard visible.width >= 4, visible.height >= 4,
                screens.contains(where: { $0.intersects(visible) }),
                !emittedFrames.contains(where: { near($0, visible) })
            else { continue }
            emittedFrames.append(visible)
            emittedElements.append(element)
            emit([(InputField(element: element, appPID: pid, frame: visible), target.order)])
        }

        var queue: [AXUIElement] = [target.window]
        var head = 0
        while head < queue.count, visited < Self.maxVisitedElementsPerApp,
            shouldContinue(
                deadline: deadline, windowStarted: windowStarted,
                lastFound: lastFound, foundAny: foundInWindow > 0)
        {
            let current = queue[head]
            head += 1
            visited += 1
            guard let node = node(current, primaryHeight: primaryHeight),
                let role = node.role
            else { continue }
            if watchWebContent != nil, role == "AXWebArea" {
                watchWebContent?.set()
            }

            if textRoles.contains(role) {
                /* Read-only text shares these roles (chat transcripts, code
                   viewers, consoles are all AXTextAreas): only a settable
                   value marks a real input — checked last, it's the one
                   extra IPC call. Password fields are never touched. Frames
                   are clipped to the window so elements scrolled out of
                   view don't get phantom labels. */
                guard node.subrole != kAXSecureTextFieldSubrole,
                    let frame = node.frame
                else { continue }
                let visible = frame.intersection(target.frame)
                guard visible.width >= 4, visible.height >= 4,
                    screens.contains(where: { $0.intersects(visible) }),
                    !emittedFrames.contains(where: { near($0, visible) }),
                    isEditable(current)
                else { continue }
                emittedFrames.append(visible)
                emittedElements.append(current)
                foundInWindow += 1
                lastFound = CFAbsoluteTimeGetCurrent()
                emit([
                    (InputField(element: current, appPID: pid, frame: visible), target.order)
                ])
                /* Inputs don't nest further inputs. */
                continue
            }
            if prunedRoles.contains(role) { continue }
            queue.append(contentsOf: node.children)
        }

        if debugLogging {
            NSLog(
                "Jamb: pid %d window %d — %.0f ms, %d fields (visited %d)",
                pid, target.order,
                (CFAbsoluteTimeGetCurrent() - windowStarted) * 1000,
                foundInWindow, visited)
        }
        storeCachedFields(emittedElements, for: target.id)
    }

    private static func near(_ seen: NSRect, _ frame: NSRect) -> Bool {
        abs(seen.minX - frame.minX) < 3 && abs(seen.minY - frame.minY) < 3
            && abs(seen.width - frame.width) < 6 && abs(seen.height - frame.height) < 6
    }

    // MARK: - Cross-invocation field cache

    /* Fields found last time, per window, revalidated cheaply on the next
       scan (see scanWindow). Element references stay valid for the target
       app's lifetime; dead ones simply fail their revalidation fetch.
       Guarded by a lock — window scans run concurrently. */
    private static let cacheLock = NSLock()
    private static var fieldCache: [CGWindowID: [AXUIElement]] = [:]

    private static func cachedFields(for windowID: CGWindowID) -> [AXUIElement] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return fieldCache[windowID] ?? []
    }

    private static func storeCachedFields(_ fields: [AXUIElement], for windowID: CGWindowID) {
        cacheLock.lock()
        fieldCache[windowID] = fields
        cacheLock.unlock()
    }

    static func pruneCache(keeping liveWindowIDs: Set<CGWindowID>) {
        cacheLock.lock()
        fieldCache = fieldCache.filter { liveWindowIDs.contains($0.key) }
        cacheLock.unlock()
    }

    /* Thread-safe boolean for the concurrent window scans. */
    private final class LockedFlag {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }

    private static let debugLogging =
        ProcessInfo.processInfo.environment["JAMB_DEBUG"] == "1"

    private static func shouldContinue(
        deadline: CFAbsoluteTime, windowStarted: CFAbsoluteTime,
        lastFound: CFAbsoluteTime, foundAny: Bool
    ) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        guard now < deadline else { return false }
        guard foundAny else { return now - windowStarted < Self.emptyWindowBudget }
        return now - lastFound < Self.trailingGrace
    }

    /* One-shot report for remote debugging: what the scanner sees on THIS
       machine, per app — copyable by a tester in one click (the status
       menu's Copy Diagnostics). Sequential on purpose; latency doesn't
       matter here, attribution does. */
    static func diagnostics(screens: [NSRect]) -> String {
        _ = messagingTimeoutConfigured
        let primaryHeight = screens.first?.maxY ?? 0
        var lines: [String] = ["Jamb diagnostics"]
        let info = Bundle.main.infoDictionary
        lines.append(
            "version: \(info?["CFBundleShortVersionString"] as? String ?? "dev")"
                + " (\(info?["CFBundleVersion"] as? String ?? "-"))")
        lines.append("accessibility trusted: \(AXIsProcessTrusted())")
        lines.append("screens: \(screens.map { "\(Int($0.width))x\(Int($0.height))@(\(Int($0.minX)),\(Int($0.minY)))" }.joined(separator: ", "))")

        let windows = onScreenWindows(primaryHeight: primaryHeight)
        var appPIDs: [pid_t] = []
        for window in windows where !appPIDs.contains(window.pid) {
            appPIDs.append(window.pid)
        }
        lines.append("on-screen windows: \(windows.count), apps: \(appPIDs.count) (scanning first \(min(appPIDs.count, Self.maxApps)))")

        for pid in appPIDs.prefix(Self.maxApps) {
            let appWindows = windows.filter { $0.pid == pid }
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName
                ?? "pid \(pid)"
            let started = CFAbsoluteTimeGetCurrent()
            /* Windows scan concurrently; the counters need the lock. */
            let lock = NSLock()
            var found = 0
            var visible = 0
            scanApp(
                pid: pid, appWindows: appWindows,
                screens: screens, primaryHeight: primaryHeight
            ) { windowFields in
                let visibleCount = windowFields.filter {
                    isUnoccluded($0.field, primaryHeight: primaryHeight)
                }.count
                lock.lock()
                found += windowFields.count
                visible += visibleCount
                lock.unlock()
            }
            let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            lines.append(
                "\(name): windows \(appWindows.count), fields \(found)"
                    + " -> visible \(visible), \(ms) ms")
        }
        return lines.joined(separator: "\n")
    }

    /* Cross-window occlusion, z-order-free: the system-wide hit test
       answers with whatever is really on top at the field's center. A
       different app there, or a different window of the same app, means
       the field is covered. An element from the field's OWN window keeps
       it — placeholders and icons legitimately overlay a field's center,
       and they must never cost a real input its label. Inconclusive
       answers keep the field. */
    private static func isUnoccluded(_ field: InputField, primaryHeight: CGFloat) -> Bool {
        var hit: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            systemWide, Float(field.frame.midX),
            Float(primaryHeight - field.frame.midY), &hit)
        guard result == .success, let hit else { return true }
        var hitPID: pid_t = 0
        guard AXUIElementGetPid(hit, &hitPID) == .success else { return true }
        /* Our own overlay panels are click-through and normally invisible to
           hit-testing, but if a system ever answers with one, that says
           nothing about the field. */
        guard hitPID != ProcessInfo.processInfo.processIdentifier else { return true }
        guard hitPID == field.appPID else { return false }
        guard let hitWindow = element(hit, kAXWindowAttribute),
            let fieldWindow = element(field.element, kAXWindowAttribute)
        else { return true }
        return CFEqual(hitWindow, fieldWindow)
    }

    /* Is `ancestor` the element itself or one of its containers, within a
       few parent hops? */
    private static func isElement(_ element: AXUIElement, within ancestor: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let candidate = current else { return false }
            if CFEqual(candidate, ancestor) { return true }
            current = self.element(candidate, kAXParentAttribute)
        }
        return false
    }

    // MARK: - Jump

    /* The jump: focus the field, then park the caret after its last
       character. The insertion point makes the field immediately typable —
       that's the entire point.

       Timing traps everywhere. The caller must let the overlay panel
       finish resigning key before this runs — a focus write while another
       window still holds key is silently dropped by some apps. A field in
       a background app needs that app activated first (typing follows app
       activation), and the focus write must trail the activation. And the
       caret write must trail the focus change, because apps that reset
       their selection on focus would clobber a same-turn write. */
    static func jumpToEnd(of field: InputField) {
        /* Raise the field's own window: activating the app only brings its
           last-key window forward, which need not be the one the field
           lives in — the jump would then "succeed" behind another window. */
        if let window = element(field.element, kAXWindowAttribute) {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if frontmost == field.appPID {
            focusAndPlaceCaret(field)
        } else {
            NSRunningApplication(processIdentifier: field.appPID)?.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                focusAndPlaceCaret(field)
            }
        }
    }

    private static func focusAndPlaceCaret(_ field: InputField) {
        let focusResult = AXUIElementSetAttributeValue(
            field.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            /* Verify the focus actually landed — some apps answer success
               and do nothing (custom focus models, layered UIs). One real
               click is the universal fallback. */
            let landed = isFocused(field)
            if debugLogging {
                NSLog(
                    "Jamb: jump pid %d — focus write %d, landed %@%@",
                    field.appPID, focusResult.rawValue, landed ? "yes" : "no",
                    (focusResult != .success || !landed) ? ", clicking" : "")
            }
            if focusResult != .success || !landed {
                syntheticClick(at: field.frame)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                placeCaretAtEnd(field)
            }
        }
    }

    private static func isFocused(_ field: InputField) -> Bool {
        let app = AXUIElementCreateApplication(field.appPID)
        guard let focused = element(app, kAXFocusedUIElementAttribute) else { return false }
        /* Some apps report an inner editor element as focused; the field
           counts as focused if it contains whatever is. */
        return isElement(focused, within: field.element)
    }

    private static func placeCaretAtEnd(_ field: InputField) {
        var length = string(field.element, kAXValueAttribute)?.utf16.count ?? 0
        if let count = value(field.element, kAXNumberOfCharactersAttribute) as? Int {
            length = count
        }
        var caret = CFRange(location: length, length: 0)
        if let range = AXValueCreate(.cfRange, &caret) {
            AXUIElementSetAttributeValue(
                field.element, kAXSelectedTextRangeAttribute as CFString, range)
        }
    }

    /* Last-resort focus for elements that refuse the AX write: a real
       click in the field's center. The pointer is put back where it was —
       the whole point of Jamb is not having to move it. */
    private static func syntheticClick(at frame: NSRect) {
        let original = CGEvent(source: nil)?.location
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let point = CGPoint(x: frame.midX, y: primaryHeight - frame.midY)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(
                mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: point, mouseButton: .left
            )?.post(tap: .cghidEventTap)
        }
        if let original {
            CGWarpMouseCursorPosition(original)
        }
    }

    // MARK: - AX plumbing

    private struct NodeInfo {
        let role: String?
        let subrole: String?
        let frame: NSRect?
        let children: [AXUIElement]
    }

    /* The batched fetch. Missing attributes come back as AXValue error
       placeholders, which every typed cast below rejects. */
    private static func node(_ element: AXUIElement, primaryHeight: CGFloat) -> NodeInfo? {
        var values: CFArray?
        guard
            AXUIElementCopyMultipleAttributeValues(
                element, batchAttributes, AXCopyMultipleAttributeOptions(), &values)
                == .success,
            let slots = values as? [AnyObject], slots.count == 5
        else { return nil }

        var frame: NSRect?
        if let position: CGPoint = axValue(slots[2], .cgPoint, CGPoint.zero),
            let size: CGSize = axValue(slots[3], .cgSize, CGSize.zero)
        {
            /* AX coordinates hang from the primary display's top-left;
               AppKit's grow from its bottom-left. */
            frame = NSRect(
                x: position.x, y: primaryHeight - position.y - size.height,
                width: size.width, height: size.height)
        }
        return NodeInfo(
            role: slots[0] as? String,
            subrole: slots[1] as? String,
            frame: frame,
            children: slots[4] as? [AXUIElement] ?? [])
    }

    private static func axValue<Value>(
        _ slot: AnyObject, _ type: AXValueType, _ zero: Value
    ) -> Value? {
        guard CFGetTypeID(slot) == AXValueGetTypeID() else { return nil }
        let value = slot as! AXValue
        guard AXValueGetType(value) == type else { return nil }
        var out = zero
        AXValueGetValue(value, type, &out)
        return out
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard
            AXUIElementIsAttributeSettable(
                element, kAXValueAttribute as CFString, &settable) == .success
        else { return false }
        return settable.boolValue
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute),
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }
}
