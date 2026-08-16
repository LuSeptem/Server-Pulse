# Server Pulse

[English](README.md) · 中文说明

Server Pulse 是一个 Windows 原生桌面浮窗，用来实时查看 SSH 服务器的 GPU、显存、CPU 和内存占用。它不是网页应用，不需要浏览器，也不会在本机启动 HTTP 服务。

仓库种子配置默认提供 `3090` 和 `a6000` 两个 SSH 别名。已有的密钥免密登录和 `ssh-agent` 配置可以继续使用，也可以在服务器管理窗口中使用普通账户密码。

当前版本：**v1.1.0** · [中英双语更新说明](CHANGELOG.md)

## Tauri 2.0 Preview

`codex/tauri-port` 分支包含跨平台重写版本。现有 PowerShell/WPF 版本通过 `port-baseline-v1.1.0` 标签保留，新版本在同一仓库中独立开发。Preview 目标为 Windows 10/11 x64 与 macOS Intel/Apple Silicon；Linux 桌面端不纳入 v1。

当前垂直闭环已包含 Vue 3 + TypeScript 监控浮窗、Pinia 事件状态、ECharts 历史页、托盘与次级窗口、Tokio 采集任务、canonical POSIX 采样脚本、JSON/JSONL 存储、数据根目录迁移基础能力、系统 OpenSSH、OpenSSH 配置别名发现与诊断、旧版 Windows 服务器配置兼容、免密/凭据认证选项、重试退避和脱敏错误事件。Preview 未签名，仅用于内部测试。macOS 窗口行为尚未在真实 Mac 上验证，服务器端 Agent 控制属于 v1.1，主机指纹确认和仅本次会话密码交互仍需在合并前补齐。

在仓库根目录执行：

```powershell
npm ci --prefix frontend
npm --prefix frontend run typecheck
npm --prefix frontend run test:unit
npm --prefix frontend run build
cargo test --workspace --manifest-path src-tauri/Cargo.toml
npm --prefix frontend exec -- tauri build --config src-tauri/tauri.conf.json --ci
```

完整范围、里程碑、CI 矩阵、迁移规则和验收门槛见 [`docs/TAURI-PORT-PLAN.md`](docs/TAURI-PORT-PLAN.md)。该分支不应视为稳定公开发行版。

## 功能概览

- 在一个紧凑、可置顶的浮窗中同时查看多台 SSH 服务器。
- 重点显示每张 GPU 的型号、利用率、显存占用和温度。
- 查看 CPU、系统内存和逐卡显存的用户归属；用户明细默认隐藏，悬停预览、单击固定。
- 窗口可以贴到左侧、右侧或顶部自动隐藏，并可调节尺寸、背景透明度和刷新间隔。
- 从托盘恢复、隐藏或退出，不在任务栏重复显示窗口。
- 支持暗色、亮色、跟随系统主题，以及中文、English、跟随系统语言。
- 打开记录窗口查询 CPU、MEM、GPU、显存和温度的分钟级历史曲线。
- 在记录页设置 1–3650 个自然日的保留期限，或选择“永不清理”，并迁移完整的数据根目录。
- 为任意已保存服务器注入常驻的服务器端监控代理，在“管理”中检测状态并控制启停，把服务器端记录合并进本地历史——应用关闭时监控仍持续。它和本地实时采集互不依赖，同一分钟双方都有记录时按有效样本数去重合并。

## 界面预览

以下截图来自 `demo/`，主机地址和用户名已做脱敏处理。

| 暗色主界面 | 亮色主界面 |
| --- | --- |
| ![暗色主界面](demo/dark_main_ui.png) | ![亮色主界面](demo/light_main_ui.png) |

| SSH 服务器管理 | 添加 SSH 服务器 |
| --- | --- |
| ![SSH 服务器管理](demo/manage_servers.png) | ![添加 SSH 服务器](demo/add_server.png) |

