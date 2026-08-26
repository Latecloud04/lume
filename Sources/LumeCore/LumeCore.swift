import AppKit
import Darwin
import Foundation
import ServiceManagement

public enum LumeColor: String, Codable, Sendable {
    case mint, orange, red, gray

    public static func forRemaining(_ percentage: Int?) -> LumeColor {
        guard let percentage else { return .gray }
        switch percentage {
        case 50...100: return .mint
        case 20...49: return .orange
        case 0...19: return .red
        default: return .gray
        }
    }
}

public enum LumePresentation: String, Codable, Sendable { case ring, rail }
public enum DockSide: String, Codable, Sendable { case left, right }
public enum PanelVisual: Equatable, Sendable {
    case ring
    case rail(DockSide)

    public static func resolved(presentation: LumePresentation, dockSide: DockSide?) -> PanelVisual {
        guard presentation == .rail, let dockSide else { return .ring }
        return .rail(dockSide)
    }
}
public enum UsagePresentationState: Equatable, Sendable { case fresh(Int), stale(Int), unavailable }
public struct LumeDisplay: Equatable, Sendable {
    public let identifier: String
    public let visibleFrame: CGRect
    public init(identifier: String, visibleFrame: CGRect) { self.identifier = identifier; self.visibleFrame = visibleFrame }
}

public struct PanelPlacement: Codable, Equatable, Sendable {
    public var originX: Double
    public var originY: Double
    public var displayIdentifier: String?
    public init(origin: CGPoint, displayIdentifier: String?) {
        originX = origin.x; originY = origin.y; self.displayIdentifier = displayIdentifier
    }
    public static func ring(origin: CGPoint, displayIdentifier: String?) -> PanelPlacement { PanelPlacement(origin: origin, displayIdentifier: displayIdentifier) }
    public var origin: CGPoint { CGPoint(x: originX, y: originY) }
    public func migrated(to displays: [LumeDisplay], size: CGSize = PanelGeometry.ringHitSize) -> PanelPlacement {
        guard !displays.isEmpty else { return self }
        let selected = displays.first(where: { $0.identifier == displayIdentifier })
            ?? displays.min(by: { $0.visibleFrame.distance(to: origin) < $1.visibleFrame.distance(to: origin) })!
        var result = self; result.displayIdentifier = selected.identifier
        result.originX = PanelGeometry.clampedOrigin(origin, size: size, in: selected.visibleFrame).x
        result.originY = PanelGeometry.clampedOrigin(origin, size: size, in: selected.visibleFrame).y
        return result
    }
}
private extension CGRect {
    func distance(to point: CGPoint) -> CGFloat {
        let x = min(max(point.x, minX), maxX), y = min(max(point.y, minY), maxY)
        return hypot(point.x - x, point.y - y)
    }
}

public struct PanelGeometry: Equatable, Sendable {
    public static let ringHitSize = CGSize(width: 48, height: 48)
    public static let ringVisibleDiameter: CGFloat = 44
    public static let railHitSize = CGSize(width: 24, height: 64)
    public static let railVisibleSize = CGSize(width: 10, height: 54)
    public static let clickDistance: CGFloat = 3
    public static let dockPreviewDistance: CGFloat = 24
    public static let dockCommitDistance: CGFloat = 16
    public static let railUndockDistance: CGFloat = 40

    public static func isClick(from start: CGPoint, to end: CGPoint) -> Bool {
        hypot(end.x - start.x, end.y - start.y) < clickDistance
    }

    public static func draggedOrigin(
        from origin: CGPoint,
        pointerStart: CGPoint,
        pointerCurrent: CGPoint,
        didExceedThreshold: Bool = false
    ) -> CGPoint? {
        guard didExceedThreshold || !isClick(from: pointerStart, to: pointerCurrent) else { return nil }
        return CGPoint(
            x: origin.x + pointerCurrent.x - pointerStart.x,
            y: origin.y + pointerCurrent.y - pointerStart.y
        )
    }

    public static func initialRingOrigin(in visibleFrame: CGRect) -> CGPoint {
        CGPoint(
            x: visibleFrame.midX - ringHitSize.width / 2,
            y: visibleFrame.maxY - ringHitSize.height - 20
        )
    }

    public static func railOrigin(
        from origin: CGPoint,
        pointerStart: CGPoint,
        pointerCurrent: CGPoint,
        side: DockSide,
        in visibleFrame: CGRect
    ) -> CGPoint {
        let edgeX = side == .left ? visibleFrame.minX : visibleFrame.maxX - railHitSize.width
        let proposed = CGPoint(x: edgeX, y: origin.y + pointerCurrent.y - pointerStart.y)
        return clampedOrigin(proposed, size: railHitSize, in: visibleFrame)
    }

    public static func expandedRingOrigin(
        from railFrame: CGRect,
        side: DockSide,
        in visibleFrame: CGRect
    ) -> CGPoint {
        let edgeX = side == .left ? visibleFrame.minX : visibleFrame.maxX - ringHitSize.width
        let centered = CGPoint(x: edgeX, y: railFrame.midY - ringHitSize.height / 2)
        return clampedOrigin(centered, size: ringHitSize, in: visibleFrame)
    }

