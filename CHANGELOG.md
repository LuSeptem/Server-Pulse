# Changelog

## Tauri 2.0 Preview — Unreleased

### 中文

#### 新增

- 新增 `codex/tauri-port` 同仓库重写分支、`port-baseline-v1.1.0` 基线标签，以及 Vue 3 + TypeScript + Pinia + ECharts 前端骨架。
- 新增 Tauri 2 Rust workspace：协议/历史核心、系统 OpenSSH、跨平台数据根目录、文件锁和 `keyring` 凭据抽象。
- 新增 canonical LF-only POSIX 采样脚本、协议/历史黄金样例、Rust/Vitest 测试和 Windows/macOS CI 构建矩阵。
- 新增实时 snapshot/status 事件、Tokio 采集任务、JSONL 历史写入、迁移预览/应用、数据根目录命令和托盘/管理/历史窗口。
- 新增 OpenSSH `Host`/简单 `Include` 别名发现、旧版 Windows `Servers` 配置读取兼容，以及管理窗口新增/删除服务器和可选凭据保存。

#### 变更

- Preview 目标改为 Windows 10/11 x64 与 macOS Intel/Apple Silicon；Linux 桌面端和服务器 Agent 控制移至 v1.1。
- Preview 为未签名内部版本；macOS 透明窗口、托盘、贴边和睡眠恢复尚未在真实 Mac 上验证。
- Windows Release 桌面进程改为 GUI subsystem，SSH/askpass 子进程使用无控制台启动，避免 Preview 启动时额外弹出终端。
- 主浮窗增加可靠的拖拽与关闭按钮；管理页增加 SSH 配置诊断/重新加载和免密 SSH（密钥或 ssh-agent）选项。
- 移除 `codex/tauri-port` 分支中的旧版 PowerShell/WPF 主机脚本与历史代码（旧版代码由 `main` / `legacy/v1.1.0` 完整保留），并生成独立便携版 `ServerPulse.exe`。

#### 修复

- 统一主界面、管理界面与历史界面的暗色设计语言：去除管理窗口多余外边距与背景色差，采用一致的深曜石绿主题色彩、卡片质感、状态徽标与交互按钮。
- 修复 Tauri 2 窗口权限配置：添加 `src-tauri/capabilities/default.json` 完整赋权，避免多窗口事件监听与 IPC 调用失败导致前端数据加载受阻。
- 强化 SSH 配置与别名解析可靠性：集成 `dirs::home_dir()` Win32 原生主目录定位，优化 Pinia Store 初始化与容灾逻辑，确保 `~/.ssh/config` 别名与候选主机始终稳定加载。
- 修复保存服务器配置时出现的 `JSON error: expected value at line 1 column 1` 报错：完善 UTF-8 BOM（`\u{feff}`）与 UTF-16 编码识别解码，确保写入和合并旧版 PowerShell 遗留的 `servers.json` 时完全兼容。
- 修复 SSH 监控采样阻塞并一直卡在 `connecting`/`rechecking` 的问题：为 OpenSSH 补充 `-T`（禁用伪终端分配）与远端指令 `sh -s`，并在发送脚本时严格清理回车符 `\r` 与及时关闭标准输入管道，使指标采样在毫秒级快速完成。
- 在管理界面（Manage）为已有 SSH 服务器列表增加监控复选框（Monitor Checkbox），支持自由勾选/取消勾选任意服务器的监控状态，并即时启停后台采集与同步持久化配置。
- 强化监控状态与前端画面同步链路：后端增加内存快照/状态注册表与 `get_monitoring_state` 全量查询指令，前端结合实时 Tauri 事件与防抖轮询双重同步，杜绝前端未挂载时事件漏接导致的画面空白。
- 增强主界面服务器卡片呈现：支持 CPU、内存、GPU 卡数与 Host 概览，并增加独立 GPU 详细信息栏（GPU 索引、型号、核心利用率、显存占用与上限）。
- 修复服务器在 `online` 状态下仍残留初始超时错误提示的问题：优化后端 `get_monitoring_state` 与前端 Pinia Store 的错误清理机制，并在服务器卡片中增加状态守护条件，确保在线状态下不显示过期的连接错误信息。
- 支持自主配置监控刷新采样频率（Cadence / Refresh Interval）：新增全局/单机自定义采样间隔设置（预设 2s、5s、10s、30s、60s 及 1~300s 自定义输入），并在主浮窗展示当前刷新间隔徽标，修改后即时更新后台采集器。
- 支持多窗口采样频率实时同步与主界面直接修改：后端增加 `interval_seconds` 状态注册与 `interval.changed` 多窗口广播事件，前端主窗口增加交互式下拉选择菜单（支持直接点选 1s、2s、3s、5s、10s、30s、60s 档位），管理窗口与主浮窗双向无缝秒级联动。
- 修复主浮窗无边框透明模式下无法拖动窗口的问题：排查并移除导致 WebView2 鼠标事件拦截失效的 Electron 专有样式 `-webkit-app-region`，在 Rust 后端补充 `drag_window` 原生拖拽指令，并在前端主浮窗所有空白与标题区域增加全域拖拽响应与精准交互元素穿透过滤。
- 修复管理界面（Manage）与历史界面（History）被主浮窗遮挡的问题：由于主浮窗设置了 `alwaysOnTop: true`，在创建与唤起管理及历史窗口时为其同步配置 `always_on_top(true)`、`set_focus()` 与居中呈现，确保管理与历史窗口始终位于最上层。
- 重构历史界面（History）：将历史数据全面改为**分服务器（Per-Server）结构化展示**与**分 GPU（Per-GPU）独立图表呈现**。支持日期快速翻页与今日跳转、多服务器过滤药丸胶囊（Filter Pills）、服务器峰值/均值指标徽章、CPU/内存时序图以及每块 GPU 的核心利用率（%）和显存占用（GB）独立折线图表与缩放交互，保持与主界面一致的深色黑曜石设计语言。
- 主浮窗按需仅展示已勾选监控的服务器：在主浮窗（Main Window）中仅渲染 `monitored === true` 的服务器卡片，未勾选的服务器直接不占位显示；当管理界面切换勾选状态时，通过 `servers.changed` 事件实时跨窗口同步刷新主浮窗列表与在线统计。
- 主浮窗服务器卡片增加独立 GPU 迷你卡片（GPU Mini-Cards）：重构主界面每台服务器的 GPU 呈现形式，为每块显卡设计独立的圆角卡片，包含显卡型号标签、温度徽标（如 `67°C`）、大号核心利用率百分比与双进度条。
- GPU 迷你卡片支持动态阈值色彩与自适应多列并排布局：
  - 动态阈值变色：GPU 利用率默认使用绿色（`#4ade80`），负荷高于 80% 时自动切换为珊瑚红警示（`#f87171`）；显存进度条默认使用天青色（`#38bdf8`），高于 80% 时同步变红；数字文字保持恒定纯白色（`#ffffff`），保持统一与高辨识度；
  - 自适应多列布局：采用 CSS 响应式网格布局，在默认宽度及自由拉伸窗口时支持每行并排展示 2 张（或更多）显卡迷你卡片，大幅缩减竖向高度占用。

