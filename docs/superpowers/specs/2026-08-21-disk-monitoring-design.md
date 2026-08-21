# 磁盘容量监控设计（Disk Capacity Monitoring Design）

- 日期：2026-08-21
- 状态：已评审通过，待实现
- 目标版本：2.1.0
- 关联文档：`docs/DEVELOPMENT.md`、`docs/TAURI-PORT-PLAN.md`、`README.md`

## 1. 背景与目标

Server Pulse 当前监控 SSH 服务器的 CPU、内存、GPU 利用率/显存/温度，并支持按用户归因。本设计为 v2.1.0 增加磁盘维度：

1. **实时容量**：自动发现远端全部真实本地文件系统，展示各挂载点 已用/总量/百分比；
2. **按用户归因**：由服务端每日低频扫描 + 手动触发扫描，按挂载点分别统计每个用户的磁盘占用；
3. **历史回看**：容量与归因均写入本地历史，History 页可绘制磁盘曲线与用户占用曲线。

## 2. 需求决策记录

| 决策点 | 结论 |
| --- | --- |
| 监控内容 | 实时容量（df 风格）+ 每日低频用户归因 |
| 挂载点范围 | 自动发现全部真实文件系统，排除虚拟文件系统；网络文件系统保留容量、跳过归因扫描 |
| 主卡片展示 | MEM 行下新增 DISK 行，显示使用率最高的挂载点，可展开全部挂载点 |
| 历史记录 | 容量与归因都入历史 |
| 归因粒度 | 按挂载点分别归因 |
| 手动触发 | 卡片 DISK 展开区内「立即扫描」按钮，detached 执行，不装 agent 也可用 |

## 3. 方案选择

**采用方案 A：协议 v2 渐进扩展，agent 承担每日调度，手动触发 detached 扫描。**

否决的替代方案：

- **方案 B（协议升 v3 + 实时会话按需归因）**：版本升级强制所有存量 agent 重新注入；hover 触发同步扫描需等待数分钟至数小时且应用关闭即中断。
- **方案 C（仅容量不做归因）**：不满足需求。

关键兼容性原则：协议在 v2 内做加法扩展，旧 sampler / 旧 agent 不输出磁盘段时解析为空值，监控行为不变。更新本版本后需对已有 agent 执行一次 Restart/Inject 才能获得每日自动调度（与 README 现有约定一致）；手动触发不受此限制。

## 4. 架构总览

```text
远端 Linux 服务器                                本机
├─ sampler (实时) ── df 采集 ──→ DISKS 段 ──┐
├─ scan.sh (每日/手动) ── find 按 uid 汇总 ──┼─→ SSH 通道 → Rust 解析 → MetricSnapshot.disks
└─ agent 定时调度 + 锁文件防重入 ────────────┘         ├─ 卡片 DISK 行（实时容量）
        ↓ 归因记录写入 ~/.serverpulse/attribution/     ├─ hover 面板（最新归因 + 扫描按钮）
                                                      └─ 分钟聚合 → v2 JSONL 历史 → History 曲线
```

新增仓库资产：

- `assets/serverpulse-sample.sh`：扩展 DISKS 输出段（仍是唯一 canonical sampler）；
- `assets/serverpulse-scan.sh`：**第二个 canonical 脚本**，POSIX sh、LF-only，负责归因扫描。

## 5. 协议扩展（v2 内加法）

### 5.1 sampler 输出

在现有 `GPU_USER_STATUS` 行之后新增：

```text
DISKS_BEGIN
/dev/sda1	/	419430400	210034688	ext4
/dev/sdb1	/data	3904877896	3051802759	xfs
DISKS_END
```

每行 tab 分隔五列：设备、挂载点、总 KiB、已用 KiB、文件系统类型。数据来源 `df -kP`。

### 5.2 过滤规则

sampler 内完成过滤，只保留真实文件系统：

- 按设备名剔除：`tmpfs`、`devtmpfs`、`overlay`、`shm`、`none`、`udev`、`squashfs` 及伪挂载路径（`/proc`、`/sys`、`/dev`、`/run`、`/boot/efi`）；
- 网络文件系统（nfs/cifs 等）**保留**——NAS 容量参与展示与历史；但归因扫描对其默认跳过（`find -xdev` 不跨设备，且 NAS IO 代价不可控）。

### 5.3 Rust 结构与容错

