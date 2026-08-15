# Server Pulse 开发文档

本文面向贡献者、维护者和打包人员。普通用户请先阅读仓库根目录的 [`README.md`](../README.md)。

## 1. 设计目标与边界

Server Pulse 是一个原生 Windows WPF 应用，不包含 Web 服务、浏览器前端或 Node.js 运行时。它通过系统 OpenSSH 客户端连接远端 Linux，并把按用户聚合后的 GPU、CPU、内存数据交给 WPF 界面。

实现时应保持以下边界：

- 不使用 `sudo`，不安装远端软件，不修改全局 OpenSSH 设置。
- 不把密码放进命令行、环境变量、服务器配置、日志或历史文件。
- 远端只输出 UID 聚合结果，不输出 PID、进程名或命令行。
- 单台服务器的认证、网络错误或权限问题不能拖垮其他服务器和主 UI。
- UI 回调不能依赖 PowerShell 动态局部变量；状态必须放在控件的 `Tag`、`DataContext` 或窗口资源中。

## 2. 运行时架构

```text
ServerPulse.exe
└─ 进程内 Windows PowerShell / WPF
   ├─ 主窗口与托盘
   ├─ 服务器管理窗口
   ├─ 历史窗口与曲线渲染
   └─ 长期采集 Worker（Runspace Pool）
      ├─ 服务器 A：长期 SSH 会话
      └─ 服务器 B：长期 SSH 会话
```

`src/ServerPulse.Host.cs` 是无控制台宿主。它设置固定的 `Public.ServerPulse.Desktop` AppUserModelID，把 PowerShell/WPF 脚本加载到当前进程，并使用 Windows Job Object 让退出时的后代进程一并清理。宿主源码变更后需要重新构建根目录的 `ServerPulse.exe`。

长期采集器只在启动时建立一次。每台服务器有独立会话，远端在同一 SSH 连接中循环输出带边界的采样帧；刷新间隔只决定 UI 取用和历史写入节奏，不再每轮重新建立连接。断线采用 `5s → 15s → 30s → 1m → 5m` 退避并加入抖动，连续失败进入熔断；“重新检测”会立即清除退避和熔断。

## 3. 源码布局

| 路径 | 责任 |
| --- | --- |
| `ServerPulse.ps1` | 主窗口、托盘、贴边、主题/语言入口、刷新调度 |
| `src/Collect-Metrics.ps1` | 长期采集 Worker、Runspace Pool、诊断入口 |
| `src/ServerPulse.Persistent.ps1` | 长期 SSH 会话、帧读取、退避和熔断 |
| `src/ServerPulse.Core.ps1` | 配置校验、指标解析、GPU 型号格式化、协议对象 |
| `src/ServerPulse.Ssh.ps1` | SSH 目标解析、凭据键、主机指纹和 ASKPASS 通道 |
| `src/ServerPulse.ServerManager.ps1` | 服务器发现、认证验证、密码、服务器端监控行和管理窗口 |
| `src/ServerPulse.Agent.ps1` | 服务器端代理脚本生成、状态/控制、agent-state 与合并引擎 |
| `src/ServerPulse.Sample.ps1` | 共享远端采样脚本（本地采集器与服务器端代理共用） |
| `src/ServerPulse.History.ps1` | 分钟聚合、JSON/JSONL 混读、历史曲线和用户曲线 |
| `src/ServerPulse.Storage.ps1` | 数据根目录指针、保留策略、路径校验、清理决策和迁移事务 |
| `src/ServerPulse.Theme.ps1` | 亮/暗/系统主题和可复用画刷缓存 |
| `src/ServerPulse.Localization.ps1` | 中文、英文和系统语言资源 |
| `src/ServerPulse.Host.cs` | 原生 EXE 宿主、AppUserModelID、Job Object |
| `scripts/Build-ServerPulseHost.ps1` | 使用系统 C# 编译器构建 EXE |
| `tests/ServerPulse.Tests.ps1` | 解析、持久化、认证、WPF 事件和安全边界测试 |

所有 PowerShell 源码使用 UTF-8 BOM，以兼容 Windows PowerShell 5.1 的中文脚本读取。

## 4. 采集模型与协议

### 4.1 CPU、内存和 GPU 归属

