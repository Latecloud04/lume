import Foundation

public enum UsageText {
    public static func window(_ window: UsageWindowState, label: String, now: Date, detail: Bool = false, timeZone: TimeZone = .current) -> String {
        let percentage = window.visiblePercentage(at: now).map { "\($0)%" } ?? "--"
        var parts = ["\(label) 剩余：\(percentage)"]
        if window.isStale(at: now) { parts.append("缓存") }
        if let reset = window.resetsAt {
            if reset <= now {
                parts.append("重置时间已到，等待刷新")
            } else if label == "5H" && !detail {
                let minutes = Int(ceil(reset.timeIntervalSince(now) / 60))
                parts.append(minutes >= 60 ? "约 \(minutes / 60) 小时 \(minutes % 60) 分钟后重置" : "约 \(minutes) 分钟后重置")
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "zh_CN")
                formatter.timeZone = timeZone
                formatter.dateFormat = detail ? "yyyy-MM-dd HH:mm z" : "M月d日 EEEE HH:mm"
                parts.append("\(formatter.string(from: reset)) 重置")
            }
        }
        if let date = window.lastSuccessfulAt {
            let age = max(0, Int(now.timeIntervalSince(date)))
            let relative = age < 60 ? "\(age) 秒" : "\(age / 60) 分钟"
            parts.append("上次成功读取：\(relative)前")
        } else {
            parts.append("尚未成功读取")
        }
        return parts.joined(separator: " · ")
    }

    public static func status(_ status: UsageReadStatus) -> String {
        switch status {
        case .success: return "额度读取成功"
        case .throttled: return "等待下次刷新"
        case .executableNotFound: return "未找到 Codex，请安装后刷新"
        case .timedOut: return "读取超时，可点“刷新额度”重试"
        case .protocolError: return "当前 Codex 额度不可识别，可更新 Lume 后重试"
        case .cancelled: return "读取已取消，可重新刷新"
        default: return "额度读取失败，请检查 Codex 登录状态后刷新"
        }
    }

    public static func tooltip(state: LumeState, now: Date) -> String {
        [window(state.fiveHour, label: "5H", now: now, detail: true),
         window(state.sevenDay, label: "7D", now: now, detail: true),
         status(state.latestReadStatus)].joined(separator: "\n")
    }
}

public enum LumeMenuAction: Sendable { case info, openCodex, togglePanel, refresh, launchAtLogin, about, quit }
public struct LumeMenuItem: Sendable {
    public let title: String
    public let action: LumeMenuAction
    public init(_ title: String, action: LumeMenuAction = .info) { self.title = title; self.action = action }
}
public struct LumeMenuPresentation: Sendable {
    public let items: [LumeMenuItem]
    public init(state: LumeState, panelVisible: Bool, now: Date, warning: String? = nil) {
        items = [
            LumeMenuItem(UsageText.window(state.fiveHour, label: "5H", now: now)),
            LumeMenuItem(UsageText.window(state.sevenDay, label: "7D", now: now)),
            LumeMenuItem(warning ?? UsageText.status(state.latestReadStatus)),
            LumeMenuItem("打开 Codex", action: .openCodex),
            LumeMenuItem(panelVisible ? "隐藏额度浮窗" : "显示额度浮窗", action: .togglePanel),
            LumeMenuItem("刷新额度", action: .refresh),
            LumeMenuItem("登录时启动", action: .launchAtLogin),
            LumeMenuItem("关于 Lume", action: .about),
            LumeMenuItem("退出 Lume", action: .quit),
        ]
    }
}
