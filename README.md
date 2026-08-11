# Server Pulse

Server Pulse 是一个原生 Windows WPF 监控浮窗，直接通过本机 `ssh.exe` 读取计算服务器的 GPU、CPU 和内存状态。它不是网页：没有 HTTP 服务、端口、浏览器、Electron、Node.js 或 npm 依赖。

默认监控本机 SSH 配置中已配置免密登录的 `3090` 与 `a6000` 两个主机别名。

## 功能

- 原生无边框桌面浮窗，默认尺寸约为 420 × 560。
- 拖动顶栏移动窗口，拖动右下角调整宽高；最小尺寸为 340 × 300。
- 顶栏滑块可在 40%–100% 范围调节背景透明度；文字、数字、状态灯和进度条始终保持清晰不透明。
- 可切换始终置顶。
- 可贴到屏幕左侧、右侧或顶部自动隐藏，仅保留 7 像素；收起后先把鼠标移开边缘，再次触碰对应边缘即可恢复。
- 自动保存透明度、尺寸、位置、置顶、贴边开关和刷新间隔。
- 可在浮窗中手动设置 1–300 秒的刷新间隔；两台服务器始终并行采集，采集过程不阻塞窗口。
- 按分钟聚合并保存所有采集指标：CPU、系统内存、LOAD、运行时间、延迟，以及每张 GPU 的利用率、显存、温度、功耗/上限和风扇。
- 原生历史窗口支持分钟精度的起止时间查询，默认显示最近 1 小时，并按服务器和 GPU 显示曲线。
- CPU 与系统内存以紧凑辅助指标显示，并紧贴服务器名称与主机信息，减少纵向留白。
- GPU 是主要信息区：逐卡大号显示利用率，并显示显存已用/总量、独立显存进度条和温度；服务器标题处汇总总显存。
- 单台服务器连接失败不会影响另一台，错误会显示在对应节点卡片中。

## 环境要求

- Windows 10 或 Windows 11。
- 系统自带的 Windows PowerShell 5.1 与 WPF。
- 本机安装并可调用 OpenSSH 客户端 `ssh.exe`。
- 远端为 Linux，具有 `/proc`、POSIX `sh` 和 `awk`。
- GPU 指标需要远端可运行 `nvidia-smi`；没有 NVIDIA GPU 时 CPU 与内存监控仍可工作。

先确认免密 SSH：

```powershell
ssh -o BatchMode=yes 3090 hostname
ssh -o BatchMode=yes a6000 hostname
```

## 启动

最简单的方式是双击：

```text
Start Server Pulse.vbs
```

启动器会隐藏 PowerShell 控制台，只显示监控浮窗。

