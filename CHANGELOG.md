# Changelog

## v2.1.5 — 2026-09-05

### 中文

本次发布汇总自 v2.1.2 以来的更新，包含此前未发布的 v2.1.3、v2.1.4 改动。

#### 新增

- 主界面 MEM 指标显示内存百分比及已用/总容量；历史界面的 RAM 统计和图表提示同步显示总内存及容量明细。旧记录缺少总内存时自动隐藏相关明细。

#### 变更

- 移除服务器卡片中独立的 DISK 概览框，保留 GPU 卡片下方的“全部磁盘”入口及各挂载点的使用率、容量和进度条。
- 每次功能更新或修复后重新构建并更新 portable exe，校验其与构建产物一致，便于直接测试。

#### 修复

- 修复服务器列表滚动后标题栏和最小化/关闭按钮被滚出屏幕的问题；现在仅服务器列表滚动，顶部标题栏和窗口控制始终可见。

### English

This release includes all updates since v2.1.2, including the previously unpublished v2.1.3 and v2.1.4 changes.

#### Added

- The main window's MEM metric now shows used/total memory alongside the percentage. History RAM statistics and chart tooltips also show total memory and capacity details. Details are hidden when older records lack total memory.

#### Changed

- Removed the separate DISK summary box from server cards. The “全部磁盘” (All disks) control below the GPU cards still expands per-mount usage, capacity, and progress bars.
- Rebuild and refresh the portable executable after every feature update or bug fix, verifying it matches the build output for direct testing.

#### Fixed

- Fixed the title bar and minimize/close buttons scrolling off-screen with long server lists. Only the server list now scrolls; the title bar and window controls remain visible.

## v2.1.4 — 2026-08-31

### 中文

#### 新增

- **系统内存显示总内存（主界面 + 历史界面）**：
  - 主界面：服务器卡片 MEM 行在百分比旁显示 `已用 / 总量 GB`（例如 `72.1% · 92.3 / 128.0 GB`），与 DISK 行风格一致。
  - 历史界面：服务器 “RAM Peak / Avg” 统计芯片追加总内存（例如 `68.2% / 55.1% · 128 GB`）；CPU & 内存图表的固定弹窗与悬停 tooltip 的内存值追加 已用/总量 明细（例如 `内存 72.1% · 92.3 / 128 GB`）。
  - 数据来源：历史采样记录本就包含 `MemoryUsedMiB` / `MemoryTotalMiB` 字段，此前前端未解析显示；旧记录缺失总内存时自动隐藏明细，不显示占位符。
  - 回归防护：新增 Playwright e2e 测试 `frontend/e2e/memory-total.spec.ts` — 主界面通过 Pinia 实例注入真实形状快照后断言 MEM 行包含 `92.3 / 128.0 GB`；历史界面断言 RAM 芯片包含 `128 GB`。

### English

#### Added

- **System memory now shows total memory on the main window and History page**:
  - Main window: the server card's MEM row now shows `used / total GB` next to the percentage (e.g. `72.1% · 92.3 / 128.0 GB`), matching the DISK row style.
  - History page: the server's "RAM Peak / Avg" stat chip appends the total memory (e.g. `68.2% / 55.1% · 128 GB`); the CPU & memory chart's pinned popup and hover tooltip append the used/total detail to the memory value (e.g. `内存 72.1% · 92.3 / 128 GB`).
  - Data source: history samples already carried `MemoryUsedMiB` / `MemoryTotalMiB` — the frontend just never parsed or displayed them. Records without a total (older data) hide the detail instead of showing a placeholder.
  - Regression protection: new Playwright e2e test `frontend/e2e/memory-total.spec.ts` — asserts the main window MEM row contains `92.3 / 128.0 GB` after injecting a real-shaped snapshot via the Pinia instance, and the history RAM chip contains `128 GB`.

## v2.1.3 — 2026-08-31

### 中文

#### 修复

