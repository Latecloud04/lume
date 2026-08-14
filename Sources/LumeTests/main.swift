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
            print("LIVE status=\(result.status.rawValue) value=\(result.remainingPercentage.map(String.init) ?? "--") code=\(result.failureCode.rawValue) durationMs=\(Int(result.duration * 1_000))")
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
        check(LumeState.empty(now: epoch).displayValue == "--", "unavailable state displays dashes", failures: &failures)
        check(LumeColor.forRemaining(50) == .mint && LumeColor.forRemaining(49) == .orange && LumeColor.forRemaining(20) == .orange && LumeColor.forRemaining(19) == .red, "thresholds exactly match specification", failures: &failures)
        check(PanelGeometry.isClick(from: .zero, to: CGPoint(x: 2.99, y: 0)) && !PanelGeometry.isClick(from: .zero, to: CGPoint(x: 3, y: 0)), "three point movement distinguishes click from drag", failures: &failures)
        let screen = CGRect(x: 0, y: 0, width: 100, height: 100)
        check(PanelGeometry.draggedOrigin(from: CGPoint(x: 40, y: 50), pointerStart: .zero, pointerCurrent: CGPoint(x: 2.99, y: 0)) == nil && PanelGeometry.draggedOrigin(from: CGPoint(x: 40, y: 50), pointerStart: .zero, pointerCurrent: CGPoint(x: 3, y: 0)) == CGPoint(x: 43, y: 50), "sub-threshold clicks never move the ring", failures: &failures)
        check(PanelGeometry.initialRingOrigin(in: CGRect(x: -800, y: 20, width: 800, height: 600)) == CGPoint(x: -420, y: 560), "first placement centers below the selected main screen top", failures: &failures)
        let railScreen = CGRect(x: -800, y: 20, width: 800, height: 600)
        check(PanelGeometry.railOrigin(from: CGPoint(x: -800, y: 200), pointerStart: CGPoint(x: -790, y: 220), pointerCurrent: CGPoint(x: -790, y: 300), side: .left, in: railScreen) == CGPoint(x: -800, y: 280), "left rail drags vertically while remaining on its edge", failures: &failures)
        check(PanelGeometry.railOrigin(from: CGPoint(x: -23, y: 590), pointerStart: CGPoint(x: -10, y: 600), pointerCurrent: CGPoint(x: -10, y: 700), side: .right, in: railScreen) == CGPoint(x: -23, y: 560), "right rail remains edge-pinned and clamps to the visible screen", failures: &failures)
        check(PanelGeometry.expandedRingOrigin(from: CGRect(x: -23, y: 280, width: 23, height: 60), side: .right, in: railScreen) == CGPoint(x: -40, y: 290), "right rail expands leftward at its current vertical center", failures: &failures)
        check(PanelGeometry.expandedRingOrigin(from: CGRect(x: -800, y: 280, width: 23, height: 60), side: .left, in: railScreen) == CGPoint(x: -800, y: 290), "left rail expands rightward at its current vertical center", failures: &failures)
        check(PanelVisual.resolved(presentation: .ring, dockSide: .right) == .ring, "ring presentation cannot retain a stale rail visual", failures: &failures)
        check(PanelVisual.resolved(presentation: .rail, dockSide: .left) == .rail(.left), "rail visual requires a matching dock side", failures: &failures)
        check(PanelTransition.ringRelease(start: .zero, end: CGPoint(x: 16, y: 40), screen: screen) == .dock(.left), "dock commits at sixteen points", failures: &failures)
        check(PanelTransition.ringRelease(start: .zero, end: CGPoint(x: 1, y: 0), didDrag: true, screen: screen) == .dock(.left), "returning below threshold after a drag never triggers handoff", failures: &failures)
        check(PanelTransition.railRelease(inwardDrag: 39.9) == .none && PanelTransition.railRelease(inwardDrag: 40) == .restoreRing, "rail requires forty point inward drag", failures: &failures)
        var state = LumeState(remainingPercentage: 70, lastSuccessfulAt: epoch, lastStatus: .failed)
        check(state.presentationState(at: epoch.addingTimeInterval(10)) == .stale(70) && state.color(at: epoch.addingTimeInterval(10)) == .mint, "stale state preserves the last successful color", failures: &failures)
        check(state.presentationState(at: epoch.addingTimeInterval(901)) == .unavailable && state.color(at: epoch.addingTimeInterval(901)) == .gray, "expired state becomes neutral", failures: &failures)
        state.apply(UsageReadResult(status: .success, remainingPercentage: 21, observedAt: epoch))
        check(state.displayValue == "21" && state.color(at: epoch) == .orange, "successful read updates percentage", failures: &failures)
        let coordinator = UsageRefreshCoordinator(reader: StubReader(result: UsageReadResult(status: .success, remainingPercentage: 80, observedAt: epoch)))
        let first = await coordinator.refresh(now: epoch, reason: .launch); let second = await coordinator.refresh(now: epoch.addingTimeInterval(59), reason: .manual)
        check(first.status == .success && second.status == .throttled, "manual refresh coalesces within sixty seconds", failures: &failures)
        let presentationCoordinator = UsageRefreshCoordinator(reader: StubReader(result: UsageReadResult(status: .success, remainingPercentage: 79, observedAt: epoch)))
        var dockedState = LumeState.empty(now: epoch); dockedState.presentation = .rail
        let presentationResult = await presentationCoordinator.refresh(now: epoch, reason: .timer)
        dockedState.apply(presentationResult)
        check(dockedState.presentation == .rail, "usage refresh preserves the current docked rail presentation", failures: &failures)
        let slowHelper = FileManager.default.temporaryDirectory.appendingPathComponent("lume-slow-helper-\(UUID().uuidString).py")
        try? "import time\ntime.sleep(10)\n".write(to: slowHelper, atomically: true, encoding: .utf8)
        let slowStartedAt = Date()
        let slowResolution = await SolControlBridge(helperURL: slowHelper, installerURL: slowHelper).resolve()
        check(slowResolution == nil && Date().timeIntervalSince(slowStartedAt) < 5, "Sol Control helper calls time out without blocking Lume", failures: &failures)
        try? FileManager.default.removeItem(at: slowHelper)
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
        check(usage.status == .success && usage.remainingPercentage == 20 && abs((usage.remainingPercentageExact ?? 0) - 19.9) < 0.0001 && usage.resetsAt == Date(timeIntervalSince1970: 2000), "usage reader preserves unrounded seven day allowance and reset", failures: &failures)
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
        let menu = LumeMenuPresentation(state: LumeState(remainingPercentage: 8, lastSuccessfulAt: epoch, lastStatus: .success), panelVisible: false, refreshStatus: .throttled, launchAtLogin: false, now: epoch)
        check(menu.items.map(\.title) == ["7D 额度：8%", "等待刷新", "打开 Codex", "显示额度浮窗", "刷新额度", "登录时启动", "Sol Control", "关于 Lume", "退出 Lume"], "menu labels are localized and keep Sol Control in a short parent item", failures: &failures)
        let agedMenu = LumeMenuPresentation(state: LumeState(remainingPercentage: 8, lastSuccessfulAt: epoch, lastStatus: .success), panelVisible: true, refreshStatus: .success, launchAtLogin: false, lastUpdateAt: epoch, now: epoch.addingTimeInterval(65))
        check(agedMenu.items[1].title == "更新于 1 分钟前" && agedMenu.items[3].title == "隐藏额度浮窗", "localized menu reports update age and panel visibility", failures: &failures)
        let numericShape = "{\"id\":2,\"result\":{\"rateLimitsByLimitId\":{\"other\":{\"primary\":{\"usedPercent\":90,\"windowDurationMins\":300},\"secondary\":{\"usedPercent\":25,\"windowDurationMins\":10080}}}}}"
        let normalized = await CodexAppServerUsageReader(factory: StubFactory(transport: StubTransport(lines: [initResponse, numericShape])), now: { epoch }).read()
        check(normalized.status == .success && normalized.remainingPercentage == 75, "reader accepts NSNumber rate-limit shapes and selects long window", failures: &failures)
        let multiBucket = "{\"id\":2,\"result\":{\"rateLimitsByLimitId\":{\"codex\":{\"primary\":{\"usedPercent\":90,\"windowDurationMins\":300}},\"codex_other\":{\"secondary\":{\"usedPercent\":81,\"windowDurationMins\":10080}}}}}"
        let multiBucketUsage = await CodexAppServerUsageReader(factory: StubFactory(transport: StubTransport(lines: [initResponse, multiBucket])), now: { epoch }).read()
        check(multiBucketUsage.status == .success && multiBucketUsage.remainingPercentage == 19, "reader locates the actual seven day window across returned buckets", failures: &failures)
        let stringIDResponse = "{\"id\":\"2\",\"result\":{\"rateLimits\":{\"secondary\":{\"usedPercent\":50,\"windowDurationMins\":10080}}}}"
        let stringIDUsage = await CodexAppServerUsageReader(factory: StubFactory(transport: StubTransport(lines: [initResponse, stringIDResponse])), now: { epoch }).read()
        let malformed = await CodexAppServerUsageReader(factory: StubFactory(transport: StubTransport(lines: ["not json"])), now: { epoch }).read()
        check(stringIDUsage.status == .success && stringIDUsage.remainingPercentage == 50 && malformed.status == .invalidJSON, "reader accepts string IDs and rejects malformed frames", failures: &failures)
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
        check(shortOnlyUsage.status == .protocolError && shortOnlyUsage.remainingPercentage == nil, "reader never mislabels a short-only window as 7D", failures: &failures)
        let longerWindow = "{\"id\":2,\"result\":{\"rateLimits\":{\"secondary\":{\"usedPercent\":10,\"windowDurationMins\":43200}}}}"
        let longerWindowUsage = await CodexAppServerUsageReader(factory: StubFactory(transport: StubTransport(lines: [initResponse, longerWindow])), now: { epoch }).read()
        check(longerWindowUsage.status == .protocolError && longerWindowUsage.remainingPercentage == nil, "reader never labels a non-seven-day long window as 7D", failures: &failures)
        var invalidUTF8 = AppServerFrameBuffer()
        try? invalidUTF8.append(Data([0xFF, 0x0A]))
        let invalidUTF8Result = Result { try invalidUTF8.nextLine() }
        if case .failure = invalidUTF8Result { check(true, "frame buffer rejects invalid UTF-8", failures: &failures) }
        else { check(false, "frame buffer rejects invalid UTF-8", failures: &failures) }
        exit(Int32(failures))
    }
}