| 历史记录 | 历史详情与用户曲线 |
| --- | --- |
| ![历史记录](demo/usage_history.png) | ![历史详情](demo/usage_history_details.png) |

## 快速开始

### 环境要求

- Windows 10/11 x64 或 macOS (Intel / Apple Silicon)。
- 本机可以调用 OpenSSH 客户端 `ssh.exe`（Windows）或 `ssh`（macOS）。
- 远端 Linux 提供 `/proc`、POSIX `sh` 和 `nvidia-smi`。没有 NVIDIA GPU 时，CPU 和内存仍可监控。

### 启动与运行

- **便携版直接运行**：双击根目录的 `ServerPulse.exe`（已编译的独立便携版）。
- **开发模式**：
  ```powershell
  # 启动 Tauri 桌面开发窗口
  npm run tauri dev --prefix frontend
  # 或仅启动前端浏览器预览
  npm run dev --prefix frontend
  ```
- **生产构建**：
  ```powershell
  npm run build --prefix frontend
  cargo build --release --manifest-path src-tauri/Cargo.toml
  ```

首次运行前可以验证现有免密配置：

```powershell
ssh -o BatchMode=yes 3090 hostname
ssh -o BatchMode=yes a6000 hostname
```

命令能返回主机名后，打开“管理”，勾选服务器并点击“验证并应用”。

## SSH 服务器与认证

点击主窗口在线统计右侧的“管理”，或右键托盘图标选择“SSH 服务器”。候选服务器来自数据根目录中的 `servers.json`（兼容旧版 Windows 的 `Servers` / `SshTarget` / `HostName` 格式）、当前用户 `~/.ssh/config` 中不含通配符的 `Host` 及 `Include` 包含文件（通过系统 `ssh -G` 解析用户与端口），以及管理窗口手动添加的服务器。

管理窗口现在提供“添加服务器”、“重新加载”、可点击预填的别名标签，以及“SSH 配置发现候选”列表，支持单键“+ 加入监控”与“全部导入”。页面会显示实际配置路径、已发现别名、候选服务器及读取错误；密码只写入 Windows 凭据管理器，不会写入 `servers.json`。

“监视”复选框决定服务器是否生成实时卡片。缺少认证的服务器保持暂停，不会阻塞其他服务器。

### 固定认证顺序

1. 使用密钥或 `ssh-agent` 的免密 SSH（`BatchMode`）；
2. Windows 凭据管理器中已保存的密码；
3. 仅用于本次运行的密码（规划中；当前 Preview 尚未提供）。

“免密 SSH”选项会使用密钥或 `ssh-agent`，并以 `BatchMode=yes` 连接。只有需要保存密码时才关闭该选项；Preview 暂未提供交互式的“仅本次会话密码”输入框。

Windows 凭据管理器是 Windows 自带的安全存储，不需要安装。Server Pulse 保存的凭据只供本程序使用，普通终端中的 `ssh` 不会读取，也不会修改全局 OpenSSH 或 `SSH_ASKPASS` 配置。

密码框默认不保存密码。只有明确勾选“存入 Windows 凭据管理器”并且验证成功后才会写入凭据。未保存的密码在取消监视或退出程序时清除，不写入服务器配置、日志或历史文件。

首次遇到未知主机时，程序会显示主机密钥算法和 SHA256 指纹，确认后才写入当前用户的 `known_hosts`。指纹变化会严格阻断，不会自动覆盖。

每台服务器维持一个长期 SSH 采集会话，在同一连接中连续输出监控结果。网络断线后按 5 秒、15 秒、30 秒、1 分钟、5 分钟并加入随机抖动进行退避；连续失败会熔断并显示下次重试时间，点击“重新检测”可立即解除暂停，避免每次刷新都建立新连接。

## 主窗口

### 顶栏按钮

