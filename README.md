# Server Pulse

Server Pulse 是一个 Electron 桌面浮窗，通过 SSH 实时展示计算服务器的 GPU、CPU、内存、负载与在线状态。默认监控本机 SSH 配置中已经免密登录的 `3090` 和 `a6000` 两个主机别名；也可以只启动内置 Web 控制面。

## 当前功能

- 每 5 秒并行轮询两台服务器，单台失败不会阻塞另一台。
- 展示 CPU 占用、内存占用与容量、1/5/15 分钟系统负载、运行时间。
- 展示每块 NVIDIA GPU 的利用率、显存、温度和功耗。
- 使用 Server-Sent Events 将采集结果实时推送到浏览器，并显示最近 60 秒的 CPU、内存、GPU 趋势。
- 清楚区分连接中、在线、离线状态；SSH 错误会显示在对应节点卡片中。
- 默认仅监听 `127.0.0.1`，指标只保存在进程内存中，不写入磁盘或数据库。
- 前端为响应式“机房控制台”界面，支持窄屏和减少动态效果的系统偏好。
- 桌面浮窗默认始终置顶，可拖拽到屏幕左侧、右侧或顶部自动隐藏，鼠标触碰对应边缘时自动滑出。
- 控制栏可在 40%–100% 范围内调节透明度，也可随时关闭贴边隐藏或置顶；设置会保存在 Electron 用户数据目录。

## 环境要求

- 本机：Node.js 22.12 或更高版本、OpenSSH 客户端；桌面浮窗需要安装项目中的 Electron 开发依赖。
- 远端：Linux、`/proc` 文件系统、POSIX `sh`、`awk`。
- GPU 指标：远端已安装 NVIDIA 驱动并可执行 `nvidia-smi`。没有 NVIDIA GPU 时，CPU 与内存监控仍可工作。
- SSH 配置中存在可免密登录的 `3090`、`a6000` 主机别名。

先在终端确认 SSH 可用：

```powershell
ssh -o BatchMode=yes 3090 hostname
ssh -o BatchMode=yes a6000 hostname
```

## 启动

首次使用先安装依赖：

```powershell
pnpm install
# 或 npm install
```

项目在 `pnpm-workspace.yaml` 中只允许 Electron 执行依赖安装脚本，用于下载与当前平台匹配的桌面运行时；不会放开其他依赖的构建脚本。

如果当前网络无法访问 Electron 的默认 GitHub 发布源，可按 Electron 官方安装文档使用中国 CDN 镜像后重试：

```powershell
$env:ELECTRON_MIRROR='https://npmmirror.com/mirrors/electron/'
pnpm install
```

启动桌面浮窗：

```powershell
pnpm start
# 或 npm start
```

窗口上方可以调节透明度、切换贴边隐藏、切换置顶、最小化或关闭。把窗口拖到屏幕左侧、右侧或顶部并松开，约 0.7 秒后窗口会自动收起，只留下 8 像素；把鼠标移到对应屏幕边缘即可唤回。

如只需要浏览器版本，可跳过 Electron 界面并运行：

```powershell
node server.js
# 或 pnpm start:web
```

然后打开 <http://127.0.0.1:4173>。

按 `Ctrl+C` 停止服务。

## 配置

配置文件位于 `config/servers.json`：

```json
{
  "port": 4173,
  "bind": "127.0.0.1",
  "pollIntervalMs": 5000,
  "sshTimeoutMs": 8000,
  "servers": [
    { "id": "3090", "label": "RTX 3090", "host": "3090" },
    { "id": "a6000", "label": "RTX A6000", "host": "a6000" }
  ]
}
```

- `host` 是本机 `~/.ssh/config` 中的 SSH 主机别名，只允许字母、数字、点、下划线和连字符。
- `pollIntervalMs` 是轮询间隔；若上一次采集仍未结束，同一节点不会重叠执行。
- `sshTimeoutMs` 同时控制 SSH 连接与整次采集的超时上限。
- 环境变量 `MONITOR_PORT` 和 `MONITOR_BIND` 可覆盖监听端口和地址。例如需要允许局域网访问时，可显式设置 `MONITOR_BIND=0.0.0.0`；此时应同时配置防火墙或反向代理认证。

## 架构

```text
Electron 浮窗 / 浏览器 ─ GET + SSE ─┐
                                    ├─ Node.js 本地控制面
                                    ├─ ssh 3090 ── /proc + nvidia-smi
                                    └─ ssh a6000 ─ /proc + nvidia-smi
```

- `server.js`：静态文件、JSON API、SSE 推送和轮询调度。
- `src/collector.js`：通过 SSH 执行只读采集脚本并解析输出。
- `src/config.js`：读取并校验服务器配置。
- `public/`：无框架前端仪表盘。
- `electron/`：无边框浮窗、透明度/置顶控制和贴边自动隐藏。
- `test/`：使用 Node.js 内置测试运行器的解析器测试。

## API

- `GET /api/servers`：返回所有节点的最新快照和轮询间隔。
- `GET /api/events`：SSE 流；每次节点采集完成后发送 `snapshot` 事件。

## 测试

```powershell
node --test test/collector.test.js
```

测试覆盖 CSV 字段解析、系统/GPU 指标解析和异常输出。安装 Electron 后还可以运行真实桌面浮窗冒烟测试：

```powershell
pnpm test:desktop
```

桌面冒烟模式会在系统分配的临时本地端口上启动隐藏的 Electron 窗口，避免与正在运行的 Web 实例冲突；它会验证预加载 IPC、浮窗控制栏、两台节点卡片、透明度 API，以及一次左侧贴边收起与恢复。等待两台节点完成首次采集和入场动画后，测试会将实际窗口截图写入已忽略的 `test/artifacts/electron-window.png`，恢复原窗口设置并自动退出。

服务级冒烟检查可在启动后访问：

```powershell
Invoke-RestMethod http://127.0.0.1:4173/api/servers
```

## 常见问题

- **卡片显示离线**：先执行 `ssh -o BatchMode=yes <别名> hostname`；检查别名、密钥权限、VPN、跳板机配置和远端 shell。
- **GPU 列表为空**：在远端执行 `nvidia-smi`。CPU 与内存数据不依赖 NVIDIA 工具。
- **首次连接失败**：先手动 SSH 一次并确认远端主机指纹；服务使用 `BatchMode=yes`，不会弹出交互式密码或确认提示。
- **外部字体不可用**：界面会回退到等宽字体，不影响监控功能。若在完全离线环境部署，可将字体改为本地文件。

## 协作约定

仓库级修改规则记录在 `AGENTS.md`。每次修改必须同步更新本 README、执行相关测试、创建 Git 提交，并在交付时列出提交与修改详情。