```rust
pub struct DiskMetric {
    pub device: String,
    pub mount: String,
    pub total_mib: Option<f64>,
    pub used_mib: Option<f64>,
    pub percent: Option<f64>,
    pub fs_type: String,
}
// MetricSnapshot 增加：
pub disks: Vec<DiskMetric>,
```

`percent` 由 Rust 侧在 `total_mib > 0` 时按 `used_mib * 100 / total_mib` 计算，协议不传输百分比列（保持帧最小）。

解析容错：段缺失或单行解析失败 → `disks` 为空或跳过该行，不影响快照其余字段（与 GPU 段处理一致）。旧 sampler 无此段 → 空数组 → 前端不渲染 DISK 行。

## 6. 归因扫描机制

### 6.1 scan.sh

- 入参为挂载点列表；对每个挂载点执行 `find <mount> -xdev -printf '%U\t%s\n' | awk` 按 uid 汇总字节数；
- uid→用户名解析复用 sampler 的 `/etc/passwd`（或 getent）方案；
- 无读权限条目跳过并计数，跳过数 > 0 时该挂载点标记 `partial`（与进程归因语义一致）；
- 全程 `nice -n 19` + `ionice -c3`（可用时）；单次扫描带可配置超时（默认 4 小时），超时按 `partial` 收尾并记录时长。

### 6.2 防重入

锁文件 `~/.serverpulse/state/scan.lock` 记录 PID + 启动时间；启动前做 PID 存活检测（复用 agent 状态检测模式），判死锁后允许新扫描接管。每日调度与手动触发走同一脚本、同一把锁，天然互斥。

### 6.3 每日调度（agent）

agent 在采样循环中检查状态文件的最后扫描日期；到点未扫则以 detached 方式拉起 scan.sh。默认服务器本地时间 **03:17**；扫描开关与时刻进入现有 agent Configure 面板（与 interval/retention 同一配置机制）。

### 6.4 手动触发

新增 Tauri 命令：

- `trigger_disk_scan(server)` → 结构化结果 `launched / already-running / failed(原因)`
  - 装了 agent：短命令 SSH 调用服务器上的 scan.sh，确认拉起后立即返回；
  - 未装 agent：先将当前版 scan.sh 写到服务器 `~/.serverpulse/scan.sh`（目录不存在则创建），再同样 detached 拉起；
- `get_disk_scan_status(server)` → 读状态文件返回：扫描中（含已运行时长）/ 上次完成时间 / 失败原因。

两种情况均为秒级返回，扫描在服务器后台继续，应用退出不中断。

### 6.5 结果落盘

写入 `~/.serverpulse/attribution/yyyy-MM-dd.jsonl`（独立于分钟记录目录，避免混入现有 merge 的分钟解析逻辑），每行一个挂载点：

```json
{"kind":"diskAttribution","scannedAt":"2026-08-20T03:12:45Z","mount":"/data",
 "totalMib":3813357,"usedMib":2980276,"status":"ok","durationSeconds":5432,
 "users":[{"uid":"1000","name":"alice","usedMib":1234567}]}
```

`status` 取值 `ok / partial / unavailable`；文件名按 `scannedAt` 的 UTC 日期。

## 7. 历史存储与合并

### 7.1 分钟记录（容量）

v2 JSONL 的 Server 条目增加可选 `Disks` 数组：

```json
{"Version":2,"Record":{"Timestamp":"…","SampleCount":1,
 "Servers":[{"Id":"3090","CpuPercent":42.5,"MemoryPercent":50.0,"Gpus":[],
   "Disks":[{"Mount":"/data","Percent":78.1,"TotalMib":3813357,"UsedMib":2978220}]}]}}
```

- serde `#[serde(default)]` 保证旧记录照常解析；分钟记录只存展示所需子集（Mount/Percent/TotalMib/UsedMib），device 与 fs_type 不入历史以控制文件体积；
- 分钟聚合沿用现有规则：磁盘百分比按有效样本数加权平均，缺磁盘数据的样本不进分母（不出现假零）；
- 旧记录无 `Disks` → 曲线留缺口。

### 7.2 归因记录（本地镜像）

落盘 `<data-root>/history/attribution/yyyy-MM-dd.jsonl`（按 UTC 日期分文件）。独立子目录使现有分钟查询路径完全不动。`query_history(day)` 响应增加 `diskAttribution` 字段返回当日记录。

### 7.3 合并与清理

