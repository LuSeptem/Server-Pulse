# 磁盘容量监控实现计划（Disk Capacity Monitoring Implementation Plan）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 Server Pulse v2.1.0 增加磁盘维度：实时容量（自动发现真实文件系统）、每日低频按挂载点用户归因、手动触发扫描、全部入历史并可绘制曲线。

**Architecture:** 协议 v2 内做加法扩展——sampler 新增 DISKS 段，Rust 解析为 `MetricSnapshot.disks`；归因由独立 canonical 脚本 `assets/serverpulse-scan.sh` 在服务器上 detached 执行（agent 每日调度或手动触发），结果写入 `~/.serverpulse/attribution/` 并经现有 merge 管道进入本地 `history/attribution/`；前端卡片新增 DISK 行与扫描按钮，History 页新增磁盘视图。

**Tech Stack:** Rust workspace（serverpulse-core/-ssh/-platform + tauri bin）、POSIX sh、Vue 3 + Pinia + ECharts、Vitest、Playwright。

**Spec:** `docs/superpowers/specs/2026-08-21-disk-monitoring-design.md`（本计划依据该 spec；执行者需同时阅读两者）。

## Global Constraints

- 两个远端脚本（`assets/serverpulse-sample.sh`、`assets/serverpulse-scan.sh`）必须保持 POSIX sh、LF-only。提交前用 `sh -n <file>` 做语法检查。
- 协议版本保持 v2，不升版本；所有新字段可缺失（旧 sampler/旧 agent 输出必须照常解析）。
- 记录只含 uid、用户名、字节数、挂载点路径——禁止 PID、进程名、命令行、密码。
- 错误信息脱敏后才能上卡片/事件（复用 `ServerPulseError::public_error()` 或手工截断）。
- 所有命令从仓库根目录执行：前端用 `npm --prefix frontend run …`，Rust 用 `cargo … --manifest-path src-tauri/Cargo.toml`。
- 每个任务结束：运行该任务声明的测试 + `git diff` + `git status`，然后单一主题提交（AGENTS.md 规则）。
- 版本号本次不改（发布时统一升 2.1.0）；CHANGELOG 只加 Unreleased 小节。
- 测试数据一律合成（主机名 `demo`/`3090`、用户 `alice`/`bob` 等），不得出现真实地址。

## 对 spec 的两处实现级修正（已确认必要）

1. 归因记录增加 `serverId` 字段：本地 `history/attribution/` 聚合多台服务器的扫描结果，没有 serverId 无法区分归属。合并去重键相应为 `(serverId, mount, scannedAt)`。
2. 每日调度按「小时粒度」触发：agent 在采样循环里发现「当前服务器本地小时 ≥ 配置小时且今天未扫」即拉起（默认 3 点时段内首次循环）。spec 的 03:17 精确到分钟无必要（各服务器时钟本就不同）。

## File Structure

| 文件 | 动作 | 职责 |
| --- | --- | --- |
| `src-tauri/crates/serverpulse-core/src/lib.rs` | 修改 | `DiskMetric` 结构、DISKS 段解析、归因记录模型与合并 |
| `assets/serverpulse-sample.sh` | 修改 | 新增 DISKS 输出段 |
| `tests/fixtures/metrics-v2.sample.txt` | 修改 | 黄金样例补 DISKS 段 |
| `src-tauri/src/main.rs` | 修改 | 实时历史 Disks 字段、trigger/status 命令、归因拉取合并、query_history 扩展 |
| `src-tauri/crates/serverpulse-core/src/agent.rs` | 修改 | AWK 聚合器 Disks 支持、scan 部署/触发/状态脚本生成、agent 配置与调度 |
| `assets/serverpulse-scan.sh` | 新建 | canonical 归因扫描脚本 |
| `src-tauri/crates/serverpulse-platform/src/lib.rs` | 修改 | `AgentServerState` 增加 scan_enabled/scan_hour |
| `frontend/src/types.ts` | 修改 | DiskMetric/DiskAttributionRecord/DiskScanStatusInfo 类型 |
| `frontend/src/stores/monitor.ts` | 修改 | loadHistory 扩展、triggerDiskScan/fetchDiskScanStatus actions |
| `frontend/src/composables/useUserUsagePopup.ts` | 修改 | kind 增加 'disk' |
| `frontend/src/components/ServerCard.vue` | 修改 | DISK 行、展开列表、扫描按钮 |
| `frontend/src/components/UserUsagePopup.vue` | 修改 | 磁盘归因渲染 |
| `frontend/src/views/MainView.vue` | 修改 | 传递新 props、处理 scan 事件 |
| `frontend/src/views/HistoryView.vue` | 修改 | 'disk' 视图模式与曲线 |
| `frontend/src/views/ManageView.vue` | 修改 | agent Configure 面板扫描项 |
| `README.md` / `README.zh-CN.md` / `docs/DEVELOPMENT.md` / `CHANGELOG.md` | 修改 | 文档同步 |

---

### Task 1: core — DiskMetric 结构与 DISKS 段解析

**Files:**
- Modify: `src-tauri/crates/serverpulse-core/src/lib.rs`（结构体加在 `GpuMetric` 之后约 L274；解析逻辑在 `parse_metric_output`；测试在底部 `mod tests`）

**Interfaces:**
- Produces: `DiskMetric { device: String, mount: String, total_mib: Option<f64>, used_mib: Option<f64>, percent: Option<f64>, fs_type: String }`；`MetricSnapshot.disks: Vec<DiskMetric>`（serde camelCase → 前端拿到 `disks[].mount/totalMib/usedMib/percent/fsType/device`）。后续所有任务依赖此结构。

- [ ] **Step 1: 写失败测试**

在 `mod tests` 内、`SAMPLE` 常量之后追加（注意：`SAMPLE` 本身含字面 tab 字符，新测试用 `\t` 转义构造即可）：

```rust
    #[test]
    fn parses_disks_section_and_computes_percent() {
        let mut output = String::from(SAMPLE);
        output.push_str("\nDISKS_BEGIN\n");
        output.push_str("/dev/sda1\t/\t419430400\t210034688\text4\n");
        output.push_str("not-a-disk-line\n");
        output.push_str("/dev/sdb1\t/data\t2048000\t1024000\txfs\n");
        output.push_str("DISKS_END\n");
        let snapshot = parse_metric_output(&output).expect("sample should parse");
        assert_eq!(snapshot.disks.len(), 2);
        let root = &snapshot.disks[0];
        assert_eq!(root.device, "/dev/sda1");
        assert_eq!(root.mount, "/");
        assert_eq!(root.fs_type, "ext4");
        let expected = (210034688.0 / 1024.0) * 100.0 / (419430400.0 / 1024.0);
        assert!((root.percent.unwrap() - expected).abs() < 0.001);
        assert!((root.total_mib.unwrap() - 409600.0).abs() < 0.001);
    }

    #[test]
    fn missing_disks_section_yields_empty_vec() {
        let snapshot = parse_metric_output(SAMPLE).expect("sample should parse");
        assert!(snapshot.disks.is_empty());
    }
```

- [ ] **Step 2: 运行确认失败**

Run: `cargo test --workspace --manifest-path src-tauri/Cargo.toml parses_disks_section`
Expected: 编译失败（`snapshot.disks` 字段不存在）。

- [ ] **Step 3: 实现**

(a) 在 `GpuMetric` 结构体定义之后添加：

```rust
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DiskMetric {
    pub device: String,
    pub mount: String,
    pub total_mib: Option<f64>,
    pub used_mib: Option<f64>,
    pub percent: Option<f64>,
    pub fs_type: String,
}
```

(b) `MetricSnapshot` 在 `pub gpus: Vec<GpuMetric>,` 之后加一行：

```rust
    pub disks: Vec<DiskMetric>,
```

(c) `parse_metric_output` 内：(1) 与其他局部变量一起声明 `let mut disks = Vec::new(); let mut in_disks_section = false;`；(2) 行循环中，紧跟现有 `if in_gpu_section { … continue; }` 块之后插入：

```rust
        if line == "DISKS_END" {
            in_disks_section = false;
            continue;
        }
        if line == "DISKS_BEGIN" {
            in_disks_section = true;
            continue;
        }
        if in_disks_section {
            if !line.is_empty() {
                let fields: Vec<&str> = line.split('\t').collect();
                if fields.len() >= 5 {
                    let total_mib = fields[2].trim().parse::<f64>().ok().map(|value| value / 1024.0);
                    let used_mib = fields[3].trim().parse::<f64>().ok().map(|value| value / 1024.0);
                    let percent = match (used_mib, total_mib) {
                        (Some(used), Some(total)) if total > 0.0 => {
                            Some((used * 100.0 / total).clamp(0.0, 100.0))
                        }
                        _ => None,
                    };
                    disks.push(DiskMetric {
                        device: fields[0].trim().to_owned(),
                        mount: fields[1].trim().to_owned(),
                        total_mib,
                        used_mib,
                        percent,
                        fs_type: fields[4].trim().to_owned(),
                    });
                }
            }
            continue;
        }
```

(3) 函数末尾 `Ok(MetricSnapshot { … })` 中 `gpus,` 之后加 `disks,`。

- [ ] **Step 4: 运行确认通过**

Run: `cargo test --workspace --manifest-path src-tauri/Cargo.toml`
Expected: 全部 PASS（`cargo check` 会强制找出所有遗漏 `disks` 字段的构造点；若 stream.rs 等处有编译错误，按同样方式补 `disks: Vec::new()`）。

- [ ] **Step 5: 提交**

```bash
git add src-tauri/crates/serverpulse-core/src/lib.rs
git commit -m "feat(core): parse protocol v2 DISKS section into MetricSnapshot"
```

---

### Task 2: sampler 新增 DISKS 输出段 + 黄金样例

**Files:**
- Modify: `assets/serverpulse-sample.sh`（文件末尾 `echo "GPU_USER_STATUS=$gpu_query_status"` 之后）
- Modify: `tests/fixtures/metrics-v2.sample.txt`（末尾追加）

**Interfaces:**
- Produces: 协议文本段 `DISKS_BEGIN` / 每行 `device\tmount\ttotal_kib\tused_kib\tfstype` / `DISKS_END`。Task 1 的解析器与 Task 4 的 AWK 聚合器都消费此格式。

- [ ] **Step 1: 修改 sampler**

在 `assets/serverpulse-sample.sh` 最后一行 `echo "GPU_USER_STATUS=$gpu_query_status"` 之后追加：

```sh

echo "DISKS_BEGIN"
df -kTP 2>/dev/null | awk '
NR > 1 {
  if (NF >= 7) { dev = $1; fstype = $2; total = $3; used = $4; mount = $7 }
  else if (NF == 6) { dev = $1; fstype = ""; total = $2; used = $3; mount = $6 }
  else { next }
  if (dev ~ /^(tmpfs|devtmpfs|overlay|shm|none|udev|squashfs|cgroup|ramfs|aufs|proc|sysfs|devpts|mqueue|hugetlbfs|binfmt_misc|configfs|securityfs|pstore|debugfs|tracefs|bpf|autofs|efivarfs|nsfs)/) next
  if (mount ~ /^\/(proc|sys|dev|run|boot\/efi)(\/|$)/) next
  if (total + 0 <= 0) next
  printf "%s\t%s\t%s\t%s\t%s\n", dev, mount, total, used, fstype
}'
echo "DISKS_END"
```

说明：`df -kTP` 是 GNU df（目标服务器为 Linux，与现有 `/proc`+`nvidia-smi` 前提一致）；NF==6 分支兜底不支持 `-T` 的 df。挂载点含空格的场景不支持（与 GPU CSV 解析同级限制）。网络文件系统（nfs/cifs）不过滤，自然保留。

- [ ] **Step 2: 更新黄金样例**

在 `tests/fixtures/metrics-v2.sample.txt` 末尾追加（tab 分隔，保持 LF）：