- **修复主界面滚动后标题栏与最小化/关闭按钮被滚出屏幕、无法关闭窗口的问题**：
  - 根因：主窗口 `.widget-window` 原先是常规块级容器（`min-height: 100vh` + `overflow: hidden`）。当服务器卡片数量较多、内容超过窗口高度时，实际滚动的是**整个文档**（`html/body`），因此处于常规文档流中的 `.window-header`（标题「Server monitor」+ 贴边自动隐藏 / History / Manage / 最小化 / 关闭按钮）会随页面一起被滚出视口，滚动到底后按钮不可见、无法点击，窗口便无法关闭。
  - 修复：将 `.widget-window` 改为固定视口高度的弹性纵向容器（`height: 100vh` + `display: flex` + `flex-direction: column`），并把滚动职责收敛到服务器卡片列表上——标题栏与状态摘要行固定不滚动（`flex: 0 0 auto`），仅 `.server-list` 在窗口内部独立滚动（`flex: 1 1 auto` + `min-height: 0` + `overflow-y: auto`）。这样无论卡片多少，顶部标题与窗口控制按钮始终钉在窗口顶部可见可点。
  - 回归防护：新增 Playwright e2e 回归测试 `frontend/e2e/pinned-header.spec.ts`。该测试在 440×620（与真实主窗口一致）视口下，通过注入 `window.__TAURI_INTERNALS__` 桩向 store 提供 12 个受监控服务器，使卡片列表高度确实超过视口（触发原 bug 的滚动条件），随后把页面与列表都滚动到底，断言关闭按钮与整个标题栏仍完整落在视口内。

### English

#### Fixed

- **Fixed the main window's title bar and minimize/close buttons scrolling off-screen, making the window impossible to close after scrolling down**:
  - Root cause: the main window's `.widget-window` was a regular block container (`min-height: 100vh` + `overflow: hidden`). When enough server cards made the content taller than the window, the **document** (`html/body`) — not the widget — was what scrolled, so the in-flow `.window-header` (the "Server monitor" title plus the edge auto-hide / History / Manage / minimize / close buttons) was carried out of the viewport with the page. Scrolled to the bottom, the buttons were invisible and unclickable, so the widget could not be closed.
  - Fix: `.widget-window` is now a fixed-viewport-height flex column (`height: 100vh` + `display: flex` + `flex-direction: column`) with the scrolling responsibility confined to the server-card list — the title bar and status summary row are pinned (`flex: 0 0 auto`), and only `.server-list` scrolls independently inside the window (`flex: 1 1 auto` + `min-height: 0` + `overflow-y: auto`). No matter how many cards there are, the top title and window controls now stay pinned, visible and clickable.
  - Regression protection: new Playwright e2e regression test `frontend/e2e/pinned-header.spec.ts`. It runs at a 440×620 viewport (matching the real main window), injects a `window.__TAURI_INTERNALS__` stub that hands the store 12 monitored servers so the card list is genuinely taller than the viewport (the original scroll condition that triggered the bug), then scrolls both the page and the list to the bottom and asserts the close button and the whole title bar remain fully inside the viewport.

## v2.1.2 — 2026-08-31

### 中文

#### 修复

- 修复 Manage 页勾选/取消勾选服务器后主界面不实时同步的问题（此前必须退出重进才生效）。
- 跨窗口事件名改为合法形式（去除点号），事件监听改为独立注册，单个注册失败不再影响其余监听。
- 重新构建并更新 `frontend/dist` 发布产物，修复 Release 打包到过期前端构建的问题。

### English

#### Fixed

- Fixed selection changes in the Manage window not syncing live to the main window (a quit-and-restart was previously required).
- Cross-window event names changed to legal forms (no dots); event listeners are now registered independently so one failing registration no longer disables the rest.
- Rebuilt and refreshed the `frontend/dist` release artifact, fixing releases shipping a stale frontend build.

## v2.1.1 — 2026-08-29

### 中文

#### 变更