远端采集在同一 POSIX shell 中完成：

1. 读取两次 `/proc` 快照，中间等待 0.2 秒；进程键为 `PID + starttime`，避免 PID 复用误归属。
2. 用两次 `/proc/stat` 的中点计算整机 CPU 和 UID CPU 增量。CPU 百分比归一化为整台服务器的 0–100%。
3. 第二次快照读取进程 RSS，以数字 UID 聚合；用户名只在采样结束后通过一次 `getent passwd`（必要时回退 `/etc/passwd`）映射。
4. 用一次 `nvidia-smi --query-compute-apps=gpu_uuid,pid,used_gpu_memory` 将 PID 映射到 UID，再按物理 GPU UUID 聚合显存。

采集器不尝试把 GPU 利用率、温度、功耗或风扇拆到用户。短时进程、权限不足、驱动保留显存和共享 RSS 会形成差额或重叠，必须通过状态字段表达，不能静默改成零。

### 4.2 输出对象

`ServerPulse.Core.ps1` 将远端文本解析为兼容旧版的对象，并新增：

```text
Cpu.UserUsage = {
  Status, Users[{Uid, Name, Percent}],
  AttributedPercent, UnattributedPercent, OverlapPercent,
  SkippedProcesses
}

Memory.UserUsage = {
  Status, Users[{Uid, Name, UsedMiB, Percent}],
  AttributedMiB, UnattributedMiB, OverlapMiB,
  SkippedProcesses
}

Gpu.UserMemory = {
  Status, Users[{Uid, Name, UsedMiB, Percent}],
  AttributedMiB, UnattributedMiB, UnmappedProcesses
}
```

状态为 `ok`、`partial` 或 `unavailable`。协议缺少用户段时按旧版数据处理，用户归属标记为不可用而不是空占用。

## 5. 历史存储、数据根目录与查询