```text
DISKS_BEGIN
/dev/sda1	/	419430400	210034688	ext4
/dev/sdb1	/data	3904877896	3051802759	xfs
DISKS_END
```

- [ ] **Step 3: 验证**

Run: `sh -n assets/serverpulse-sample.sh && cargo test --workspace --manifest-path src-tauri/Cargo.toml`
Expected: 语法检查通过；全部测试 PASS（fixture 不被 Rust 测试直接读取，仅作黄金参照；Task 1 测试覆盖解析）。
再手工冒烟（可选，Git Bash）：`sh assets/serverpulse-sample.sh | tail -8` 在 WSL/Linux 下应输出 DISKS 段。

- [ ] **Step 4: 提交**

```bash
git add assets/serverpulse-sample.sh tests/fixtures/metrics-v2.sample.txt
git commit -m "feat(sampler): emit DISKS section with real filesystem capacity"
```

---

### Task 3: 实时历史记录写入 Disks 字段

**Files:**
- Modify: `src-tauri/src/main.rs`（`history_line()` 函数，约 L242-341；其后新增测试模块）

**Interfaces:**
- Consumes: Task 1 的 `MetricSnapshot.disks`。
- Produces: v2 JSONL Server 条目新增 `"Disks":[{"Mount","Percent","TotalMib","UsedMib"}]`（只存展示子集，device/fsType 不入历史——spec §7.1）。

- [ ] **Step 1: 写失败测试**

在 `history_line()` 函数之后插入：

```rust
#[cfg(test)]
mod history_line_tests {
    use super::*;

    #[test]
    fn history_line_includes_disks_subset() {
        let server = ServerConfig {
            id: "s1".to_owned(),
            label: "S1".to_owned(),
            host: "s1".to_owned(),
            user: None,
            port: None,
            monitored: true,
            passwordless: true,
        };
        let snapshot_json = r#"{"hostname":"demo","protocolVersion":2,"cpuPercent":1.0,"memoryTotalMib":10,"memoryUsedMib":5,"memoryPercent":50,"loadOne":null,"loadFive":null,"loadFifteen":null,"uptimeSeconds":null,"cpuUserStatus":"unavailable","cpuUsers":[],"memoryUserStatus":"unavailable","memoryUsers":[],"gpus":[],"disks":[{"device":"/dev/sda1","mount":"/data","totalMib":1000.0,"usedMib":250.0,"percent":25.0,"fsType":"xfs"}]}"#;
        let snapshot: MetricSnapshot = serde_json::from_str(snapshot_json).unwrap();
        let line = history_line(&server, "2026-08-21T00:00:00Z", &snapshot).unwrap();
        assert!(line.contains("\"Disks\":[{\"Mount\":\"/data\",\"Percent\":25.0,\"TotalMib\":1000.0,\"UsedMib\":250.0}]"));
    }

    #[test]
    fn history_line_without_disks_omits_entries() {
        let server = ServerConfig {
            id: "s1".to_owned(),
            label: "S1".to_owned(),
            host: "s1".to_owned(),
            user: None,
            port: None,
            monitored: true,
            passwordless: true,
        };
        let snapshot_json = r#"{"hostname":"demo","protocolVersion":2,"cpuPercent":1.0,"memoryTotalMib":10,"memoryUsedMib":5,"memoryPercent":50,"loadOne":null,"loadFive":null,"loadFifteen":null,"uptimeSeconds":null,"cpuUserStatus":"unavailable","cpuUsers":[],"memoryUserStatus":"unavailable","memoryUsers":[],"gpus":[],"disks":[]}"#;
        let snapshot: MetricSnapshot = serde_json::from_str(snapshot_json).unwrap();
        let line = history_line(&server, "2026-08-21T00:00:00Z", &snapshot).unwrap();
        assert!(line.contains("\"Disks\":[]"));
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cargo test --workspace --manifest-path src-tauri/Cargo.toml history_line`
Expected: FAIL（行内无 `"Disks"`）。

- [ ] **Step 3: 实现**

`history_line()` 中，`let gpus_json … .collect();` 之后加：

```rust
    let disks_json: Vec<serde_json::Value> = snapshot
        .disks
        .iter()
        .map(|disk| {
            serde_json::json!({
                "Mount": disk.mount,
                "Percent": disk.percent,
                "TotalMib": disk.total_mib,
                "UsedMib": disk.used_mib,
            })
        })
        .collect();
```

并在函数末尾 `serde_json::json!({…})` 的 `"Gpus": gpus_json,` 之后加 `"Disks": disks_json,`。

- [ ] **Step 4: 运行确认通过**

Run: `cargo test --workspace --manifest-path src-tauri/Cargo.toml`
Expected: 全部 PASS。

- [ ] **Step 5: 提交**

```bash
git add src-tauri/src/main.rs
git commit -m "feat(history): record per-mount disk capacity in live minute records"
```

---

### Task 4: agent AWK 聚合器支持 Disks

**Files:**
- Modify: `src-tauri/crates/serverpulse-core/src/agent.rs`（`AWK_AGGREGATOR` 常量、`generate_agent_script` 测试）

**Interfaces:**
- Consumes: Task 2 的 DISKS 段格式。
- Produces: agent 分钟记录 Server 条目新增 `"Disks":[{"Mount","Percent","TotalMiB","UsedMiB"}]`（与 Task 3 本地实时记录同形，merge 管道无需感知差异）。

- [ ] **Step 1: 写失败测试**

修改现有测试 `agent_script_generation_and_substitution`：调用改为传新参数（本任务 Step 3 会扩展签名），并追加断言。先改成期望形态：

```rust
    #[test]
    fn agent_script_generation_and_substitution() {
        let script = generate_agent_script("srv-1", "My Server", "10.0.0.1", 10, 60, true, 3, "echo SAMPLE");
        assert!(script.contains("sp_interval=10"));
        assert!(script.contains("sp_retention_days=60"));
        assert!(script.contains("sp_server_id=\"srv-1\""));
        assert!(script.contains("sp_server_label=\"My Server\""));
        assert!(script.contains("echo SAMPLE"));
        assert!(script.contains("sp_scan_enabled=1"));
        assert!(script.contains("sp_scan_hour=3"));
        assert!(script.contains("m_d_keys"));
        assert!(script.contains("emit_disks"));
    }
```

Run: `cargo test --workspace --manifest-path src-tauri/Cargo.toml agent_script_generation`
Expected: 编译失败（参数数量不符）。

- [ ] **Step 2: 修改 AWK_AGGREGATOR**

以下五处文本编辑都在 `AWK_AGGREGATOR` 原始字符串内：

(a) `reset_sample()` 函数末尾 `delete s_gu_unmap` 之后追加：

```awk
  s_d_list = ""
  delete s_d_dev
  delete s_d_total
  delete s_d_used
  delete s_d_seen
```

(b) `finalize_sample()` 内 GPU 循环结束之后（即 `if (s_cpu_status == "ok" || …)` 之前）追加：

```awk
    nd = split(s_d_list, di, " ")
    for (i = 1; i <= nd; i++) {
      mnt = di[i]
      if (!(mnt in m_d_seen)) { m_d_seen[mnt] = 1; m_d_keys = m_d_keys " " mnt }
      m_d_cnt[mnt]++
      m_d_total_sum[mnt] += s_d_total[mnt]
      m_d_used_sum[mnt] += s_d_used[mnt]
      m_d_dev[mnt] = s_d_dev[mnt]
    }
```

(c) 新增函数（放在 `function emit_record(` 之前）：

```awk
function emit_disks(   i, j, n, kd, t, first, mnt, avg_total, avg_used, pct) {
  n = split(m_d_keys, kd, " ")
  for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) {
    if (m_d_used_sum[kd[j]] > m_d_used_sum[kd[i]]) { t = kd[i]; kd[i] = kd[j]; kd[j] = t }
  }
  first = 1
  for (i = 1; i <= n; i++) {
    mnt = kd[i]
    if (!(m_d_cnt[mnt] > 0)) continue
    if (first) { printf ",\"Disks\":["; first = 0 } else printf ","
    avg_total = m_d_total_sum[mnt] / m_d_cnt[mnt]
    avg_used = m_d_used_sum[mnt] / m_d_cnt[mnt]
    pct = (avg_total > 0) ? avg_used * 100.0 / avg_total : 0
    printf "{\"Mount\":\"%s\",\"Percent\":%s,\"TotalMiB\":%s,\"UsedMiB\":%s}", jstr(mnt), jnum(pct, 1), jnum(avg_total, 1), jnum(avg_used, 1)
  }
  if (!first) printf "]"
}
```

(d) `BEGIN` 块中 `delete m_gu_unmap` 之后、`reset_sample()` 之前追加：

```awk
  m_d_keys = ""
  delete m_d_seen
  delete m_d_cnt
  delete m_d_total_sum
  delete m_d_used_sum
  delete m_d_dev
```

(e) 主规则块中 `if ($0 == "GPUS_BEGIN") { in_gpus = 1; next }` 之后插入：

```awk
  if ($0 == "DISKS_END") { in_disks = 0; next }
  if (in_disks) {
    nf2 = split($0, df2, "\t")
    if (nf2 >= 5 && isnum(df2[3]) && isnum(df2[4])) {
      dmount = df2[2]
      s_d_dev[dmount] = df2[1]
      s_d_total[dmount] = df2[3] + 0
      s_d_used[dmount] = df2[4] + 0
      if (!(dmount in s_d_seen)) { s_d_seen[dmount] = 1; s_d_list = s_d_list " " dmount }
    }
    next
  }
  if ($0 == "DISKS_BEGIN") { in_disks = 1; next }
```

(f) `emit_record()` 结尾：把最后的 `printf "]}]}}"` 改为：

```awk
  printf "]"
  emit_disks()
  printf "}]}}"
```

(g) `in_gpus` 变量在 `reset_sample()` 里已有 `in_gpus = 0`；同样在 reset_sample 的 `s_gpu_count = 0` 附近加 `in_disks = 0`。

- [ ] **Step 3: 扩展 generate_agent_script 与 config**

(a) `generate_agent_config` 增加两个参数并在 format! 末尾追加两行（保持既有 clamp 风格）：

```rust
pub fn generate_agent_config(
    server_id: &str,
    label: &str,
    server_host: &str,
    interval_seconds: u32,
    retention_days: u32,
    scan_enabled: bool,
    scan_hour: u32,
) -> String {
    let interval = interval_seconds.clamp(1, 3600);
    let retention = retention_days.clamp(1, 3650);
    let scan_hour = scan_hour.clamp(0, 23);
    format!(
        "interval={}\nretention_days={}\nserver_id={}\nserver_label={}\nserver_host={}\nscan_enabled={}\nscan_hour={}\n",
        interval,
        retention,
        sanitize_agent_value(server_id),
        sanitize_agent_value(label),
        sanitize_agent_value(server_host),
        if scan_enabled { 1 } else { 0 },
        scan_hour
    )
}
```

(b) `generate_agent_script` 签名加 `scan_enabled: bool, scan_hour: u32`（位置在 `retention_days` 之后、`sample_script` 之前）。模板头部变量区加：

```
sp_scan_enabled={scan_enabled}
sp_scan_hour={scan_hour}
```

`sp_reload_config` 的 case 列表加：

```sh
        scan_enabled=*) sp_scan_enabled=${{sp_line#*=}} ;;
        scan_hour=*) sp_scan_hour=${{sp_line#*=}} ;;
```

其后的数值校验区加：

```sh
  case "$sp_scan_enabled" in 1) ;; *) sp_scan_enabled=0 ;; esac
  case "$sp_scan_hour" in *[!0-9]*|'') sp_scan_hour=3 ;; esac
```

主循环 `touch "$sp_state/heartbeat"` 之后、`sp_prune` 之前插入调度函数调用与定义（函数定义放在 `sp_prune` 定义之后）：