- **冻结「按用户磁盘归因」功能**（基于 `find` 的扫描在远端服务器上非常占用内存和磁盘，计划后续正式下架）：
  - 远端 agent 不再调度或部署每日 `find` 扫描：所有代理配置恒以 `scan_enabled=0` 写入；以旧配置部署的已有代理在执行一次「重启」「注入」或保存配置后停止调度。
  - 卡片「立即扫描」入口、按用户磁盘归属弹窗、History 页按用户磁盘曲线全部隐藏；各窗口 5 分钟归属自动刷新关闭。
  - 记录合并不再拉取/合并归属记录，历史查询不再返回归属数据。
  - 实时磁盘容量监控（DISK 行、挂载点列表、每挂载点使用率曲线）不受影响。
  - 本地与远端已有的归属历史原样保留，不清理、不删除。
  - 实现方式：代码级功能开关——Rust 层 `serverpulse_core::DISK_ATTRIBUTION_FROZEN` + 前端 `DISK_ATTRIBUTION_FROZEN`，代码完整保留、翻转开关即可恢复；正式下架时整体删除相关代码路径。

#### 修复

- 修复历史查询内存占用过高的问题（快速采样下历史查询可冲到 3–4 GB）：日文件改为按时间戳预过滤的流式读取，不再整文件载入并逐行构建值树；去重改用结构化记录哈希，不再为每条记录保留再序列化副本。
- 本地历史记录现在每台服务器每个 UTC 分钟最多落盘一行（实时卡片仍按所选采样间隔刷新），历史日文件体积缩小约 40 倍，也降低了对远端与本地的磁盘写入压力。

### English

#### Changed

- **Per-user disk attribution frozen** (the `find`-based scan is heavy on memory and disk on the remote server; decommissioning is planned):
  - Remote agents no longer schedule or deploy the daily `find` scan: every agent config is written with `scan_enabled=0`; agents deployed with an older config stop scheduling after one Restart/Inject/config save.
  - The card "Scan now" entry, the per-user disk attribution popup, and the per-user disk curves in History are hidden; the 5-minute attribution auto-refresh in every window is off.
  - Record merges no longer pull/merge attribution records, and history queries no longer return attribution data.
  - Real-time disk capacity monitoring (DISK row, mount list, per-mount usage curves) is unaffected.
  - Existing local and remote attribution history is preserved untouched — not cleaned up, not deleted.
  - Implementation: code-level feature flags — Rust `serverpulse_core::DISK_ATTRIBUTION_FROZEN` plus frontend `DISK_ATTRIBUTION_FROZEN`; all code is retained and flipping the flags re-enables the feature; decommissioning will remove the code paths entirely.

#### Fixed

- Fixed excessive memory usage in history queries (3–4 GB spikes at fast sampling): day files are now read through a streaming reader with a timestamp prefilter instead of loading each file in full and building a value tree per line; deduplication uses a structural record hash instead of a re-serialized copy of every record.
- Local history now writes at most one line per server per UTC minute (live cards still refresh at the chosen sampling interval), shrinking day files roughly 40x and reducing disk-write pressure on both the local machine and the remote servers.

## v2.1.0 — 2026-08-22

### 中文

#### 新增

- 磁盘容量监控：自动发现真实本地文件系统，主卡片新增 DISK 行与全部挂载点展开列表。
- 按用户磁盘归因：服务端每日低频扫描（默认 3 点时段、可配置），结果按挂载点记录并合并入本地历史；支持卡片「立即扫描」手动触发（无需安装 agent，detached 执行）。
- History 页新增磁盘视图：每挂载点使用率曲线与按用户已用容量的日级阶梯曲线。

#### 变更

- 协议 v2 向后兼容扩展（DISKS 段）；旧 sampler/agent 输出不受影响。
- agent 配置新增 scan_enabled/scan_hour；更新后需 Restart/Inject 一次以启用每日调度。

#### 修复

- 「立即扫描」完成后现在自动拉取合并结果到本地历史并刷新归属面板；此前结果会留在服务器上，直到手动执行「合并记录」。
- 修复扫描完成后轮询 tick 堆叠导致重复并发全量合并，进而占满内存与磁盘写入的问题：状态轮询加在飞保护，每次完成的扫描仅合并一次（新扫描重新武装）。
- 磁盘监控现在按文件系统类型过滤，snap 的 squashfs 回挂载（/snap/…）等虚拟文件系统不再出现在挂载点列表中；历史页解析同样过滤，修复前的存量记录和尚未更新 sampler 的 agent 记录中的 snap 挂载也不再显示。
- 磁盘归属弹窗文案改为磁盘语义（用户占用而非活跃进程）。
- 磁盘用户曲线改为按占用总量降序选取（最多 3 条），不再按用户名字母序——修复 `_apt` 等系统服务账号因字母序霸占图例的问题。
- 修复历史页磁盘用户曲线把稀疏扫描点直接连线、tooltip 多数时间显示 NaN 的问题：曲线现在展开到完整时间轴并保持日级阶梯语义（两次扫描之间维持上次扫描值，首次扫描之前留空）。