- **主题**：亮、暗或跟随系统，默认暗色。
- **语言**：中文、English 或跟随系统，当前默认中文。
- **透明度**：只改变背景透明度，文字、状态灯和进度条保持清晰。
- **置顶**：向上箭头按钮切换始终置顶。
- **贴边**：抵边箭头按钮启用左、右、顶部贴边隐藏。
- **刷新**：输入 `1`–`300` 秒，按 Enter 或移开焦点生效。
- **记录**：打开历史记录窗口。
- **管理**：打开 SSH 服务器管理窗口。
- **关闭（×）**：关闭主窗口；顶栏空白区域可拖动，按钮区域不会触发拖动。

### 移动、贴边和托盘

- 拖动顶栏空白处移动窗口。
- 拖动右下角点阵手柄调整大小，最小尺寸约为 340 × 300。
- 拖到左、右或顶部边缘后，短暂延迟后收起为窄条。
- 先把鼠标移开边缘，再次触碰对应边缘即可恢复；鼠标停留在展开的窗口内部时不会收起，只有离开整个窗口才会重新计时。
- `—` 隐藏到托盘，`×` 退出。托盘左键恢复，右键提供显示、隐藏和退出。

## 指标与用户明细

- **CPU**：整台服务器 CPU 百分比。
- **MEM**：百分比以及已用/总内存，例如 `73% · 92.2/125.5 GB`。
- **GPU**：每张卡显示型号、利用率、显存已用/总量和温度。

把鼠标移到 CPU、MEM 或单卡显存数值/进度条上可预览用户占用。单击固定，再次单击同一指标、点击空白处或按 `Esc` 关闭；点击另一个指标会直接替换。默认显示当前占用最高的前 8 名，系统/未归属始终单列在末尾。

用户归属状态可能是“正常”“部分可用”或“不可用”。权限不足会明确显示，不能伪装成零占用。

## 记录、曲线与保存机制

点击醒目的“记录”按钮，默认打开最近 1 小时。开始和结束时间可以分别输入年、月、日、时、分；无效或越界值会立即以红框和红色 `!` 标记。

记录窗口支持：

- GPU、VRAM、温度曲线分别显示或隐藏；
- 按分钟定位，浮窗显示完整时间和同一分钟的全部指标；
- 单击曲线固定浮窗，双击解除固定；
- 每张图最多 3 条用户曲线，颜色稳定且可移除；
- 缺失分钟保持断线，不把缺口前后的点直接相连；
- 同一天混合读取旧版 JSON 和新版追加式 JSONL。

窗口会立即出现，首次查询在窗口显示后以后台优先级执行。查询只解析所选时间段内的分钟记录，而不是全天文件，因此打开记录页和切换时间段都保持流畅，即使保留期很长也是如此。

### 本地历史目录

历史只保存在当前 Windows 用户本机。默认数据根目录为 `%LOCALAPPDATA%\\ServerPulse\\`。第一次打开记录页会要求明确保存策略，默认预选 7 天。查询范围没有单独的最大跨度，早于保留范围时只显示“所选时间段暂无记录”。

```text
%LOCALAPPDATA%\\ServerPulse\\
├─ settings.json           # 界面、刷新和保留策略
├─ servers.json            # 服务器列表，不含密码
├─ error.log               # 本地错误摘要
└─ history\\
   ├─ yyyy-MM-dd.v2.jsonl  # 新格式：一行一个分钟记录，追加写入
   └─ yyyy-MM-dd.json      # 旧格式：继续兼容读取
```

规则如下：

- 新记录追加到 `yyyy-MM-dd.v2.jsonl`；保留时长按自然日计算，允许 1–3650 天；“永不清理”跳过自动删除。
- 损坏或越界的设置会安全回到未配置状态，下次打开记录页时要求重新确认，不会阻止主窗口启动。
- 保存记录设置会同时应用保留天数、永不清理和清理暂停状态；输入错误留在弹窗中，不影响监控。
- 旧 JSON 和新 JSONL 可以混合查询，旧文件不迁移、不删除。
- 同一分钟重复记录按有效样本数加权合并；用户在可用采样中缺席按零计算；不可用采样不进入分母；旧版记录缺少用户字段时曲线断线而不是补零。
- 自动清理同时处理 `.json` 和 `.v2.jsonl`；删除 `history` 只清空记录，不影响界面设置和服务器配置。
- 文件保存 UID、用户名和分钟聚合值，不保存 PID、进程名、命令行或密码。