    public static func previewSide(at point: CGPoint, in screen: CGRect) -> DockSide? {
        if point.x - screen.minX <= dockPreviewDistance { return .left }
        if screen.maxX - point.x <= dockPreviewDistance { return .right }
        return nil
    }

    public static func committedSide(at point: CGPoint, in screen: CGRect) -> DockSide? {
        if point.x - screen.minX <= dockCommitDistance { return .left }
        if screen.maxX - point.x <= dockCommitDistance { return .right }
        return nil
    }
    public static func display(containing point: CGPoint, displays: [LumeDisplay]) -> LumeDisplay? {
        displays.first(where: { $0.visibleFrame.contains(point) }) ?? displays.min(by: { $0.visibleFrame.distance(to: point) < $1.visibleFrame.distance(to: point) })
    }
    public static func previewSide(at point: CGPoint, displays: [LumeDisplay]) -> DockSide? {
        display(containing: point, displays: displays).flatMap { previewSide(at: point, in: $0.visibleFrame) }
    }
    public static func committedSide(at point: CGPoint, displays: [LumeDisplay]) -> DockSide? {
        display(containing: point, displays: displays).flatMap { committedSide(at: point, in: $0.visibleFrame) }
    }
    public static func clampedOrigin(_ origin: CGPoint, size: CGSize, in visibleFrame: CGRect) -> CGPoint {
        CGPoint(x: min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - size.width), y: min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - size.height))
    }
}

public enum PanelTransition: Equatable, Sendable {
    case none
    case handoff
    case previewDock(DockSide)
    case dock(DockSide)
    case restoreRing

    public static func ringRelease(start: CGPoint, end: CGPoint, didDrag: Bool = false, screen: CGRect) -> PanelTransition {
        if !didDrag && PanelGeometry.isClick(from: start, to: end) { return .handoff }
        return PanelGeometry.committedSide(at: end, in: screen).map(PanelTransition.dock) ?? .none
    }

    public static func railRelease(inwardDrag: CGFloat) -> PanelTransition {
        inwardDrag >= PanelGeometry.railUndockDistance ? .restoreRing : .none
    }
    public static func railRelease(start: CGPoint, end: CGPoint, didDrag: Bool = false, side: DockSide) -> PanelTransition {
        if !didDrag && PanelGeometry.isClick(from: start, to: end) { return .restoreRing }
        let horizontal = end.x - start.x
        let inward = side == .left ? horizontal : -horizontal
        return inward >= PanelGeometry.railUndockDistance ? .restoreRing : .none
    }
}

public enum UsageReadStatus: String, Codable, Sendable { case success, executableNotFound, timedOut, cancelled, invalidJSON, protocolError, processExited, failed, throttled }
public enum UsageFailureCode: String, Codable, Sendable { case none, executableNotFound, timeout, cancelled, invalidJSON, frameTooLarge, serverError, resultMissing, initializeResultMissing, processExited, processStartFailed, processIO }

public struct UsageWindowSnapshot: Sendable, Equatable {
    public let remainingPercentageExact: Double
    public let resetsAt: Date?
    public var remainingPercentage: Int { Int(remainingPercentageExact.rounded()) }

    public init(remainingPercentageExact: Double, resetsAt: Date?) {
        self.remainingPercentageExact = min(100, max(0, remainingPercentageExact))
        self.resetsAt = resetsAt
    }
}

public struct UsageReadResult: Sendable, Equatable {
    public let status: UsageReadStatus
    public let fiveHour: UsageWindowSnapshot?
    public let sevenDay: UsageWindowSnapshot?
    public let observedAt: Date
    public let failureCode: UsageFailureCode
    public let duration: TimeInterval

    // Compatibility accessors keep integrations built against Lume 1.1 reading 7D.
    public var remainingPercentage: Int? { sevenDay?.remainingPercentage }
    public var remainingPercentageExact: Double? { sevenDay?.remainingPercentageExact }
    public var resetsAt: Date? { sevenDay?.resetsAt }

    public init(status: UsageReadStatus, fiveHour: UsageWindowSnapshot?, sevenDay: UsageWindowSnapshot?, observedAt: Date, failureCode: UsageFailureCode = .none, duration: TimeInterval = 0) {
        self.status = status
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.observedAt = observedAt
        self.failureCode = failureCode
        self.duration = duration
    }

    public init(status: UsageReadStatus, remainingPercentage: Int?, remainingPercentageExact: Double? = nil, resetsAt: Date? = nil, observedAt: Date, failureCode: UsageFailureCode = .none, duration: TimeInterval = 0) {
        self.status = status
        fiveHour = nil
        sevenDay = (remainingPercentageExact ?? remainingPercentage.map(Double.init)).map {
            UsageWindowSnapshot(remainingPercentageExact: $0, resetsAt: resetsAt)
        }
        self.observedAt = observedAt
        self.failureCode = failureCode
        self.duration = duration
    }
}

public protocol UsageReader: Sendable { func read() async -> UsageReadResult }