#### 已知限制

- 构建产物当前未签名、未公证，仅用于内部测试。
- macOS 代码保持编译兼容，但透明窗口、托盘、贴边和睡眠恢复尚未在真实 Mac 上验收。

### English

#### Added

- Disk capacity monitoring: auto-discovered real filesystems, new DISK card row with expandable per-mount breakdown.
- Per-user disk attribution via daily server-side scans (configurable, default 3am hour) merged into local history, plus an on-demand "Scan now" button that runs detached without requiring the agent.
- New History disk view: per-mount usage curves and stepped daily per-user curves.

#### Changed

- Backward-compatible protocol v2 extension (DISKS section); old samplers/agents keep working.
- Agent config gains scan_enabled/scan_hour; one Restart/Inject is needed after updating to enable daily scheduling.

#### Fixed

- "Scan now" now automatically pulls and merges results into local history and refreshes the attribution panel when the scan finishes; previously results stayed on the server until a manual merge.
- Fixed memory/disk-write saturation after a completed scan: poll ticks no longer stack, and each completed scan merges exactly once (re-armed by the next scan).
- Disk monitoring now filters by filesystem type as well as device name, so snap squashfs loop mounts (/snap/…) and similar virtual filesystems no longer appear in the mount list; the History view applies the same filter so legacy records and records from agents that still run the old sampler are hidden as well.
- Disk attribution popup copy now uses disk semantics (per-user occupancy, not active processes).
- Disk user curves are now ranked by total usage (top 3) instead of alphabetically by name, so tiny system service accounts such as _apt no longer crowd the legend.
- Fixed the History disk per-user curves connecting sparse scan points directly and reading NaN in most tooltip slots: curves are now expanded onto the full axis with daily step semantics (the last scan value is carried forward between scans, and the chart stays blank before the first scan).

#### Known limitations

- Build artifacts are currently unsigned and unnotarized for internal testing only.
- macOS code remains compile-compatible, but transparency, tray, edge docking, and sleep/resume have not been accepted on physical Mac hardware.

## v2.0.0 — 2026-08-21

### 中文

#### 从 v1.1.0 到 v2.0.0

- 运行时从 Windows PowerShell/WPF 宿主迁移到 Tauri 2 + Rust + Vue 3；`main` 现在只运行 Tauri 实现，`legacy/v1.1.0` 分支和 `port-baseline-v1.1.0` 标签保留旧版作为回滚基线。
- 原有 `servers.json`、SSH config 别名、密钥、ssh-agent、ProxyJump 和 OS 凭据继续兼容；旧版历史 JSON/JSONL、无时区时间戳和 Windows 服务器配置可继续读取。
- v1.1.0 的服务器端 Agent 仍保留注入、状态、控制、拉取和合并能力；v2.0.0 的本地实时采集改用每台服务器一个持久分帧 SSH 会话，二者互不冲突。
- 历史新写入统一使用 UTC `Z` 时间戳和 UTC 日期文件；用户按本地日期查询，图表按本地时间显示，跨版本记录无需手动迁移。
- v2.0.0 暂不签名或公证，Windows 10/11 x64 是主要验收平台；macOS 保持编译兼容但仍需真实设备验收窗口和托盘行为。

#### 新增