```sh
sp_maybe_scan() {{
  [ "$sp_scan_enabled" = "1" ] || return 0
  sp_today=$(date +%Y-%m-%d 2>/dev/null) || return 0
  [ -f "$sp_state/last-scan-day" ] && [ "$(cat "$sp_state/last-scan-day" 2>/dev/null)" = "$sp_today" ] && return 0
  sp_hour=$(date +%H 2>/dev/null) || return 0
  case "$sp_hour" in *[!0-9]*|'') return 0 ;; esac
  [ "$sp_hour" -lt "$sp_scan_hour" ] && return 0
  echo "$sp_today" > "$sp_state/last-scan-day" 2>/dev/null
  [ -f "$sp_base/scan.sh" ] || return 0
  export SERVERPULSE_SERVER_ID="$sp_server_id"
  ( cd "$HOME" && if command -v setsid >/dev/null 2>&1; then nohup setsid sh "$sp_base/scan.sh" >>"$sp_base/scan.log" 2>&1 </dev/null & else nohup sh "$sp_base/scan.sh" >>"$sp_base/scan.log" 2>&1 </dev/null & fi )
}}
```

主循环里调用点：`touch "$sp_state/heartbeat" 2>/dev/null` 之后加一行 `sp_maybe_scan`。

注意：模板是 `format!` 字符串，所有字面 `{`/`}` 必须写成 `{{`/`}}`（照抄上例转义）；`{scan_enabled}`/`{scan_hour}` 为插值参数，需在 format! 参数列表补 `scan_enabled = if scan_enabled { 1 } else { 0 }, scan_hour = scan_hour.clamp(0, 23),`。

- [ ] **Step 4: 运行确认通过**

Run: `sh -n` 无法检查生成脚本（含插值占位符），改用测试验证 + 手工冒烟：
`cargo test --workspace --manifest-path src-tauri/Cargo.toml`
Expected: 全部 PASS。
WSL/Linux 冒烟（可选但推荐）：临时写一个小 Rust 示例或用 `cargo test agent_script_generation -- --nocapture` 打印脚本贴入 `sh -n`。

- [ ] **Step 5: 提交**

```bash
git add src-tauri/crates/serverpulse-core/src/agent.rs
git commit -m "feat(agent): aggregate disk capacity and schedule daily attribution scans"
```

---

### Task 5: canonical 归因扫描脚本 assets/serverpulse-scan.sh

**Files:**
- Create: `assets/serverpulse-scan.sh`

**Interfaces:**
- Produces: 服务器端可独立执行的扫描脚本。约定：
  - 基目录 `SERVERPULSE_BASE`（默认 `~/.serverpulse`）；服务器身份 `SERVERPULSE_SERVER_ID`（由触发方 export，可为空）；
  - 结果追加到 `$BASE/attribution/yyyy-MM-dd.jsonl`，每行一个挂载点的 JSON（Task 6 的 `DiskAttributionRecord` 消费此格式）；
  - 状态写 `$BASE/state/scan.status`（`SP_SCAN_STATUS=running|done`、`SP_SCAN_PID`、`SP_SCAN_STARTED_AT`、`SP_SCAN_FINISHED_AT`、`SP_SCAN_LAST_MOUNT`），锁文件 `$BASE/state/scan.lock`；
  - 退出输出 `SP_SCAN_RESULT=done|already_running|failed`。

- [ ] **Step 1: 创建脚本**

新建 `assets/serverpulse-scan.sh`，内容如下（LF-only；提交前确认 `.gitattributes` 不做 CRLF 转换——仓库现有 `.gitattributes` 已对 `*.sh` 强制 LF 则无需改动）：

```sh
#!/bin/sh
# Server Pulse canonical disk attribution scanner. POSIX sh, LF-only.
# Usage: serverpulse-scan.sh [mount ...]
# With no arguments every real local filesystem reported by df is scanned.
# One JSON line per mount is appended to $BASE/attribution/<utc-day>.jsonl.
# Mount points containing whitespace are not supported (same limit as df parsing).
LC_ALL=C
export LC_ALL
umask 077

sp_base="${SERVERPULSE_BASE:-$HOME/.serverpulse}"
sp_state="$sp_base/state"
sp_attr="$sp_base/attribution"
sp_budget="${SERVERPULSE_SCAN_BUDGET_SECS:-14400}"
mkdir -p "$sp_state" "$sp_attr" 2>/dev/null || exit 1

sp_lock="$sp_state/scan.lock"
sp_status="$sp_state/scan.status"

sp_write_status() {
  : > "$sp_status.tmp" 2>/dev/null || return 0
  for sp_kv in "$@"; do
    printf '%s\n' "$sp_kv" >> "$sp_status.tmp"
  done
  mv "$sp_status.tmp" "$sp_status" 2>/dev/null || true
}

if [ -f "$sp_lock" ]; then
  sp_old=$(cat "$sp_lock" 2>/dev/null)
  case "$sp_old" in
    ''|*[!0-9]*) rm -f "$sp_lock" ;;
    *)
      if kill -0 "$sp_old" 2>/dev/null; then
        echo "SP_SCAN_RESULT=already_running"
        exit 0
      fi
      rm -f "$sp_lock"
      ;;
  esac
fi
echo $$ > "$sp_lock"
trap 'rm -f "$sp_lock"' EXIT HUP INT TERM

sp_tmp=$(mktemp -d "${TMPDIR:-/tmp}/serverpulse-scan.XXXXXX" 2>/dev/null) || sp_tmp=""
if [ -z "$sp_tmp" ]; then
  echo "SP_SCAN_RESULT=failed"
  exit 1
fi
trap 'rm -rf "$sp_tmp"; rm -f "$sp_lock"' EXIT HUP INT TERM

sp_start=$(date +%s 2>/dev/null); sp_start=${sp_start:-0}
sp_write_status "SP_SCAN_STATUS=running" \
  "SP_SCAN_PID=$$" \
  "SP_SCAN_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"

# --- mount selection ---------------------------------------------------------
if [ "$#" -gt 0 ]; then
  sp_mounts="$*"
else
  sp_mounts=$(df -kTP 2>/dev/null | awk '
    NR > 1 {
      if (NF >= 7) { dev = $1; fstype = $2; total = $3; mount = $7 }
      else if (NF == 6) { dev = $1; fstype = ""; total = $2; mount = $6 }
      else next
      if (fstype ~ /^(nfs|nfs4|cifs|smbfs|smb2|ncpfs|9p|autofs|tmpfs|devtmpfs|overlay|squashfs|proc|sysfs|devpts|mqueue|hugetlbfs|securityfs|debugfs|tracefs|configfs|fusectl|efivarfs|bpf|nsfs|ramfs|cgroup)/) next
      if (dev ~ /^(tmpfs|devtmpfs|overlay|shm|none|udev|squashfs)/) next
      if (mount ~ /^\/(proc|sys|dev|run|boot\/efi)(\/|$)/) next
      if (total + 0 <= 0) next
      print mount
    }')
fi
if [ -z "$sp_mounts" ]; then
  sp_write_status "SP_SCAN_STATUS=done" \
    "SP_SCAN_FINISHED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" \
    "SP_SCAN_NOTE=no-mounts"
  echo "SP_SCAN_RESULT=done"
  exit 0
fi

# --- df totals snapshot and user database cache ------------------------------
df -kTP 2>/dev/null | awk '
  NR > 1 {
    if (NF >= 7) { print $7 "\t" $1 "\t" $3 "\t" $4 "\t" $2 }
    else if (NF == 6) { print $6 "\t" $1 "\t" $2 "\t" $3 "\t" }
  }' > "$sp_tmp/df.txt" 2>/dev/null

if command -v getent >/dev/null 2>&1 && getent passwd > "$sp_tmp/passwd" 2>/dev/null; then :
elif [ -r /etc/passwd ]; then
  cp /etc/passwd "$sp_tmp/passwd" 2>/dev/null || :
fi
touch "$sp_tmp/passwd"

sp_day=$(date -u +%Y-%m-%d)
sp_out="$sp_attr/$sp_day.jsonl"
: > "$sp_tmp/out.jsonl"

for sp_mount in $sp_mounts; do
  sp_now=$(date +%s 2>/dev/null); sp_now=${sp_now:-$sp_start}
  sp_remaining=$((sp_budget - sp_now + sp_start))
  [ "$sp_remaining" -gt 0 ] || break
  sp_write_status "SP_SCAN_STATUS=running" "SP_SCAN_PID=$$" "SP_SCAN_LAST_MOUNT=$sp_mount"

  sp_prefix=""
  command -v nice >/dev/null 2>&1 && sp_prefix="nice -n 19"
  command -v ionice >/dev/null 2>&1 && sp_prefix="$sp_prefix ionice -c3"
  command -v timeout >/dev/null 2>&1 && sp_prefix="timeout $sp_remaining $sp_prefix"

  : > "$sp_tmp/find.err"
  $sp_prefix find "$sp_mount" -xdev -printf '%U\t%s\n' \
    > "$sp_tmp/sizes.txt" 2> "$sp_tmp/find.err"
  sp_find_rc=$?
  sp_skipped=$(wc -l < "$sp_tmp/find.err" 2>/dev/null | tr -d ' ')
  sp_skipped=${sp_skipped:-0}

  awk '{ sum[$1] += $2 } END { for (u in sum) printf "%s\t%.0f\n", u, sum[u] }' \
    "$sp_tmp/sizes.txt" 2>/dev/null | sort -t "$(printf '\t')" -k2,2 -rn > "$sp_tmp/users.sorted"

  sp_dfline=$(awk -v m="$sp_mount" -F '\t' '$1 == m { print; exit }' "$sp_tmp/df.txt")
  sp_dev=$(printf '%s' "$sp_dfline" | cut -f2)
  sp_totalk=$(printf '%s' "$sp_dfline" | cut -f3)
  sp_usedk=$(printf '%s' "$sp_dfline" | cut -f4)
  sp_fstype=$(printf '%s' "$sp_dfline" | cut -f5)
  sp_finished=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
  sp_now=$(date +%s 2>/dev/null); sp_now=${sp_now:-$sp_start}
  sp_dur=$((sp_now - sp_start))

  awk -v mnt="$sp_mount" -v dev="$sp_dev" -v totalk="$sp_totalk" -v usedk="$sp_usedk" \
      -v fstype="$sp_fstype" -v finished="$sp_finished" -v dur="$sp_dur" \
      -v skipped="$sp_skipped" -v findrc="$sp_find_rc" -v pwfile="$sp_tmp/passwd" '
  function jstr(s) {
    gsub(/\\/, "\\\\", s)
    gsub(/"/, "\\\"", s)
    gsub(/\t/, " ", s)
    return s
  }
  BEGIN {
    while ((getline line < pwfile) > 0) {
      split(line, p, ":")
      pname[p[3]] = p[1]
    }
    close(pwfile)
    FS = "\t"
    status = "ok"
    if (findrc + 0 != 0 || skipped + 0 > 0) status = "partial"
    total = totalk + 0
    used = usedk + 0
    pct = total > 0 ? used * 100.0 / total : 0
    serverid = ENVIRON["SERVERPULSE_SERVER_ID"]
    printf "{\"kind\":\"diskAttribution\",\"serverId\":\"%s\",\"scannedAt\":\"%s\",\"mount\":\"%s\",\"device\":\"%s\",\"fstype\":\"%s\",\"totalMib\":%.0f,\"usedMib\":%.0f,\"percent\":%.2f,\"status\":\"%s\",\"durationSeconds\":%d,\"skippedEntries\":%d,\"users\":[", jstr(serverid), finished, jstr(mnt), jstr(dev), jstr(fstype), total / 1024, used / 1024, pct, status, dur + 0, skipped + 0
    first = 1
  }
  {
    uid = $1
    bytes = $2 + 0
    if (bytes <= 0) next
    name = (uid in pname) ? pname[uid] : "UID " uid
    if (!first) printf ","
    first = 0
    printf "{\"uid\":\"%s\",\"name\":\"%s\",\"usedMib\":%.0f}", jstr(uid), jstr(name), bytes / 1048576
  }
  END { printf "]}\n" }' "$sp_tmp/users.sorted" >> "$sp_tmp/out.jsonl" 2>/dev/null
done

if [ -s "$sp_tmp/out.jsonl" ]; then
  cat "$sp_tmp/out.jsonl" >> "$sp_out"
fi
sp_end=$(date +%s 2>/dev/null); sp_end=${sp_end:-$sp_start}
sp_write_status "SP_SCAN_STATUS=done" \
  "SP_SCAN_FINISHED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" \
  "SP_SCAN_DURATION=$((sp_end - sp_start))"
echo "SP_SCAN_RESULT=done"
```