public struct UsageWindowState: Codable, Equatable, Sendable {
    public var remainingPercentageExact: Double?
    public var resetsAt: Date?
    public var lastSuccessfulAt: Date?
    public var lastStatus: UsageReadStatus

    public init(remainingPercentageExact: Double? = nil, resetsAt: Date? = nil, lastSuccessfulAt: Date? = nil, lastStatus: UsageReadStatus = .failed) {
        self.remainingPercentageExact = remainingPercentageExact
        self.resetsAt = resetsAt
        self.lastSuccessfulAt = lastSuccessfulAt
        self.lastStatus = lastStatus
    }

    public var remainingPercentage: Int? { remainingPercentageExact.map { Int($0.rounded()) } }
    public var displayValue: String { remainingPercentage.map(String.init) ?? "--" }
    public func presentationState(at now: Date) -> UsagePresentationState {
        guard let remainingPercentage, let lastSuccessfulAt, now.timeIntervalSince(lastSuccessfulAt) <= LumeState.staleAfter else { return .unavailable }
        return lastStatus == .success ? .fresh(remainingPercentage) : .stale(remainingPercentage)
    }
    public func isStale(at now: Date) -> Bool { if case .stale = presentationState(at: now) { return true }; return false }
    public func visiblePercentage(at now: Date) -> Int? { switch presentationState(at: now) { case .fresh(let value), .stale(let value): return value; case .unavailable: return nil } }
    public func visiblePercentageExact(at now: Date) -> Double? { visiblePercentage(at: now) == nil ? nil : remainingPercentageExact }
    public func color(at now: Date) -> LumeColor { LumeColor.forRemaining(visiblePercentage(at: now)) }

    mutating func apply(_ snapshot: UsageWindowSnapshot?, status: UsageReadStatus, observedAt: Date) {
        lastStatus = snapshot == nil && status == .success ? .protocolError : status
        guard status == .success, let snapshot else { return }
        remainingPercentageExact = snapshot.remainingPercentageExact
        resetsAt = snapshot.resetsAt
        lastSuccessfulAt = observedAt
    }
}

public struct LumeState: Codable, Equatable, Sendable {
    public static let staleAfter: TimeInterval = 15 * 60
    public var fiveHour: UsageWindowState
    public var sevenDay: UsageWindowState
    public var presentation: LumePresentation

    public static func empty(now _: Date) -> LumeState { LumeState(fiveHour: UsageWindowState(), sevenDay: UsageWindowState(), presentation: .ring) }

    public init(fiveHour: UsageWindowState, sevenDay: UsageWindowState, presentation: LumePresentation = .ring) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.presentation = presentation
    }

    public init(remainingPercentage: Int?, lastSuccessfulAt: Date?, lastStatus: UsageReadStatus, presentation: LumePresentation = .ring) {
        fiveHour = UsageWindowState()
        sevenDay = UsageWindowState(remainingPercentageExact: remainingPercentage.map(Double.init), lastSuccessfulAt: lastSuccessfulAt, lastStatus: lastStatus)
        self.presentation = presentation
    }

    // Compatibility accessors represent the historical 7D surface.
    public var remainingPercentage: Int? { sevenDay.remainingPercentage }
    public var lastSuccessfulAt: Date? { [fiveHour.lastSuccessfulAt, sevenDay.lastSuccessfulAt].compactMap { $0 }.max() }
    public var lastStatus: UsageReadStatus { sevenDay.lastStatus }
    public var displayValue: String { sevenDay.displayValue }
    public func presentationState(at now: Date) -> UsagePresentationState { sevenDay.presentationState(at: now) }
    public func isStale(at now: Date) -> Bool { sevenDay.isStale(at: now) }
    public func visiblePercentage(at now: Date) -> Int? { sevenDay.visiblePercentage(at: now) }
    public func color(at now: Date) -> LumeColor { sevenDay.color(at: now) }

    private enum CodingKeys: String, CodingKey {
        case fiveHour, sevenDay, presentation
        case remainingPercentage, lastSuccessfulAt, lastStatus
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        presentation = try values.decodeIfPresent(LumePresentation.self, forKey: .presentation) ?? .ring
        fiveHour = try values.decodeIfPresent(UsageWindowState.self, forKey: .fiveHour) ?? UsageWindowState()
        if let current = try values.decodeIfPresent(UsageWindowState.self, forKey: .sevenDay) {
            sevenDay = current
        } else {
            let remaining = try values.decodeIfPresent(Int.self, forKey: .remainingPercentage)
            let successfulAt = try values.decodeIfPresent(Date.self, forKey: .lastSuccessfulAt)
            let status = try values.decodeIfPresent(UsageReadStatus.self, forKey: .lastStatus) ?? .failed
            sevenDay = UsageWindowState(remainingPercentageExact: remaining.map(Double.init), lastSuccessfulAt: successfulAt, lastStatus: status)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(fiveHour, forKey: .fiveHour)
        try values.encode(sevenDay, forKey: .sevenDay)
        try values.encode(presentation, forKey: .presentation)
    }

    public mutating func apply(_ result: UsageReadResult) {
        fiveHour.apply(result.fiveHour, status: result.status, observedAt: result.observedAt)
        sevenDay.apply(result.sevenDay, status: result.status, observedAt: result.observedAt)
    }
}

