import AppKit
import Foundation
import LumeCore

private func check(_ condition: @autoclosure () -> Bool, _ message: String, failures: inout Int) { if condition() { print("PASS \(message)") } else { fputs("FAIL \(message)\n", stderr); failures += 1 } }

private struct StubReader: UsageReader { let result: UsageReadResult; func read() async -> UsageReadResult { result } }
private actor StubTransport: AppServerTransport { var lines: [String]; init(lines: [String]) { self.lines = lines }; func send(_: String) async throws {}; func receive() async throws -> String? { lines.isEmpty ? nil : lines.removeFirst() }; func terminate() async {} }
private struct StubFactory: AppServerTransportFactory { let transport: StubTransport; func start() async throws -> any AppServerTransport { transport } }
private struct AnyTransportFactory: AppServerTransportFactory { let transport: any AppServerTransport; func start() async throws -> any AppServerTransport { transport } }
private final class ActivationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
private struct StubCodex: CodexApplicationControlling {
    let frontmost: Bool
    let running: Bool
    let activated: Bool
    let launched: Bool
    let activationProbe: ActivationProbe?
    init(frontmost: Bool, running: Bool, activated: Bool, launched: Bool, activationProbe: ActivationProbe? = nil) {
        self.frontmost = frontmost
        self.running = running
        self.activated = activated
        self.launched = launched
        self.activationProbe = activationProbe
    }
    func isFrontmost(bundleIdentifier _: String) -> Bool { frontmost }
    func isRunning(bundleIdentifier _: String) -> Bool { running }
    func activateRunning(bundleIdentifier _: String) async -> Bool { activationProbe?.record(); return activated }
    func launchConfirmed(bundleIdentifier _: String) async -> Bool { launched }
}
private struct StartFailureFactory: AppServerTransportFactory { let error: AppServerStartError; func start() async throws -> any AppServerTransport { throw error } }
private actor IOFailureTransport: AppServerTransport { func send(_: String) async throws {}; func receive() async throws -> String? { throw AppServerTransportError.io }; func terminate() async {} }
private actor BlockingTransport: AppServerTransport {
    private(set) var didTerminate = false
    func send(_: String) async throws {}
    func receive() async throws -> String? { try await Task.sleep(for: .seconds(1)); return nil }
    func terminate() async { didTerminate = true }
}