历史可能包含敏感运维信息，请勿把 `%LOCALAPPDATA%\\ServerPulse\\history` 或真实的 `servers.json` 上传到公开仓库。

### 数据目录设置、迁移与回退

“记录设置”中的路径是完整数据根目录，不是只有 `history` 子目录。支持 `%LOCALAPPDATA%` 等环境变量，只接受本机绝对路径，不接受相对路径或 UNC 网络路径；保存前自动创建目录并测试读写权限。

修改路径会先刷新当前分钟记录、暂停历史写入并显示迁移摘要。目标存在同名文件时可选择覆盖、自动合并或取消，默认取消；覆盖会先备份目标，自动合并会去除完全相同的 JSON/JSONL 记录、保留冲突分钟记录并追加 `error.log`。迁移成功后旧目录改名为带时间戳的备份，并原子更新：

```text
%LOCALAPPDATA%\\ServerPulse.location.json
```

指针文件只保存首选/活动数据根目录和待同步状态，不保存密码。Windows 凭据管理器中的密码不会迁移。首选目录被删除或失去权限时，本次运行会明确回退到默认目录并提示重新选择，不会静默切换到未知目录。

## 服务器端监控

对已保存的服务器可以注入一个常驻采集代理：即使应用关闭、笔记本休眠或网络断开，它仍在服务器端持续采样记录。代理以你的登录用户身份运行（无 root、无 systemd、不改 crontab），记录保存在 `~/.serverpulse/`：

```text
~/.serverpulse/
├─ agent.sh               # 自包含 POSIX sh 代理（由应用生成）
├─ config                 # 采样间隔、保留天数、服务器身份
├─ state/                 # pid 与心跳文件，用于状态检测
├─ records/yyyy-MM-dd.v2.jsonl  # 分钟记录，与本地历史同格式（UTC 时间戳）
└─ agent.log              # 代理输出
```

打开“管理”，使用每台服务器下方的“服务器端监控”行：

- **状态徽标**：运行中、卡顿（进程在但心跳过期）、已停止、未注入、未知。
- **注入**：写入代理并以脱离 SSH 会话的方式启动；应用退出或连接断开后继续运行。已在运行时再次注入为无操作。
- **停止**：发送 TERM（宽限后 KILL 兜底）；**重启**重写并重新启动；**卸载**停止代理并删除 `~/.serverpulse`（含全部服务器端记录——如还需要请先合并）。
- **配置**：设置采样间隔（1–3600 秒）、服务器端保留天数（1–3650），以及应用启动时是否自动恢复已停止的代理。
- **合并记录**：拉取服务器端记录，把 UTC 分钟换算成本地时区后并入本地历史。同一分钟双方都有记录时，有效样本数多者胜，平局保留本地；增量游标避免重复拉取已合并的分钟；**合并全部**对所有已配置服务器执行。合并对话框还可选择合并后删除服务器端已合并记录（默认不删；代理自身按配置的保留天数自动清理旧记录）。
- 记录页设置面板提供“启动时自动合并服务器端记录”开关（默认关闭）。

注意事项与限制：

- 代理写入 UTC 分钟时间戳，合并时换算为你的本地时区，服务器与电脑时区不同也能正确对齐。
- 服务器重启会使代理停止（普通用户进程），徽标显示“已停止”；可手动重新注入，或在“配置”中开启启动时自动恢复。
- 记录内容与本地历史一致：UID、用户名、分钟聚合，绝不包含 PID、进程名、命令行或密码。
- 服务器需要 POSIX `sh`、`awk`、`/proc`，可选 `nvidia-smi`——与实时监控要求相同。

