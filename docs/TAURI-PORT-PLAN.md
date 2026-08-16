# Server Pulse Tauri 跨平台重写方案

本文档是 `codex/tauri-port` 分支的实施基线。它把现有 Windows PowerShell/WPF 版本重写为同仓库内的 Tauri 2 桌面应用，并明确 Preview 阶段的边界、验收门槛和未验证风险。

## 1. 冻结决策

| 项目 | 决策 |
| --- | --- |
| 开发分支 | `codex/tauri-port` |
| Windows 基线 | 当前 Windows 版创建 `port-baseline-v1.1.0` tag；旧实现由 tag 与 legacy 分支保留 |
| 产品版本 | `Tauri 2.0 Preview`，当前包版本 `2.0.0-preview.1` |
| v1 桌面平台 | Windows 10/11 x64、macOS Intel、macOS Apple Silicon |
| 排除范围 | Linux 桌面端不纳入 v1；服务器端 POSIX Agent 放到 v1.1 |
| v1 闭环 | 实时监控、浮窗/托盘、多窗口、历史查询、数据迁移、安全 SSH |
| 前端 | Vue 3 + TypeScript + npm + Pinia + ECharts |
| 后端 | Rust + Tokio；核心库不依赖 Tauri 或窗口环境 |
| SSH | 系统 OpenSSH，不使用 `russh`；保留 SSH config、密钥、agent、ProxyJump、known_hosts 和别名 |
| 凭据 | Windows Credential Manager / macOS Keychain，通过 `keyring` 抽象；支持保存密码与会话密码，但会话密码通道仍是合并前必补项 |
| 分发 | 未签名、未公证的内部 Preview；不要求 Apple Developer 账号，不面向公开分发 |
| 合并条件 | 核心闭环完成、黄金样例差分测试通过、CI 双平台构建通过；无真实 Mac 时必须保留未验证风险，不宣称完整兼容 |

## 2. 仓库结构

```text
frontend/
├─ src/
│  ├─ stores/                 # Pinia 状态与 Tauri event 订阅
│  ├─ views/                  # 主浮窗、服务器管理、历史窗口
│  ├─ components/             # 服务器卡片等可复用 UI
│  └─ charts/                 # ECharts 配置与历史曲线
└─ package.json

src-tauri/
├─ crates/
│  ├─ serverpulse-core/       # 协议、指标、历史、领域模型、错误/退避
│  ├─ serverpulse-ssh/        # 系统 OpenSSH、askpass、超时、进程清理
│  └─ serverpulse-platform/   # 路径、凭据、锁、原子写入、迁移
└─ src/                       # Tauri command、event、窗口和托盘生命周期

assets/serverpulse-sample.sh  # 唯一 canonical 远端采样脚本，LF-only
tests/fixtures/               # 从旧实现提取的协议/历史黄金样例
```

旧 PowerShell 目录在迁移阶段继续作为行为参考。`main` 合并后只保留 Tauri 实现，但删除旧实现前必须保留基线 tag 和 legacy 分支。

## 3. 分层与数据流

```text
┌───────────────────────────────────────────────────────────┐
│ Vue 3 UI                                                   │
│ Main floating window · Manage · History · Pinia · ECharts  │
└───────────────────────┬───────────────────────────────────┘
                        │ typed invoke / event stream
┌───────────────────────▼───────────────────────────────────┐
│ Tauri shell                                                │
│ commands · server.snapshot · server.status · server.error  │
│ tray · window lifecycle · cancellation                     │
└──────────────┬────────────────────┬───────────────────────┘
               │                    │
┌──────────────▼─────────┐  ┌───────▼───────────────────────┐
│ serverpulse-core        │  │ platform / ssh                │
│ parse · history · error │  │ OpenSSH · keyring · files     │
│ retry · domain models   │  │ lock · root · migration       │
└──────────────┬─────────┘  └──────────────┬────────────────┘
               │                           │
               └──────────────┬────────────┘
                              ▼
                 Linux remote POSIX sampler
```

