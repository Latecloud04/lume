import AppKit
import LumeCore

@main
struct LumeMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = LumeAppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class LumeAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var state = LumeState.empty(now: Date())
    private var preferences = LumePreferences(state: .empty(now: Date()))
    private let preferencesStore = LumePreferencesStore()
    private var coordinator: UsageRefreshCoordinator?
    private let launchAtLogin = SystemLaunchAtLoginProvider()
    private var refreshTimer: Timer?
    private var presentationTimer: Timer?
    private var refreshing = false
    private weak var openMenu: NSMenu?
    private var lastCodexActiveAt = Date()
    private var warning: String?

    func applicationDidFinishLaunching(_: Notification) {
        preferences = preferencesStore.load(now: Date())
        state = preferences.state
        if state.presentation == .rail && preferences.dockSide == nil {
            state.presentation = .ring
            preferences.state = state
        } else if state.presentation == .ring {
            preferences.dockSide = nil
        }
        coordinator = UsageRefreshCoordinator(reader: DiscoveredCodexUsageReader())
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.templateImage
        item.menu = makeMenu()
        statusItem = item
        if preferences.isPanelVisible { showPanel() }
        refresh(reason: .launch)
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(applicationActivityChanged), name: name, object: nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersDidChange), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(systemDidWake), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    func applicationWillTerminate(_: Notification) {
        refreshTimer?.invalidate()
        presentationTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        persistFrame()
        preferencesStore.save(preferences)
    }

    @objc private func systemDidWake(_: Notification) { refresh(reason: .wake) }
    @objc private func screenParametersDidChange(_: Notification) {
        guard panel != nil else { return }
        restorePlacement()
        persistFrame()
        updatePresentation()
    }
    @objc private func openCodex(_: Any?) {
        Task { [weak self] in
            guard let self else { return }
            let result = await CodexHandoff().perform()
            if result == .unavailable || result == .failed { showWarning("无法打开 Codex，请确认应用已安装") }
            else { warning = nil; statusItem?.menu = makeMenu() }
        }
    }
    @objc private func togglePanel(_: Any?) {
        if panel?.isVisible == true { persistFrame(); panel?.orderOut(nil); preferences.isPanelVisible = false }
        else { preferences.isPanelVisible = true; showPanel() }
        preferencesStore.save(preferences)
        statusItem?.menu = makeMenu()
    }
    @objc private func refresh(_: Any?) { refresh(reason: .manual) }
    @objc private func toggleLaunchAtLogin(_: Any?) {
        do {
            try launchAtLogin.setEnabled(!launchAtLogin.isEnabled)
            preferences.launchAtLogin = launchAtLogin.isEnabled
            warning = nil
        } catch {
            showWarning("登录启动设置失败，请在系统设置中检查登录项")
        }
        preferencesStore.save(preferences)
        statusItem?.menu = makeMenu()
        updatePresentation()
    }
    @objc private func quit(_: Any?) { NSApp.terminate(nil) }
    func menuWillOpen(_ menu: NSMenu) {
        openMenu = menu
        let latest = makeMenu()
        menu.removeAllItems()
        for item in latest.items {
            latest.removeItem(item)
            menu.addItem(item)
        }
        refresh(reason: .menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        openMenu = nil
    }

    private func makeMenu() -> NSMenu {
        let model = LumeMenuPresentation(state: state, panelVisible: panel?.isVisible == true, now: Date(), warning: warning)
        let menu = NSMenu()
        menu.delegate = self
        for entry in model.items {
            let action: Selector?
            switch entry.action {
            case .openCodex: action = #selector(openCodex(_:))
            case .togglePanel: action = #selector(togglePanel(_:))
            case .refresh: action = #selector(refresh(_:))
            case .launchAtLogin: action = #selector(toggleLaunchAtLogin(_:))
            case .about: action = #selector(NSApplication.orderFrontStandardAboutPanel(_:))
            case .quit: action = #selector(quit(_:))
            case .info: action = nil
            }
            let item = menu.addItem(withTitle: entry.title, action: action, keyEquivalent: entry.action == .quit ? "q" : "")
            item.target = entry.action == .about ? NSApp : self
            if entry.action == .launchAtLogin { item.state = launchAtLogin.isEnabled ? .on : .off }
        }
        return menu
    }

    private func activity(now: Date) -> CodexActivity {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: CodexHandoff.bundleIdentifier).isEmpty else { return .stopped }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == CodexHandoff.bundleIdentifier {
            lastCodexActiveAt = now
            return .active
        }
        return now.timeIntervalSince(lastCodexActiveAt) < 300 ? .active : .background
    }

    @objc private func applicationActivityChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == CodexHandoff.bundleIdentifier else { return }
        if notification.name == NSWorkspace.didActivateApplicationNotification {
            lastCodexActiveAt = Date()
            refresh(reason: .activation)
        } else {
            Task { await scheduleRefresh() }
        }
    }

    private func scheduleRefresh() async {
        guard let coordinator else { return }
        let now = Date()
        let resets = [state.fiveHour.resetsAt, state.sevenDay.resetsAt].compactMap { $0 }
        let delay = await coordinator.nextDelay(now: now, activity: activity(now: now), resets: resets)
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh(reason: .timer) }
        }
        timer.tolerance = min(5, delay / 10)
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func refresh(reason: RefreshReason) {
        guard !refreshing else { return }
        refreshing = true
        Task { [weak self] in
            guard let self, let coordinator else { return }
            let result = await coordinator.refresh(now: Date(), reason: reason)
            if result.status != .throttled {
                state.apply(result)
                preferences.state = state
                LumeLog.record(result)
                preferencesStore.save(preferences)
            }
            if let openMenu {
                let entries = LumeMenuPresentation(state: state, panelVisible: panel?.isVisible == true, now: Date(), warning: warning).items
                for (item, entry) in zip(openMenu.items, entries) { item.title = entry.title }
            } else {
                statusItem?.menu = makeMenu()
            }
            updatePresentation()
            refreshing = false
            await scheduleRefresh()
        }
    }

    private func showPanel() {
        if panel == nil {
            let panel = NSPanel(contentRect: .init(origin: .zero, size: PanelGeometry.ringHitSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.isExcludedFromWindowsMenu = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            self.panel = panel
        }
        restorePlacement()
        updatePresentation()
        panel?.orderFrontRegardless()
    }

    private func screens() -> [LumeDisplay] {
        NSScreen.screens.map { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return LumeDisplay(identifier: number?.stringValue ?? screen.localizedName, visibleFrame: screen.visibleFrame)
        }
    }
    private func displayIdentifier(for screen: NSScreen?) -> String? {
        guard let screen else { return nil }
        return (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? screen.localizedName
    }

    private func restorePlacement() {
        guard let panel else { return }
        let allScreens = screens()
        let mainScreenIdentifier = displayIdentifier(for: NSScreen.main)
        guard let initialTarget = allScreens.first(where: { $0.identifier == preferences.screenIdentifier })
            ?? allScreens.first(where: { $0.identifier == mainScreenIdentifier })
            ?? allScreens.first
        else { return }
        if preferences.screenIdentifier == nil && preferences.panelOriginX == 0 && preferences.panelOriginY == 0 {
            state.presentation = .ring
            preferences.state = state
            preferences.dockSide = nil
            panel.setContentSize(PanelGeometry.ringHitSize)
            panel.setFrameOrigin(PanelGeometry.initialRingOrigin(in: initialTarget.visibleFrame))
            persistFrame()
            return
        }
        let size = state.presentation == .rail ? PanelGeometry.railHitSize : PanelGeometry.ringHitSize
        var placement = PanelPlacement(origin: CGPoint(x: preferences.panelOriginX, y: preferences.panelOriginY), displayIdentifier: preferences.screenIdentifier)
        placement = placement.migrated(to: allScreens, size: size)
        let target = allScreens.first(where: { $0.identifier == placement.displayIdentifier }) ?? initialTarget
        if state.presentation == .rail, let side = preferences.dockSide {
            let y = PanelGeometry.clampedOrigin(placement.origin, size: size, in: target.visibleFrame).y
            let x = side == .left ? target.visibleFrame.minX : target.visibleFrame.maxX - size.width
            panel.setContentSize(size); panel.setFrameOrigin(CGPoint(x: x, y: y))
        } else {
            panel.setContentSize(size); panel.setFrameOrigin(placement.origin)
        }
    }

    private func updatePresentation(preview: DockSide? = nil) {
        guard let panel else { return }
        let oldFrame = panel.frame
        let size = state.presentation == .ring ? PanelGeometry.ringHitSize : PanelGeometry.railHitSize
        if panel.contentView?.frame.size != size { panel.setContentSize(size) }
        if state.presentation == .rail, let side = preferences.dockSide {
            panel.setFrameOrigin(CGPoint(x: side == .left ? oldFrame.minX : oldFrame.maxX - size.width, y: oldFrame.midY - size.height / 2))
        }
        if let view = panel.contentView as? LumePanelView {
            view.update(state: state, dockSide: preferences.dockSide, preview: preview, warning: warning)
        } else {
            panel.contentView = LumePanelView(
                state: state,
                dockSide: preferences.dockSide,
                preview: preview,
                warning: warning,
                pointerStarted: { [weak self] in self?.pointerStarted() },
                pointerMoved: { [weak self] start, current in self?.pointerMoved(start: start, current: current) },
                pointerReleased: { [weak self] start, end in self?.pointerReleased(start: start, end: end) },
                showContextMenu: { [weak self] event, view in
                    guard let self else { return }
                    NSMenu.popUpContextMenu(self.makeMenu(), with: event, for: view)
                })
        }
        presentationTimer?.invalidate()
        let now = Date()
        let transitions = [state.fiveHour, state.sevenDay].flatMap { window -> [Date] in
            guard let observed = window.lastSuccessfulAt else { return [] }
            return [observed.addingTimeInterval(120.1), observed.addingTimeInterval(900.1)] + [window.resetsAt].compactMap { $0 }
        }
        if let next = transitions.filter({ $0 > now }).min() {
            let timer = Timer(timeInterval: next.timeIntervalSince(now), repeats: false) { [weak self] _ in
                Task { @MainActor in self?.updatePresentation() }
            }
            RunLoop.main.add(timer, forMode: .common)
            presentationTimer = timer
        }
    }

    private func pointerStarted() {
        panelFrameAtStart = panel?.frame.origin ?? .zero
        panelScreenIdentifierAtStart = displayIdentifier(for: panel?.screen)
        panelDragExceededThreshold = false
    }
    private func pointerMoved(start: CGPoint, current: CGPoint) {
        guard let panel else { return }
        if state.presentation == .ring {
            guard let draggedOrigin = PanelGeometry.draggedOrigin(
                from: panelFrameAtStart,
                pointerStart: start,
                pointerCurrent: current,
                didExceedThreshold: panelDragExceededThreshold
            ) else { return }
            panelDragExceededThreshold = true
            panel.setFrameOrigin(draggedOrigin)
            let preview = PanelGeometry.previewSide(at: current, displays: screens())
            (panel.contentView as? LumePanelView)?.setPreview(preview)
        } else if !PanelGeometry.isClick(from: start, to: current) {
            panelDragExceededThreshold = true
            guard let side = preferences.dockSide,
                  let target = screens().first(where: { $0.identifier == panelScreenIdentifierAtStart })
                    ?? PanelGeometry.display(containing: start, displays: screens())
            else { return }
            let origin = PanelGeometry.railOrigin(
                from: panelFrameAtStart,
                pointerStart: start,
                pointerCurrent: current,
                side: side,
                in: target.visibleFrame
            )
            panel.setFrameOrigin(origin)
        }
    }
    private var panelFrameAtStart = CGPoint.zero
    private var panelScreenIdentifierAtStart: String?
    private var panelDragExceededThreshold = false
    private func pointerReleased(start: CGPoint, end: CGPoint) {
        guard let panel else { return }
        defer {
            panelFrameAtStart = .zero
            panelScreenIdentifierAtStart = nil
            panelDragExceededThreshold = false
        }
        if state.presentation == .rail {
            guard let side = preferences.dockSide else { return }
            if PanelTransition.railRelease(start: start, end: end, didDrag: panelDragExceededThreshold, side: side) == .restoreRing {
                restoreRing()
            } else if panelDragExceededThreshold {
                persistFrame()
            }
            return
        }
        let displays = screens()
        guard let target = PanelGeometry.display(containing: end, displays: displays) else { return }
        switch PanelTransition.ringRelease(start: start, end: end, didDrag: panelDragExceededThreshold, screen: target.visibleFrame) {
        case .handoff:
            openCodex(nil)
            return
        case .dock(let side):
            dock(to: side, on: target)
        default:
            let clamped = PanelGeometry.clampedOrigin(panel.frame.origin, size: PanelGeometry.ringHitSize, in: target.visibleFrame)
            panel.setFrameOrigin(clamped)
            preferences.screenIdentifier = target.identifier
            (panel.contentView as? LumePanelView)?.setPreview(nil)
            persistFrame()
        }
        panel.displayIfNeeded()
    }

    private func dock(to side: DockSide, on display: LumeDisplay) {
        guard let panel else { return }
        let old = panel.frame
        state.presentation = .rail; preferences.state = state; preferences.dockSide = side; preferences.screenIdentifier = display.identifier
        syncPanelContent()
        let size = PanelGeometry.railHitSize
        let y = PanelGeometry.clampedOrigin(CGPoint(x: old.minX, y: old.midY - size.height / 2), size: size, in: display.visibleFrame).y
        let destination = NSRect(x: side == .left ? display.visibleFrame.minX : display.visibleFrame.maxX - size.width, y: y, width: size.width, height: size.height)
        animate(panel, to: destination, duration: 0.22) { [weak self] in self?.updatePresentation() }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        preferences.panelOriginX = destination.origin.x; preferences.panelOriginY = destination.origin.y
        preferencesStore.save(preferences)
    }

    private func restoreRing() {
        guard let panel, let side = preferences.dockSide else { return }
        let displays = screens()
        guard let display = displays.first(where: { $0.identifier == preferences.screenIdentifier })
            ?? PanelGeometry.display(containing: CGPoint(x: panel.frame.midX, y: panel.frame.midY), displays: displays)
        else { return }
        let origin = PanelGeometry.expandedRingOrigin(from: panel.frame, side: side, in: display.visibleFrame)
        state.presentation = .ring; preferences.state = state; preferences.dockSide = nil
        syncPanelContent()
        let destination = NSRect(origin: origin, size: PanelGeometry.ringHitSize)
        animate(panel, to: destination, duration: 0.22) { [weak self] in self?.updatePresentation() }
        preferences.panelOriginX = destination.origin.x; preferences.panelOriginY = destination.origin.y
        preferences.screenIdentifier = display.identifier
        preferencesStore.save(preferences)
    }

    private func animate(_ panel: NSPanel, to frame: NSRect, duration: TimeInterval, completion: @escaping @MainActor () -> Void) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(frame, display: true)
            completion()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { Task { @MainActor in completion() } })
    }

    private func persistFrame() {
        guard let panel else { return }
        preferences.panelOriginX = panel.frame.origin.x; preferences.panelOriginY = panel.frame.origin.y
        preferences.screenIdentifier = displayIdentifier(for: panel.screen)
        preferences.state = state
        preferencesStore.save(preferences)
    }
    private func syncPanelContent(preview: DockSide? = nil) {
        (panel?.contentView as? LumePanelView)?.update(
            state: state,
            dockSide: preferences.dockSide,
            preview: preview,
            warning: warning
        )
    }
    private func showWarning(_ message: String, beep: Bool = true) {
        warning = message
        if beep { NSSound.beep() }
        statusItem?.menu = makeMenu()
        updatePresentation()
    }

    private static var templateImage: NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        NSColor.black.setStroke()
        let ring = NSBezierPath()
        ring.appendArc(withCenter: CGPoint(x: 9, y: 9), radius: 6, startAngle: 28, endAngle: 315, clockwise: false)
        ring.lineWidth = 2
        ring.stroke()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

private final class LumePanelView: NSView {
    private var state: LumeState
    private var dockSide: DockSide?
    private var preview: DockSide?
    private var warning: String?
    private let pointerStarted: () -> Void
    private let pointerMoved: (CGPoint, CGPoint) -> Void
    private let pointerReleased: (CGPoint, CGPoint) -> Void
    private let showContextMenu: (NSEvent, NSView) -> Void
    private var startGlobal = CGPoint.zero
    private var hoverTracking: NSTrackingArea?
    private var displayedFiveHour: CGFloat?
    private var displayedSevenDay: CGFloat?
    private var progressTimer: Timer?

    init(state: LumeState, dockSide: DockSide?, preview: DockSide?, warning: String?, pointerStarted: @escaping () -> Void, pointerMoved: @escaping (CGPoint, CGPoint) -> Void, pointerReleased: @escaping (CGPoint, CGPoint) -> Void, showContextMenu: @escaping (NSEvent, NSView) -> Void) {
        self.state = state; self.dockSide = dockSide; self.preview = preview; self.warning = warning; self.pointerStarted = pointerStarted; self.pointerMoved = pointerMoved; self.pointerReleased = pointerReleased; self.showContextMenu = showContextMenu
        displayedFiveHour = state.fiveHour.visiblePercentageExact(at: Date()).map { CGFloat($0) }
        displayedSevenDay = state.sevenDay.visiblePercentageExact(at: Date()).map { CGFloat($0) }
        super.init(frame: .init(origin: .zero, size: state.presentation == .ring ? PanelGeometry.ringHitSize : PanelGeometry.railHitSize))
        wantsLayer = true
        setAccessibilityElement(true)
        updateAccessibilityAndTooltip(now: Date())
        setAccessibilityHelp(Self.accessibilityHelp(for: PanelVisual.resolved(presentation: state.presentation, dockSide: dockSide)))
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }
    override func mouseEntered(with event: NSEvent) {
        updateAccessibilityAndTooltip(now: Date())
        displayedFiveHour = state.fiveHour.visiblePercentageExact(at: Date()).map { CGFloat($0) }
        displayedSevenDay = state.sevenDay.visiblePercentageExact(at: Date()).map { CGFloat($0) }
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) { startGlobal = globalPoint(event); pointerStarted() }
    override func mouseDragged(with event: NSEvent) { pointerMoved(startGlobal, globalPoint(event)) }
    override func mouseUp(with event: NSEvent) { pointerReleased(startGlobal, globalPoint(event)) }
    override func rightMouseDown(with event: NSEvent) { showContextMenu(event, self) }

    func update(state: LumeState, dockSide: DockSide?, preview: DockSide?, warning: String?) {
        let previousFiveHour = displayedFiveHour
        let previousSevenDay = displayedSevenDay
        self.state = state
        self.dockSide = dockSide
        self.preview = preview
        self.warning = warning
        let now = Date()
        updateAccessibilityAndTooltip(now: now)
        setAccessibilityHelp(Self.accessibilityHelp(for: PanelVisual.resolved(presentation: state.presentation, dockSide: dockSide)))
        animateProgress(
            fromFiveHour: previousFiveHour,
            toFiveHour: state.fiveHour.visiblePercentageExact(at: now).map { CGFloat($0) },
            fromSevenDay: previousSevenDay,
            toSevenDay: state.sevenDay.visiblePercentageExact(at: now).map { CGFloat($0) }
        )
    }

    func setPreview(_ preview: DockSide?) {
        guard self.preview != preview else { return }
        self.preview = preview
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let now = Date()
        switch PanelVisual.resolved(presentation: state.presentation, dockSide: dockSide) {
        case .ring:
            NSGraphicsContext.saveGraphicsState()
            NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
            NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 44, height: 44)).fill()
            drawRing(center: CGPoint(x: 24, y: 24), radius: 20.5, lineWidth: 3, percentage: displayedFiveHour, window: state.fiveHour, now: now)
            drawRing(center: CGPoint(x: 24, y: 24), radius: 15.5, lineWidth: 2.5, percentage: displayedSevenDay, window: state.sevenDay, now: now)
            let value = state.fiveHour.visiblePercentage(at: now).map { "\($0)%" } ?? "--"
            drawCentered(value, y: 20, font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .bold), color: .labelColor)
            drawCentered("5H", y: 11, font: .systemFont(ofSize: 6.5, weight: .medium), color: .secondaryLabelColor)
            if let preview { nsColor(state.fiveHour.color(at: now)).withAlphaComponent(0.35).setFill(); NSBezierPath(rect: NSRect(x: preview == .left ? 0 : 44, y: 0, width: 4, height: 48)).fill() }
            NSGraphicsContext.restoreGraphicsState()
        case .rail(let dockSide):
            let edgeX: CGFloat = dockSide == .left ? 0 : 21
            let contentX: CGFloat = dockSide == .left ? 4 : 14
            drawRail(x: edgeX, width: 3, percentage: displayedSevenDay, window: state.sevenDay, now: now)
            drawRail(x: contentX, width: 6, percentage: displayedFiveHour, window: state.fiveHour, now: now)
            let indicatorX: CGFloat = dockSide == .left ? 12 : 8
            if state.fiveHour.isStale(at: now) || state.sevenDay.isStale(at: now) { NSColor.systemOrange.setFill(); NSBezierPath(ovalIn: NSRect(x: indicatorX, y: 57, width: 4, height: 4)).fill() }
        }
    }

    private func drawRing(center: CGPoint, radius: CGFloat, lineWidth: CGFloat, percentage: CGFloat?, window: UsageWindowState, now: Date) {
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.quaternaryLabelColor.setStroke()
        track.stroke()
        guard let percentage else { return }
        let progress = NSBezierPath()
        progress.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * percentage / 100, clockwise: true)
        progress.lineWidth = lineWidth
        progress.lineCapStyle = .round
        nsColor(window.color(at: now)).withAlphaComponent(window.isStale(at: now) ? 0.55 : 1).setStroke()
        progress.stroke()
    }

    private func drawRail(x: CGFloat, width: CGFloat, percentage: CGFloat?, window: UsageWindowState, now: Date) {
        let trackBounds = NSRect(x: x, y: 5, width: width, height: 54)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: trackBounds, xRadius: width / 2, yRadius: width / 2).fill()
        guard let percentage else { return }
        let fillHeight = 54 * min(100, max(0, percentage)) / 100
        nsColor(window.color(at: now)).withAlphaComponent(window.isStale(at: now) ? 0.55 : 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: 5, width: width, height: fillHeight), xRadius: width / 2, yRadius: width / 2).fill()
    }

    private func animateProgress(fromFiveHour: CGFloat?, toFiveHour: CGFloat?, fromSevenDay: CGFloat?, toSevenDay: CGFloat?) {
        progressTimer?.invalidate()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              fromFiveHour != toFiveHour || fromSevenDay != toSevenDay
        else {
            displayedFiveHour = toFiveHour
            displayedSevenDay = toSevenDay
            needsDisplay = true
            return
        }
        let startedAt = CACurrentMediaTime()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let linear = min(1, (CACurrentMediaTime() - startedAt) / 0.18)
            let eased = 1 - pow(1 - linear, 3)
            displayedFiveHour = Self.interpolate(fromFiveHour, toFiveHour, CGFloat(eased))
            displayedSevenDay = Self.interpolate(fromSevenDay, toSevenDay, CGFloat(eased))
            needsDisplay = true
            if linear >= 1 { timer.invalidate(); progressTimer = nil }
        }
    }

    private static func interpolate(_ from: CGFloat?, _ to: CGFloat?, _ progress: CGFloat) -> CGFloat? {
        guard let to else { return nil }
        let start = from ?? 0
        return start + (to - start) * progress
    }

    private func updateAccessibilityAndTooltip(now: Date) {
        let text = UsageText.tooltip(state: state, now: now)
        setAccessibilityLabel(text)
        toolTip = [text, warning].compactMap { $0 }.joined(separator: "\n")
    }
    private static func accessibilityHelp(for visual: PanelVisual) -> String {
        switch visual {
        case .ring: return "单击打开 Codex；拖动移动或贴边"
        case .rail: return "单击展开；沿边缘拖动移动，向内拖动展开"
        }
    }
    private func drawCentered(_ string: String, y: CGFloat, font: NSFont, color: NSColor) {
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        attributed.draw(at: CGPoint(x: (bounds.width - attributed.size().width) / 2, y: y))
    }
    private func globalPoint(_ event: NSEvent) -> CGPoint { window?.convertPoint(toScreen: event.locationInWindow) ?? .zero }
    private func nsColor(_ value: LumeColor) -> NSColor { switch value { case .mint: .systemMint; case .orange: .systemOrange; case .red: .systemRed; case .gray: .systemGray } }
}
