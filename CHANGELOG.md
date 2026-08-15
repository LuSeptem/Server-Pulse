# Changelog

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