## 本地配置目录

```text
%LOCALAPPDATA%\\ServerPulse\\
├─ settings.json       # 主题、语言、位置、尺寸、刷新和保留策略
├─ servers.json        # 当前服务器列表，不含密码
├─ history\\            # 分钟历史
└─ error.log           # UI/历史异常摘要
```

持久密码由 Windows 凭据管理器按规范化的 `用户名@主机:端口` 保存，不写入上述 JSON。仓库中的 `config/servers.json` 只是首次运行种子配置，不保存密码。

## 仓库目录

```text
server_monitoring/
├─ ServerPulse.exe          # 可直接运行的 Windows 宿主
├─ ServerPulse.ps1          # 主窗口入口
├─ Start Server Pulse.vbs   # 兼容启动器
├─ assets/                  # SVG/ICO 图标
├─ config/                  # 首次运行种子配置
├─ scripts/                 # 构建脚本
├─ src/                     # 采集、历史、存储、SSH、主题和宿主源码
├─ frontend/                # Vue 3 + TypeScript Preview 界面
├─ src-tauri/               # Tauri 宿主与平台无关 Rust crate
├─ assets/serverpulse-sample.sh # canonical、仅 LF 的远端采样脚本
├─ tests/fixtures/           # 协议与历史黄金样例
├─ tests/                   # 自动化测试和模拟 SSH
├─ docs/DEVELOPMENT.md      # 开发者文档
├─ docs/TAURI-PORT-PLAN.md  # Tauri 跨平台移植方案
├─ CHANGELOG.md             # 中英双语版本历史和发布说明
├─ README.md                # 英文说明书
└─ README.zh-CN.md         # 中文说明书
```

## 常见问题

**服务器离线怎么办？** 运行 `ssh -o BatchMode=yes <别名> hostname`，检查别名、密钥、VPN、跳板机和主机指纹。一个服务器失败不会阻塞其他服务器。

**GPU 数量为 0？** 在远端执行 `nvidia-smi`；CPU 和内存不依赖 NVIDIA 工具。

**用户明细部分可用？** 远端 `/proc` 或 NVIDIA 进程查询可能受权限限制，或者进程在两个采样之间退出。整机指标仍会保留，并明确标记归属状态。

**保存的密码会被终端 ssh 使用吗？** 不会。它只供 Server Pulse 使用，终端 `ssh` 仍按自己的密钥、agent 或手动密码流程工作。

**窗口找不到了？** 触碰启用的贴边位置或点击托盘图标；若位置不可用，删除 `%LOCALAPPDATA%\\ServerPulse\\settings.json` 恢复默认位置。

**启动 Preview 时为什么有终端窗口？** 请从资源管理器或快捷方式启动生成的 `serverpulse-tauri.exe`；Release 版本使用 GUI 子系统，不会主动创建控制台。如果从 Windows Terminal 中输入命令启动，父终端按设计会继续保持打开。

**SSH aliases 没有显示怎么办？** 打开“管理”并点击“重新加载”，检查页面显示的配置路径、已发现别名和读取错误。Preview 会读取 `~/.ssh/config` 及简单 `Include` 文件中的具体 `Host`，只含通配符的条目会被跳过。

**如何报告问题？** 请附版本、Windows 版本、EXE/脚本模式、复现步骤和脱敏后的 `error.log`。不要上传历史目录、密码、私钥、真实主机地址或用户列表。

## 开发者文档

架构、采集协议、历史格式、构建、测试、安全边界和发布检查清单位于 [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md)。普通用户只需要阅读本文。

跨平台移植（Tauri）的规划见 [`docs/TAURI-PORT-PLAN.md`](docs/TAURI-PORT-PLAN.md)。

本地协作说明文件 `AGENTS.md` 仅保留在本地版本控制之外，不会包含在公开源码快照中。

## 许可证

本项目采用 MIT 许可证，完整文本请参阅 [`LICENSE`](LICENSE)。
