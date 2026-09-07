# Lume

Lume 是一个轻量的 macOS Codex 额度伴侣。它常驻菜单栏，不显示在 Dock，并通过可拖动的浮窗同时显示 Codex 5H 与 7D 剩余额度。

## 功能

- 默认显示 44pt 双额度圆环：外环为 5H、内环为 7D，中心数字为 5H。
- 圆环拖近屏幕左右边缘时吸附为双额度竖条，内容侧宽条为 5H、屏幕侧细条为 7D。
- 竖条可沿屏幕边缘上下拖动，单击后在当前位置向屏幕内展开为圆环。
- 单击圆环可将 Codex 窗口带到前台。
- 菜单栏提供额度刷新、浮窗显示、登录启动和退出操作。
- 每个额度窗口独立显示上次成功读取时间；缓存以低透明度显示，重置时间到达或超过十五分钟后显示不可用。
- 5H 显示重置倒计时，7D 显示日期与时间；悬停查看完整时间与读取状态。
- 根据 Codex 活动调整刷新频率：使用时约一分钟，后台闲置五分钟，退出后十五分钟。连续失败时逐步延长重试间隔，手动刷新冷却十秒。

## 系统要求

- macOS 14 或更高版本
- Apple Silicon
- 已安装 Codex Desktop
- Xcode Command Line Tools 或 Swift 5.10+

## 构建与测试

```bash
swift run LumeTests
swift build -c release
tests/packaging/test-lume-verifier.sh
scripts/build-lume.sh
```

构建产物位于 `artifacts/lume/`：

- `Lume.app`
- `Lume.dmg`

## 额度来源

Lume 从 Codex app-server 读取 Codex 额度桶内的 5H 与 7D 窗口，并兼容旧版单桶响应。无法确认额度归属时显示读取状态，保留有明确新鲜度标记的有效缓存。

设计决策见 [ADR 0009](docs/adr/0009-trustworthy-quota-companion.md)。

## 隐私

额度查询通过本机 Codex app-server 完成，认证由 Codex 管理。Lume 将浮窗位置与额度缓存保存在本机偏好设置中。

## 许可证

本仓库目前未附带开源许可证。源码公开可见不等同于授予复制、修改或再分发许可。