每台服务器一个 Tokio 长期任务。成功采样产生 snapshot，失败只影响该服务器；任务使用取消/abort、超时和进程组清理，不把一个 SSH 子进程泄漏到应用退出之后。当前 Preview 已完成单服务器垂直链路和 JSONL 单样本落盘；按分钟加权聚合仍是合并前的验收项。

## 4. IPC 契约

Rust `serde` 结构是 IPC 的单一数据源。正式合并前应从 Rust 类型生成 TypeScript 类型，当前 `frontend/src/types.ts` 是同步的 Preview 镜像。

### 命令

```text
list_servers()
inspect_ssh_config()
save_server(server)
delete_server(server_id)
start_monitoring(server, interval_seconds)
stop_monitoring(server_id)
recheck_monitoring(server)
query_history(day)
get_data_root()
validate_data_root(path)
set_data_root(path)
preview_import(source, target?)
apply_import(source, target?, mode)
save_credential(server, password)
delete_credential(server)
open_window(kind)
hide_main_window()
close_main_window()
```

### 事件

事件名称固定为：

- `server.snapshot`
- `server.status`
- `server.error`（最终错误专用事件；Preview 当前把错误放在 status detail 中）

每个事件必须包含 `server_id`、UTC `timestamp`、递增 `sequence` 和可序列化 `payload`。状态事件的错误结构为：

```json
{
  "code": "timeout",
  "messageKey": "error.timeout",
  "retryable": true,
  "detail": "redacted diagnostic"
}
```

`detail` 只能是脱敏诊断信息，不能包含密码、环境变量、命令行、私钥、完整 SSH 输出或历史数据。错误码和文案 key 由 Rust 固定，前端负责本地化。

## 5. Rust 核心接口

核心抽象固定如下，具体实现不得把 Tauri 类型泄漏到 `serverpulse-core`：

```text
SshTransport
├─ resolve_config()
├─ verify_host_key()
├─ connect_stream()
└─ execute_short_command()

CredentialStore
├─ get()
├─ set()
└─ delete()

CollectorManager
├─ start()
├─ stop()
└─ recheck()

HistoryStore
├─ append_minute()
├─ query()
├─ merge()
└─ migrate()

DataRootManager
├─ validate()
├─ resolve()
├─ preview_import()
└─ apply_import()
```

当前实现已经落地 `CredentialStore`、`DataRootManager`、JSONL store、核心解析/错误/退避、旧 Windows `Servers` 配置兼容、SSH config 别名发现/诊断、服务器新增/删除、免密/凭据模式和 OpenSSH short command；`CollectorManager`、完整 `SshTransport` 长连接/指纹接口和深度历史聚合仍需在 M2–M4 收口。

## 6. SSH 与安全边界

### 6.1 连接方式

- 使用系统 `ssh`/`ssh.exe`，默认 `BatchMode=yes`；发现已保存凭据时使用 askpass，密码由 askpass 子进程从 OS keyring 读取。
- 参数只放目标、端口、超时和 OpenSSH 选项；密码不得进入命令行、普通环境变量、配置、日志或历史。
- `SSH_ASKPASS` 只指向当前应用的 askpass 入口，环境中最多传递非秘密 credential identity。
- 使用 LF 版本的 `assets/serverpulse-sample.sh` 通过 stdin 发送远端 shell。
- Windows 使用无控制台的新进程组，Unix 使用 process group，结合超时和取消清理本地 SSH 子进程；Release 桌面进程使用 GUI subsystem，避免启动时弹出终端。

### 6.2 主机指纹

正式合并前必须实现并测试：

1. 读取用户现有 SSH config 与 known_hosts；
2. 首次未知主机展示算法和 SHA256 指纹，用户确认后才写入；
3. 指纹变化严格阻断，禁止自动覆盖；
4. 测试不写入真实用户的 known_hosts，也不使用真实指纹样本。