#### 未完成

- 主机指纹确认/变更阻断的完整界面、仅本次会话密码通道、按分钟加权聚合、完整服务器编辑、Agent 注入控制和 macOS 实机验收仍需在 Preview 合并前完成。

### English

#### Added

- Added the `codex/tauri-port` same-repository rewrite branch, the `port-baseline-v1.1.0` baseline tag, and the Vue 3 + TypeScript + Pinia + ECharts frontend scaffold.
- Added a Tauri 2 Rust workspace for protocol/history core logic, system OpenSSH, cross-platform data roots, file locks, and the `keyring` credential abstraction.
- Added the canonical LF-only POSIX sampler, protocol/history golden fixtures, Rust/Vitest tests, and a Windows/macOS CI build matrix.
- Added Tokio collectors, typed snapshot/status events, JSONL history writes, migration preview/apply commands, data-root commands, and tray/manage/history windows.
- Added OpenSSH `Host`/simple `Include` alias discovery, compatibility with the legacy Windows `Servers` config shape, and manager add/remove actions with optional credential saving.

#### Changed

- The Preview targets Windows 10/11 x64 and macOS Intel/Apple Silicon; Linux desktop and server Agent control move to v1.1.
- The Preview is unsigned and for internal testing; macOS transparency, tray, edge docking, and sleep/resume remain unverified on physical hardware.
- The Windows Release desktop process now uses the GUI subsystem, and SSH/askpass children use no-console creation flags so the Preview does not open an extra terminal on startup.
- Added reliable main-window dragging and close controls, SSH config diagnostics/reload, and an explicit passwordless SSH (key or ssh-agent) option in Manage.
- Removed legacy PowerShell/WPF host scripts and files from `codex/tauri-port` (all preserved on `main` / `legacy/v1.1.0`), and built the standalone portable `ServerPulse.exe`.

#### Fixed

