# Lume

Lume 是一个轻量的 macOS Codex 额度伴侣。它常驻菜单栏，不显示在 Dock，并通过可拖动的浮窗同时显示 Codex 5H 与 7D 剩余额度。

## 功能

- 默认显示 44pt 双额度圆环：外环为 5H、内环为 7D，中心数字为 5H。
- 圆环拖近屏幕左右边缘时吸附为双额度竖条，内容侧宽条为 5H、屏幕侧细条为 7D。
- 竖条可沿屏幕边缘上下拖动，单击后在当前位置向屏幕内展开为圆环。
- 单击圆环可将 Codex 窗口带到前台。
- 菜单栏提供额度刷新、浮窗显示、登录启动和退出操作。
- 可选 Sol Control 模式选择：在菜单栏或明确的自然语言指令中持久选择 `openai` 或 `quota-save`。

## 系统要求

- macOS 14 或更高版本
- Apple Silicon
- 已安装 Codex Desktop
- Xcode Command Line Tools 或 Swift 5.10+

## 构建与测试

```bash
swift run LumeTests
swift build -c release
tests/sol-control/test-lume-integration.sh
tests/packaging/test-lume-verifier.sh
scripts/build-lume.sh
```

构建产物位于 `artifacts/lume/`：

- `Lume.app`
- `Lume.dmg`

## Sol Control 模式选择

Lume 菜单提供 `openai` 与 `quota-save` 两种持久模式。Sol Control 在创建每个新 worker 前读取 `~/.codex/sol-control-policy.json`；明确限定“这次”或“本轮”的指令只影响当次调用。

安装脚本随 App 一同打包，也可从源码运行：

```bash
integrations/sol-control/install.sh
```

架构决策见 [ADR 0008](docs/adr/0008-use-user-selected-sol-control-modes.md)。

## 隐私

Lume 在本机读取 Codex app-server 的额度数据，不包含遥测、自动更新器、Tessalume 主题运行时、.NET Helper 或 Windows 组件。

## 许可证

本仓库目前未附带开源许可证。源码公开可见不等同于授予复制、修改或再分发许可。