public enum RefreshReason: Sendable { case launch, manual, wake, unlock, timer }

public actor UsageRefreshCoordinator {
    public static let minimumInterval: TimeInterval = 60
    private let reader: any UsageReader
    private var lastAttemptAt: Date?

    public init(reader: any UsageReader) { self.reader = reader }

    public func refresh(now: Date, reason _: RefreshReason) async -> UsageReadResult {
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < Self.minimumInterval {
            return UsageReadResult(status: .throttled, remainingPercentage: nil, observedAt: lastAttemptAt)
        }
        lastAttemptAt = now
        return await reader.read()
    }
}

public struct LumePreferences: Codable, Equatable, Sendable {
    public var state: LumeState
    public var panelOriginX: Double
    public var panelOriginY: Double
    public var screenIdentifier: String?
    public var dockSide: DockSide?
    public var isPanelVisible: Bool
    public var launchAtLogin: Bool

    public init(state: LumeState, panelOrigin: CGPoint = .zero, screenIdentifier: String? = nil, dockSide: DockSide? = nil, isPanelVisible: Bool = true, launchAtLogin: Bool = false) {
        self.state = state; panelOriginX = panelOrigin.x; panelOriginY = panelOrigin.y; self.screenIdentifier = screenIdentifier; self.dockSide = dockSide; self.isPanelVisible = isPanelVisible; self.launchAtLogin = launchAtLogin
    }
}

public struct LumeMenuItem: Equatable, Sendable { public let title: String; public init(_ title: String) { self.title = title } }
public struct LumeMenuPresentation: Sendable {
    public let items: [LumeMenuItem]
    public init(state: LumeState, panelVisible: Bool, refreshStatus: UsageReadStatus, launchAtLogin _: Bool, lastUpdateAt: Date? = nil, now: Date) {
        let status: String
        switch refreshStatus {
        case .success: status = lastUpdateAt.map { "更新于 \(Self.relativeAge(now.timeIntervalSince($0)))" } ?? "额度已更新"
        case .throttled: status = lastUpdateAt.map { "更新于 \(Self.relativeAge(now.timeIntervalSince($0)))" } ?? "等待刷新"
        case .executableNotFound: status = "Codex 不可用"
        case .timedOut: status = "额度读取超时"
        default: status = "额度暂不可用"
        }
        items = [
            LumeMenuItem(Self.usageTitle(label: "5H", window: state.fiveHour, now: now)),
            LumeMenuItem(Self.usageTitle(label: "7D", window: state.sevenDay, now: now)),
            LumeMenuItem(status),
            LumeMenuItem("打开 Codex"),
            LumeMenuItem(panelVisible ? "隐藏额度浮窗" : "显示额度浮窗"),
            LumeMenuItem("刷新额度"),
            LumeMenuItem("登录时启动"),
            LumeMenuItem("Sol Control"),
            LumeMenuItem("关于 Lume"),
            LumeMenuItem("退出 Lume"),
        ]
    }

    private static func usageTitle(label: String, window: UsageWindowState, now: Date) -> String {
        guard let exact = window.visiblePercentageExact(at: now) else { return "\(label) 额度：--" }
        let percentage = exact.rounded() == exact ? String(Int(exact)) : String(format: "%.1f", exact)
        guard let reset = window.resetsAt else { return "\(label) 额度：\(percentage)%" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return "\(label) 额度：\(percentage)% · 重置于 \(formatter.string(from: reset))"
    }

    private static func relativeAge(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        if seconds < 60 { return "\(seconds) 秒前" }
        return "\(seconds / 60) 分钟前"
    }
}

public protocol AppServerTransport: Sendable {
    func send(_ line: String) async throws
    func receive() async throws -> String?
    func terminate() async
}
public protocol AppServerTransportFactory: Sendable { func start() async throws -> any AppServerTransport }
public enum AppServerTransportError: Error { case io, invalidUTF8, cancelled }
public enum AppServerStartError: Error { case executableNotFound, permissionDenied, launchFailed }

public struct AppServerFrameBuffer: Sendable {
    public static let maximumFrameBytes = 1_048_576
    public static let maximumBufferedBytes = maximumFrameBytes + 1
    private var bytes = Data()
    public init() {}
    public mutating func append(_ data: Data) throws {
        guard data.count <= Self.maximumBufferedBytes,
              bytes.count <= Self.maximumBufferedBytes - data.count
        else { throw AppServerFrameError.tooLarge }
        bytes.append(data)
        if let newline = bytes.firstIndex(of: 10), newline > Self.maximumFrameBytes { throw AppServerFrameError.tooLarge }
        if bytes.firstIndex(of: 10) == nil && bytes.count > Self.maximumFrameBytes { throw AppServerFrameError.tooLarge }
    }
    public mutating func nextLine() throws -> String? {
        guard let newline = bytes.firstIndex(of: 10) else { return nil }
        let frame = bytes.prefix(upTo: newline); bytes.removeSubrange(...newline)
        let normalized = frame.last == 13 ? frame.dropLast() : frame[...]
        guard normalized.count <= Self.maximumFrameBytes else { throw AppServerFrameError.tooLarge }
        guard let line = String(data: Data(normalized), encoding: .utf8) else {
            throw AppServerTransportError.invalidUTF8
        }
        return line
    }
}
public enum AppServerFrameError: Error { case tooLarge }

public struct CodexAppServerUsageReader: UsageReader {
    private let factory: any AppServerTransportFactory
    private let now: @Sendable () -> Date
    private let timeout: TimeInterval
    public init(factory: any AppServerTransportFactory, now: @escaping @Sendable () -> Date = { Date() }, timeout: TimeInterval = 10) { self.factory = factory; self.now = now; self.timeout = timeout }