- [ ] **Step 2: 本地验证（WSL/Git Bash 环境）**

```bash
sh -n assets/serverpulse-scan.sh
```

功能冒烟（WSL/Linux，合成目录）：

```bash
export SERVERPULSE_BASE=/tmp/sp-scan-test
export SERVERPULSE_SERVER_ID=demo
mkdir -p /tmp/sp-scan-test/state /tmp/sp-fixture/alice /tmp/sp-fixture/bob
# 用当前用户模拟两个 uid 的文件（单 uid 环境下验证聚合与 JSON 结构即可）
dd if=/dev/zero of=/tmp/sp-fixture/alice/a.bin bs=1k count=512 2>/dev/null
dd if=/dev/zero of=/tmp/sp-fixture/bob/b.bin bs=1k count=256 2>/dev/null
sh assets/serverpulse-scan.sh /tmp/sp-fixture
cat /tmp/sp-scan-test/attribution/$(date -u +%Y-%m-%d).jsonl
cat /tmp/sp-scan-test/state/scan.status
```

Expected: 一行 JSON，`"mount":"/tmp/sp-fixture"`、`"status":"ok"`、`users` 数组含当前用户名与 `usedMib≈1`（512+256 KiB ≈ 0.75 MiB，`%.0f` 后为 1）；`scan.status` 含 `SP_SCAN_STATUS=done`。锁文件已清理。重复运行第二次输出 `already_running` 不可测（首次已退出），跳过。
清理：`rm -rf /tmp/sp-scan-test /tmp/sp-fixture`。

- [ ] **Step 3: 提交**

```bash
git add assets/serverpulse-scan.sh
git commit -m "feat(scan): add canonical server-side disk attribution scanner"
```

---

### Task 6: core — 归因记录模型、解析与合并

**Files:**
- Modify: `src-tauri/crates/serverpulse-core/src/lib.rs`（结构体加在 `HistoryEntry` 附近；测试在 `mod tests`）

**Interfaces:**
- Produces:
  - `DiskUserUsage { uid: String, name: String, used_mib: f64 }`
  - `DiskAttributionRecord { kind: String, server_id: String, scanned_at: DateTime<Utc>, mount: String, device: Option<String>, fs_type: Option<String>, total_mib: Option<f64>, used_mib: Option<f64>, percent: Option<f64>, status: UserUsageStatus, duration_seconds: Option<u64>, skipped_entries: u64, users: Vec<DiskUserUsage> }`（serde camelCase）
  - `parse_disk_attribution_line(&str) -> Result<DiskAttributionRecord, ServerPulseError>`
  - `merge_attribution_lines(existing: &str, incoming: &str) -> String`（按 `(server_id, mount, scanned_at)` 去重，先到者优先，输出按时间排序）
  - Task 9 的拉取解析与 query_history、前端 types 均依赖。

- [ ] **Step 1: 写失败测试**

`mod tests` 内追加：

```rust
    const ATTR_LINE_A: &str = r#"{"kind":"diskAttribution","serverId":"s1","scannedAt":"2026-08-20T03:12:45Z","mount":"/data","device":"/dev/sdb1","fstype":"xfs","totalMib":3813357,"usedMib":2980276,"percent":78.15,"status":"ok","durationSeconds":5432,"skippedEntries":0,"users":[{"uid":"1000","name":"alice","usedMib":1234567}]}"#;

    #[test]
    fn parses_disk_attribution_line() {
        let record = parse_disk_attribution_line(ATTR_LINE_A).expect("record should parse");
        assert_eq!(record.server_id, "s1");
        assert_eq!(record.mount, "/data");
        assert_eq!(record.status, UserUsageStatus::Ok);
        assert_eq!(record.users.len(), 1);
        assert_eq!(record.users[0].name, "alice");
    }

    #[test]
    fn rejects_non_attribution_line() {
        let error = parse_disk_attribution_line(r#"{"Version":2,"Record":{}}"#).expect_err("must reject");
        assert_eq!(error.code(), "invalid_history");
    }

    #[test]
    fn merges_attribution_by_server_mount_and_time() {
        let line_b = ATTR_LINE_A.replace("\"mount\":\"/data\"", "\"mount\":\"/\"");
        let incoming = format!("{}\n{}\n", ATTR_LINE_A, line_b);
        let merged = merge_attribution_lines(ATTR_LINE_A, &incoming);
        let count = merged.lines().count();
        assert_eq!(count, 2); // 完全重复的 A 只保留一条；不同 mount 的 B 保留
        let first: serde_json::Value = serde_json::from_str(merged.lines().next().unwrap()).unwrap();
        assert_eq!(first["mount"], serde_json::Value::String("/".to_owned())); // 按时间排序时同秒记录按 mount 排序
    }
```

- [ ] **Step 2: 运行确认失败**

Run: `cargo test --workspace --manifest-path src-tauri/Cargo.toml attribution`
Expected: 编译失败（函数不存在）。

- [ ] **Step 3: 实现**

在 `HistoryEntry` 定义之前添加（`use chrono::{DateTime, Utc}` 文件顶部已有）：

```rust
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DiskUserUsage {
    pub uid: String,
    pub name: String,
    pub used_mib: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DiskAttributionRecord {
    pub kind: String,
    #[serde(default)]
    pub server_id: String,
    pub scanned_at: DateTime<Utc>,
    pub mount: String,
    #[serde(default)]
    pub device: Option<String>,
    #[serde(default)]
    pub fs_type: Option<String>,
    #[serde(default)]
    pub total_mib: Option<f64>,
    #[serde(default)]
    pub used_mib: Option<f64>,
    #[serde(default)]
    pub percent: Option<f64>,
    pub status: UserUsageStatus,
    #[serde(default)]
    pub duration_seconds: Option<u64>,
    #[serde(default)]
    pub skipped_entries: u64,
    #[serde(default)]
    pub users: Vec<DiskUserUsage>,
}

pub fn parse_disk_attribution_line(line: &str) -> Result<DiskAttributionRecord, ServerPulseError> {
    let clean = line.trim();
    if clean.is_empty() {
        return Err(ServerPulseError::InvalidHistory("empty attribution line".to_owned()));
    }
    let record: DiskAttributionRecord = serde_json::from_str(clean)
        .map_err(|error| ServerPulseError::InvalidHistory(format!("bad attribution line: {error}")))?;
    if record.kind != "diskAttribution" {
        return Err(ServerPulseError::InvalidHistory("line is not a diskAttribution record".to_owned()));
    }
    Ok(record)
}

pub fn merge_attribution_lines(existing: &str, incoming: &str) -> String {
    let mut seen = HashSet::new();
    let mut rows = Vec::new();
    for line in existing.lines().chain(incoming.lines()) {
        let Ok(record) = parse_disk_attribution_line(line) else {
            continue;
        };
        let key = (
            record.server_id.clone(),
            record.mount.clone(),
            record.scanned_at.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        );
        if !seen.insert(key) {
            continue;
        }
        rows.push(record);
    }
    rows.sort_by(|a, b| a.scanned_at.cmp(&b.scanned_at).then(a.mount.cmp(&b.mount)));
    let mut out = String::new();
    for record in rows {
        if let Ok(line) = serde_json::to_string(&record) {
            out.push_str(&line);
            out.push('\n');
        }
    }
    out
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cargo test --workspace --manifest-path src-tauri/Cargo.toml`
Expected: 全部 PASS。注意排序断言：A 与 B 的 scannedAt 相同（同一字符串），按 mount 排序 `/` < `/data`，故首行为 `/`。

- [ ] **Step 5: 提交**

```bash
git add src-tauri/crates/serverpulse-core/src/lib.rs
git commit -m "feat(core): model, parse, and merge disk attribution records"
```

---

### Task 7: scan 部署/触发/状态脚本生成 + agent 注入部署 scan.sh

**Files:**
- Modify: `src-tauri/crates/serverpulse-core/src/agent.rs`（新增生成函数与解析；修改 `generate_agent_inject_script` 签名；测试）

**Interfaces:**
- Consumes: Task 5 的 `assets/serverpulse-scan.sh` 文本（由调用方传入）。
- Produces:
  - `generate_scan_deploy_and_trigger_script(scan_script: &str, server_id: &str) -> String`
  - `generate_scan_status_script() -> &'static str`
  - `DiskScanStatusInfo { installed: bool, active: bool, pid: Option<u32>, state: String, started_at: Option<String>, finished_at: Option<String>, last_mount: Option<String>, last_file: Option<String> }`
  - `parse_scan_status_output(output: &str) -> DiskScanStatusInfo`
  - `generate_agent_inject_script(agent_script, config_text, scan_script)`（签名扩展）
  - Task 8 的 Tauri 命令依赖以上全部。

- [ ] **Step 1: 写失败测试**

`agent.rs` 底部没有测试模块，在文件末尾新增：

```rust
#[cfg(test)]
mod scan_tests {
    use super::*;

    #[test]
    fn trigger_script_deploys_scan_and_reports_launch() {
        let script = generate_scan_deploy_and_trigger_script("echo hi # scan", "srv-1");
        assert!(script.contains("SERVERPULSE_SCAN_EOF"));
        assert!(script.contains("echo hi # scan"));
        assert!(script.contains("SERVERPULSE_SERVER_ID=\"srv-1\""));
        assert!(script.contains("SP_SCAN_RESULT=launched"));
        assert!(script.contains("SP_SCAN_RESULT=already_running"));
    }

    #[test]
    fn parses_scan_status_output() {
        let output = "SP_SCAN_INSTALLED=1\nSP_SCAN_ACTIVE=1\nSP_SCAN_PID=777\nSP_SCAN_STATUS=running\nSP_SCAN_STARTED_AT=2026-08-20T03:00:00Z\nSP_SCAN_LAST_MOUNT=/data\n";
        let info = parse_scan_status_output(output);
        assert!(info.installed);
        assert!(info.active);
        assert_eq!(info.pid, Some(777));
        assert_eq!(info.state, "running");
        assert_eq!(info.last_mount.as_deref(), Some("/data"));
    }

    #[test]
    fn inject_script_writes_scan_sh() {
        let inject = generate_agent_inject_script("#!/bin/sh\nagent", "interval=5\n", "#!/bin/sh\nscan");
        assert!(inject.contains("SERVERPULSE_SCAN_EOF"));
        assert!(inject.contains("#!/bin/sh\nscan"));
    }
}
```

Run: `cargo test --workspace --manifest-path src-tauri/Cargo.toml scan_tests`
Expected: 编译失败。

- [ ] **Step 2: 实现**

(a) 在 `generate_agent_uninstall_script` 之后新增：