- Unified the visual language between the Main, Manage, and History windows: eliminated inconsistent window padding and background mismatch, applying a cohesive deep obsidian green palette, card borders, status pills, and action buttons.
- Configured Tauri 2 capabilities in `src-tauri/capabilities/default.json` for full window permissions, multi-window events, and IPC calls.
- Hardened SSH config alias and candidate loading: integrated `dirs::home_dir()` Win32 native home resolution, and made store initialization resilient so `~/.ssh/config` aliases are always discovered and displayed.
- Fixed `JSON error: expected value at line 1 column 1` when saving server configs: added transparent UTF-8 BOM (`\u{feff}`) and UTF-16 decoding across config and history parsers, ensuring seamless compatibility with legacy PowerShell `servers.json`.
- Fixed SSH sampling process hanging indefinitely on `connecting`/`rechecking`: added OpenSSH `-T` (no pseudo-terminal) and remote command `sh -s`, stripped carriage returns `\r`, and closed stdin immediately to guarantee fast metric execution.
- Added monitor toggle checkboxes to the Manage view server list, allowing users to easily enable or disable monitoring for any configured SSH server with immediate background start/stop and persistent config saves.
- Hardened monitoring state synchronization between backend and frontend: added in-memory state caching in Rust and the `get_monitoring_state` IPC command, backed by both Tauri events and reactive polling in Pinia to eliminate missed startup events.
- Enhanced server cards on the main dashboard with complete metric grids (CPU, Memory, GPU count, Hostname) and per-GPU breakdown rows (GPU model, utilization, VRAM usage/limit).
- Fixed lingering initial timeout error notices on online servers: pruned stale errors on online transitions in both Rust and Pinia, and guarded card error rendering so error text only displays when the server is genuinely disconnected.
- Added user-configurable monitoring refresh interval (cadence): provided presets (2s, 5s default, 10s, 30s, 60s) and a custom 1–300s input in Manage view with live indicator on the main dashboard, immediately updating background collection tasks.
- Added cross-window interval synchronization and direct inline cadence modification on the main dashboard: broadcasted `interval.changed` events across Tauri windows and added a quick popover selector directly on the main floating widget (1s, 2s, 3s, 5s, 10s, 30s, 60s).
- Fixed main floating window dragging on Windows frameless/transparent mode: removed conflicting `-webkit-app-region` styles that intercepted WebView2 DOM events, added dedicated native `drag_window` IPC command, and enabled comprehensive blank-area and header drag hit-testing with button exclusions.
- Fixed window z-order hierarchy so Manage and History windows stay in front of the main widget: configured `always_on_top(true)` and focus targeting on secondary windows so they are not obscured by the floating main window.
- Redesigned History view with per-server segmentation and per-GPU breakdown charts: added server filter pills, date navigation controls, peak/avg summary chips, CPU/RAM timeline charts, and dedicated per-GPU core utilization (%) and VRAM memory (GB) series with pan/zoom interactions and cohesive dark obsidian styling.
- Display only checked/monitored servers on the main floating dashboard: filtered server cards by `monitored === true` and added cross-window `servers.changed` broadcast so changes in Manage reflect immediately on the main dashboard without showing unselected servers.
- Added responsive multi-column layout and dynamic utilization threshold colors for GPU mini-cards: rendered GPU cards in 2+ columns responsive to window resize, using green default for GPU core utilization with automatic coral red transition when exceeding 80%, cyan for VRAM, and clean white numbers consistently.

#### Remaining

- Full host-key confirmation/change blocking UX, the session-only password channel, minute-weighted aggregation, complete server editing, Agent injection/control, and physical Mac acceptance remain required before Preview merge.

## v1.1.0 — 2026-08-15

### 中文

#### 新增

- 增加服务器端常驻监控代理：支持注入、停止、重启、更新配置、卸载和运行状态检测。
- 服务器端在应用关闭、电脑休眠或网络断开期间继续采样，并将分钟记录按 UTC 保存、按本地时区合并到历史记录。
- 支持启动时自动恢复服务器代理、增量合并游标、服务器端记录清理，以及“合并全部服务器”。
- 历史记录查询改为按窗口读取 JSONL，并在窗口显示后异步执行首次查询，减少打开记录页时的阻塞。
- 增加合并无记录、游标跳过记录、采样失败字节数等诊断信息。

#### 修复

- 修复服务器端 awk 聚合器未正确退出 `GPUS_END` 区段，导致同步记录缺少 GPU 用户显存明细的问题。
- 修复 Windows PowerShell 5.1 空用户样本合并异常，以及后台合并传递服务器 ID 数组时的兼容性问题。
- 修复大规模 SSH 输出可能造成读取超时的问题。
- 统一发往 Linux 服务器的脚本使用 LF 行尾，并修复后台 runspace 缺少核心模块的问题。

### English

#### Added

- Added a persistent server-side monitoring agent with inject, stop, restart, configuration update, uninstall, and status controls.
- The agent keeps sampling while the app is closed, the computer sleeps, or the network is disconnected; minute records are stored in UTC and merged into local history in the user's timezone.
- Added startup auto-restore, incremental merge cursors, server-side record cleanup, and a Merge All Servers action.
- History queries now read only the requested JSONL window, and the first query runs asynchronously after the window is shown to reduce UI blocking.
- Added diagnostics for empty merges, cursor-skipped records, and failed samples with byte counts.

#### Fixed

- Fixed the server-side awk aggregator so it exits the `GPUS_END` section correctly; synchronized records now retain per-GPU user VRAM details.
- Fixed empty user-sample merges on Windows PowerShell 5.1 and compatibility issues when passing known server ID arrays to background merges.
- Fixed SSH read timeouts caused by large stdout/stderr output.
- Normalized scripts sent to Linux hosts to LF line endings and fixed missing core-module loading in background runspaces.