    public func read() async -> UsageReadResult {
        let started = now()
        do {
            let transport = try await factory.start()
            let result = await read(using: transport, started: started, deadline: started.addingTimeInterval(timeout))
            await transport.terminate()
            return result
        } catch let error as AppServerStartError {
            switch error {
            case .executableNotFound: return failed(.executableNotFound, .executableNotFound, started)
            case .permissionDenied, .launchFailed: return failed(.failed, .processStartFailed, started)
            }
        } catch is CancellationError { return failed(.cancelled, .cancelled, started) }
        catch is UsageReaderTimeout { return failed(.timedOut, .timeout, started) }
        catch is AppServerFrameError { return failed(.invalidJSON, .frameTooLarge, started) }
        catch { return failed(.failed, .processStartFailed, started) }
    }

    private func read(using transport: any AppServerTransport, started: Date, deadline: Date) async -> UsageReadResult {
        do {
            try await transport.send("{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"lume\",\"title\":\"Lume\",\"version\":\"1.0\"}}}")
            let initialize = try await response(id: 1, from: transport, deadline: deadline)
            guard case .message(let initializeMessage) = initialize, isValidInitialize(initializeMessage) else { return failure(for: initialize, initialize: true, started: started) }
            try await transport.send("{\"method\":\"initialized\"}")
            try await transport.send("{\"id\":2,\"method\":\"account/rateLimits/read\",\"params\":null}")
            let usage = try await response(id: 2, from: transport, deadline: deadline)
            guard case .message(let usageMessage) = usage else { return failure(for: usage, initialize: false, started: started) }
            let windows = normalizeWindows(usageMessage)
            guard windows.fiveHour != nil || windows.sevenDay != nil else { return failed(.protocolError, .resultMissing, started) }
            return UsageReadResult(
                status: .success,
                fiveHour: windows.fiveHour,
                sevenDay: windows.sevenDay,
                observedAt: started,
                duration: now().timeIntervalSince(started))
        } catch is UsageReaderTimeout { return failed(.timedOut, .timeout, started) }
        catch is CancellationError { return failed(.cancelled, .cancelled, started) }
        catch is AppServerFrameError { return failed(.invalidJSON, .frameTooLarge, started) }
        catch is AppServerTransportError { return failed(.failed, .processIO, started) }
        catch { return failed(.invalidJSON, .invalidJSON, started) }
    }

    private func failed(_ status: UsageReadStatus, _ code: UsageFailureCode, _ started: Date) -> UsageReadResult { UsageReadResult(status: status, remainingPercentage: nil, observedAt: started, failureCode: code, duration: now().timeIntervalSince(started)) }

    private enum Response { case message([String: Any]), serverError, processExited }
    private func response(id: Int, from transport: any AppServerTransport, deadline: Date) async throws -> Response {
        while let line = try await receiveBefore(deadline: deadline, from: transport) {
            guard line.utf8.count <= AppServerFrameBuffer.maximumFrameBytes else { throw AppServerFrameError.tooLarge }
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { throw UsageInvalidJSON() }
            if let actual = object["id"] as? Int, actual == id { return object["error"] == nil ? .message(object) : .serverError }
            if let actual = object["id"] as? String, actual == String(id) { return object["error"] == nil ? .message(object) : .serverError }
        }
        return .processExited
    }