也可以从终端启动，方便查看启动错误：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ServerPulse.ps1
```

项目无需安装或下载依赖。

## 窗口操作

- **移动**：按住顶栏空白处拖动。窗口使用应用内坐标拖拽，不调用 Windows 系统窗口移动，因此拖到屏幕边缘时不会触发系统的半屏排列/Snap Assist。
- **调整尺寸**：拖动窗口右下角的点阵手柄。
- **查看更多 GPU**：窗口较小时，在节点区域使用鼠标滚轮纵向滚动；滚动条保持隐藏以减少视觉干扰。
- **背景透明度**：拖动顶栏滑块，范围为 40%–100%；文字和指标不会随之变淡。
- **刷新间隔**：在状态栏的“刷新”输入框中填写 `1`–`300` 秒，按 Enter 或移开焦点后生效；无效输入会恢复当前值。
- **占用记录**：点击状态栏中醒目的绿色“记录”按钮打开历史窗口，右上角 `×` 可直接关闭；关闭按钮与标题拖拽区域相互独立，不会被拖动操作截获。开始与结束时间分别提供年、月、日、时、分 5 个可编辑输入框；年支持 `2000`–`9999`，月为 `1`–`12`，日按实际年月（含闰年）校验，时为 `0`–`23`，分为 `0`–`59`。空值、非数字、越界数值或无效日期会立即显示红色边框和红色 `!`。“最近 1 小时”按钮可恢复默认范围。鼠标移入任意折线图时，会选择二维距离最近的记录点，以同色圆圈和竖向定位线标记，并显示该点的时间、指标、数值和单位；移出图表后自动隐藏。若本地历史文件损坏或尚未完整写入，查询异常会留在历史窗口中以红色提示显示，不会再导致软件退出。
- **异常保护**：时间编辑、查询等界面事件即使发生未预料的异常，也会由应用级保护拦截，主窗口继续运行；详细堆栈写入 `%LOCALAPPDATA%\ServerPulse\error.log`，状态栏会提示日志位置。
- **贴边隐藏**：绿色“边”表示已启用。把窗口拖到屏幕左、右或上边缘，窗口边框到达或随鼠标越过屏幕边界时都会吸附，约 0.7 秒后自动收起。为防止松开鼠标时立刻反弹，收起后需要先把鼠标移离边缘，再次触碰对应边缘才会恢复。
- **置顶**：绿色“置”表示窗口始终置顶。
- **最小化/关闭**：使用顶栏右侧的 `—` 与 `×`。

窗口设置保存在：

```text
%LOCALAPPDATA%\ServerPulse\settings.json
```

删除该文件即可恢复默认尺寸、位置、背景透明度和刷新间隔。

新版使用应用内拖拽后，设置格式升级为版本 2；首次运行会自动丢弃旧版 Windows 半屏排列遗留的异常尺寸与位置，恢复为 420 × 560。此后的手动缩放和位置会继续正常保存。

历史记录按天保存在 `%LOCALAPPDATA%\ServerPulse\history\yyyy-MM-dd.json`。每个文件保存当天的分钟平均值，默认保留 30 天；删除 `history` 目录只会清空历史，不影响窗口设置。

## 配置

服务器配置位于 `config/servers.json`：

```json
{
  "pollIntervalMs": 5000,
  "sshTimeoutMs": 8000,
  "historyRetentionDays": 30,
  "servers": [
    { "id": "3090", "label": "RTX 3090", "host": "3090" },
    { "id": "a6000", "label": "RTX A6000", "host": "a6000" }
  ]
}
```

- `host` 是 `~/.ssh/config` 中的主机别名，只允许字母、数字、点、下划线和连字符。
- `pollIntervalMs` 是未保存过手动设置时的默认采集间隔；浮窗中的秒数设置会优先使用并自动保存。
- `sshTimeoutMs` 是单台服务器每次 SSH 采集的超时上限。
- `historyRetentionDays` 是本地分钟历史的保留天数，默认为 30；过期的按天文件会在启动时清理。

## 实现结构

```text
ServerPulse.ps1（原生 WPF 浮窗）
        │
        └─ 隐藏 PowerShell 采集进程
               ├─ ssh 3090 ── /proc + nvidia-smi
               └─ ssh a6000 ─ /proc + nvidia-smi
```

- `ServerPulse.ps1`：WPF 界面、窗口设置、尺寸/背景透明度控制、逐卡 GPU/显存视图、贴边隐藏和刷新调度。
- `Start Server Pulse.vbs`：无控制台启动器。
- `src/Collect-Metrics.ps1`：并行 SSH 采集并输出 JSON 快照。
- `src/ServerPulse.Core.ps1`：配置校验、CSV 与指标解析。
- `src/ServerPulse.History.ps1`：分钟聚合、按天持久化、时间范围查询和原生历史曲线窗口。
- `tests/ServerPulse.Tests.ps1`：指标解析、配置、分钟聚合与历史持久化测试。

PowerShell 脚本使用 UTF-8 BOM 保存，以兼容 Windows PowerShell 5.1 对中文源码的读取方式。

## 测试

核心测试：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\ServerPulse.Tests.ps1
```

原生窗口冒烟测试：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ServerPulse.ps1 -SmokeTest
```

冒烟模式会实际运行一次 SSH 采集，验证 WPF 主窗口与历史窗口、应用内坐标拖拽、历史窗口关闭按钮的命中、事件隔离与实际关闭、刷新间隔、分钟历史聚合、默认最近一小时、分框日期输入与红框/`!` 越界提示、折线图最近点悬停及移出隐藏、损坏历史文件的查询异常拦截、未处理 UI 事件的应用级保护、仅背景透明、逐卡显存数据和贴边隐藏，然后生成 `tests/artifacts/native-window.png` 与 `tests/artifacts/history-window.png` 并自动退出。

单独检查采集器：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Collect-Metrics.ps1 -ConfigPath .\config\servers.json
```

## 常见问题

- **窗口显示离线**：先在终端运行 `ssh -o BatchMode=yes <别名> hostname`，检查 SSH 别名、密钥、VPN、跳板机和远端主机指纹。
- **GPU 数量为 0**：在对应远端执行 `nvidia-smi`。CPU 和内存采集不依赖 NVIDIA 工具。
- **双击没有显示窗口**：使用终端启动命令运行一次，以查看配置或 PowerShell 错误。
- **窗口隐藏后找不到**：把鼠标移动到窗口停靠的屏幕边缘；也可以删除 `%LOCALAPPDATA%\ServerPulse\settings.json` 恢复默认位置。

## 协作约定

仓库规则记录在 `AGENTS.md`。每次修改必须同步更新本 README、运行相应测试、创建 Git 提交，并在交付时列出提交和修改详情。