- 完成 Tauri 2 + Vue 3 + TypeScript + Pinia + ECharts 跨平台桌面应用，并将 `main` 作为当前实现；`legacy/v1.1.0` 与 `port-baseline-v1.1.0` 保留为回滚基线。
- 新增 Tauri 2 Rust workspace：协议/历史核心、系统 OpenSSH、跨平台数据根目录、文件锁和 `keyring` 凭据抽象。
- 新增 canonical LF-only POSIX 采样脚本、协议/历史黄金样例、Rust/Vitest 测试和 Windows/macOS CI 构建矩阵。
- 新增实时 snapshot/status 事件、Tokio 采集任务、JSONL 历史写入、迁移预览/应用、数据根目录命令和托盘/管理/历史窗口。
- 新增 OpenSSH `Host`/简单 `Include` 别名发现、旧版 Windows `Servers` 配置读取兼容，以及管理窗口新增/删除服务器和可选凭据保存。

#### 变更

- v2.0.0 目标为 Windows 10/11 x64 与 macOS Intel/Apple Silicon；Linux 桌面端不在当前版本范围内，服务器 Agent 的短命令控制继续保留。
- v2.0.0 为未签名内部版本；macOS 透明窗口、托盘、贴边和睡眠恢复尚未在真实 Mac 上验证。
- Windows Release 桌面进程改为 GUI subsystem，SSH/askpass 子进程使用无控制台启动，避免应用启动时额外弹出终端。
- 主浮窗增加可靠的拖拽与关闭按钮；管理页增加 SSH 配置诊断/重新加载和免密 SSH（密钥或 ssh-agent）选项。
- 将旧版 PowerShell/WPF 实现从当前运行路径移出，旧版代码由 `legacy/v1.1.0` 与 `port-baseline-v1.1.0` 完整保留，并生成独立便携版 `ServerPulse-Portable.exe`。

#### 修复

- 统一主界面、管理界面与历史界面的暗色设计语言：去除管理窗口多余外边距与背景色差，采用一致的深曜石绿主题色彩、卡片质感、状态徽标与交互按钮。
- 修复 Tauri 2 窗口权限配置：添加 `src-tauri/capabilities/default.json` 完整赋权，避免多窗口事件监听与 IPC 调用失败导致前端数据加载受阻。
- 强化 SSH 配置与别名解析可靠性：集成 `dirs::home_dir()` Win32 原生主目录定位，优化 Pinia Store 初始化与容灾逻辑，确保 `~/.ssh/config` 别名与候选主机始终稳定加载。
- 修复保存服务器配置时出现的 `JSON error: expected value at line 1 column 1` 报错：完善 UTF-8 BOM（`\u{feff}`）与 UTF-16 编码识别解码，确保写入和合并旧版 PowerShell 遗留的 `servers.json` 时完全兼容。
- 修复 SSH 监控采样阻塞并一直卡在 `connecting`/`rechecking` 的问题：为 OpenSSH 补充 `-T`（禁用伪终端分配）与远端指令 `sh -s`，并在发送脚本时严格清理回车符 `\r` 与及时关闭标准输入管道，使指标采样在毫秒级快速完成。
- 修复 Tauri/Explorer 启动时 SSH 别名解析到错误目标的问题：显式使用当前用户的 SSH 配置文件，并让 `ssh`、`ssh -G` 和 Windows 主机密钥探测保持同一配置。
- 修复 Windows 主机密钥探测参数错误导致目标地址被截断为 `0.0.0.5` 的问题，并保留受影响 Win32-OpenSSH `sntrup761x25519` 的安全回退路径。
- 完成主机密钥确认与变更阻断：未知主机必须确认 SHA256 指纹，指纹变化直接阻断，应用专用 `known_hosts` 可忘记后重新验证，用户文件只读兼容。
- 完成会话密码安全通道：支持保存到 OS credential store 或仅当前运行使用；密码只在主进程 zeroize 内存和一次性 askpass 通道中存在，不写入配置、参数、普通环境变量、日志或历史。
- 完成每台服务器一个持久流式 SSH 会话：远端按帧输出、多帧连续解析，超时/损坏/断线按退避重连，不可重试认证错误暂停该服务器并保留结构化状态。
- 完成 UTC 历史存储与本地日期查询：新记录统一写入带 `Z` 的 RFC3339 和 UTC 日期文件，查询按本地日转换 UTC 范围并兼容旧版无时区记录。
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
- 优化服务器卡片头部信息排布与紧凑度：将原本独立占据整行卡片的 GPU 数量（如 `4 GPUs`）与主机名（如 `amax-BD4908P`）整合收敛至服务器名称下方的副标题小字（`server_host · hostname · X GPUs`），主指标区精简聚焦为 CPU 与 MEM 双列并排，极大地节省了卡片垂直空间。
- 精简管理界面（Manage View）：由于主界面已内置交互式下拉菜单支持秒级点选刷新频率，管理界面移除了冗余的“采样刷新频率”控制卡片，使管理界面纯粹聚焦于 SSH 别名发现与服务器列表管理。
- 增强管理界面添加服务器字段提示：在 SSH alias / hostname 输入框中增加明确的 IP 与别名示例提示（`123.23.23.23 / gpu-01`），支持用户直接输入远程服务器 IP 或别名。
- 实现主窗口贴靠屏幕上、左、右三边自动吸附与隐藏（Edge Auto-Hide）：
  - 严格对齐老版本贴边逻辑与按钮交互：默认开启贴边自动隐藏（`autoHide = true`），右上角按钮显示为贴边按钮（`⇥` / `⇤`），高亮绿色代表“已开启贴边隐藏”（点击可关闭）；
  - 屏幕有效工作区缓存（`savedWorkArea`）与贴边探测：在吸附时刻准确锁定当前显示器的有效工作区与窗口尺寸，杜绝隐藏后多屏或屏幕外判定跳变导致坐标错位；
  - Win32 全局光标追踪（Global Cursor Tracking）与 8px 无圆角深黑发光手柄：引入原生 `GetCursorPos` 每 75ms 周期巡检全局物理光标，隐藏时在屏幕边缘呈现 8px 纯色直角黑边手柄（`#0d100e` 搭配 `4px #4ade80` 亮绿发光外框）；光标靠近屏幕边缘 24px 范围内必定 100% 触发平滑展开并激活置顶；
  - 移出自动收起与动画：鼠标离开窗口区域 600ms（或失焦 300ms）后自动平滑缩进隐藏；下拉菜单处于展开操作状态时暂停自动收起，窗口被拖离边缘（> 35px）时自动解除贴边状态。

