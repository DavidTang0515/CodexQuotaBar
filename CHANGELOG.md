# 更新日志

## v0.4.0 - 2026-08-26

第四个功能版本，在保留 5 小时和 7 天双额度展示的基础上，新增本机 Token 统计并提升刷新稳定性。

### 新增

- 菜单新增 `Local Token` 区域，可切换今天、7 天、30 天、本月和全部记录。
- 展示 Token 总量及输入、缓存输入、输出构成。
- 使用本机 `usage.sqlite` 增量索引 Codex 会话日志中的 Token 计数事件。
- 悬浮球支持悬停查看 5h、7d、重置时间和 Token 摘要；点击可固定详情，再点击其他位置收起。

### 调整与修复

- 状态栏继续同时显示 5h 和 7d，不引入驾驶舱窗口。
- 额度读取增加 15 秒超时，Token 扫描增加 30 秒超时，避免刷新长期卡住。
- 刷新失败时保留上一次有效额度，不再短暂清空状态栏。
- 避免额度未变化时重复绘制状态栏图标。
- 修复超长提示文字的换行和尺寸计算。

### 隐私和本机文件边界

- 只从 `~/.codex/sessions` 与 `~/.codex/archived_sessions` 提取 Token 计数、时间和模型元数据。
- 不保存 prompts、responses 或项目文件内容。
- Token 索引、额度历史和偏好均保存在 `~/Library/Application Support/CodexQuotaBar`，可通过 `Clear Local Data...` 移入废纸篓。

## v0.3.0 - 2026-07-12

第三个功能版本，新增本机额度历史和消耗趋势估算。

### 新增

- 使用 `history.sqlite` 保存本机额度历史，用于估算近期消耗速率。
- 菜单中新增 `Usage trend` 区域，展示 5 小时额度近 1 小时消耗速率。
- 菜单中新增 7 天额度近 24 小时消耗速率。
- 显示与上一时间窗口的简单对比。
- 显示按当前速率估算的 5 小时额度预计可用时间。
- 新增 `Clear Local Data...`，可将额度历史和 UI 偏好移动到系统废纸篓。

### 隐私和本机文件边界

- 额度历史仅保存时间戳、剩余额度百分比、重置时间、plan 和 source。
- 不保存 prompts、responses、项目路径、文件内容、Cookie 或认证文件。
- 额度历史默认保留最近 30 天。
- 趋势是基于额度百分比的估算，不等同于真实 token 计数。

## v0.2.1 - 2026-07-10

兼容性修复版本，适配 Codex 合入 ChatGPT 后的新版 macOS 应用。

### 修复与调整

- 修复新版 Codex 合入 ChatGPT 后无法找到内置 Codex CLI 的问题。
- 新增对 `ChatGPT.app` 内置 CLI 的支持。
- 保留独立 Codex CLI 和旧版 `Codex.app` 的兼容性。
- 将菜单中的 `Open Codex` 更新为 `Open ChatGPT`。
- 改进 CLI 缺失、启动失败和额度请求失败时的错误提示。
- 更新安装要求及隐私说明。
- 未改变额度计算、菜单栏样式、悬浮球和开机启动功能。

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
