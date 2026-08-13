# Lume

Lume 是一个轻量的 macOS Codex 额度伴侣。它常驻菜单栏，不显示在 Dock，并通过可拖动的浮窗显示 Codex 7D 剩余额度。

## 功能

- 默认显示 36pt 额度圆环。
- 圆环拖近屏幕左右边缘时吸附为额度竖条。
- 竖条可沿屏幕边缘上下拖动，单击后在当前位置向屏幕内展开为圆环。
- 单击圆环可将 Codex 窗口带到前台。
- 菜单栏提供额度刷新、浮窗显示、登录启动和退出操作。
- 可选 Sol Control 联动：7D 额度低于 20% 时，`auto` 模式为后续新 worker 选择 `quota-save`；恢复到 25% 后切回 `openai`。

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

## Sol Control 联动

Lume 只发布本机额度事实；Sol Control 保留路由策略所有权。联动通过显式 `$sol-control` 的 `UserPromptSubmit` Hook 生效，不会向普通 Codex 对话注入消息，也不会迁移已经创建的 worker。

安装脚本随 App 一同打包，也可从源码运行：

```bash
integrations/sol-control/install.sh
```

架构决策见 [ADR 0007](docs/adr/0007-route-sol-control-from-a-local-lume-signal.md)。

## 隐私

Lume 在本机读取 Codex app-server 的额度数据，不包含遥测、自动更新器、Tessalume 主题运行时、.NET Helper 或 Windows 组件。

## 许可证

本仓库目前未附带开源许可证。源码公开可见不等同于授予复制、修改或再分发许可。
