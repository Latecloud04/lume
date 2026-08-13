import AppKit
import LumeCore
@preconcurrency import UserNotifications

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
final class LumeAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var state = LumeState.empty(now: Date())
    private var preferences = LumePreferences(state: .empty(now: Date()))
    private let preferencesStore = LumePreferencesStore()
    private var coordinator: UsageRefreshCoordinator?
    private let launchAtLogin = SystemLaunchAtLoginProvider()
    private var refreshTimer: Timer?
    private var breathingTimer: Timer?
    private var warningTimer: Timer?
    private var refreshStatus: UsageReadStatus = .failed
    private var warning: String?
    private var lastUpdateAt: Date?
    private var solControlBridge: SolControlBridge?
    private var solControlDoctor: SolControlDoctor?
    private var solControlResolution: SolControlResolution?
    private var lowQuotaNotificationArmed = true
    private var lowQuotaNotificationPending = false

    func applicationDidFinishLaunching(_: Notification) {
        preferences = preferencesStore.load(now: Date())
        state = preferences.state
        if state.presentation == .rail && preferences.dockSide == nil {
            state.presentation = .ring
            preferences.state = state
        } else if state.presentation == .ring {
            preferences.dockSide = nil
        }
        refreshStatus = state.lastStatus
        lastUpdateAt = state.lastSuccessfulAt
        lowQuotaNotificationArmed = UserDefaults.standard.object(forKey: "Lume.lowQuotaNotificationArmed") as? Bool ?? true
        solControlBridge = SolControlBridge.bundled(resourceURL: Bundle.main.resourceURL)
        coordinator = UsageRefreshCoordinator(reader: DiscoveredCodexUsageReader())
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.templateImage
        item.menu = makeMenu()
        statusItem = item
        if preferences.isPanelVisible { showPanel() }
        refreshSolControlStatus()
        refresh(reason: .launch)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh(reason: .timer) } }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersDidChange), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityDisplayOptionsDidChange), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(systemDidWake), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    func applicationWillTerminate(_: Notification) {
        refreshTimer?.invalidate()
        breathingTimer?.invalidate()
        warningTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        persistFrame()
        preferencesStore.save(preferences)
    }

    @objc private func systemDidWake(_: Notification) { refresh(reason: .wake) }
    @objc private func accessibilityDisplayOptionsDidChange(_: Notification) { updateBreathing() }
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
            if result == .unavailable || result == .failed { showWarning("Codex unavailable") }
        }
    }
    @objc private func togglePanel(_: Any?) {
        if panel?.isVisible == true { persistFrame(); panel?.orderOut(nil); preferences.isPanelVisible = false; updateBreathing() }
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
            showWarning("Launch at login unavailable")
        }
        preferencesStore.save(preferences)
        statusItem?.menu = makeMenu()
        updatePresentation()
    }
    @objc private func quit(_: Any?) { NSApp.terminate(nil) }
    @objc private func enableSolControl(_: Any?) {
        guard let bridge = solControlBridge else { showWarning("联动资源不可用"); return }
        Task { [weak self] in
            guard let self else { return }
            if await bridge.install() {
                await refreshSolControlStatusAsync()
                showWarning("Sol Control 联动已启用", beep: false)
            } else {
                showWarning("Sol Control 联动安装失败")
            }
        }
    }
    @objc private func setSolControlAuto(_: Any?) { setSolControlMode(.auto) }
    @objc private func setSolControlOpenAI(_: Any?) { setSolControlMode(.openai) }
    @objc private func setSolControlQuotaSave(_: Any?) { setSolControlMode(.quotaSave) }

    private func setSolControlMode(_ mode: SolControlConfiguredMode) {
        guard let bridge = solControlBridge else { showWarning("联动资源不可用"); return }
        Task { [weak self] in
            guard let self else { return }
            guard let resolution = await bridge.setMode(mode) else { showWarning("Sol Control 设置失败"); return }
            solControlResolution = resolution
            await refreshSolControlStatusAsync()
        }
    }

    private func makeMenu() -> NSMenu {
        let model = LumeMenuPresentation(state: state, panelVisible: panel?.isVisible == true, refreshStatus: refreshStatus, launchAtLogin: launchAtLogin.isEnabled, lastUpdateAt: lastUpdateAt, now: Date())
        let menu = NSMenu()
        for (index, entry) in model.items.enumerated() {
            let item: NSMenuItem
            switch index {
            case 2: item = menu.addItem(withTitle: entry.title, action: #selector(openCodex(_:)), keyEquivalent: ""); item.target = self
            case 3: item = menu.addItem(withTitle: entry.title, action: #selector(togglePanel(_:)), keyEquivalent: ""); item.target = self
            case 4: item = menu.addItem(withTitle: entry.title, action: #selector(refresh(_:)), keyEquivalent: ""); item.target = self
            case 5:
                item = menu.addItem(withTitle: entry.title, action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
                item.target = self
                item.state = launchAtLogin.isEnabled ? .on : .off
            case 6:
                item = menu.addItem(withTitle: entry.title, action: nil, keyEquivalent: "")
                item.submenu = makeSolControlMenu()
            case 7: item = menu.addItem(withTitle: entry.title, action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""); item.target = NSApp
            case 8: item = menu.addItem(withTitle: entry.title, action: #selector(quit(_:)), keyEquivalent: "q"); item.target = self
            default: item = menu.addItem(withTitle: entry.title, action: nil, keyEquivalent: "")
            }
        }
        return menu
    }

    private func makeSolControlMenu() -> NSMenu {
        let menu = NSMenu()
        guard solControlBridge != nil, let doctor = solControlDoctor else {
            let status = menu.addItem(withTitle: "联动不可用", action: nil, keyEquivalent: "")
            status.isEnabled = false
            let enable = menu.addItem(withTitle: "启用 Sol Control 联动…", action: #selector(enableSolControl(_:)), keyEquivalent: "")
            enable.target = self
            return menu
        }
        let configured = ["helper", "hook", "skill", "hookConfig"].allSatisfy { doctor.checks[$0] == true }
        guard configured, let resolution = solControlResolution else {
            let status = menu.addItem(withTitle: "联动未安装", action: nil, keyEquivalent: "")
            status.isEnabled = false
            let enable = menu.addItem(withTitle: "启用 Sol Control 联动…", action: #selector(enableSolControl(_:)), keyEquivalent: "")
            enable.target = self
            return menu
        }
        let statusTitle = doctor.available ? solControlStatusTitle(resolution) : "等待下一次 Sol Control 调用验证"
        let current = menu.addItem(withTitle: statusTitle, action: nil, keyEquivalent: "")
        current.isEnabled = false
        menu.addItem(.separator())
        let entries: [(String, SolControlConfiguredMode, Selector)] = [
            ("自动", .auto, #selector(setSolControlAuto(_:))),
            ("强制 OpenAI", .openai, #selector(setSolControlOpenAI(_:))),
            ("强制 quota-save", .quotaSave, #selector(setSolControlQuotaSave(_:))),
        ]
        for (title, mode, action) in entries {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = resolution.configuredMode == mode.rawValue ? .on : .off
        }
        return menu
    }

    private func solControlStatusTitle(_ resolution: SolControlResolution) -> String {
        switch resolution.configuredMode {
        case SolControlConfiguredMode.openai.rawValue:
            return "当前有效：强制 OpenAI"
        case SolControlConfiguredMode.quotaSave.rawValue:
            return "当前有效：强制 quota-save"
        default:
            let allowance = resolution.remainingPercentage.map { value in
                value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
            } ?? "--"
            return "当前有效：\(resolution.mode) · 7D \(allowance)%"
        }
    }

    private func refresh(reason: RefreshReason) {
        Task { [weak self] in
            guard let self, let coordinator else { return }
            let result = await coordinator.refresh(now: Date(), reason: reason)
            refreshStatus = result.status
            if result.status == .throttled {
                if lastUpdateAt == nil { lastUpdateAt = result.observedAt }
                statusItem?.menu = makeMenu()
                return
            }
            state.apply(result)
            lastUpdateAt = result.observedAt
            preferences.state = state
            if result.status == .success { warning = nil }
            else { showWarning("Usage update unavailable", beep: false) }
            LumeLog.record(result)
            preferencesStore.save(preferences)
            if let bridge = solControlBridge {
                solControlResolution = await bridge.publish(result)
                solControlDoctor = await bridge.doctor()
                handleLowQuotaNotification(result: result, resolution: solControlResolution)
            }
            statusItem?.menu = makeMenu()
            updatePresentation()
        }
    }

    private func refreshSolControlStatus() {
        Task { [weak self] in await self?.refreshSolControlStatusAsync() }
    }

    private func refreshSolControlStatusAsync() async {
        guard let bridge = solControlBridge else {
            solControlDoctor = nil
            solControlResolution = nil
            statusItem?.menu = makeMenu()
            return
        }
        solControlDoctor = await bridge.doctor()
        if let resolution = solControlDoctor?.resolution {
            solControlResolution = resolution
        } else {
            solControlResolution = await bridge.resolve()
        }
        statusItem?.menu = makeMenu()
    }

    private func handleLowQuotaNotification(result: UsageReadResult, resolution: SolControlResolution?) {
        guard result.status == .success, let remaining = result.remainingPercentageExact else { return }
        if remaining >= 25 {
            if !lowQuotaNotificationArmed {
                lowQuotaNotificationArmed = true
                UserDefaults.standard.set(true, forKey: "Lume.lowQuotaNotificationArmed")
            }
            return
        }
        guard remaining < 20, lowQuotaNotificationArmed, !lowQuotaNotificationPending else { return }
        lowQuotaNotificationPending = true
        let forcedOpenAI = resolution?.configuredMode == SolControlConfiguredMode.openai.rawValue
        let content = UNMutableNotificationContent()
        content.title = "Codex 7D 额度低"
        content.body = forcedOpenAI
            ? "剩余 \(String(format: "%.1f", remaining))%，但 Sol Control 当前为强制 OpenAI。"
            : "剩余 \(String(format: "%.1f", remaining))%，后续 Sol Control 将使用 quota-save。"
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] allowed, _ in
            Task { @MainActor in
                guard let self else { return }
                self.lowQuotaNotificationPending = false
                self.lowQuotaNotificationArmed = false
                UserDefaults.standard.set(false, forKey: "Lume.lowQuotaNotificationArmed")
                guard allowed else { return }
                try? await center.add(UNNotificationRequest(identifier: "lume.low-quota", content: content, trigger: nil))
            }
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
        updateBreathing()
    }

    private func updateBreathing() {
        breathingTimer?.invalidate()
        guard let panel,
              panel.isVisible,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              (state.visiblePercentage(at: Date()) ?? 100) < 10
        else { panel?.alphaValue = 1; return }
        var dimmed = false
        breathingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak panel] _ in
            guard let panel, panel.isVisible else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 1
                panel.animator().alphaValue = dimmed ? 1 : 0.88
            }
            dimmed.toggle()
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
        animate(panel, to: destination, duration: 0.20) { [weak self] in self?.updatePresentation() }
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
        warningTimer?.invalidate()
        warning = message
        if beep { NSSound.beep() }
        updatePresentation()
        warningTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.warning = nil
                self?.updatePresentation()
            }
        }
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

    init(state: LumeState, dockSide: DockSide?, preview: DockSide?, warning: String?, pointerStarted: @escaping () -> Void, pointerMoved: @escaping (CGPoint, CGPoint) -> Void, pointerReleased: @escaping (CGPoint, CGPoint) -> Void, showContextMenu: @escaping (NSEvent, NSView) -> Void) {
        self.state = state; self.dockSide = dockSide; self.preview = preview; self.warning = warning; self.pointerStarted = pointerStarted; self.pointerMoved = pointerMoved; self.pointerReleased = pointerReleased; self.showContextMenu = showContextMenu
        super.init(frame: .init(origin: .zero, size: state.presentation == .ring ? PanelGeometry.ringHitSize : PanelGeometry.railHitSize))
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityLabel(state.visiblePercentage(at: Date()).map { "Codex 7D remaining \($0) percent" } ?? "Codex 7D unavailable")
        setAccessibilityHelp(Self.accessibilityHelp(for: PanelVisual.resolved(presentation: state.presentation, dockSide: dockSide)))
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { startGlobal = globalPoint(event); pointerStarted() }
    override func mouseDragged(with event: NSEvent) { pointerMoved(startGlobal, globalPoint(event)) }
    override func mouseUp(with event: NSEvent) { pointerReleased(startGlobal, globalPoint(event)) }
    override func rightMouseDown(with event: NSEvent) { showContextMenu(event, self) }

    func update(state: LumeState, dockSide: DockSide?, preview: DockSide?, warning: String?) {
        self.state = state
        self.dockSide = dockSide
        self.preview = preview
        self.warning = warning
        setAccessibilityLabel(state.visiblePercentage(at: Date()).map { "Codex 7D remaining \($0) percent" } ?? "Codex 7D unavailable")
        setAccessibilityHelp(Self.accessibilityHelp(for: PanelVisual.resolved(presentation: state.presentation, dockSide: dockSide)))
        needsDisplay = true
    }

    func setPreview(_ preview: DockSide?) {
        guard self.preview != preview else { return }
        self.preview = preview
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let color = nsColor(state.color(at: Date()))
        switch PanelVisual.resolved(presentation: state.presentation, dockSide: dockSide) {
        case .ring:
            NSGraphicsContext.saveGraphicsState()
            NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
            NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 36, height: 36)).fill()
            let ringBounds = NSRect(x: 3, y: 3, width: 34, height: 34)
            let track = NSBezierPath(ovalIn: ringBounds); track.lineWidth = 2; NSColor.quaternaryLabelColor.setStroke(); track.stroke()
            if let percentage = state.visiblePercentage(at: Date()) {
                let progress = NSBezierPath()
                progress.appendArc(withCenter: CGPoint(x: 20, y: 20), radius: 17, startAngle: 90, endAngle: 90 - 360 * CGFloat(percentage) / 100, clockwise: true)
                progress.lineWidth = 2; progress.lineCapStyle = .round; color.setStroke(); progress.stroke()
            }
            let value = state.visiblePercentage(at: Date()).map { "\($0)%" } ?? "--"
            drawCentered(value, y: 16, font: .monospacedDigitSystemFont(ofSize: 10, weight: .bold), color: .labelColor)
            drawCentered("7D", y: 7, font: .systemFont(ofSize: 7, weight: .medium), color: .secondaryLabelColor)
            if state.isStale(at: Date()) { NSColor.systemOrange.setFill(); NSBezierPath(ovalIn: NSRect(x: 32, y: 32, width: 4, height: 4)).fill() }
            if let preview { color.withAlphaComponent(0.35).setFill(); NSBezierPath(rect: NSRect(x: preview == .left ? 0 : 36, y: 0, width: 4, height: 40)).fill() }
            if warning != nil { NSColor.systemOrange.setFill(); NSBezierPath(ovalIn: NSRect(x: 2, y: 34, width: 4, height: 4)).fill() }
            NSGraphicsContext.restoreGraphicsState()
        case .rail(let dockSide):
            let railX: CGFloat = dockSide == .left ? 0 : 15
            NSColor.quaternaryLabelColor.setFill(); NSBezierPath(roundedRect: NSRect(x: railX, y: 5, width: 8, height: 50), xRadius: 4, yRadius: 4).fill()
            let fraction = CGFloat(state.visiblePercentage(at: Date()) ?? 0) / 100
            color.setFill(); NSBezierPath(roundedRect: NSRect(x: railX, y: 5, width: 8, height: 50 * fraction), xRadius: 4, yRadius: 4).fill()
            let indicatorX: CGFloat = dockSide == .left ? 10 : 9
            if state.isStale(at: Date()) { NSColor.systemOrange.setFill(); NSBezierPath(ovalIn: NSRect(x: indicatorX, y: 52, width: 4, height: 4)).fill() }
            if warning != nil { NSColor.systemOrange.setFill(); NSBezierPath(ovalIn: NSRect(x: indicatorX, y: 4, width: 4, height: 4)).fill() }
        }
    }
    private static func accessibilityHelp(for visual: PanelVisual) -> String {
        switch visual {
        case .ring: return "Click to open Codex; drag to move or dock"
        case .rail: return "Click to expand; drag inward forty points to expand"
        }
    }
    private func drawCentered(_ string: String, y: CGFloat, font: NSFont, color: NSColor) {
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        attributed.draw(at: CGPoint(x: (bounds.width - attributed.size().width) / 2, y: y))
    }
    private func globalPoint(_ event: NSEvent) -> CGPoint { window?.convertPoint(toScreen: event.locationInWindow) ?? .zero }
    private func nsColor(_ value: LumeColor) -> NSColor { switch value { case .mint: .systemMint; case .orange: .systemOrange; case .red: .systemRed; case .gray: .systemGray } }
}