- `pull_and_merge_records` 增加拉取 `~/.serverpulse/attribution/`（沿用批量 120 秒 deadline），按 `(mount, scannedAt)` 去重；重复且内容不一致 → 保留先到者并记 `error.log`；
- 「合并后删除服务端文件」选项覆盖归因目录；
- retention 清理扩展到 `history/attribution/`（同一日历日规则）。

## 8. 前端 UI

### 8.1 主卡片

- MEM 行下新增 **DISK 行**：显示使用率最高的挂载点，格式 `DISK 78% · 3.1/4.0 TB`；
- 点击展开全部挂载点列表：每行进度条 + 百分比 + used/total + 挂载点名（复用现有进度条样式）；
- hover/点击 DISK 数值弹出按用户归因面板（复用 UserUsagePopup 模式），顶部标注新鲜度「来自 X 日扫描」；无归因数据时明示原因「需服务端 agent 或手动扫描」；
- 展开区内放 **「立即扫描」按钮**：扫描中禁用并显示已运行时长；通过 `get_disk_scan_status` 轮询刷新。

### 8.2 History 页

- 曲线开关区新增「磁盘」开关：开启后每个挂载点一条使用率曲线（颜色稳定、图例可移除，机制同现有曲线）；
- 现有「用户曲线（最多 3 条）」机制扩展支持磁盘归因数据：按日步进折线（两次扫描之间保持阶梯值，不做线性插值）。

### 8.3 i18n

所有新文案中英双语同步（zh/en 资源文件成对更新）。

## 9. 错误处理

全部遵循现有「显式降级、不假零、不中断其他服务器」原则：

| 场景 | 行为 |
| --- | --- |
| df 失败/无输出 | `disks=[]`，卡片不显示 DISK 行（同「无 NVIDIA GPU」语义，非错误态） |
| 扫描中单个挂载点失败 | 该挂载点记 `partial/unavailable`，其余继续 |
| 扫描超时 | 已扫部分按 `partial` 落盘并记录时长 |
| 锁残留（扫描进程崩溃） | PID 存活检测判死锁后允许新扫描接管 |
| 手动触发失败 | 结构化 `failed(原因)`，脱敏后显示在卡片 |
| 旧版 agent | 手动触发不受影响（scan.sh 触发时现场部署）；每日自动调度需 Restart/Inject 一次 |
| 合并冲突 | `(mount, scannedAt)` 重复且内容不一致 → 保留先到者并记 `error.log` |

## 10. 隐私边界

记录只含 uid、用户名、字节数、挂载点路径——无 PID、进程名、命令行、密码。挂载点路径属运维信息，敏感级别与现有用户名展示同级。提交前敏感信息扫描规则不变（合成数据除外）。

## 11. 测试计划

- **Rust 单测**：`parse_metric_output` 扩展黄金样例 `tests/fixtures/metrics-v2.sample.txt`（新增 DISKS 段），补缺失段/坏行/nfs 用例；历史读写含 `Disks` 与否的双向兼容；归因文件解析、`(mount, scannedAt)` 去重、retention 清理覆盖 attribution 目录；
- **脚本验证**：sampler 的 df 段与 scan.sh 用合成 df/find 输出夹具验证（CI 在 Windows，与现有 sampler 测试同策略——Rust 侧解析夹具为主）；scan.sh 的 awk 汇总逻辑用合成目录树在 WSL/Linux 本地验证；
- **前端**：vitest 覆盖 store 的 disks/attribution/扫描状态处理；
- **手动验收**：真实 GPU 服务器核对过滤规则（tmpfs 剔除、nfs 保留）、小挂载点全流程（扫描→落盘→合并→曲线→hover）。

## 12. 文档与发布影响

- `README.md` + `README.zh-CN.md`：DISK 行、扫描按钮、agent Configure 新增项、数据目录新增 `history/attribution/`；
- `docs/DEVELOPMENT.md`：协议段、运行时结构（第二个 canonical 脚本）、历史布局；
- `CHANGELOG.md`：发布时补中英双语条目，版本升 **2.1.0**（minor）。

## 13. 兼容性与迁移

- 协议 v2 加法扩展，无版本升级、无破坏性迁移；
- 存量 agent 更新后需一次 Restart/Inject 以获得每日自动调度能力；
- 旧历史记录无 `Disks` 字段 → 曲线留缺口，与现有兼容规则一致；
- 数据根目录布局为纯增量（新增 `history/attribution/` 子目录），无既有文件迁移。
