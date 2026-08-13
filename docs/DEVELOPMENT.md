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
| `src/ServerPulse.ServerManager.ps1` | 服务器发现、认证验证、密码和管理窗口 |
| `src/ServerPulse.History.ps1` | 分钟聚合、JSON/JSONL 混读、历史曲线和用户曲线 |
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

## 5. 历史存储与查询

新格式为 `%LOCALAPPDATA%\ServerPulse\history\yyyy-MM-dd.v2.jsonl`，一行一个版本 2 的分钟记录，采用追加写入。读取器同时兼容旧版 `yyyy-MM-dd.json`，同一天允许新旧格式混合。

分钟聚合规则：

- 只对资源可用的采样计算平均；`unavailable` 不进入该资源分母。
- 用户在可用采样中缺席按零计算，避免只平均“出现过”的样本而夸大短时进程。
- 同一分钟因重启产生多行时按有效样本数加权合并。
- 旧版记录没有用户字段时，用户曲线断线，不补零。
- 文件末尾的损坏/不完整 JSONL 行被忽略，并累计 `ReadErrors`，此前记录仍可查询。
- 保留期由 `historyRetentionDays` 控制，默认 30 天；清理同时处理 `.json` 和 `.jsonl`。

记录只保存分钟聚合资源、UID 和用户名，不保存进程详情。历史 UI 以 `serverId + gpuIndex` 复用图表锚点，避免刷新时固定弹窗失联；曲线断点必须真实反映缺失分钟。

## 6. SSH、凭据与主机密钥

服务器配置候选来自 `config/servers.json`、当前用户 SSH config 和运行时 `%LOCALAPPDATA%\ServerPulse\servers.json`。仓库配置只作为首次导入种子。服务器 ID 变更策略、历史继承和凭据键逻辑在 `ServerPulse.Ssh.ps1` 中集中处理。

凭据规范化键为解析后的 `username@hostname:port`，同一身份的多个 SSH 别名共享 Generic Credential。保存密码使用 Windows Credential Manager；会话密码通过标准输入和当前用户 SID 限定的一次性命名管道交给 ASKPASS 辅助程序。密码不进命令行、环境变量、配置、日志或历史。

主机密钥验证使用隔离临时 `known_hosts`。首次未知主机必须展示算法和 SHA256 指纹并经用户确认；已知指纹变化严格阻断，禁止自动覆盖真实 `known_hosts`。

认证失败只暂停该服务器并发一次托盘通知；网络错误和超时仍按退避策略重试。实现或测试中不得向真实服务器写入密码、修改全局 SSH 配置或使用真实主机指纹样本。

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

测试覆盖：旧/新采集协议、CPU jiffies 差分、PID 复用、RSS 重复、逐卡显存映射、历史混读和加权、损坏末行、认证状态、凭据键、主题/语言、WPF 事件生命周期、图表固定、贴边和内存缓存。

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