    private func receiveBefore(deadline: Date, from transport: any AppServerTransport) async throws -> String? {
        let interval = deadline.timeIntervalSince(now())
        guard interval > 0 else { throw UsageReaderTimeout() }
        let race = ReceiveRace()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                Task {
                    do { race.complete(.success(try await transport.receive())) }
                    catch { race.complete(.failure(error)) }
                }
                Task {
                    do {
                        try await Task.sleep(for: .seconds(interval))
                        race.complete(.failure(UsageReaderTimeout()))
                    } catch {
                        // The task may be cancelled after another branch wins.
                    }
                }
            }
        } onCancel: {
            race.complete(.failure(CancellationError()))
        }
    }

    private func failure(for response: Response, initialize: Bool, started: Date) -> UsageReadResult {
        switch response {
        case .serverError: return failed(.protocolError, .serverError, started)
        case .processExited: return failed(.processExited, .processExited, started)
        case .message: return failed(.protocolError, initialize ? .initializeResultMissing : .resultMissing, started)
        }
    }

    private func isValidInitialize(_ value: [String: Any]) -> Bool {
        guard let result = value["result"] as? [String: Any] else { return false }
        return ["codexHome", "platformFamily", "platformOs", "userAgent"].allSatisfy { (result[$0] as? String)?.isEmpty == false }
    }

    private func normalizeWindows(_ value: Any) -> (fiveHour: UsageWindowSnapshot?, sevenDay: UsageWindowSnapshot?) {
        guard let response = value as? [String: Any], let result = response["result"] as? [String: Any] else { return (nil, nil) }
        var candidates = [[String: Any]]()
        if let direct = result["rateLimits"] as? [String: Any] { candidates.append(direct) }
        if let buckets = result["rateLimitsByLimitId"] as? [String: Any] {
            let orderedKeys = buckets.keys.sorted { lhs, rhs in
                if lhs == "codex" { return true }
                if rhs == "codex" { return false }
                return lhs < rhs
            }
            candidates.append(contentsOf: orderedKeys.compactMap { buckets[$0] as? [String: Any] })
        }
        if candidates.isEmpty { candidates.append(result) }
        let windows = candidates.flatMap { limits in ["primary", "secondary"].compactMap { name -> (duration: Int, remaining: Double, resetsAt: Date?)? in
            guard let window = limits[name] as? [String: Any],
                  let used = finiteNumber(window["usedPercent"]),
                  (0...100).contains(used) else { return nil }
            let duration = finiteNumber(window["windowDurationMins"]).flatMap {
                $0 > 0 && $0 <= Double(Int.max) && $0.rounded() == $0 ? Int($0) : nil
            } ?? 0
            let reset = finiteNumber(window["resetsAt"]).flatMap { value in
                value >= 0 ? Date(timeIntervalSince1970: value) : nil
            }
            return (duration, 100 - used, reset)
        } }
        func snapshot(duration: Int) -> UsageWindowSnapshot? {
            windows.first(where: { $0.duration == duration }).map {
                UsageWindowSnapshot(remainingPercentageExact: $0.remaining, resetsAt: $0.resetsAt)
            }
        }
        return (snapshot(duration: 300), snapshot(duration: 10_080))
    }
    private func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }
}

public protocol CodexApplicationControlling: Sendable {
    func isFrontmost(bundleIdentifier: String) -> Bool
    func isRunning(bundleIdentifier: String) -> Bool
    func activateRunning(bundleIdentifier: String) async -> Bool
    func launchConfirmed(bundleIdentifier: String) async -> Bool
}

public struct CodexHandoff: Sendable {
    public static let bundleIdentifier = "com.openai.codex"
    private let controller: any CodexApplicationControlling
    public init(controller: any CodexApplicationControlling = WorkspaceCodexApplicationController()) {
        self.controller = controller
    }

    public func perform() async -> HandoffResult {
        let wasFrontmost = controller.isFrontmost(bundleIdentifier: Self.bundleIdentifier)
        if controller.isRunning(bundleIdentifier: Self.bundleIdentifier) {
            guard await controller.activateRunning(bundleIdentifier: Self.bundleIdentifier) else { return .failed }
            return wasFrontmost ? .alreadyFrontmost : .activated
        }
        return await controller.launchConfirmed(bundleIdentifier: Self.bundleIdentifier) ? .launched : .unavailable
    }
}

public final class ProcessAppServerTransportFactory: @unchecked Sendable, AppServerTransportFactory {
    public init(executableURL: URL) { self.executableURL = executableURL }
    private let executableURL: URL
    public func start() async throws -> any AppServerTransport {
        guard FileManager.default.fileExists(atPath: executableURL.path) else { throw AppServerStartError.executableNotFound }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { throw AppServerStartError.permissionDenied }
        let process = Process(); process.executableURL = executableURL; process.arguments = ["app-server", "--stdio"]
        let input = Pipe(); let output = Pipe(); process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw AppServerStartError.launchFailed }
        return ProcessAppServerTransport(process: process, input: input.fileHandleForWriting, output: output.fileHandleForReading)
    }
}

private final class ProcessAppServerTransport: @unchecked Sendable, AppServerTransport {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let lines = AsyncLineQueue()
    private let lifecycleLock = NSLock()
    private var terminated = false

    init(process: Process, input: FileHandle, output: FileHandle) {
        self.process = process
        self.input = input
        self.output = output
        output.readabilityHandler = { [weak lines] handle in
            let data = handle.availableData
            if data.isEmpty { lines?.finish() }
            else { lines?.append(data) }
        }
    }

    func send(_ line: String) async throws {
        do { try input.write(contentsOf: Data((line + "\n").utf8)) }
        catch { throw AppServerTransportError.io }
    }

    func receive() async throws -> String? { try await lines.next() }

    func terminate() async {
        let shouldTerminate = lifecycleLock.withLock {
            guard !terminated else { return false }
            terminated = true
            return true
        }
        guard shouldTerminate else { return }

        output.readabilityHandler = nil
        try? input.close()
        lines.finish(error: AppServerTransportError.cancelled)
        if process.isRunning { process.terminate() }
        for _ in 0..<20 where process.isRunning { try? await Task.sleep(for: .milliseconds(25)) }
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        for _ in 0..<40 where process.isRunning { try? await Task.sleep(for: .milliseconds(25)) }
        try? output.close()
    }
}