默认数据根目录为 `%LOCALAPPDATA%\ServerPulse\`，目录结构固定为：

```text
settings.json
servers.json
error.log
history\yyyy-MM-dd.v2.jsonl
history\yyyy-MM-dd.json
```

默认首次配置为 7 个自然日。记录页没有独立的查询最大跨度；查询早于保留截止日期时返回空结果。设置对象新增：

```text
HistoryRetentionDays       # 1–3650；永不清理时保留最后一次有效值
HistoryNeverCleanup        # true 时跳过自动删除
HistoryLastRetentionDays   # 取消永不清理时恢复
HistoryStorageConfigured   # 首次配置确认后为 true
CleanupPaused              # “不清理”动作留下的暂停状态
CleanupOnStartup           # “下次启动清理”一次性标记
```

`%LOCALAPPDATA%\ServerPulse.location.json` 是数据根目录之外的原子指针文件，只保存首选/活动路径和待同步状态，不保存密码、历史或用户指标。启动时先测试默认目录，再测试首选目录；首选目录删除、断盘或无权限时只回退到默认目录并标记 `PendingSync`，不会静默选择其他路径。

新格式为 `history\yyyy-MM-dd.v2.jsonl`，一行一个版本 2 的分钟记录，采用追加写入。读取器同时兼容旧版 `yyyy-MM-dd.json`，同一天允许新旧格式混合。

读取性能：查询先按分钟窗口对 JSONL 行做字符串预过滤（`"Timestamp":"yyyy-MM-ddTHH:mm"` 前缀的序数比较），只解析窗口内的行，并拼接为单个 JSON 数组一次性 `ConvertFrom-Json`，避免为窄查询逐行解析全天文件；批量解析失败时退回逐行解析，保留“忽略损坏末行”语义（PS 5.1 数组输出带 NoEnumerate 标记，需先赋值再展开）。记录页首次查询在窗口显示后以后台优先级异步执行，避免阻塞窗口出现。

分钟聚合规则：

- 只对资源可用的采样计算平均；`unavailable` 不进入该资源分母。
- 用户在可用采样中缺席按零计算，避免只平均“出现过”的样本而夸大短时进程。
- 同一分钟因重启产生多行时按有效样本数加权合并。
- 旧版记录没有用户字段时，用户曲线断线，不补零。
- 文件末尾的损坏/不完整 JSONL 行被忽略，并累计 `ReadErrors`，此前记录仍可查询。
- `settings.json` 中保留策略损坏时启动阶段回到未配置状态，由记录页重新确认，不能阻断主窗口。
- 清理由 `1–3650` 个自然日控制，同时处理 `.json` 和 `.v2.jsonl`。保留缩短时由用户选择立即清理、下次启动清理或暂停自动清理；“下次启动清理”消费一次后立即持久化清除，“永不清理”跳过所有删除。

记录只保存分钟聚合资源、UID 和用户名，不保存进程详情。历史 UI 以 `serverId + gpuIndex` 复用图表锚点，避免刷新时固定弹窗失联；曲线断点必须真实反映缺失分钟。

### 5.1 迁移事务

路径变更先刷新当前分钟、暂停新的历史写入并生成源/目标/文件数/估算大小摘要。目标冲突策略为 `Overwrite`、`Merge`、`Cancel`，默认取消：

- `settings.json`、`servers.json` 以当前源为权威，覆盖前先备份目标；
- `error.log` 在合并模式追加；
- JSON/JSONL 历史去除完全相同记录，内容冲突的同一分钟记录保留；
- 成功后源目录重命名为带时间戳的备份，再原子更新 location 指针；
- 任意步骤失败时源目录保持可用，目标冲突备份用于回滚。

Windows 凭据管理器属于操作系统安全存储，不在迁移范围内；规范化凭据键保持不变。迁移完成后重新绑定记录器、服务器列表和 ASKPASS 辅助目录，并按原查询范围重绘曲线。

## 6. SSH、凭据与主机密钥

服务器配置候选来自 `config/servers.json`、当前用户 SSH config 和运行时 `%LOCALAPPDATA%\ServerPulse\servers.json`。仓库配置只作为首次导入种子。服务器 ID 变更策略、历史继承和凭据键逻辑在 `ServerPulse.Ssh.ps1` 中集中处理。

凭据规范化键为解析后的 `username@hostname:port`，同一身份的多个 SSH 别名共享 Generic Credential。保存密码使用 Windows Credential Manager；会话密码通过标准输入和当前用户 SID 限定的一次性命名管道交给 ASKPASS 辅助程序。密码不进命令行、环境变量、配置、日志或历史。

主机密钥验证使用隔离临时 `known_hosts`。首次未知主机必须展示算法和 SHA256 指纹并经用户确认；已知指纹变化严格阻断，禁止自动覆盖真实 `known_hosts`。

认证失败只暂停该服务器并发一次托盘通知；网络错误和超时仍按退避策略重试。实现或测试中不得向真实服务器写入密码、修改全局 SSH 配置或使用真实主机指纹样本。

## 6.1 服务器端监控代理（Server Pulse Agent）

`src/ServerPulse.Agent.ps1` 提供服务器端常驻监控：注入、状态检测、控制和合并。采样脚本本体收敛在 `src/ServerPulse.Sample.ps1`，本地采集器与代理共用同一份文本，保证字段兼容。

### 服务器端布局与生命周期

远端 `sh` 拒绝 CRLF 脚本。Windows 工作区在 `core.autocrlf=true` 的检出下会把 here-string 内容转成 CRLF，因此所有发给远端 shell 的文本（采样脚本、循环脚本、代理脚本、控制命令）必须在边界经 `ConvertTo-ServerPulseShText` 归一化为 LF——该规则对新增的 sh 生成代码是强制的，测试中有无 `\r` 断言。

```text
~/.serverpulse/            # umask 077，由注入命令创建
├─ agent.sh                # 自包含 POSIX sh 代理（cat 写入，heredoc 分隔符唯一）
├─ config                  # interval / retention_days / server_id / server_label / server_host
├─ state/pid               # 代理启动时写入 $$，停止时删除
├─ state/heartbeat         # 每轮循环 touch，状态检测用
├─ records/yyyy-MM-dd.v2.jsonl   # 分钟记录，UTC 时间戳，与本地 JSONL 同 schema
└─ agent.log               # 启动时 nohup 重定向
```

注入用 `cat` + 带引号的 heredoc 写入脚本，再以 `nohup setsid sh agent.sh >>agent.log 2>&1 </dev/null &` 脱离会话启动；`setsid` 不可用时回退 `nohup`（`-T` 无 TTY 场景）。无 root、无 systemd、无 crontab：服务器重启后代理必然停止，由本地状态徽标如实显示，用户手动重新注入或开启启动时自动恢复。

### 代理主循环与 awk 聚合

代理每轮：重读 `config`（改间隔/保留天数无需重启）→ 子 shell 运行内嵌采样脚本并追加到 `state/samples-<UTC分钟>` → UTC 分钟变化时对上一分钟文件运行一次内嵌 awk 聚合，追加一条 JSONL 到 `records/<UTC日期>.v2.jsonl` → touch 心跳 → 按保留天数清理旧文件 → sleep。TERM/INT 陷阱先聚合当前分钟再删除 pid 退出。

awk 聚合器与本地 `ConvertTo-HistoryMinuteRecord` 语义对齐：CPU/MEM/负载/GPU 逐值平均（缺失值不进分母）、用户归因按有效样本数平均（缺席样本计 0、`unavailable` 排除分母）、Hostname/Uptime 取最后值、GPU 按 Index 输出并带 UserMemory 合并；JSON 输出转义 `"` `\` 与控制字符。awk 程序以内嵌单引号字符串写入 agent.sh，因此聚合器本身**不得包含单引号**（有专门断言）。时间戳一律 UTC，合并时换算本地时区，避免服务器与电脑时区/夏令时错位。数值舍入与本地 `[Math]::Round(,2)` 存在 0.005 级差异，属可接受偏差。