### 6.3 认证顺序与重试

认证顺序固定为免密 key/agent、已保存密码、当前会话临时密码。网络失败退避为 5 秒、15 秒、30 秒、1 分钟、5 分钟并带抖动；重复失败进入熔断，Recheck 清除熔断。当前代码已实现基础退避和保存凭据 askpass；会话密码安全通道、指纹 UX 和完整长连接仍是合并门槛。

## 7. 存储与迁移

### 7.1 数据根目录

默认目录：

- Windows：`%LOCALAPPDATA%\\ServerPulse\\`
- macOS：`~/Library/Application Support/ServerPulse/`

继续支持 JSON/JSONL 与 version 2 历史协议、损坏末行忽略、UTC 时间戳、原子写入、location pointer、权限检测和跨平台文件锁。自定义数据根目录必须是可写的本地绝对路径；Windows UNC/network path 拒绝。密码、窗口位置和平台相关设置不进入迁移。

### 7.2 Windows → macOS 导入

导入向导必须：

- 让用户选择旧数据根目录；
- 预览文件数、历史范围和服务器数量；
- 默认冲突操作为取消；
- 合并时去重完全相同历史记录，冲突分钟记录保留；
- 对服务器配置冲突要求确认；
- 不导入凭据、窗口位置和平台设置；
- 失败时保留备份并回滚 pointer，不阻塞实时监控。

当前 `serverpulse-platform` 已提供路径验证、pointer、预览、备份、原子复制、JSONL 去重合并、服务器配置读写和旧 Windows `Servers` schema 迁移基础；按分钟有效样本加权、旧 JSON 深度混读、完整 UI 向导和回滚验收仍需补充。

## 8. 前端与窗口

主窗口为透明、无装饰、置顶的监控浮窗；管理窗口和历史窗口使用独立 Tauri Webview 窗口。Pinia 管理服务器列表、snapshot/status、历史查询、数据根目录、主题和语言。ECharts 负责历史曲线、缺口、tooltip 和固定详情。

行为目标是对齐而不是 WPF 像素复制：保留置顶、透明、拖拽、缩放、托盘、贴边收起、主题和语言；允许 Web UI 重新设计布局。Preview 当前已提供主浮窗拖拽/关闭、管理/历史窗口、托盘菜单、状态卡片、SSH config 发现与诊断、服务器新增/删除、免密/凭据选项和基础历史图表；贴边、透明度、主题语言设置、多服务器细节面板和 macOS 窗口行为仍需实机验收。

官方 Tauri 插件仅用于通用文件、对话框、shell 和窗口状态；SSH、凭据、历史和窗口策略继续走最小权限的自定义 Rust command。

## 9. 里程碑与交付物

| 阶段 | 交付物 | 当前状态 |
| --- | --- | --- |
| M0 基线冻结 | 分支、tag、canonical sampler、黄金样例、配置/schema 固定 | 已完成 |
| M1 Rust 核心 | 协议 v1/v2、CSV、缺失/partial、历史 JSON/JSONL、保留/迁移、错误模型、差分测试 | 基础能力已完成；加权聚合与完整差分待补 |
| M2 SSH 垂直闭环 | OpenSSH、指纹、keyring/askpass、长期会话、退避、进程清理、单服务器 event→浮窗 | 基础闭环已完成；SSH config/旧配置读取已补；指纹、会话密码、长连接待补 |
| M3 桌面 UI | 主浮窗、托盘、管理/历史窗口、多服务器、主题语言、ECharts、生命周期 | 主浮窗、管理新增/删除和基础历史 UI 已完成；行为细节待补 |
| M4 迁移稳定性 | 自定义根目录、导入向导、加权合并、异常回退、Windows 10/11 验证 | API 基础已完成；向导和 Windows 实机验收待补 |
| M5 CI/Preview | Rust/Vitest/Playwright、Windows 构建、macOS Intel/ARM 构建、Preview 包 | workflow 已提交；macOS 与完整桌面测试待验证 |
| v1.1 Agent | 保留 POSIX Agent、状态/注入/控制/拉取/合并/游标 | 不阻塞 Preview，但尚未迁移 |