#### 已知限制

- 构建产物当前未签名、未公证，仅用于内部测试。
- macOS 代码保持编译兼容，但透明窗口、托盘、贴边和睡眠恢复尚未在真实 Mac 上验收。

### English

#### Migration from v1.1.0 to v2.0.0

- The runtime moved from the Windows PowerShell/WPF host to Tauri 2 + Rust + Vue 3. `main` now runs only the Tauri implementation, while `legacy/v1.1.0` and `port-baseline-v1.1.0` preserve the previous release as rollback baselines.
- Existing `servers.json`, SSH config aliases, keys, ssh-agent, ProxyJump, and OS credential behavior remain compatible. Legacy JSON/JSONL history, timezone-less timestamps, and the Windows server configuration shape remain readable.
- The v1.1.0 server-side Agent keeps its inject, status, control, pull, and merge operations. v2.0.0 local real-time collection uses one persistent framed SSH session per server; the two paths are independent.
- New history writes use UTC `Z` timestamps and UTC date files. Users query by local date and charts display local time, so existing records do not require a manual migration.
- v2.0.0 is currently unsigned and unnotarized. Windows 10/11 x64 is the primary acceptance platform; macOS remains compile-compatible but its window and tray behavior still requires physical-device validation.

#### Added

- Completed the Tauri 2 + Vue 3 + TypeScript + Pinia + ECharts desktop application and made `main` the current implementation; `legacy/v1.1.0` and `port-baseline-v1.1.0` remain available as rollback baselines.
- Added a Tauri 2 Rust workspace for protocol/history core logic, system OpenSSH, cross-platform data roots, file locks, and the `keyring` credential abstraction.
- Added the canonical LF-only POSIX sampler, protocol/history golden fixtures, Rust/Vitest tests, and a Windows/macOS CI build matrix.
- Added Tokio collectors, typed snapshot/status events, JSONL history writes, migration preview/apply commands, data-root commands, and tray/manage/history windows.
- Added OpenSSH `Host`/simple `Include` alias discovery, compatibility with the legacy Windows `Servers` config shape, and manager add/remove actions with optional credential saving.