### 状态检测与控制协议

单次短连接执行一段 `sh` 脚本，输出 `SP_AGENT_*` 键值行由 `ConvertFrom-ServerPulseAgentOutput` 解析：

- 状态：`SP_AGENT_INSTALLED`、`SP_AGENT_STATUS`（running/stopped）、`SP_AGENT_PID`、`SP_AGENT_HB_AGE`。本地按 `心跳年龄 > 3×间隔+30s` 判定 `stale`；连接失败归为 `error`。
- 控制：`inject`（幂等，已运行返回 `already_running`）、`stop`（TERM → 10s 宽限 → KILL，删除 pid）、`restart`（stop+inject）、`update-config`（重写 config，代理下轮生效）、`uninstall`（stop + `rm -rf ~/.serverpulse`）。结果行 `SP_AGENT_RESULT`。

所有操作走现有认证链（BatchMode → 凭据管理器 → 会话密码），短连接、带超时；UI 在后台 runspace 执行并用 DispatcherTimer 轮询，避免阻塞管理窗口。

### 本地状态与合并

`agent-state.json`（数据根目录，Version=1）保存每台服务器的间隔、保留天数、启动自动恢复、合并游标（`MergeCursorUtc`，UTC 分钟）、最近状态与最近合并摘要。`servers.json` 保持原 schema 不变。

合并流程（`Merge-ServerPulseAgentRecords`）：

1. 拉取：单次连接按游标日期过滤 `cat` 全部 `records/*.v2.jsonl`，行间以 `__SP_FILE__<日期>` 分隔。
2. 解析：`ConvertFrom-ServerPulseAgentPull` 处理 Windows PowerShell 5.1 `ConvertFrom-Json` 把 ISO 时间戳转成 `[datetime]` 的行为，按已知服务器 ID 过滤、按游标跳过、统计损坏/未知行。
3. 落盘：UTC → 本地分钟；对每个本地日文件按（分钟, 服务器 ID）合并——本地无该分钟则追加新行，已有分钟则并入服务器条目；双方都有时 `Resolve-ServerPulseAgentConflict` 取有效样本多者、平局保留本地。日文件以 temp + `[IO.File]::Replace` 原子重写。
4. 并发：分钟 flush 追加与合并重写通过 `Storage.ps1` 的命名互斥量（`Local\ServerPulse.HistoryWrite`）串行化，跨 runspace/进程生效。
5. 可选清理：`CleanMerged` 删除游标已完整覆盖的旧日期文件，保留当天文件。

### 启动任务

窗口加载 3 秒后启动一次性后台任务：按 `agent-state.json` 对开启自动恢复且状态为 stopped/not_installed 的服务器重新注入；若开启“启动时自动合并”则逐服务器增量合并。错误写入 `error.log`，不阻塞主流程。

