# Server Pulse 开发文档

本文档描述当前 `main` 分支的 Tauri 2 + Vue 3 实现、采集协议、安全边界、测试方法和发布检查。旧版 PowerShell/WPF 实现只通过 `legacy/v1.1.0` 分支与 `port-baseline-v1.1.0` 标签作为回滚和行为对照基线，不属于当前运行路径。

## 1. 当前实现与平台边界

- 当前应用是 Tauri 2 桌面程序：Rust 负责窗口、IPC、SSH、凭据、历史和生命周期；Vue 3 WebView 负责主浮窗、管理页和历史页。
- Windows 10/11 x64 是主要验收平台；Windows 发布包使用 GUI subsystem，SSH、askpass 和 host-key helper 子进程不创建控制台。
- macOS Intel/Apple Silicon 保持代码编译兼容，但透明窗口、托盘、贴边和睡眠恢复尚未在真实 Mac 上实机验收。
- Linux 桌面端不在当前版本范围内。远端服务器需要 POSIX `sh`、`/proc`；有 NVIDIA GPU 时使用 `nvidia-smi`，没有 NVIDIA 工具时仍采集 CPU 和内存。
- 应用不在远端安装全局依赖、不使用 `sudo`，也不修改用户的 SSH 配置或 `~/.ssh/known_hosts`。

## 2. 运行时结构

```text
ServerPulse-Portable.exe / serverpulse-tauri.exe
└─ Tauri shell
   ├─ Main floating window · Manage · History · tray
   ├─ Vue 3 + Pinia + ECharts WebView
   └─ Rust workspace
      ├─ serverpulse-core       协议、指标、历史、聚合、错误和退避
      ├─ serverpulse-ssh        系统 OpenSSH、askpass、主机密钥和流式会话
      └─ serverpulse-platform   数据根目录、文件锁、迁移、keyring 和原子写入
                                  │
                                  └─ Linux remote POSIX sampler
```

每台服务器最多维护一个持久 SSH 子进程。远端 sampler 按间隔循环输出协议 v2 帧，本地持续读取并解析 snapshot；帧超时、损坏、远端退出和网络断开会销毁旧进程并按退避策略重连。Agent 注入、状态、控制和历史合并继续使用短命令 SSH API。

## 3. 仓库布局

```text
frontend/
├─ src/views/                  # Main、Manage、History 页面
├─ src/components/             # 服务器卡片和交互组件
├─ src/stores/                 # Pinia 状态、IPC 和跨窗口事件
├─ src/charts/                 # 历史图表
└─ package.json

src-tauri/
├─ crates/serverpulse-core/    # 领域模型、协议和历史
├─ crates/serverpulse-ssh/     # OpenSSH、流式采集和 known_hosts
├─ crates/serverpulse-platform/# 路径、凭据、迁移和存储
└─ src/                        # Tauri commands、events、windows、tray

assets/serverpulse-sample.sh   # 唯一 canonical、LF-only 的远端 sampler
tests/fixtures/                # 协议与历史黄金样例
docs/                          # 开发、迁移和发布说明
CHANGELOG.md                   # 中英双语版本记录
README.md / README.zh-CN.md    # 用户说明
```

## 4. P0 功能状态

### 主机密钥

应用在当前数据根目录维护专用 `known_hosts`，只读兼容当前用户的 `~/.ssh/known_hosts`。`ssh-keyscan`/OpenSSH 解析后的算法和 SHA256 指纹形成结构化挑战：未知主机必须由用户确认后写入应用文件；已信任主机指纹变化直接阻断。忘记应用密钥后才允许再次验证，绝不自动覆盖用户文件或旧指纹。SSH 连接始终显式指定应用和用户 known_hosts，并使用 `StrictHostKeyChecking=yes`。

### 密码与 askpass

认证顺序固定为：当前会话密码、OS credential store、密钥或 agent。管理页可以选择保存到 Windows Credential Manager/macOS Keychain，或仅当前运行有效。会话密码只保留在 Tauri 主进程的 zeroize 内存中；Windows 使用当前用户 ACL 的一次性命名管道，macOS/Unix 使用一次性 socket。askpass 子进程只收到随机 token，token 只能读取一次。密码不得进入 `servers.json`、命令行、普通环境变量、日志或历史文件。

### 流式 SSH

远端 sampler 用以下边界输出每一帧：

```text
SERVERPULSE_FRAME_BEGIN
<protocol v2 snapshot>
SERVERPULSE_FRAME_END
```