```rust
pub fn generate_scan_deploy_and_trigger_script(scan_script: &str, server_id: &str) -> String {
    format!(
        r#"sp="$HOME/.serverpulse"
umask 077
mkdir -p "$sp/state" "$sp/attribution" 2>/dev/null || {{ echo 'SP_SCAN_RESULT=error'; echo 'SP_SCAN_ERROR=mkdir failed'; exit 0; }}
cat > "$sp/scan.sh" <<'SERVERPULSE_SCAN_EOF'
{scan}
SERVERPULSE_SCAN_EOF
chmod +x "$sp/scan.sh" 2>/dev/null
if [ -f "$sp/state/scan.lock" ]; then
  sp_old=$(cat "$sp/state/scan.lock" 2>/dev/null)
  case "$sp_old" in
    ''|*[!0-9]*) rm -f "$sp/state/scan.lock" ;;
    *) if kill -0 "$sp_old" 2>/dev/null; then echo 'SP_SCAN_RESULT=already_running'; exit 0; else rm -f "$sp/state/scan.lock"; fi ;;
  esac
fi
export SERVERPULSE_SERVER_ID="{server_id}"
( cd "$HOME" && if command -v setsid >/dev/null 2>&1; then nohup setsid sh "$sp/scan.sh" >>"$sp/scan.log" 2>&1 </dev/null & else nohup sh "$sp/scan.sh" >>"$sp/scan.log" 2>&1 </dev/null & fi )
echo 'SP_SCAN_RESULT=launched'"#,
        scan = scan_script.trim_end(),
        server_id = sanitize_agent_value(server_id)
    )
}

pub fn generate_scan_status_script() -> &'static str {
    r#"sp="$HOME/.serverpulse"
if [ -f "$sp/scan.sh" ]; then echo 'SP_SCAN_INSTALLED=1'; else echo 'SP_SCAN_INSTALLED=0'; fi
if [ -f "$sp/state/scan.lock" ]; then
  sp_pid=$(cat "$sp/state/scan.lock" 2>/dev/null)
  if [ -n "$sp_pid" ] && kill -0 "$sp_pid" 2>/dev/null; then
    echo 'SP_SCAN_ACTIVE=1'
    echo "SP_SCAN_PID=$sp_pid"
  else
    echo 'SP_SCAN_ACTIVE=0'
    rm -f "$sp/state/scan.lock"
  fi
else
  echo 'SP_SCAN_ACTIVE=0'
fi
[ -f "$sp/state/scan.status" ] && cat "$sp/state/scan.status"
if [ -d "$sp/attribution" ]; then
  sp_last=""
  for sp_file in "$sp/attribution"/*.jsonl; do
    [ -e "$sp_file" ] && sp_last="$sp_file"
  done
  if [ -n "$sp_last" ]; then
    echo "SP_SCAN_LAST_FILE=$(basename "$sp_last")"
    echo "SP_SCAN_LAST_LINES=$(wc -l < "$sp_last" | tr -d ' ')"
  fi
fi"#
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiskScanStatusInfo {
    pub installed: bool,
    pub active: bool,
    pub pid: Option<u32>,
    pub state: String,
    pub started_at: Option<String>,
    pub finished_at: Option<String>,
    pub last_mount: Option<String>,
    pub last_file: Option<String>,
}

pub fn parse_scan_status_output(output: &str) -> DiskScanStatusInfo {
    let mut fields = HashMap::new();
    for line in output.lines() {
        let clean = line.trim();
        if let Some((k, v)) = clean.split_once('=') {
            if let Some(key_tail) = k.strip_prefix("SP_SCAN_") {
                fields.insert(key_tail.to_owned(), v.to_owned());
            }
        }
    }
    DiskScanStatusInfo {
        installed: fields.get("INSTALLED").map(|v| v == "1").unwrap_or(false),
        active: fields.get("ACTIVE").map(|v| v == "1").unwrap_or(false),
        pid: fields.get("PID").and_then(|v| v.parse::<u32>().ok()),
        state: fields.get("STATUS").cloned().unwrap_or_else(|| "unknown".to_owned()),
        started_at: fields.get("STARTED_AT").cloned(),
        finished_at: fields.get("FINISHED_AT").cloned(),
        last_mount: fields.get("LAST_MOUNT").filter(|v| !v.is_empty()).cloned(),
        last_file: fields.get("LAST_FILE").cloned(),
    }
}
```

(b) `generate_agent_inject_script` 签名改为 `(agent_script: &str, config_text: &str, scan_script: &str)`，heredoc 写完 agent.sh 与 config 后追加写 scan.sh：

```sh
cat > "$sp/scan.sh" <<'SERVERPULSE_SCAN_EOF'
{scan}
SERVERPULSE_SCAN_EOF
chmod +x "$sp/scan.sh" 2>/dev/null
```

format! 参数补 `scan = scan_script.trim_end()`。

- [ ] **Step 3: 运行确认通过**

Run: `cargo test --workspace --manifest-path src-tauri/Cargo.toml`
Expected: 编译错误会指出 main.rs 两处旧签名调用（deploy_and_start_agent / restart_agent）——本任务先以最小改动修复编译：在这两处把第三个实参传 `""` 占位并在 Task 8 换成真实脚本。全部 PASS 后提交。

- [ ] **Step 4: 提交**

```bash
git add src-tauri/crates/serverpulse-core/src/agent.rs src-tauri/src/main.rs
git commit -m "feat(agent): generate scan deploy/trigger/status scripts and deploy scan.sh on inject"
```

---

### Task 8: Tauri 命令 trigger_disk_scan / get_disk_scan_status + 配置贯通

**Files:**
- Modify: `src-tauri/src/main.rs`（常量区、新命令、`deploy_and_start_agent`/`restart_agent`/`update_agent_config`、invoke_handler 注册表 L2546-2590）
- Modify: `src-tauri/crates/serverpulse-platform/src/lib.rs`（`AgentServerState` 增加字段）

**Interfaces:**
- Consumes: Task 7 的生成函数、Task 5 的 SCAN_SCRIPT。
- Produces（前端 Task 10 依赖）:
  - `trigger_disk_scan(serverId)` → `{ serverId, status: 'launched'|'already-running'|'failed', detail? }`
  - `get_disk_scan_status(serverId)` → `DiskScanStatusInfo`
  - `deploy_and_start_agent(serverId, intervalSeconds, retentionDays, scanEnabled, scanHour)`、`update_agent_config(…同四个参数…)`
  - `AgentServerState` 新增 `scanEnabled: bool`（默认 true）、`scanHour: u32`（默认 3）

- [ ] **Step 1: platform 结构体扩展**

`AgentServerState` 在 `retention_days` 之后加：

```rust
    #[serde(default = "default_scan_enabled")]
    pub scan_enabled: bool,
    #[serde(default = "default_scan_hour")]
    pub scan_hour: u32,
```

文件内加默认函数，并同步 `Default for AgentServerState` 手写实现与现有测试 `agent_state_round_trip` 的结构体字面量（补 `scan_enabled: true, scan_hour: 3,`）：

```rust
fn default_scan_enabled() -> bool {
    true
}

fn default_scan_hour() -> u32 {
    3
}
```

- [ ] **Step 2: main.rs 常量与新命令**

(a) 常量区（`SAMPLE_SCRIPT` 之后）加：

```rust
const SCAN_SCRIPT: &str = include_str!("../../assets/serverpulse-scan.sh");
```

(b) `uninstall_agent` 命令之后新增：

```rust
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct DiskScanTriggerResult {
    server_id: String,
    status: String, // launched | already-running | failed
    detail: Option<String>,
}

#[tauri::command]
async fn trigger_disk_scan(
    state: State<'_, AppState>,
    server_id: String,
) -> Result<DiskScanTriggerResult, String> {
    let (_server, target, _data_root) = resolve_server_and_target(&server_id, &state).await?;
    let ssh = SystemOpenSsh::default();
    let script = serverpulse_core::generate_scan_deploy_and_trigger_script(SCAN_SCRIPT, &server_id);
    let output = ssh
        .execute_short_command(&target, &script)
        .await
        .map_err(to_command_error)?;
    if output.stdout.contains("SP_SCAN_RESULT=launched") {
        Ok(DiskScanTriggerResult { server_id, status: "launched".to_owned(), detail: None })
    } else if output.stdout.contains("SP_SCAN_RESULT=already_running") {
        Ok(DiskScanTriggerResult { server_id, status: "already-running".to_owned(), detail: None })
    } else {
        let detail = if output.stderr.is_empty() {
            "scan trigger did not report a launch".to_owned()
        } else {
            output.stderr.lines().take(2).collect::<Vec<_>>().join(" ")
        };
        Ok(DiskScanTriggerResult { server_id, status: "failed".to_owned(), detail: Some(detail) })
    }
}

#[tauri::command]
async fn get_disk_scan_status(
    state: State<'_, AppState>,
    server_id: String,
) -> Result<serverpulse_core::DiskScanStatusInfo, String> {
    let (_server, target, _data_root) = resolve_server_and_target(&server_id, &state).await?;
    let ssh = SystemOpenSsh::default();
    let output = ssh
        .execute_short_command(&target, serverpulse_core::generate_scan_status_script())
        .await
        .map_err(to_command_error)?;
    Ok(serverpulse_core::parse_scan_status_output(&output.stdout))
}
```

(c) invoke_handler 列表 `pull_and_merge_all_records` 之后追加 `trigger_disk_scan, get_disk_scan_status,`。

- [ ] **Step 3: 配置参数贯通**

(a) `deploy_and_start_agent` 与 `update_agent_config` 签名各加 `scan_enabled: bool, scan_hour: u32`；两处 `generate_agent_config(…)` 调用补实参；`generate_agent_script(…)` 调用补两个实参；`generate_agent_inject_script(…)` 第三实参传 `SCAN_SCRIPT`；entry 更新处加 `entry.scan_enabled = scan_enabled; entry.scan_hour = scan_hour;`。

(b) `restart_agent`：从 existing_entry 读默认值——

```rust
    let scan_enabled = existing_entry.map(|e| e.scan_enabled).unwrap_or(true);
    let scan_hour = existing_entry.map(|e| e.scan_hour).unwrap_or(3);
```

并按 (a) 同样方式传参。

(c) `check_agent_status`/`check_all_agent_statuses` 中 `or_insert_with(|| AgentServerState { id: …, ..Default::default() })` 无需改动（Default 已含新字段）。

- [ ] **Step 4: 验证**

Run: `cargo fmt --manifest-path src-tauri/Cargo.toml -- --check && cargo test --workspace --manifest-path src-tauri/Cargo.toml`
Expected: 全部 PASS。再 `cargo check` 确认无 warning 级未使用变量。

- [ ] **Step 5: 提交**

```bash
git add src-tauri/src/main.rs src-tauri/crates/serverpulse-platform/src/lib.rs
git commit -m "feat(app): add disk scan trigger/status commands and scan schedule config"
```

---

### Task 9: 归因拉取合并 + query_history 扩展 + 远端清理

**Files:**
- Modify: `src-tauri/crates/serverpulse-core/src/agent.rs`（`generate_agent_pull_script`、`generate_agent_clean_script`、新增 `parse_agent_attribution_output`、测试）
- Modify: `src-tauri/src/main.rs`（`pull_and_merge_records_impl`、`HistoryResponse`、`query_history`）

**Interfaces:**
- Consumes: Task 6 的 `parse_disk_attribution_line`/`merge_attribution_lines`。
- Produces:
  - `parse_agent_attribution_output(output: &str) -> (Vec<(String /*utc_day*/, String /*line*/)>, usize /*corrupt*/)`
  - `AgentMergeResult` 新增 `attributionLines: usize`
  - `HistoryResponse` 新增 `diskAttribution: Vec<DiskAttributionRecord>`（前端 Task 10 依赖）
  - 本地目录 `<data-root>/history/attribution/<utc-day>.jsonl`

- [ ] **Step 1: 写失败测试**

`agent.rs` 的 `mod tests`（core lib.rs 的测试在 lib.rs；agent.rs 无测试模块，新增一个）：

