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

- 修复 `~/.ssh/config` 别名未作为候选服务器加载的问题：优化配置解析支持 `Host = alias`、引号与多主机名模式，修复 `~` 包含路径展开，并使用 `ssh -G` 自动解析候选主机的用户名与端口。
- 增强管理窗口的候选发现体验：提供可点击预填的别名标签、候选列表单键“+ 加入监控”以及“全部导入”功能。

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

- Fixed SSH alias candidate discovery from `~/.ssh/config`: corrected `~` include expansion, supported `Host = alias`, quotes, and multi-alias lines, and used `ssh -G` to automatically resolve target usernames, ports, and hostnames.
- Enhanced SSH candidate management UI: added interactive alias badges for instant form pre-filling, single-click "+ Add to monitor" candidate cards, and an "Import all" action matching the legacy ServerPulse experience.

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