本地使用 `open_stream`、`next_snapshot` 和 `shutdown` 管理每台服务器的单一长期会话。停止服务器、删除服务器、修改采样间隔和应用退出时必须显式关闭并等待 SSH 子进程退出。不可重试的主机密钥、密码缺失和认证错误暂停该服务器，结构化结果区分 `started`、`host-key-required`、`host-key-changed`、`password-required` 和 `authentication-failed`。

### UTC 历史

新记录使用带 `Z` 的 RFC3339 UTC 时间戳，并按 UTC 日期写入 `yyyy-MM-dd.v2.jsonl`。`query_history(day)` 接收用户本地日期，将本地日界转换为 UTC 范围，读取可能跨越的 UTC 文件，再由前端按本地时间显示。旧版 JSON/JSONL 和无时区时间戳继续按兼容规则读取。分钟聚合按有效样本数加权，不可用样本不进入分母。

## 5. IPC 与前端状态

主机密钥和认证相关调用包括：

- `probe_host_key(server)` → `HostKeyChallenge`
- `accept_host_key(challenge_id)`、`forget_host_key(server)`
- `verify_and_apply_server(request)` → `ApplyServerResult`
- `start_monitoring(server, interval)` → `StartResult`
- `clear_session_credential(server_id)`

前端处理 `server.host_key_required` 及结构化 start/recheck 结果。确认指纹后自动重试原操作；提交、取消、停止后立即清空密码输入，不写入 `localStorage`。跨窗口服务器选择、采样间隔和 monitoring 状态通过 Tauri events 与 Pinia 状态同步。

## 6. 数据与安全约束

默认数据根目录为 Windows `%LOCALAPPDATA%\ServerPulse` 或 macOS `~/Library/Application Support/ServerPulse`，包含 `settings.json`、`servers.json`、`error.log`、`known_hosts` 和 `history/`。仓库中的 `config/servers.json` 只是首次运行种子，不含密码。

提交前必须确认源码、测试、样例、日志和发布包不含真实用户名、邮箱、IP、密码、私钥、本地路径或用户列表。测试只使用合成主机名、用户名和指纹。错误事件和卡片显示必须脱敏；密码不得进入普通日志。

## 7. 本地构建与测试

从仓库根目录执行：

```powershell
npm ci --prefix frontend
npm --prefix frontend run typecheck
npm --prefix frontend run test:unit
npm --prefix frontend run build
npm --prefix frontend run test:e2e
cargo fmt --manifest-path src-tauri/Cargo.toml -- --check
cargo test --workspace --manifest-path src-tauri/Cargo.toml
npm --prefix frontend exec -- tauri build --config src-tauri/tauri.conf.json --ci
```

若只需 Rust 侧验证，可先运行 `cargo test --workspace --manifest-path src-tauri/Cargo.toml`。Windows 安装包由 Tauri 生成到 `src-tauri/target/release/bundle/`；便携测试文件可复制为仓库根目录的 `ServerPulse-Portable.exe`，该生成文件不应提交。

发布前还要执行：

```powershell
git diff --check
git status --short --branch
git grep -n -E 'password|secret|private_key|real-host|real-user' -- ':!CHANGELOG.md'
```

敏感信息扫描只接受合成测试数据命中；历史版本说明中的旧实现名称不能被误解为当前运行实现。

## 8. 发布清单

1. `Cargo.toml`、`Cargo.lock`、`tauri.conf.json`、`frontend/package.json` 和 lockfile 的版本一致。
2. `README.md`、`README.zh-CN.md`、`docs/` 与实现一致；`CHANGELOG.md` 同时包含中英文新增、变更、修复和已知限制。
3. Rust fmt、workspace tests、Vitest、类型检查、Vite 构建、Playwright 和 Windows x64 Tauri/NSIS 构建通过。
4. Windows 产物为 GUI/no-console；不打包个人数据根目录、凭据、历史、错误日志、私钥或本机配置。
5. macOS 仅在 CI/本地编译通过时宣称代码兼容；未实机验证的窗口能力必须继续列为限制。
6. 查看 `git diff --check`、敏感扫描和最终 `git status`，每轮修改使用单一主题提交。

## 9. 迁移与回滚

当前 `main` 正式取代 WPF 作为运行版本。需要比较旧行为或回滚时使用 `legacy/v1.1.0` 或 `port-baseline-v1.1.0`，不要在当前主分支重新恢复旧版入口文件。跨版本数据迁移由 Tauri platform crate 处理，用户的 OS credential store 不迁移到普通文件。

## 10. 贡献约定

保持提交主题单一。修改代码、配置或文档时同步更新 README，运行与变更匹配的检查，查看 diff/status 后再提交。不要把生成的 `target/`、前端依赖、便携 EXE、用户数据或本机路径加入版本库。