### 测试

单元/集成测试在 `tests/ServerPulse.Tests.ps1` 末尾用 mock 的 `Invoke-ServerPulseServerConnection` 覆盖：脚本生成（间隔/保留注入、标签消毒、awk 无单引号）、三态状态、控制操作、UTC→本地换算、拉取解析统计与游标、冲突规则、合并落盘与增量游标、状态文件往返、启动任务、合并后清理、UTF-8 BOM。代理 awk 的逐字段一致性建议在真实 Linux 主机上人工验证（采样脚本与本地采集器共用，输入同构）。

跨 runspace 传递**数组**参数（如合并的已知服务器 ID 集合）必须用真实的 `string[]` 参数直传，不要经 `ConvertTo-Json`/`ConvertFrom-Json` 往返：Windows PowerShell 5.1 会把数组 JSON 包裹成 `count=1` 的嵌套数组，`-notin` 会拒绝全部元素（表现为"拉取 N 行、未知 N 行"且零合并）。

## 7. 主题、语言和 WPF 事件

主题模式 `dark`、`light`、`system` 和语言模式 `zh`、`en`、`system` 都由设置模块规范化。切换只重绘已有视觉树，不在每轮刷新创建不可回收的画刷；动态画刷必须通过主题缓存按源颜色、透明度和语义键复用。

WPF 事件注册应使用独立函数，并从 `sender` 的 `Tag`、`DataContext` 或 `Resources` 读取状态。管理窗口、记录窗口和用户弹层必须显式设置 owner、置顶和关闭行为，避免临时窗口隐身后阻塞主窗口。

历史悬停浮窗的未锁定状态应穿透鼠标，以便继续查看其覆盖下的曲线；锁定后才恢复交互。浮窗位置必须避开当前卡片和滚动区域，必要时提升所属图表的 Z 顺序。

## 8. 构建、测试和诊断

### 构建宿主

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-ServerPulseHost.ps1
```

构建脚本使用 Windows 自带的 .NET Framework `csc.exe`、PowerShell 程序集和 `assets/server-pulse.ico`。构建前退出正在运行的 EXE，避免文件被锁定。

### 核心测试

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\ServerPulse.Tests.ps1
```

测试覆盖：旧/新采集协议、CPU jiffies 差分、PID 复用、RSS 重复、逐卡显存映射、历史混读和加权、损坏末行、认证状态、凭据键、主题/语言、WPF 事件生命周期、图表固定、贴边和内存缓存，以及保留天数边界、永不清理/暂停、自然日截止、location 指针、环境变量路径、数据根目录迁移、源目录备份和 JSONL 清理。

### 冒烟测试

```powershell
.\ServerPulse.exe --smoke-test
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ServerPulse.ps1 -SmokeTest
```

冒烟测试会使用模拟或已配置的 SSH 采集，并验证 EXE 宿主、WPF 窗口、托盘、主题、语言、历史、管理窗口和任务栏归属。不要在未经确认的环境中执行会修改真实 `known_hosts` 的测试。

### 推荐检查

```powershell
git diff --check
git status --short
```

修改 PowerShell 后应在 Windows PowerShell 5.1 和 PowerShell 7 各运行一次测试，并检查 UTF-8 BOM、AST 解析和构建产物的版本资源。

## 9. 发布前检查清单

- README 的用户可见行为与实际版本一致，技术细节同步到本文。
- 源码、测试、配置、历史样例、日志和二进制资源不含真实用户名、邮箱、IP、密码、私钥或本地路径。
- `ServerPulse.exe` 已由当前宿主源码重新构建，图标、AppUserModelID 和版本资源正确。
- Windows PowerShell 5.1、PowerShell 7、AST、BOM、核心测试、EXE 冒烟和 `git diff --check` 全部通过。
- 发布包不包含 `%LOCALAPPDATA%\ServerPulse` 下的个人设置、凭据、历史或错误日志。
- Git 历史和待推送对象已完成敏感信息扫描；发现误提交时先重写历史再发布。

## 10. 贡献约定

保持单一主题提交；每次代码、配置或文档修改都同步更新 README，运行与改动匹配的测试，检查 diff 和工作区后再提交。提交信息应说明改动目的，不要把生成的用户数据或本机路径加入仓库。