#### Changed

- v2.0.0 targets Windows 10/11 x64 and macOS Intel/Apple Silicon; Linux desktop is out of scope for this release, while the server Agent short-command controls remain available.
- v2.0.0 is unsigned and for internal testing; macOS transparency, tray, edge docking, and sleep/resume remain unverified on physical hardware.
- The Windows Release desktop process now uses the GUI subsystem, and SSH/askpass children use no-console creation flags so the application does not open an extra terminal on startup.
- Added reliable main-window dragging and close controls, SSH config diagnostics/reload, and an explicit passwordless SSH (key or ssh-agent) option in Manage.
- Moved the legacy PowerShell/WPF implementation out of the current runtime path, preserving it on `legacy/v1.1.0` and `port-baseline-v1.1.0`, and built the standalone portable `ServerPulse-Portable.exe`.

#### Fixed

- Unified the visual language between the Main, Manage, and History windows: eliminated inconsistent window padding and background mismatch, applying a cohesive deep obsidian green palette, card borders, status pills, and action buttons.
- Configured Tauri 2 capabilities in `src-tauri/capabilities/default.json` for full window permissions, multi-window events, and IPC calls.
- Hardened SSH config alias and candidate loading: integrated `dirs::home_dir()` Win32 native home resolution, and made store initialization resilient so `~/.ssh/config` aliases are always discovered and displayed.
- Fixed `JSON error: expected value at line 1 column 1` when saving server configs: added transparent UTF-8 BOM (`\u{feff}`) and UTF-16 decoding across config and history parsers, ensuring seamless compatibility with legacy PowerShell `servers.json`.
- Fixed SSH sampling process hanging indefinitely on `connecting`/`rechecking`: added OpenSSH `-T` (no pseudo-terminal) and remote command `sh -s`, stripped carriage returns `\r`, and closed stdin immediately to guarantee fast metric execution.
- Fixed Tauri/Explorer launches resolving SSH aliases to the wrong target by explicitly using the current user's SSH config for `ssh`, `ssh -G`, and Windows host-key probing.
- Fixed the Windows host-key probe argument bug that truncated the target to `0.0.0.5`, while retaining the safe fallback for affected Win32-OpenSSH `sntrup761x25519` builds.
- Completed host-key confirmation and change blocking: unknown hosts require SHA256 fingerprint confirmation, changed fingerprints are blocked, the app-owned `known_hosts` can be forgotten and re-verified, and the user's file remains read-only.
- Completed the session-password security channel: passwords may be saved in the OS credential store or used for the current run only; they exist only in zeroized main-process memory and a one-time askpass channel, never in config, arguments, ordinary environment variables, logs, or history.
- Completed one persistent framed SSH session per server: the remote sampler emits frames, the client parses them continuously, and timeouts/corruption/disconnects reconnect with backoff while non-retryable authentication errors pause only that server with a structured status.
- Completed UTC history storage and local-date querying: new records use `Z` RFC3339 timestamps and UTC date files, local-day queries convert to UTC ranges, and legacy timezone-less records remain readable.
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
- Streamlined server card header metadata and metrics layout: consolidated GPU count and host name into a clean, muted subtitle line under the server name (`server_host · hostname · X GPUs`), focusing the main metric grid into a compact, balanced 2-column CPU and MEM display.
- Decluttered Manage window: removed the redundant monitoring interval setting card from Manage view since cadence can now be configured directly and interactively on the main floating widget.
- Added clear IP address and hostname example hints to the Add Server form: updated field label to `SSH alias / Hostname / IP` and placeholder to `123.23.23.23 / gpu-01`.
- Implemented top, left, and right screen edge docking and auto-hide: integrated locked `savedWorkArea` caching, native `GetCursorPos` global cursor tracking, 8px topmost solid sharp edge handles, 150ms smooth sliding animations, hover-to-reveal with 600ms debounce hide, dropdown interaction protection, and persistent EdgeButton toggle.

#### Known limitations

- Build artifacts are currently unsigned and unnotarized for internal testing only.
- macOS code remains compile-compatible, but transparency, tray, edge docking, and sleep/resume have not been accepted on physical Mac hardware.

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