```rust
#[cfg(test)]
mod attribution_pull_tests {
    use super::*;

    #[test]
    fn parses_attribution_lines_from_pull_output() {
        let output = concat!(
            "__SP_FILE__2026-08-19\n",
            "{\"Version\":2,\"Record\":{\"Timestamp\":\"2026-08-19T10:00:00Z\",\"SampleCount\":1,\"Servers\":[]}}\n",
            "SP_AGENT_RECORD_FILES=1\n",
            "__SP_ATTR_FILE__2026-08-20\n",
            "{\"kind\":\"diskAttribution\",\"serverId\":\"s1\",\"scannedAt\":\"2026-08-20T03:12:45Z\",\"mount\":\"/data\",\"status\":\"ok\",\"durationSeconds\":10,\"skippedEntries\":0,\"users\":[{\"uid\":\"1000\",\"name\":\"alice\",\"usedMib\":12}]}\n",
            "broken-line\n",
            "__SP_DONE__\n",
        );
        let (rows, corrupt) = parse_agent_attribution_output(output);
        assert_eq!(rows.len(), 1);
        assert_eq!(corrupt, 1);
        assert_eq!(rows[0].0, "2026-08-20");
        assert!(rows[0].1.contains("diskAttribution"));
    }
}
```

Run: `cargo test --workspace --manifest-path src-tauri/Cargo.toml attribution_pull`
Expected: 编译失败。

- [ ] **Step 2: agent.rs 实现**

(a) `generate_agent_pull_script` 的 records 循环结束后、`echo "SP_AGENT_RECORD_FILES=…"` 之前插入（注意 format! 转义 `{{`）：

```sh
if [ -d "$sp/attribution" ]; then
  for sp_file in "$sp/attribution"/*.jsonl; do
    [ -e "$sp_file" ] || continue
    sp_base=${{sp_file##*/}}
    case "$sp_base" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].jsonl) ;;
      *) continue ;;
    esac
    echo "__SP_ATTR_FILE__${{sp_base%.jsonl}}"
    cat "$sp_file"
  done
fi
```

（归因文件很小，不做 cursor 过滤；去重交给本地 merge。）

(b) `generate_agent_clean_script` 在 `echo '__SP_DONE__'` 之前插入（复用同一 cursor 日期）：

```sh
if [ -n "$sp_cursor" ] && [ -d "$sp/attribution" ]; then
  for sp_file in "$sp/attribution"/*.jsonl; do
    [ -e "$sp_file" ] || continue
    sp_base=${{sp_file##*/}}
    sp_date=${{sp_base%.jsonl}}
    case "$sp_date" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) continue ;;
    esac
    if awk -v a="$sp_date" -v b="$sp_cursor_date" 'BEGIN {{ exit !(a < b) }}'; then
      rm -f "$sp_file" 2>/dev/null
      echo "SP_AGENT_CLEANED_ATTR=$sp_date"
    fi
  done
fi
```

(c) 新增解析函数（`parse_agent_pull_output` 之后）：

```rust
pub fn parse_agent_attribution_output(output: &str) -> (Vec<(String, String)>, usize) {
    let mut rows = Vec::new();
    let mut corrupt = 0usize;
    let mut current_day: Option<String> = None;
    for line in output.lines() {
        let clean = line.trim();
        if clean.is_empty() || clean == "__SP_DONE__" {
            continue;
        }
        if let Some(day) = clean.strip_prefix("__SP_ATTR_FILE__") {
            current_day = Some(day.to_owned());
            continue;
        }
        if clean.starts_with("SP_AGENT_") || clean.starts_with("__SP_FILE__") || clean.starts_with("SP_AGENT_CLEANED") {
            continue;
        }
        // Minute-record lines belong to parse_agent_pull_output; skip them here.
        let parsed: Option<serde_json::Value> = serde_json::from_str(clean).ok();
        if parsed.as_ref().and_then(|v| v.get("Record")).is_some() {
            continue;
        }
        let Some(day) = current_day.clone() else {
            continue;
        };
        match serverpulse_core_parse_attribution(clean) {
            Ok(_) => rows.push((day, clean.to_owned())),
            Err(_) => corrupt += 1,
        }
    }
    (rows, corrupt)
}

fn serverpulse_core_parse_attribution(
    line: &str,
) -> Result<crate::DiskAttributionRecord, crate::ServerPulseError> {
    crate::parse_disk_attribution_line(line)
}
```

（`serverpulse_core_parse_attribution` 只是让示例自洽——agent.rs 属于 core crate，直接调用 `parse_disk_attribution_line(clean)?` 即可，无需包装；实现时直接用 `super::parse_disk_attribution_line`。）

- [ ] **Step 3: main.rs 合并与查询**

(a) `pull_and_merge_records_impl`：在 day_groups 写盘循环之后、`if clean_remote` 之前插入：

```rust
    let (attr_rows, attr_corrupt) =
        serverpulse_core::parse_agent_attribution_output(&output.stdout);
    let attribution_dir = history_dir.join("attribution");
    let _ = fs::create_dir_all(&attribution_dir);
    let mut attr_days: std::collections::BTreeMap<String, Vec<String>> = Default::default();
    for (day, line) in attr_rows {
        attr_days.entry(day).or_default().push(line);
    }
    for (day, lines) in &attr_days {
        let path = attribution_dir.join(format!("{day}.jsonl"));
        let existing = fs::read_to_string(&path).unwrap_or_default();
        let incoming = lines.join("\n") + "\n";
        let merged = serverpulse_core::merge_attribution_lines(&existing, &incoming);
        let _ = serverpulse_platform::atomic_write(&path, merged.as_bytes());
    }
```

`AgentMergeResult` 结构体加 `pub attribution_lines: usize,`，构造处（含 pull_and_merge_all_records 的 error 分支）填 `attribution_lines: attr_rows_total`（把 `attr_rows.len()` 累计保存；error 分支填 0）；`last_merge_summary` 追加 `", {} attribution lines"`。

(b) `HistoryResponse` 加字段：

```rust
    disk_attribution: Vec<serverpulse_core::DiskAttributionRecord>,
```

`query_history` 中 candidate_days 循环之后：

```rust
    let mut disk_attribution = Vec::new();
    for candidate in candidate_days.iter() {
        let path = store
            .history_root
            .join("attribution")
            .join(format!("{candidate}.jsonl"));
        if path.exists() {
            let text = fs::read_to_string(&path).unwrap_or_default();
            for line in text.lines() {
                if let Ok(record) = serverpulse_core::parse_disk_attribution_line(line) {
                    disk_attribution.push(record);
                }
            }
        }
    }
    disk_attribution.sort_by(|a, b| a.scanned_at.cmp(&b.scanned_at));
```

返回值补 `disk_attribution,`。

- [ ] **Step 4: 验证**

Run: `cargo test --workspace --manifest-path src-tauri/Cargo.toml`
Expected: 全部 PASS（含 Task 9 新测试与既有 `agent_pull_and_merge_day_entries`）。

- [ ] **Step 5: 提交**

```bash
git add src-tauri/crates/serverpulse-core/src/agent.rs src-tauri/src/main.rs
git commit -m "feat(merge): pull and merge disk attribution records into local history"
```

---

### Task 10: 前端类型、store 与单元测试

**Files:**
- Modify: `frontend/src/types.ts`
- Modify: `frontend/src/stores/monitor.ts`
- Modify: `frontend/src/stores/monitor.spec.ts`

**Interfaces:**
- Consumes: Task 8/9 的命令与响应形状。
- Produces:
  - types：`DiskMetric`、`DiskUserUsage`、`DiskAttributionRecord`、`DiskScanStatusInfo`；`MetricSnapshot.disks`
  - store：`loadHistory` 存 `diskAttribution`；`triggerDiskScan(serverId)`、`fetchDiskScanStatus(serverId)`、state `diskScans: Record<string, DiskScanStatusInfo>`

- [ ] **Step 1: types.ts 追加**

```ts
export interface DiskMetric {
  device: string
  mount: string
  totalMib: number | null
  usedMib: number | null
  percent: number | null
  fsType: string
}

export interface DiskUserUsage {
  uid: string
  name: string
  usedMib: number
}

export interface DiskAttributionRecord {
  kind: string
  serverId: string
  scannedAt: string
  mount: string
  device?: string | null
  fsType?: string | null
  totalMib?: number | null
  usedMib?: number | null
  percent?: number | null
  status: UserUsageStatus
  durationSeconds?: number | null
  skippedEntries: number
  users: DiskUserUsage[]
}

export interface DiskScanStatusInfo {
  installed: boolean
  active: boolean
  pid?: number | null
  state: string
  startedAt?: string | null
  finishedAt?: string | null
  lastMount?: string | null
  lastFile?: string | null
}

export interface DiskScanTriggerResult {
  serverId: string
  status: 'launched' | 'already-running' | 'failed' | string
  detail?: string | null
}
```

`MetricSnapshot` 在 `gpus: GpuMetric[]` 后加 `disks: DiskMetric[]`。

- [ ] **Step 2: 写失败测试（monitor.spec.ts）**

mock invoke 增加分支（`query_history` 与 `trigger_disk_scan`）：

```ts
    if (command === 'query_history') {
      return {
        entries: [],
        corruptLines: 0,
        diskAttribution: [
          {
            kind: 'diskAttribution', serverId: '3090', scannedAt: '2026-08-20T03:12:45Z',
            mount: '/data', status: 'ok', skippedEntries: 0,
            users: [{ uid: '1000', name: 'alice', usedMib: 1234567 }],
          },
        ],
      }
    }
    if (command === 'trigger_disk_scan') {
      return { serverId: args?.serverId, status: 'launched', detail: null }
    }
```

新测试用例（describe 内追加）：

```ts
  it('loads disk attribution with history', async () => {
    setActivePinia(createPinia())
    const store = useMonitorStore()
    await store.init()
    await store.loadHistory('2026-08-21')
    expect(store.diskAttribution).toHaveLength(1)
    expect(store.diskAttribution[0].mount).toBe('/data')
  })

  it('triggers disk scan and stores status', async () => {
    setActivePinia(createPinia())
    const store = useMonitorStore()
    await store.init()
    const result = await store.triggerDiskScan('3090')
    expect(result.status).toBe('launched')
    expect(store.diskScans['3090'].state).toBe('running')
  })
```

Run: `npm --prefix frontend run test:unit`
Expected: FAIL（store 无对应成员）。

- [ ] **Step 3: monitor.ts 实现**

(a) import type 区补 `DiskAttributionRecord, DiskScanStatusInfo, DiskScanTriggerResult`。

(b) state 增加：

```ts
    diskAttribution: [] as DiskAttributionRecord[],
    diskScans: {} as Record<string, DiskScanStatusInfo>,
```

（state() 返回对象里初始化 `diskAttribution: []`、`diskScans: {}`。）

(c) `loadHistory` 改为：

```ts
    async loadHistory(day: string) {
      const response = await invoke<{ entries: HistoryEntry[]; corruptLines: number; diskAttribution?: DiskAttributionRecord[] }>('query_history', { day })
      this.history = response.entries
      this.historyCorruptLines = response.corruptLines
      this.diskAttribution = response.diskAttribution ?? []
    },
```

(d) actions 末尾追加：

```ts
    async triggerDiskScan(serverId: string) {
      const result = await invoke<DiskScanTriggerResult>('trigger_disk_scan', { serverId })
      if (result.status === 'launched' || result.status === 'already-running') {
        this.diskScans = {
          ...this.diskScans,
          [serverId]: {
            installed: true,
            active: true,
            pid: null,
            state: 'running',
            startedAt: null,
            finishedAt: null,
            lastMount: null,
            lastFile: null,
          },
        }
      }
      return result
    },
    async fetchDiskScanStatus(serverId: string) {
      const status = await invoke<DiskScanStatusInfo>('get_disk_scan_status', { serverId })
      this.diskScans = { ...this.diskScans, [serverId]: status }
      return status
    },
```

- [ ] **Step 4: 运行确认通过**

Run: `npm --prefix frontend run typecheck && npm --prefix frontend run test:unit`
Expected: 全部 PASS。

- [ ] **Step 5: 提交**