public protocol CodexExecutableLocating: Sendable { func locate() -> URL? }
public struct SystemCodexExecutableLocator: @unchecked Sendable, CodexExecutableLocating {
    private let environment: [String: String]
    private let homeDirectory: URL
    private let applicationResources: URL?
    private let isExecutable: @Sendable (String) -> Bool

    public init() {
        environment = ProcessInfo.processInfo.environment
        homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        applicationResources = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: CodexHandoff.bundleIdentifier)
            .flatMap { Bundle(url: $0)?.resourceURL }
        isExecutable = { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public init(
        environment: [String: String],
        homeDirectory: URL,
        applicationResources: URL?,
        isExecutable: @escaping @Sendable (String) -> Bool
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.applicationResources = applicationResources
        self.isExecutable = isExecutable
    }

    public func locate() -> URL? {
        let bundledCandidates = applicationResources.map {
            [$0.appendingPathComponent("codex"), $0.appendingPathComponent("bin/codex")]
        } ?? []
        let pathEntries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let homeLocalBin = homeDirectory.appendingPathComponent(".local/bin/codex")
        let commandLineCandidates = pathEntries.map { URL(fileURLWithPath: $0).appendingPathComponent("codex") } +
            [homeLocalBin, URL(fileURLWithPath: "/opt/homebrew/bin/codex"), URL(fileURLWithPath: "/usr/local/bin/codex")]
        return (bundledCandidates + commandLineCandidates).first(where: { isExecutable($0.path) })
    }
}

public struct DiscoveredCodexUsageReader: UsageReader {
    private let locator: any CodexExecutableLocating
    private let now: @Sendable () -> Date
    public init(locator: any CodexExecutableLocating = SystemCodexExecutableLocator(), now: @escaping @Sendable () -> Date = { Date() }) { self.locator = locator; self.now = now }
    public func read() async -> UsageReadResult {
        guard let executable = locator.locate() else {
            return UsageReadResult(status: .executableNotFound, remainingPercentage: nil, observedAt: now(), failureCode: .executableNotFound)
        }
        return await CodexAppServerUsageReader(factory: ProcessAppServerTransportFactory(executableURL: executable), now: now).read()
    }
}

public final class LumePreferencesStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "Lume.preferences.v1"
    private let geometryVersionKey = "Lume.panelGeometry.v2"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load(now: Date) -> LumePreferences {
        guard let data = defaults.data(forKey: key), var preferences = try? JSONDecoder().decode(LumePreferences.self, from: data) else {
            return LumePreferences(state: .empty(now: now))
        }
        if !defaults.bool(forKey: geometryVersionKey) {
            if preferences.state.presentation == .ring {
                preferences.panelOriginX -= 4
                preferences.panelOriginY -= 4
            } else {
                preferences.panelOriginY -= 2
            }
            defaults.set(true, forKey: geometryVersionKey)
        }
        return preferences
    }
    public func save(_ preferences: LumePreferences) {
        defaults.set(try? JSONEncoder().encode(preferences), forKey: key)
        defaults.set(true, forKey: geometryVersionKey)
    }
}

public enum SolControlConfiguredMode: String, Codable, CaseIterable, Sendable {
    case auto, openai
    case quotaSave = "quota-save"
}

public struct SolControlResolution: Codable, Equatable, Sendable {
    public let mode: String
    public let configuredMode: String
    public let source: String
    public let remainingPercentage: Double?
    public let signalStatus: String
    public let reason: String
}

public struct SolControlDoctor: Codable, Equatable, Sendable {
    public let available: Bool
    public let checks: [String: Bool]
    public let resolution: SolControlResolution
}

public struct SolControlBridge: Sendable {
    public let helperURL: URL
    public let installerURL: URL

    public init(helperURL: URL, installerURL: URL) {
        self.helperURL = helperURL
        self.installerURL = installerURL
    }

    public static func bundled(resourceURL: URL?) -> SolControlBridge? {
        guard let directory = resourceURL?.appendingPathComponent("SolControlIntegration", isDirectory: true) else { return nil }
        let helper = directory.appendingPathComponent("lume_policy.py")
        let installer = directory.appendingPathComponent("install.sh")
        guard FileManager.default.isReadableFile(atPath: helper.path),
              FileManager.default.isReadableFile(atPath: installer.path)
        else { return nil }
        return SolControlBridge(helperURL: helper, installerURL: installer)
    }