@main struct LumeTests {
    static func main() async {
        if CommandLine.arguments.contains("--live") {
            let result = await DiscoveredCodexUsageReader().read()
            print("LIVE status=\(result.status.rawValue) 5H=\(result.fiveHour?.remainingPercentage.description ?? "--") 7D=\(result.sevenDay?.remainingPercentage.description ?? "--") code=\(result.failureCode.rawValue) durationMs=\(Int(result.duration * 1_000))")
            exit(result.status == .success ? 0 : 1)
        }
        if CommandLine.arguments.contains("--live-handoff") {
            let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
            _ = finder?.activate(options: [.activateAllWindows])
            try? await Task.sleep(for: .milliseconds(500))
            let before = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
            let result = await CodexHandoff().perform()
            try? await Task.sleep(for: .seconds(1))
            let after = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
            print("HANDOFF before=\(before) result=\(result) after=\(after)")
            let accepted = result == .activated || result == .alreadyFrontmost
            exit(accepted && after == CodexHandoff.bundleIdentifier ? 0 : 1)
        }
        var failures = 0; let epoch = Date(timeIntervalSince1970: 0)
        check(PanelGeometry.ringHitSize == CGSize(width: 48, height: 48) && PanelGeometry.ringVisibleDiameter == 44, "dual-ring geometry preserves a forty-four point visible circle inside a forty-eight point hit target", failures: &failures)
        check(PanelGeometry.railHitSize == CGSize(width: 24, height: 64) && PanelGeometry.railVisibleSize == CGSize(width: 10, height: 54), "dual-rail geometry preserves the specified visible and hit sizes", failures: &failures)
        let fakeHome = URL(fileURLWithPath: "/Users/tester")
        let fakeResources = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources")
        let executablePaths = Set([
            fakeHome.appendingPathComponent(".local/bin/codex").path,
            fakeResources.appendingPathComponent("codex").path,
        ])
        let guiLocator = SystemCodexExecutableLocator(
            environment: ["PATH": "/usr/bin:/bin"],
            homeDirectory: fakeHome,
            applicationResources: fakeResources,
            isExecutable: { executablePaths.contains($0) }
        )
        check(guiLocator.locate() == fakeResources.appendingPathComponent("codex"), "GUI discovery prefers the self-contained Codex app executable over a PATH-dependent wrapper", failures: &failures)
        check(LumeState.empty(now: epoch).sevenDay.displayValue == "--", "unavailable state displays dashes", failures: &failures)
        check(LumeColor.forRemaining(50) == .mint && LumeColor.forRemaining(49) == .orange && LumeColor.forRemaining(20) == .orange && LumeColor.forRemaining(19) == .red, "thresholds exactly match specification", failures: &failures)
        check(PanelGeometry.isClick(from: .zero, to: CGPoint(x: 2.99, y: 0)) && !PanelGeometry.isClick(from: .zero, to: CGPoint(x: 3, y: 0)), "three point movement distinguishes click from drag", failures: &failures)
        let screen = CGRect(x: 0, y: 0, width: 100, height: 100)
        check(PanelGeometry.draggedOrigin(from: CGPoint(x: 40, y: 50), pointerStart: .zero, pointerCurrent: CGPoint(x: 2.99, y: 0)) == nil && PanelGeometry.draggedOrigin(from: CGPoint(x: 40, y: 50), pointerStart: .zero, pointerCurrent: CGPoint(x: 3, y: 0)) == CGPoint(x: 43, y: 50), "sub-threshold clicks never move the ring", failures: &failures)
        check(PanelGeometry.initialRingOrigin(in: CGRect(x: -800, y: 20, width: 800, height: 600)) == CGPoint(x: -424, y: 552), "first placement centers below the selected main screen top", failures: &failures)
        let railScreen = CGRect(x: -800, y: 20, width: 800, height: 600)
        check(PanelGeometry.railOrigin(from: CGPoint(x: -800, y: 200), pointerStart: CGPoint(x: -790, y: 220), pointerCurrent: CGPoint(x: -790, y: 300), side: .left, in: railScreen) == CGPoint(x: -800, y: 280), "left rail drags vertically while remaining on its edge", failures: &failures)
        check(PanelGeometry.railOrigin(from: CGPoint(x: -24, y: 590), pointerStart: CGPoint(x: -10, y: 600), pointerCurrent: CGPoint(x: -10, y: 700), side: .right, in: railScreen) == CGPoint(x: -24, y: 556), "right rail remains edge-pinned and clamps to the visible screen", failures: &failures)
        check(PanelGeometry.expandedRingOrigin(from: CGRect(x: -24, y: 280, width: 24, height: 64), side: .right, in: railScreen) == CGPoint(x: -48, y: 288), "right rail expands leftward at its current vertical center", failures: &failures)
        check(PanelGeometry.expandedRingOrigin(from: CGRect(x: -800, y: 280, width: 24, height: 64), side: .left, in: railScreen) == CGPoint(x: -800, y: 288), "left rail expands rightward at its current vertical center", failures: &failures)
        check(PanelVisual.resolved(presentation: .ring, dockSide: .right) == .ring, "ring presentation cannot retain a stale rail visual", failures: &failures)
        check(PanelVisual.resolved(presentation: .rail, dockSide: .left) == .rail(.left), "rail visual requires a matching dock side", failures: &failures)
        check(PanelTransition.ringRelease(start: .zero, end: CGPoint(x: 16, y: 40), screen: screen) == .dock(.left), "dock commits at sixteen points", failures: &failures)
        check(PanelTransition.ringRelease(start: .zero, end: CGPoint(x: 1, y: 0), didDrag: true, screen: screen) == .dock(.left), "returning below threshold after a drag never triggers handoff", failures: &failures)
        check(PanelTransition.railRelease(inwardDrag: 39.9) == .none && PanelTransition.railRelease(inwardDrag: 40) == .restoreRing, "rail requires forty point inward drag", failures: &failures)
        var state = LumeState(fiveHour: UsageWindowState(), sevenDay: UsageWindowState(remainingPercentageExact: 70, lastSuccessfulAt: epoch, lastStatus: .failed))
        check(state.sevenDay.presentationState(at: epoch.addingTimeInterval(10)) == .stale(70) && state.sevenDay.color(at: epoch.addingTimeInterval(10)) == .mint, "stale state preserves the last successful color", failures: &failures)
        check(state.sevenDay.presentationState(at: epoch.addingTimeInterval(901)) == .unavailable && state.sevenDay.color(at: epoch.addingTimeInterval(901)) == .gray, "expired state becomes neutral", failures: &failures)
        state.apply(UsageReadResult(status: .success, fiveHour: nil, sevenDay: UsageWindowSnapshot(remainingPercentageExact: 21, resetsAt: nil), observedAt: epoch))
        check(state.sevenDay.displayValue == "21" && state.sevenDay.color(at: epoch) == .orange, "successful read updates percentage", failures: &failures)
        let coordinator = UsageRefreshCoordinator(reader: StubReader(result: UsageReadResult(status: .success, fiveHour: nil, sevenDay: UsageWindowSnapshot(remainingPercentageExact: 80, resetsAt: nil), observedAt: epoch)))
        let first = await coordinator.refresh(now: epoch, reason: .launch); let second = await coordinator.refresh(now: epoch.addingTimeInterval(9), reason: .manual)
        check(first.status == .success && second.status == .throttled, "manual refresh coalesces within ten seconds", failures: &failures)
        let presentationCoordinator = UsageRefreshCoordinator(reader: StubReader(result: UsageReadResult(status: .success, fiveHour: nil, sevenDay: UsageWindowSnapshot(remainingPercentageExact: 79, resetsAt: nil), observedAt: epoch)))
        var dockedState = LumeState.empty(now: epoch); dockedState.presentation = .rail
        let presentationResult = await presentationCoordinator.refresh(now: epoch, reason: .timer)
        dockedState.apply(presentationResult)
        check(dockedState.presentation == .rail, "usage refresh preserves the current docked rail presentation", failures: &failures)
        let frontmostActivation = ActivationProbe()
        let frontmostHandoff = await CodexHandoff(controller: StubCodex(frontmost: true, running: true, activated: true, launched: true, activationProbe: frontmostActivation)).perform()
        let launchedHandoff = await CodexHandoff(controller: StubCodex(frontmost: false, running: false, activated: false, launched: true)).perform()
        let unavailableHandoff = await CodexHandoff(controller: StubCodex(frontmost: false, running: false, activated: false, launched: false)).perform()
        let failedActivation = await CodexHandoff(controller: StubCodex(frontmost: false, running: true, activated: false, launched: true)).perform()
        check(frontmostHandoff == .alreadyFrontmost && frontmostActivation.value == 1, "handoff reactivates frontmost Codex so a minimized window is restored", failures: &failures)
        check(launchedHandoff == .launched, "handoff launches installed Codex", failures: &failures)
        check(unavailableHandoff == .unavailable, "handoff keeps Lume available when Codex is absent", failures: &failures)
        check(failedActivation == .failed, "handoff does not launch a second Codex when running activation fails", failures: &failures)
        let initResponse = "{\"id\":1,\"result\":{\"codexHome\":\"/private\",\"platformFamily\":\"mac\",\"platformOs\":\"darwin\",\"userAgent\":\"Codex\"}}"
        let rateResponse = "{\"id\":2,\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":70.0,\"windowDurationMins\":300},\"secondary\":{\"usedPercent\":80.1,\"windowDurationMins\":10080,\"resetsAt\":2000}}}}"
        let usage = await CodexAppServerUsageReader(factory: StubFactory(transport: StubTransport(lines: [initResponse, rateResponse])), now: { epoch }).read()
        check(usage.status == .success && usage.fiveHour?.remainingPercentage == 30 && usage.sevenDay?.remainingPercentage == 20 && abs((usage.sevenDay?.remainingPercentageExact ?? 0) - 19.9) < 0.0001 && usage.sevenDay?.resetsAt == Date(timeIntervalSince1970: 2000), "usage reader preserves independent five-hour and seven-day windows", failures: &failures)
        let invalidInitialize = await CodexAppServerUsageReader(factory: StubFactory(transport: StubTransport(lines: ["{\"id\":1,\"result\":{\"codexHome\":\"/private\"}}"])), now: { epoch }).read()
        check(invalidInitialize.status == .protocolError && invalidInitialize.failureCode == .initializeResultMissing, "usage reader rejects incomplete initialize result", failures: &failures)
        let serverError = await CodexAppServerUsageReader(factory: StubFactory(transport: StubTransport(lines: [initResponse, "{\"id\":2,\"error\":{\"code\":-1}}"])), now: { epoch }).read()
        check(serverError.status == .protocolError && serverError.failureCode == .serverError, "usage reader classifies server errors without payload logging", failures: &failures)
        let exited = await CodexAppServerUsageReader(factory: StubFactory(transport: StubTransport(lines: [])), now: { epoch }).read()
        check(exited.status == .processExited && exited.failureCode == .processExited, "usage reader classifies EOF as process exit", failures: &failures)
        var frames = AppServerFrameBuffer(); try? frames.append(Data("{\"method\":\"notice\"}\n{\"id\":2}\r\n".utf8))
        let notification = try? frames.nextLine(); let response = try? frames.nextLine()
        check(notification == "{\"method\":\"notice\"}" && response == "{\"id\":2}", "frame buffer retains notification and target response in one chunk", failures: &failures)
        var split = AppServerFrameBuffer(); try? split.append(Data("{\"id\":2".utf8)); let none = try? split.nextLine(); try? split.append(Data("}\n".utf8)); let completed = try? split.nextLine()
        check(none == nil && completed == "{\"id\":2}", "frame buffer joins split frames", failures: &failures)
        var tooLarge = AppServerFrameBuffer(); let largeResult = Result { try tooLarge.append(Data(repeating: 65, count: AppServerFrameBuffer.maximumFrameBytes + 1)) }
        if case .failure = largeResult { check(true, "frame buffer rejects payload above one MiB", failures: &failures) } else { check(false, "frame buffer rejects payload above one MiB", failures: &failures) }
        var trailingOverflow = AppServerFrameBuffer()
        let trailingOverflowResult = Result { try trailingOverflow.append(Data("{}\n".utf8) + Data(repeating: 65, count: AppServerFrameBuffer.maximumFrameBytes)) }
        if case .failure = trailingOverflowResult { check(true, "frame buffer rejects a bounded frame followed by an oversized retained tail", failures: &failures) } else { check(false, "frame buffer rejects a bounded frame followed by an oversized retained tail", failures: &failures) }
        let left = LumeDisplay(identifier: "left", visibleFrame: CGRect(x: -800, y: 0, width: 800, height: 600))
        let right = LumeDisplay(identifier: "right", visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        check(PanelGeometry.display(containing: CGPoint(x: -790, y: 20), displays: [right, left])?.identifier == "left", "release pointer selects its own display", failures: &failures)
        check(PanelGeometry.previewSide(at: CGPoint(x: 20, y: 200), displays: [left, right]) == .left && PanelGeometry.committedSide(at: CGPoint(x: 20, y: 200), displays: [left, right]) == nil, "twenty-four point preview does not commit", failures: &failures)
        check(PanelTransition.railRelease(start: .zero, end: .zero, side: .left) == .restoreRing && PanelTransition.railRelease(start: .zero, end: CGPoint(x: 40, y: 0), side: .left) == .restoreRing && PanelTransition.railRelease(start: .zero, end: CGPoint(x: -40, y: 0), side: .left) == .none, "rail click and inward direction restore only", failures: &failures)
        let placement = PanelPlacement.ring(origin: CGPoint(x: 2000, y: 2000), displayIdentifier: "gone")
        let migrated = placement.migrated(to: [left, right])
        check(migrated.displayIdentifier == "right" && right.visibleFrame.contains(migrated.origin), "placement migrates and clamps after display topology changes", failures: &failures)
        var menuState = LumeState.empty(now: epoch)
        menuState.apply(UsageReadResult(status: .success, fiveHour: UsageWindowSnapshot(remainingPercentageExact: 61.4, resetsAt: Date(timeIntervalSince1970: 1800)), sevenDay: UsageWindowSnapshot(remainingPercentageExact: 8.2, resetsAt: Date(timeIntervalSince1970: 7200)), observedAt: epoch))
        let menu = LumeMenuPresentation(state: menuState, panelVisible: false, now: epoch)
        check(menu.items[0].title.contains("61%") && menu.items[0].title.contains("30 分钟后") && menu.items[1].title.contains("1月1日"), "menu shows integer quota, short reset countdown and a dated weekly reset", failures: &failures)
        check(menu.items.count == 9 && menu.items[3].action == .openCodex, "menu actions remain bound to their meaning", failures: &failures)
        let cached = UsageText.window(menuState.fiveHour, label: "5H", now: epoch.addingTimeInterval(130))
        check(cached.contains("缓存") && cached.contains("上次成功读取：2 分钟前"), "cached window names its last successful read", failures: &failures)
        menuState.apply(UsageReadResult(status: .timedOut, fiveHour: nil, sevenDay: nil, observedAt: epoch.addingTimeInterval(140)))
        menuState.apply(UsageReadResult(status: .throttled, fiveHour: nil, sevenDay: nil, observedAt: epoch.addingTimeInterval(145)))
        check(menuState.latestReadStatus == .timedOut && menuState.fiveHour.lastSuccessfulAt == epoch, "failure followed by throttling preserves the error and successful timestamp", failures: &failures)
        check(menuState.fiveHour.visiblePercentage(at: epoch.addingTimeInterval(1800)) == nil, "elapsed reset invalidates cached quota", failures: &failures)
        check(UsageText.tooltip(state: menuState, now: epoch).contains("1970-01-01"), "tooltip includes complete reset dates", failures: &failures)
        let numericShape = "{\"id\":2,\"result\":{\"rateLimitsByLimitId\":{\"other\":{\"primary\":{\"usedPercent\":90,\"windowDurationMins\":300},\"secondary\":{\"usedPercent\":25,\"windowDurationMins\":10080}}}}}"
        let normalized = await CodexAppServerUsageReader(factory: StubFactory(transport: StubTransport(lines: [initResponse, numericShape])), now: { epoch }).read()
        check(normalized.status == .protocolError && normalized.sevenDay == nil, "reader does not assume an unknown bucket belongs to Codex", failures: &failures)
        let multiBucket = "{\"id\":2,\"result\":{\"rateLimitsByLimitId\":{\"codex\":{\"primary\":{\"usedPercent\":90,\"windowDurationMins\":300}},\"codex_other\":{\"secondary\":{\"usedPercent\":81,\"windowDurationMins\":10080}}}}}"
        let multiBucketUsage = await CodexAppServerUsageReader(factory: StubFactory(transport: StubTransport(lines: [initResponse, multiBucket])), now: { epoch }).read()
        check(multiBucketUsage.status == .success && multiBucketUsage.fiveHour?.remainingPercentage == 10 && multiBucketUsage.sevenDay == nil, "reader keeps both windows within the selected Codex bucket", failures: &failures)
        let stringIDResponse = "{\"id\":\"2\",\"result\":{\"rateLimits\":{\"secondary\":{\"usedPercent\":50,\"windowDurationMins\":10080}}}}"
        let stringIDUsage = await CodexAppServerUsageReader(factory: StubFactory(transport: StubTransport(lines: [initResponse, stringIDResponse])), now: { epoch }).read()
        let malformed = await CodexAppServerUsageReader(factory: StubFactory(transport: StubTransport(lines: ["not json"])), now: { epoch }).read()
        check(stringIDUsage.status == .success && stringIDUsage.sevenDay?.remainingPercentage == 50 && malformed.status == .invalidJSON, "reader accepts string IDs and rejects malformed frames", failures: &failures)
        let callbackResult = await CodexHandoff(controller: StubCodex(frontmost: false, running: false, activated: false, launched: true)).perform()
        check(callbackResult == .launched, "handoff waits for launch confirmation", failures: &failures)
        let missingExecutable = await CodexAppServerUsageReader(factory: StartFailureFactory(error: .executableNotFound), now: { epoch }).read()
        let permissionFailure = await CodexAppServerUsageReader(factory: StartFailureFactory(error: .permissionDenied), now: { epoch }).read()
        check(missingExecutable.status == .executableNotFound && missingExecutable.failureCode == .executableNotFound && permissionFailure.failureCode == .processStartFailed, "start failures receive stable classifications", failures: &failures)
        let ioFailure = await CodexAppServerUsageReader(factory: AnyTransportFactory(transport: IOFailureTransport()), now: { epoch }).read()
        check(ioFailure.status == UsageReadStatus.failed && ioFailure.failureCode == UsageFailureCode.processIO, "transport IO remains process IO rather than invalid JSON", failures: &failures)
        let blocking = BlockingTransport()
        let timedOut = await CodexAppServerUsageReader(factory: AnyTransportFactory(transport: blocking), timeout: 0.001).read()
        let blockingDidTerminate = await blocking.didTerminate
        check(timedOut.status == .timedOut && blockingDidTerminate, "one total timeout returns without waiting for blocking receive and terminates transport", failures: &failures)
        let shortOnly = "{\"id\":2,\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":10,\"windowDurationMins\":300}}}}"
        let shortOnlyUsage = await CodexAppServerUsageReader(factory: StubFactory(transport: StubTransport(lines: [initResponse, shortOnly])), now: { epoch }).read()
        check(shortOnlyUsage.status == .success && shortOnlyUsage.fiveHour?.remainingPercentage == 90 && shortOnlyUsage.sevenDay == nil, "reader accepts an independently available five-hour window", failures: &failures)
        let longerWindow = "{\"id\":2,\"result\":{\"rateLimits\":{\"secondary\":{\"usedPercent\":10,\"windowDurationMins\":43200}}}}"
        let longerWindowUsage = await CodexAppServerUsageReader(factory: StubFactory(transport: StubTransport(lines: [initResponse, longerWindow])), now: { epoch }).read()
        check(longerWindowUsage.status == .protocolError && longerWindowUsage.sevenDay?.remainingPercentage == nil, "reader never labels a non-seven-day long window as 7D", failures: &failures)
        var independentState = LumeState.empty(now: epoch)
        independentState.apply(UsageReadResult(status: .success, fiveHour: UsageWindowSnapshot(remainingPercentageExact: 42, resetsAt: nil), sevenDay: nil, observedAt: epoch))
        check(independentState.fiveHour.presentationState(at: epoch) == .fresh(42) && independentState.sevenDay.presentationState(at: epoch) == .unavailable, "quota windows retain independent availability", failures: &failures)
        let legacy = "{\"remainingPercentage\":73,\"lastSuccessfulAt\":0,\"lastStatus\":\"success\",\"presentation\":\"rail\"}"
        let migratedLegacy = try? JSONDecoder().decode(LumeState.self, from: Data(legacy.utf8))
        check(migratedLegacy?.sevenDay.remainingPercentage == 73 && migratedLegacy?.fiveHour.remainingPercentage == nil && migratedLegacy?.presentation == .rail, "legacy single-window state migrates into the seven-day window", failures: &failures)
        check(RefreshSchedule.interval(activity: .active, failures: 0) == 60 && RefreshSchedule.interval(activity: .background, failures: 0) == 300 && RefreshSchedule.interval(activity: .stopped, failures: 0) == 900, "refresh rate follows Codex activity", failures: &failures)
        check(RefreshSchedule.interval(activity: .active, failures: 1) == 120 && RefreshSchedule.interval(activity: .active, failures: 4) == 900, "consecutive failures back off to fifteen minutes", failures: &failures)
        check(RefreshSchedule.delay(now: epoch, activity: .background, failures: 0, resets: [epoch.addingTimeInterval(20)]) == 22, "known reset schedules a prompt refresh", failures: &failures)
        let retried = await coordinator.refresh(now: epoch.addingTimeInterval(10), reason: .manual)
        check(retried.status == .success, "manual refresh retries after a short cooldown", failures: &failures)
        var changedSource = menuState
        changedSource.apply(UsageReadResult(status: .success, sourceID: "codex", fiveHour: UsageWindowSnapshot(remainingPercentageExact: 90, resetsAt: nil), sevenDay: nil, observedAt: epoch))
        check(changedSource.sevenDay.remainingPercentage == nil, "source change clears quota cached under an earlier source", failures: &failures)
        var invalidUTF8 = AppServerFrameBuffer()
        let preferred = "{\"id\":2,\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":1,\"windowDurationMins\":300}},\"rateLimitsByLimitId\":{\"codex\":{\"primary\":{\"usedPercent\":70,\"windowDurationMins\":300},\"secondary\":{\"usedPercent\":40,\"windowDurationMins\":10080}},\"other\":{\"primary\":{\"usedPercent\":90,\"windowDurationMins\":300}}}}}"
        let preferredUsage = await CodexAppServerUsageReader(factory: StubFactory(transport: StubTransport(lines: [initResponse, preferred])), now: { epoch }).read()
        check(preferredUsage.fiveHour?.remainingPercentage == 30 && preferredUsage.sevenDay?.remainingPercentage == 60, "named Codex bucket takes precedence over the legacy view", failures: &failures)
        let encodedState = try? JSONEncoder().encode(changedSource)
        let restoredState = encodedState.flatMap { try? JSONDecoder().decode(LumeState.self, from: $0) }
        check(restoredState == changedSource, "dual-window source and read state round-trip through preferences", failures: &failures)
        check(RefreshSchedule.delay(now: epoch, activity: .background, failures: 2, resets: [epoch.addingTimeInterval(20)]) == 900, "failed reads keep backoff even near a reset", failures: &failures)
        try? invalidUTF8.append(Data([0xFF, 0x0A]))
        let invalidUTF8Result = Result { try invalidUTF8.nextLine() }
        if case .failure = invalidUTF8Result { check(true, "frame buffer rejects invalid UTF-8", failures: &failures) }
        else { check(false, "frame buffer rejects invalid UTF-8", failures: &failures) }
        exit(Int32(failures))
    }
}