```bash
git add frontend/src/types.ts frontend/src/stores/monitor.ts frontend/src/stores/monitor.spec.ts
git commit -m "feat(frontend): disk metric types, scan actions, and attribution in store"
```

---

### Task 11: ServerCard DISK 行、展开列表、扫描按钮与归因弹窗

**Files:**
- Modify: `frontend/src/composables/useUserUsagePopup.ts`
- Modify: `frontend/src/components/ServerCard.vue`
- Modify: `frontend/src/components/UserUsagePopup.vue`
- Modify: `frontend/src/views/MainView.vue`

**Interfaces:**
- Consumes: Task 10 的 types 与 store actions。
- Produces: 卡片 DISK 行（最高使用率挂载点）、可展开的挂载点列表（含每行 hover/click 归因 + 「立即扫描」按钮）、弹窗磁盘分支。

- [ ] **Step 1: useUserUsagePopup.ts**

`export type UserUsageKind = 'cpu' | 'memory' | 'vram' | 'disk'`；`UserUsageTargetInfo` 增加 `mount?: string`。

- [ ] **Step 2: ServerCard.vue**

(a) props 扩展：

```ts
const props = defineProps<{
  server: ServerConfig
  snapshot?: MetricSnapshot
  status: string
  error?: string
  diskAttribution?: DiskAttributionRecord[]
  diskScanStatus?: DiskScanStatusInfo
}>()

defineEmits<{
  start: []
  stop: []
  recheck: []
  scan: []
}>()
```

import type 补 `DiskAttributionRecord, DiskScanStatusInfo`。

(b) script 增加辅助逻辑：

```ts
const disksExpanded = ref(false)

const worstDisk = computed(() => {
  const disks = (props.snapshot?.disks ?? []).filter((d) => d.percent != null)
  if (!disks.length) return null
  return disks.reduce((a, b) => ((b.percent ?? 0) > (a.percent ?? 0) ? b : a))
})

function formatCapacity(usedMib: number | null, totalMib: number | null) {
  const fmt = (v: number | null) => (v != null ? (v / 1048576).toFixed(1) : '—')
  return `${fmt(usedMib)} / ${fmt(totalMib)} TB`
}

function attributionFor(mount: string) {
  return (props.diskAttribution ?? []).find((record) => record.mount === mount) ?? null
}

function handleDiskEnter(disk: DiskMetric, event: MouseEvent) {
  if (!props.snapshot) return
  onTargetMouseEnter(
    { serverId: props.server.id, serverLabel: props.server.label, kind: 'disk', mount: disk.mount },
    event.currentTarget as HTMLElement,
  )
}

function handleDiskClick(disk: DiskMetric, event: MouseEvent) {
  if (!props.snapshot) return
  onTargetClick(
    { serverId: props.server.id, serverLabel: props.server.label, kind: 'disk', mount: disk.mount },
    event.currentTarget as HTMLElement,
  )
}
```

import 补 `computed, ref` from 'vue' 与 `type DiskMetric`。

(c) template：metrics-grid 内 MEM metric 之后加第三个格子：

```html
      <div
        v-if="worstDisk"
        class="metric is-interactive"
        :class="{
          'is-active': isTargetActive('disk'),
          'is-pinned': isTargetActive('disk') && isPinned
        }"
        title="查看磁盘各用户占用 (点击可固定)"
        @mouseenter="handleDiskEnter(worstDisk, $event)"
        @mouseleave="onTargetMouseLeave"
        @click.stop="handleDiskClick(worstDisk, $event)"
      >
        <span>DISK</span>
        <strong>{{ worstDisk.percent != null ? worstDisk.percent.toFixed(0) + '%' : '—' }} · {{ formatCapacity(worstDisk.usedMib, worstDisk.totalMib) }}</strong>
      </div>
```

GPU 网格之后、error 段之前加展开区：

```html
    <div v-if="snapshot && snapshot.disks && snapshot.disks.length" class="disk-section">
      <button type="button" class="disk-toggle" @click.stop="disksExpanded = !disksExpanded">
        {{ disksExpanded ? '收起磁盘' : `全部磁盘 (${snapshot.disks.length})` }}
      </button>
      <template v-if="disksExpanded">
        <div
          v-for="disk in snapshot.disks"
          :key="disk.mount"
          class="disk-row is-interactive"
          @mouseenter="handleDiskEnter(disk, $event)"
          @mouseleave="onTargetMouseLeave"
          @click.stop="handleDiskClick(disk, $event)"
        >
          <span class="disk-mount" :title="disk.device">{{ disk.mount }}</span>
          <span class="disk-val">{{ disk.percent != null ? disk.percent.toFixed(0) + '%' : '—' }} · {{ formatCapacity(disk.usedMib, disk.totalMib) }}</span>
          <div class="gpu-bar-track">
            <div class="gpu-bar-fill vram-bar" :class="{ 'is-high': (disk.percent ?? 0) >= 80 }" :style="{ width: (disk.percent ?? 0) + '%' }" />
          </div>
        </div>
        <div class="disk-scan-row">
          <button
            type="button"
            :disabled="diskScanStatus?.active"
            @click.stop="$emit('scan')"
          >
            {{ diskScanStatus?.active ? `扫描中…${diskScanStatus.lastMount ? ' (' + diskScanStatus.lastMount + ')' : ''}` : '立即扫描' }}
          </button>
          <span v-if="diskAttribution && diskAttribution.length" class="muted">
            来自 {{ new Date(diskAttribution[0].scannedAt).toLocaleDateString() }} 扫描
          </span>
          <span v-else class="muted">需服务端 agent 或手动扫描</span>
        </div>
      </template>
    </div>
```

(d) `<style>` 无独立块（样式在全局 styles.css）——在 `frontend/src/styles.css` 末尾追加：

```css
.disk-section { margin-top: 6px; }
.disk-toggle { background: none; border: none; color: inherit; opacity: .7; font-size: 11px; cursor: pointer; padding: 2px 0; }
.disk-row { display: grid; grid-template-columns: auto 1fr; gap: 2px 8px; padding: 3px 0; }
.disk-row .gpu-bar-track { grid-column: 1 / -1; }
.disk-mount { font-weight: 600; font-size: 12px; }
.disk-val { font-size: 12px; text-align: right; }
.disk-scan-row { display: flex; align-items: center; gap: 8px; margin-top: 4px; }
.disk-scan-row button { font-size: 11px; padding: 2px 8px; cursor: pointer; }
.disk-scan-row button:disabled { opacity: .5; cursor: default; }
```

- [ ] **Step 3: UserUsagePopup.vue**

(a) props 增加 `diskAttribution?: DiskAttributionRecord | null`（import type 补齐）。

(b) `title` computed 开头加分支：

```ts
  if (props.target.kind === 'disk') {
    return `${props.target.serverLabel} · DISK ${props.target.mount} · 用户占用`
  }
```

(c) `status` computed 开头加：`if (props.target.kind === 'disk') return props.diskAttribution?.status ?? 'unavailable'`。

(d) `userRows` computed 开头加：

```ts
  if (props.target.kind === 'disk') {
    const record = props.diskAttribution
    if (!record) return []
    return record.users
      .map((u) => ({
        key: `disk-${u.uid || u.name}`,
        name: u.name || `UID ${u.uid}`,
        processCount: null,
        displayValue: `${(u.usedMib / 1024).toFixed(1)} GB`,
        sortValue: u.usedMib,
      }))
      .sort((a, b) => b.sortValue - a.sortValue)
  }
```

(e) `systemRow` computed 开头加：

```ts
  if (props.target.kind === 'disk') {
    const record = props.diskAttribution
    if (!record || record.status === 'unavailable' || record.usedMib == null) return null
    const usersSum = record.users.reduce((acc, u) => acc + u.usedMib, 0)
    const sys = Math.max(0, record.usedMib - usersSum)
    const pct = record.totalMib ? (sys / record.totalMib) * 100 : 0
    return { name: '系统 / 未归属', displayValue: `${(sys / 1024).toFixed(1)} GB · ${pct.toFixed(1)}%` }
  }
```

(f) 状态条下加新鲜度行（`user-popup-status-bar` div 内、count span 之后）：

```html
        <span v-if="target?.kind === 'disk' && diskAttribution" class="user-popup-count">
          {{ new Date(diskAttribution.scannedAt).toLocaleDateString() }} 扫描
        </span>
        <span v-if="target?.kind === 'disk' && !diskAttribution" class="user-popup-count">需服务端 agent 或手动扫描</span>
```

- [ ] **Step 4: MainView.vue 接线**

(a) `<ServerCard …>` 增加 props 与事件：

```html
        :disk-attribution="store.diskAttribution.filter((r) => r.serverId === server.id)"
        :disk-scan-status="store.diskScans[server.id]"
        @scan="store.triggerDiskScan(server.id).then(() => store.fetchDiskScanStatus(server.id)).catch(() => undefined)"
```

(b) `<UserUsagePopup …>` 增加 prop。MainView script 里已有 `currentTarget`；新增 computed：

```ts
const currentDiskAttribution = computed(() => {
  const target = currentTarget.value
  if (!target || target.kind !== 'disk') return null
  return (
    store.diskAttribution.find(
      (r) => r.serverId === target.serverId && r.mount === target.mount,
    ) ?? null
  )
})
```

模板传 `:disk-attribution="currentDiskAttribution"`。

- [ ] **Step 5: 验证**

Run: `npm --prefix frontend run typecheck && npm --prefix frontend run test:unit && npm --prefix frontend run build`
Expected: 全部 PASS。
手工冒烟：`npm run dev --prefix frontend` 浏览器打开——无 snapshot 时无 DISK 行（正常）；用 Vue devtools 或临时 mock 数据验证展开列表与按钮渲染。

- [ ] **Step 6: 提交**

```bash
git add frontend/src/composables/useUserUsagePopup.ts frontend/src/components/ServerCard.vue frontend/src/components/UserUsagePopup.vue frontend/src/views/MainView.vue frontend/src/styles.css
git commit -m "feat(ui): disk row with per-mount breakdown, attribution popup, and manual scan button"
```

---

### Task 12: HistoryView 磁盘视图与归因曲线

**Files:**
- Modify: `frontend/src/views/HistoryView.vue`

**Interfaces:**
- Consumes: Task 10 的 `DiskAttributionRecord`（store.diskAttribution）、分钟记录里的 `Disks` 字段。
- Produces: `ChartViewMode` 新增 `'disk'`；磁盘视图含 (a) 每挂载点使用率分钟曲线，(b) 每用户已用 GB 的日级阶梯曲线（来自归因记录）。

- [ ] **Step 1: 类型与解析**

(a) `type ChartViewMode = 'all' | 'cpu' | 'gpu_vram' | 'gpu_util' | 'gpu_temp' | 'disk' | 'users'`（L38）。

(b) `ServerHistoryRecord` 增加字段：

```ts
  disks: { mount: string; percent: (number | null)[]; usedGb: (number | null)[] }[]
```

(c) 在 `parseGpuUserMemory` 之后新增解析辅助：

```ts
function parseDiskEntries(s: any): { mount: string; percent: number | null; usedMib: number | null }[] {
  const list = Array.isArray(s?.Disks) ? s.Disks : (Array.isArray(s?.disks) ? s.disks : [])
  return list.map((d: any) => ({
    mount: String(d.Mount ?? d.mount ?? ''),
    percent: typeof d.Percent === 'number' ? d.Percent : (typeof d.percent === 'number' ? d.percent : null),
    usedMib: typeof d.UsedMiB === 'number' ? d.UsedMiB : (typeof d.usedMib === 'number' ? d.usedMib : null),
  }))
}
```

(d) 在构建 `ServerHistoryRecord` 的聚合函数中（定位：`gpusMap` 聚合所在函数，`item.gpusMap.set(idx, …)` 附近同样用 Map 按挂载点累积）：