    public func publish(_ result: UsageReadResult) async -> SolControlResolution? {
        guard result.status == .success, let exact = result.remainingPercentageExact else { return await resolve() }
        var arguments = [
            helperURL.path, "publish",
            "--remaining", String(exact),
            "--observed-at", String(result.observedAt.timeIntervalSince1970),
        ]
        if let resetsAt = result.resetsAt {
            arguments += ["--resets-at", String(resetsAt.timeIntervalSince1970)]
        }
        guard await run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: arguments) != nil else { return nil }
        return await resolve()
    }

    public func resolve() async -> SolControlResolution? {
        guard let data = await run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [helperURL.path, "resolve"]) else { return nil }
        return try? JSONDecoder().decode(SolControlResolution.self, from: data)
    }

    public func doctor() async -> SolControlDoctor? {
        guard let data = await run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [helperURL.path, "doctor"]) else { return nil }
        return try? JSONDecoder().decode(SolControlDoctor.self, from: data)
    }

    public func setMode(_ mode: SolControlConfiguredMode) async -> SolControlResolution? {
        guard await run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [helperURL.path, "set-mode", mode.rawValue]) != nil else { return nil }
        return await resolve()
    }

    public func install() async -> Bool {
        await run(executable: URL(fileURLWithPath: "/bin/bash"), arguments: [installerURL.path]) != nil
    }

    private func run(executable: URL, arguments: [String]) async -> Data? {
        await Task.detached(priority: .utility) {
            Self.runSynchronously(executable: executable, arguments: arguments)
        }.value
    }

    private static func runSynchronously(executable: URL, arguments: [String]) -> Data? {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        do {
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            try process.run()
            guard finished.wait(timeout: .now() + 3) == .success else {
                process.terminate()
                _ = finished.wait(timeout: .now() + 1)
                return nil
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            _ = error.fileHandleForReading.readDataToEndOfFile()
            return process.terminationStatus == 0 && data.count <= 4096 ? data : nil
        } catch {
            return nil
        }
    }
}

public enum HandoffResult: Equatable, Sendable { case alreadyFrontmost, activated, launched, unavailable, failed }
public final class WorkspaceCodexApplicationController: @unchecked Sendable, CodexApplicationControlling {
    public init() {}
    public func isFrontmost(bundleIdentifier: String) -> Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier }
    public func isRunning(bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }
    public func activateRunning(bundleIdentifier: String) async -> Bool {
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else { return false }
        if application.isHidden { application.unhide() }
        _ = application.activate(options: [.activateAllWindows])
        return await requestForeground(bundleIdentifier: bundleIdentifier)
    }
    public func launchConfirmed(bundleIdentifier: String) async -> Bool {
        await requestForeground(bundleIdentifier: bundleIdentifier)
    }

    private func requestForeground(bundleIdentifier: String) async -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
                continuation.resume(returning: application != nil && error == nil)
            }
        }
    }
}

public protocol LaunchAtLoginProviding: Sendable { var isEnabled: Bool { get }; func setEnabled(_ enabled: Bool) throws }
public enum LaunchAtLoginError: Error { case registrationFailed }
public final class SystemLaunchAtLoginProvider: @unchecked Sendable, LaunchAtLoginProviding {
    public init() {}
    public var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    public func setEnabled(_ enabled: Bool) throws {
        do { enabled ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
        catch { throw LaunchAtLoginError.registrationFailed }
    }
}

private struct UsageReaderTimeout: Error {}
private struct UsageInvalidJSON: Error {}
private final class ReceiveRace: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var continuation: CheckedContinuation<String?, Error>?

    func install(_ continuation: CheckedContinuation<String?, Error>) {
        lock.lock()
        if completed { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        lock.unlock()
    }

    func complete(_ result: Result<String?, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class AsyncLineQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var frameBuffer = AppServerFrameBuffer()
    private var waiter: LineWaiter?
    private var finished = false
    private var terminalResult: Result<String?, Error> = .success(nil)

    func append(_ data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        do {
            try frameBuffer.append(data)
            if let waiter, let line = try frameBuffer.nextLine() {
                self.waiter = nil
                waiter.complete(.success(line))
            }
            lock.unlock()
        } catch {
            finishLocked(error: error)
            lock.unlock()
        }
    }

    func next() async throws -> String? {
        let waiter = LineWaiter()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                lock.lock()
                do {
                    if let line = try frameBuffer.nextLine() {
                        lock.unlock()
                        waiter.complete(.success(line))
                    } else if finished {
                        let result = terminalResult
                        lock.unlock()
                        waiter.complete(result)
                    } else if self.waiter != nil {
                        lock.unlock()
                        waiter.complete(.failure(AppServerTransportError.io))
                    } else {
                        self.waiter = waiter
                        lock.unlock()
                    }
                } catch {
                    finishLocked(error: error)
                    lock.unlock()
                    waiter.complete(.failure(error))
                }
            }
        } onCancel: {
            lock.lock()
            if self.waiter === waiter { self.waiter = nil }
            lock.unlock()
            waiter.complete(.failure(CancellationError()))
        }
    }

    func finish(error: Error? = nil) {
        lock.lock()
        finishLocked(error: error)
        lock.unlock()
    }

    private func finishLocked(error: Error?) {
        guard !finished else { return }
        finished = true
        terminalResult = error.map(Result.failure) ?? .success(nil)
        waiter?.complete(terminalResult)
        waiter = nil
    }
}

private final class LineWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Error>?
    private var result: Result<String?, Error>?

    func install(_ continuation: CheckedContinuation<String?, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func complete(_ result: Result<String?, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

public enum LumeLog {
    public static func record(_ result: UsageReadResult) { NSLog("Lume usage status=%@ code=%@ durationMs=%d", result.status.rawValue, result.failureCode.rawValue, Int(result.duration * 1_000)) }
}