## 10. 测试与验收

### Rust

覆盖协议 v1/v2、CSV 引号/转义、缺失字段、partial/unavailable、CPU/内存/GPU 用户归属、JSON/JSONL 混读、损坏末行、加权聚合、时区、保留策略、永不清理、数据根目录、迁移回滚、SSH 超时/重试/熔断/指纹/密码脱敏和进程组清理。黄金样例必须与旧 PowerShell 输出执行差分测试，允许文档中明确的浮点舍入差异。

### Vue 与桌面

- Vitest：Pinia 事件更新、多服务器状态、历史缺口、用户曲线、主题语言和窗口设置。
- Playwright + `tauri-driver`：主窗口、管理窗口、历史窗口、启动/关闭、隐藏到托盘、窗口切换和关键交互。
- Windows 10/11 x64：原生透明窗口、托盘、退出清理、SSH 子进程清理。
- macOS Intel/Apple Silicon：CI 核心测试和产物生成；没有实机时必须标注透明、托盘、贴边、睡眠恢复为未验证。

## 11. CI、构建与发布

`.github/workflows/tauri-preview.yml` 执行：

1. Windows runner：`npm ci --prefix frontend`、类型检查、Vitest、`cargo test --workspace`；
2. Windows x64：使用 Tauri CLI 构建 NSIS/便携产物；
3. macOS matrix：Intel `x86_64-apple-darwin` 与 Apple Silicon `aarch64-apple-darwin`，生成 DMG/ZIP；
4. 手动触发或 `tauri-v*` tag 上传构建产物；
5. 不配置签名、公证或自动更新器。

Tauri CLI 从仓库根目录解析 sibling `src-tauri`：

```powershell
npm --prefix frontend exec -- tauri build --config src-tauri/tauri.conf.json --ci
```

GitHub-hosted runners 与 `tauri-action` 的具体 runner 架构和配额以 workflow 配置时的官方资料为准：[GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)、[tauri-action](https://github.com/tauri-apps/tauri-action)。

## 12. 固定假设与风险

- 远端服务器仍为 Linux，依赖 POSIX `sh`、`/proc`、`awk`，GPU 监控可选 `nvidia-smi`。
- v1 不包含 Linux 桌面端和服务器 Agent；Agent 不阻塞 Preview 合并，但必须在 v1.1 单独验收。
- 本地历史和配置不做额外加密，沿用现有安全边界；凭据仍只能进 OS credential store。
- v1 不要求 Apple Developer 账号、签名或公证，不面向公开分发。
- 无真实 Mac 实机时，macOS 只能宣称“CI 构建通过”，不能宣称窗口行为完整兼容。
- Tauri CLI、GitHub runner、WebView、keyring 后端和 OpenSSH 版本会随平台变化；CI 固定工具链并把平台差异留在 `serverpulse-platform`。

## 13. 合并前检查清单

- [ ] 核心闭环可从 SSH 采样到浮窗展示，并支持停止、取消和退出清理。
- [ ] 协议/历史黄金样例差分通过，包含坏末行、加权和时区用例。
- [ ] 主机首次指纹确认、变更阻断、保存密码和会话密码均有脱敏测试。
- [ ] 数据根目录导入预览、取消、合并、冲突保留、备份和回滚通过。
- [ ] Windows 10/11 x64 原生窗口/托盘测试通过。
- [ ] CI Windows 构建与 macOS Intel/Apple Silicon 构建通过；macOS 未实机验证风险写入 Preview 文档。
- [ ] `README.md`、`README.zh-CN.md`、`docs/DEVELOPMENT.md` 和本文件保持一致，`CHANGELOG.md` 使用中英双语。
- [ ] `git diff --check`、`git status`、单主题提交和敏感信息扫描通过。