```ts
        for (const d of parseDiskEntries(s)) {
          if (!d.mount) continue
          if (!item.disksMap.has(d.mount)) {
            item.disksMap.set(d.mount, { percent: [], usedMib: [] })
          }
          const bucket = item.disksMap.get(d.mount)!
          bucket.percent.push(d.percent)
          bucket.usedMib.push(d.usedMib)
        }
```

（`item` 初始化处加 `disksMap: new Map<string, { percent: (number | null)[]; usedMib: (number | null)[] }>()`；最终组装 `ServerHistoryRecord` 时：

```ts
      disks: Array.from(item.disksMap.entries()).map(([mount, bucket]) => ({
        mount,
        percent: bucket.percent,
        usedGb: bucket.usedMib.map((v) => (v != null ? v / 1024 : null)),
      })),
```

执行者需对照该函数内 gpus 数组「push null 占位」的对齐方式处理无磁盘样本（无 Disks 的样本对每个已存在 mount push null，保持与 timestamps 等长）：

```ts
        if (item.disksMap.size > 0 && parseDiskEntries(s).length === 0) {
          for (const bucket of item.disksMap.values()) {
            bucket.percent.push(null)
            bucket.usedMib.push(null)
          }
        }
```

)

- [ ] **Step 2: 磁盘图表构建**

(a) 视图模式选择器（template 中现有 `chartViewModes` 相关的按钮组）按现有 GPU 模式按钮的同构方式增加一项，label `磁盘`，value `disk`。

(b) 新增 computed `diskChartOption`（仿照现有 `gpuVrams`/chart option computed 的结构，放在它们旁边）：

```ts
const DISK_MOUNT_COLORS = ['#38bdf8', '#a3e635', '#fbbf24', '#f472b6', '#c084fc', '#fb923c']

const diskUserSeries = computed(() => {
  const serverId = /* 与其他 computed 相同的当前选中服务器 id 来源 */
  const records = store.diskAttribution.filter((r) => r.serverId === serverId)
  const byUser = new Map<string, { name: string; points: [string, number][] }>()
  for (const record of records) {
    for (const u of record.users) {
      const key = u.uid || u.name
      if (!byUser.has(key)) byUser.set(key, { name: u.name, points: [] })
      byUser.get(key)!.points.push([record.scannedAt, u.usedMib / 1024])
    }
  }
  return Array.from(byUser.values())
    .sort((a, b) => a.name.localeCompare(b.name))
    .slice(0, 3) // 用户曲线最多 3 条，与现有约定一致
})
```

图表 series（在磁盘视图的 option computed 中）：

```ts
    series: [
      ...server.disks.map((d, i) => ({
        name: d.mount,
        type: 'line' as const,
        showSymbol: false,
        connectNulls: false,
        data: d.percent,
        yAxisIndex: 0,
        itemStyle: { color: DISK_MOUNT_COLORS[i % DISK_MOUNT_COLORS.length] },
      })),
      ...diskUserSeries.value.map((u) => ({
        name: `${u.name} (GB)`,
        type: 'line' as const,
        step: 'end' as const, // 日级阶梯：两次扫描之间保持上次值，不线性插值
        data: u.points,
        yAxisIndex: 1,
      })),
    ],
    // option 需要双 y 轴：yAxis[0] 百分比 0-100，yAxis[1] GB（min: 0）
```

图例/tooltip/网格沿用同文件现有 option 写法（`legend: { data: … }`、`tooltip: { trigger: 'axis' }`）。执行时以现有 GPU 视图 option computed 为模板，仅替换 series 与 y 轴。

(c) 视图分发处（`chartViewModes` 决定渲染哪个图表的分支链）加 `disk` 分支渲染新图表，并复用 `isSeriesVisible(server.id, 'disk', mount)` 控制每条挂载点曲线显隐。

- [ ] **Step 3: 验证**

Run: `npm --prefix frontend run typecheck && npm --prefix frontend run test:unit && npm --prefix frontend run build`
Expected: 全部 PASS。
手工冒烟：`npm run dev --prefix frontend`，用临时 mock 的 history entries（含 Disks）验证磁盘曲线渲染与空数据降级（无 Disks 时磁盘视图显示空态文案「暂无磁盘数据」）。

- [ ] **Step 4: 提交**

```bash
git add frontend/src/views/HistoryView.vue
git commit -m "feat(history): disk view with per-mount curves and stepped user attribution"
```

---

### Task 13: ManageView 扫描配置 + 文档同步

**Files:**
- Modify: `frontend/src/views/ManageView.vue`
- Modify: `README.md`、`README.zh-CN.md`、`docs/DEVELOPMENT.md`、`CHANGELOG.md`

- [ ] **Step 1: ManageView Configure 面板**

(a) config modal 的响应式状态（`configInterval`/`configRetention` 旁）加：

```ts
const configScanEnabled = ref(true)
const configScanHour = ref(3)
```

(b) `openConfigModal` 补：

```ts
  configScanEnabled.value = existing?.scanEnabled ?? true
  configScanHour.value = existing?.scanHour ?? 3
```

(c) `handleSaveConfig` 校验（retention 校验之后）：

```ts
  if (configScanHour.value < 0 || configScanHour.value > 23) {
    configError.value = '扫描时刻必须在 0 到 23 之间'
    return
  }
```

并把 `store.updateAgentConfig(…)` 调用改为五参：

```ts
    await store.updateAgentConfig(
      configModalServer.value.id,
      configInterval.value,
      configRetention.value,
      configScanEnabled.value,
      configScanHour.value,
    )
```

(d) store 的 `updateAgentConfig`/`deployAndStartAgent` 签名同步加 `scanEnabled = true, scanHour = 3` 参数并透传 invoke args（`monitor.ts`，Task 10 已建文件，此处补参数）。

(e) config modal template（`configRetention` 输入行之后）加：

```html
        <label class="config-field">
          <span>每日磁盘归因扫描</span>
          <input v-model="configScanEnabled" type="checkbox" />
        </label>
        <label class="config-field">
          <span>扫描时刻（服务器本地小时）</span>
          <input v-model.number="configScanHour" type="number" min="0" max="23" />
        </label>
```

（class 名对齐该 modal 现有字段样式。）

- [ ] **Step 2: README.md / README.zh-CN.md**

按 AGENTS.md 规则同步用户手册，两侧等价内容：

- 「What you can do」列表加一条：watch per-filesystem disk capacity and per-user disk attribution (daily scan or on demand)；
- 主窗口章节：DISK 行说明（显示使用率最高文件系统，点击展开全部挂载点；hover/click 查看按用户归因；「立即扫描」按钮，扫描在服务器后台执行，关闭应用不中断）；
- 「Server-side monitoring」章节：agent Configure 新增 每日归因扫描开关与时刻（默认开启、3 点时段）；`~/.serverpulse/` 目录树加 `attribution/yyyy-MM-dd.jsonl`；更新后需 Restart/Inject 一次以获得每日调度（手动触发不受影响）；
- 「Local configuration」数据目录树加 `history\attribution\`；
- 存储规则加：归因记录按 `(serverId, mount, scannedAt)` 去重；记录只含 uid/用户名/字节数/挂载点。

- [ ] **Step 3: docs/DEVELOPMENT.md**

- §2 运行时结构图加 `serverpulse-scan.sh`（第二个 canonical 脚本）与 `history/attribution/`；
- §4 流式 SSH 节补 DISKS 段格式与解析容错；
- §5 IPC 列表补 `trigger_disk_scan(server)` → `DiskScanTriggerResult`、`get_disk_scan_status(server)` → `DiskScanStatusInfo`、`update_agent_config` 新参数；
- §6 数据布局补 attribution 子目录与隐私边界（挂载点路径属运维信息）。

- [ ] **Step 4: CHANGELOG.md**

顶部新增 Unreleased 小节，中英双语对照（格式沿用现有条目风格）：

```markdown
## Unreleased

### Added 新增
- 磁盘容量监控：自动发现真实本地文件系统，主卡片新增 DISK 行与全部挂载点展开列表。 Disk capacity monitoring: auto-discovered real filesystems, new DISK card row with expandable per-mount breakdown.
- 按用户磁盘归因：服务端每日低频扫描（默认 3 点时段、可配置），结果按挂载点记录并合并入本地历史；支持卡片「立即扫描」手动触发（无需安装 agent，detached 执行）。 Per-user disk attribution via daily server-side scans (configurable, default 3am hour) merged into local history, plus an on-demand "Scan now" button that runs detached without requiring the agent.
- History 页新增磁盘视图：每挂载点使用率曲线与按用户已用容量的日级阶梯曲线。 New History disk view: per-mount usage curves and stepped daily per-user curves.

### Changed 变更
- 协议 v2 向后兼容扩展（DISKS 段）；旧 sampler/agent 输出不受影响。 Backward-compatible protocol v2 extension (DISKS section); old samplers/agents keep working.
- agent 配置新增 scan_enabled/scan_hour；更新后需 Restart/Inject 一次以启用每日调度。 Agent config gains scan_enabled/scan_hour; one Restart/Inject is needed after updating to enable daily scheduling.
```

- [ ] **Step 5: 全量验证（发布前门禁，AGENTS.md 规则 2）**

```bash
npm --prefix frontend run typecheck && npm --prefix frontend run test:unit && npm --prefix frontend run test:e2e
npm --prefix frontend run build
cargo fmt --manifest-path src-tauri/Cargo.toml -- --check
cargo test --workspace --manifest-path src-tauri/Cargo.toml
git diff --check && git status --short --branch
git grep -n -E 'password|secret|private_key' -- ':!CHANGELOG.md' | grep -v test || true
```

Expected: 全部通过；敏感扫描仅命中合成测试数据。

- [ ] **Step 6: 提交**

```bash
git add frontend/src/views/ManageView.vue frontend/src/stores/monitor.ts README.md README.zh-CN.md docs/DEVELOPMENT.md CHANGELOG.md
git commit -m "docs: document disk monitoring, scan scheduling, and attribution storage"
```

---

## 计划外说明（执行者须知）

1. **本地 retention 清理缺口**：spec §7.3 说「retention 清理扩展到 history/attribution/」，但当前 Tauri 实现**没有任何本地 retention 清理代码**（只有 agent 端 prune）。本计划不为本功能新造清理系统（YAGNI，属既有缺口）；attribution 目录体积极小（每日每挂载点一行），待本地清理功能立项时一并覆盖。
2. **CI 无法跑 sh 集成测试**：Windows CI 上脚本验证以 `sh -n`（本地）+ Rust 解析测试为主；Task 5 的功能冒烟在 WSL/Linux 手工执行一次并记录结果。
3. **spec 的 03:17 → 小时粒度**、**归因记录增加 serverId** 两处实现级修正见「对 spec 的两处实现级修正」；实现完成后如需回写 spec，在 Task 13 一并更新。

## Self-Review 记录

- **Spec 覆盖**：§5 协议→Task 1/2；§6 扫描→Task 5/7/8；§7 历史合并→Task 3/4/9（清理缺口见上）；§8 UI→Task 10/11/12；§9 错误处理→各任务实现内（结构化结果/容错解析/锁 PID 检测）；§10 隐私→Global Constraints；§11 测试→各任务 Step + Task 13 Step 5；§12 文档→Task 13；§13 兼容→Task 1/4/6 的容错测试。无遗漏。
- **占位符扫描**：无 TBD/TODO；Task 12 的「当前选中服务器 id 来源」是 HistoryView 内既有模式（执行者照抄相邻 computed），非占位符。
- **类型一致性**：`DiskMetric`（Rust camelCase ↔ TS）、`DiskAttributionRecord.serverId`、`DiskScanStatusInfo`、`AgentServerState.scanEnabled/scanHour`、`generate_agent_script/config/inject_script` 新签名在各任务间已对齐；`updateAgentConfig` 五参在 Task 8（Rust）与 Task 10/13（TS）两侧一致。










