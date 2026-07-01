# 更新日志

## v0.2.0 - 2026-07-01

第二个公开测试版本，重点改善悬浮球和开机使用体验。

### 新增

- 默认显示悬浮球。
- 记住悬浮球的显示状态和位置。
- 菜单里新增 `Open at Login` 开关。
- 启动时如果 Codex quota 暂时不可用，会自动重试。

### 调整

- quota helper 超时时间从 5 秒调整为 10 秒。
- 发布包版本更新为 `0.2.0`。

### 隐私和本机文件边界

- 只保存 UI 偏好到 `~/Library/Application Support/CodexQuotaBar/preferences.json`。
- 不安装 LaunchAgent、daemon、自动更新、遥测或分析组件。
- 不读取浏览器 Cookie、`~/.codex/auth.json`、prompts 或 responses。

## v0.1.0 - 2026-06-29

第一个公开测试版本。

### 新增

- 在 macOS 菜单栏显示 Codex 5 小时和 7 天额度。
- 用柱形和百分比展示额度，并区分绿色、橙色、红色状态。
- 菜单中显示实时额度、重置时间、最后刷新时间、刷新、打开 Codex 和退出。
- 为 GitHub Releases 提供 DMG、zip 备用包、安装说明和 SHA-256 校验文件。
