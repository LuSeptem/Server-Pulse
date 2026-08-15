Set-StrictMode -Version Latest

# Self-contained LF normalization so any runspace that loads this module can
# generate POSIX sh text even when ServerPulse.Core.ps1 is not dot-sourced.
if ($null -eq (Get-Command ConvertTo-ServerPulseShText -ErrorAction SilentlyContinue)) {
    function ConvertTo-ServerPulseShText {
        param([AllowNull()][string]$Text)
        if ($null -eq $Text) { return '' }
        return $Text.Replace("`r`n", "`n")
    }
}

# Server-side monitoring agent support.
#
# The module is WPF-free so it can be loaded from the main window, from the
# server manager, and from background runspaces.  It generates the remote
# agent script (which reuses the shared sample script), runs one-shot control
# and status commands over the existing SSH auth chain, persists per-server
# agent settings and merge cursors in agent-state.json, and merges server-side
# minute records into the local history day files.
#
# Server-side layout (created by the agent itself, umask 077):
#   ~/.serverpulse/
#   |- agent.sh                 # generated self-contained POSIX sh agent
#   |- config                   # interval / retention_days / server identity
#   |- state/pid                # agent pid
#   |- state/heartbeat          # touched once per loop, freshness check
#   |- records/yyyy-MM-dd.v2.jsonl  # minute records, timestamps in UTC
#   `- agent.log                # agent stdout/stderr (mostly empty)

function Get-ServerPulseAgentFolder { return '.serverpulse' }

function ConvertTo-ServerPulseAgentScriptValue {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '' }
    return ($Value -replace '[\r\n\t"\\]', ' ')
}

function ConvertTo-ServerPulseAgentConfigValue {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '' }
    return ($Value -replace '[\r\n\t]', ' ')
}

function New-ServerPulseAgentConfigText {
    param(
        [Parameter(Mandatory)][string]$ServerId,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$ServerHost,
        [int]$IntervalSeconds = 5,
        [int]$RetentionDays = 30
    )
    $interval = [Math]::Max(1, [Math]::Min(3600, $IntervalSeconds))
    $retention = [Math]::Max(1, [Math]::Min(3650, $RetentionDays))
    $text = @(
        "interval=$interval"
        "retention_days=$retention"
        "server_id=$((ConvertTo-ServerPulseAgentConfigValue $ServerId))"
        "server_label=$((ConvertTo-ServerPulseAgentConfigValue $Label))"
        "server_host=$((ConvertTo-ServerPulseAgentConfigValue $ServerHost))"
    ) -join "`n"
    return ConvertTo-ServerPulseShText $text
}

# The awk aggregator is embedded in agent.sh between single quotes, so it must
# not contain single quotes itself.  It reads one accumulated minute file
# (samples separated by __SP_SAMPLE__ lines) and writes one JSONL line that
# matches the local ConvertTo-HistoryMinuteRecord schema; timestamps are UTC.
$script:ServerPulseAgentAwk = @'
function jstr(s) {
  gsub(/\\/, "\\\\", s)
  gsub(/"/, "\\\"", s)
  gsub(/\n/, "\\n", s)
  gsub(/\r/, "\\r", s)
  gsub(/\t/, "\\t", s)
  return s
}
function jnum(x, has) {
  if (!has) return "null"
  if (x == int(x)) return sprintf("%d", int(x))
  return sprintf("%.2f", x)
}
function isnum(v) {
  if (v ~ /^-?[0-9]+([.][0-9]+)?$/) return 1
  return 0
}
function avg(sum, cnt) {
  if (cnt <= 0) return 0
  return sum / cnt
}
function max0(x) {
  if (x < 0) return 0
  return x
}
function csvsplit(s, arr, n,   i, inq, field, ch) {
  n = 0
  field = ""
  inq = 0
  for (i = 1; i <= length(s); i++) {
    ch = substr(s, i, 1)
    if (inq) {
      if (ch == "\"") {
        if (substr(s, i + 1, 1) == "\"") { field = field "\""; i++ }
        else inq = 0
      } else field = field ch
    } else if (ch == "\"") {
      inq = 1
    } else if (ch == ",") {
      n++
      arr[n] = field
      field = ""
    } else {
      field = field ch
    }
  }
  n++
  arr[n] = field
  return n
}
function reset_sample() {
  s_started = 0
  s_ok = 0
  s_hostname = ""
  s_uptime_has = 0
  s_uptime = 0
  s_cpu_has = 0
  s_cpu = 0
  s_mem_used_has = 0
  s_mem_used = 0
  s_mem_total_has = 0
  s_mem_total = 0
  s_mem_percent_has = 0
  s_mem_percent = 0
  s_load1_has = 0
  s_load1 = 0
  s_load5_has = 0
  s_load5 = 0
  s_load15_has = 0
  s_load15 = 0
  s_cpu_status = "unavailable"
  s_mem_status = "unavailable"
  s_gpu_status = "unavailable"
  s_cpu_skipped = 0
  s_mem_skipped = 0
  s_cpu_attr = 0
  s_mem_attr = 0
  s_cpu_usr_list = ""
  s_mem_usr_list = ""
  s_g_list = ""
  s_gpu_count = 0
  in_gpus = 0
  delete s_cpu_usr
  delete s_cpu_usr_name
  delete s_cpu_usr_seen
  delete s_mem_usr
  delete s_mem_usr_name
  delete s_mem_usr_pct
  delete s_mem_usr_pct_has
  delete s_mem_usr_seen
  delete s_g_util
  delete s_g_util_has
  delete s_g_used
  delete s_g_used_has
  delete s_g_total
  delete s_g_total_has
  delete s_g_temp
  delete s_g_temp_has
  delete s_g_pow
  delete s_g_pow_has
  delete s_g_plim
  delete s_g_plim_has
  delete s_g_fan
  delete s_g_fan_has
  delete s_g_name
  delete s_g_uuid
  delete s_g_present
  delete s_g_uuid_to_idx
  delete s_gu_usr
  delete s_gu_usr_name
  delete s_gu_usr_pct
  delete s_gu_usr_pct_has
  delete s_gu_uid_seen
  delete s_gu_uid_list
  delete s_gu_attr
  delete s_gu_unmap
}
function finalize_sample() {
  m_total++
  if (s_hostname != "" && s_cpu_has) {
    m_online++
    if (s_cpu_has) { m_cpu_sum += s_cpu; m_cpu_cnt++ }
    if (s_mem_used_has) { m_mem_used_sum += s_mem_used; m_mem_used_cnt++ }
    if (s_mem_total_has) { m_mem_total_sum += s_mem_total; m_mem_total_cnt++ }
    if (s_mem_percent_has) { m_mem_percent_sum += s_mem_percent; m_mem_percent_cnt++ }
    if (s_load1_has) { m_load1_sum += s_load1; m_load1_cnt++ }
    if (s_load5_has) { m_load5_sum += s_load5; m_load5_cnt++ }
    if (s_load15_has) { m_load15_sum += s_load15; m_load15_cnt++ }
    if (s_uptime_has) { m_uptime = s_uptime; m_uptime_has = 1 }
    if (s_hostname != "") { m_hostname = s_hostname }
    n = split(s_g_list, gi, " ")
    for (i = 1; i <= n; i++) {
      idx = gi[i] + 0
      m_g_has[idx] = 1
      m_g_cnt[idx]++
      m_g_name[idx] = s_g_name[idx]
      m_g_uuid[idx] = s_g_uuid[idx]
      if (idx > m_g_maxidx) m_g_maxidx = idx
      if (s_g_util_has[idx]) { m_g_util_sum[idx] += s_g_util[idx]; m_g_util_cnt[idx]++ }
      if (s_g_used_has[idx]) { m_g_used_sum[idx] += s_g_used[idx]; m_g_used_cnt[idx]++ }
      if (s_g_total_has[idx]) { m_g_total_sum[idx] += s_g_total[idx]; m_g_total_cnt[idx]++ }
      if (s_g_temp_has[idx]) { m_g_temp_sum[idx] += s_g_temp[idx]; m_g_temp_cnt[idx]++ }
      if (s_g_pow_has[idx]) { m_g_pow_sum[idx] += s_g_pow[idx]; m_g_pow_cnt[idx]++ }
      if (s_g_plim_has[idx]) { m_g_plim_sum[idx] += s_g_plim[idx]; m_g_plim_cnt[idx]++ }
      if (s_g_fan_has[idx]) { m_g_fan_sum[idx] += s_g_fan[idx]; m_g_fan_cnt[idx]++ }
      uuid = s_g_uuid[idx]
      if (uuid != "" && (s_gpu_status == "ok" || s_gpu_status == "partial")) {
        m_gu_valid[uuid]++
        if (s_gpu_status == "partial") m_gu_partial[uuid] = 1
        m_gu_attr_sum[uuid] += s_gu_attr[uuid]
        m_gu_attr_cnt[uuid]++
        if (s_g_used_has[idx]) { m_gu_unattr_sum[uuid] += max0(s_g_used[idx] - s_gu_attr[uuid]); m_gu_unattr_cnt[uuid]++ }
        m_gu_unmap_sum[uuid] += s_gu_unmap[uuid]
        m_gu_unmap_cnt[uuid]++
        nuu = split(s_gu_uid_list[uuid], uidarr, " ")
        for (j = 1; j <= nuu; j++) {
          uid = uidarr[j]
          key = uuid "\t" uid
          if (!(key in m_gu_usr_sum)) m_gu_keys[uuid] = m_gu_keys[uuid] " " uid
          m_gu_usr_sum[key] += s_gu_usr[key]
          m_gu_usr_name[key] = s_gu_usr_name[key]
          if (s_gu_usr_pct_has[key]) { m_gu_usr_pct_sum[key] += s_gu_usr_pct[key]; m_gu_usr_pct_has[key] = 1 }
        }
      }
    }
  }
  if (s_cpu_status == "ok" || s_cpu_status == "partial") {
    m_cpu_valid++
    if (s_cpu_status == "partial") m_cpu_partial = 1
    n = split(s_cpu_usr_list, ua, " ")
    for (i = 1; i <= n; i++) {
      uid = ua[i]
      if (!(uid in m_cpu_usr_sum)) m_cpu_keys = m_cpu_keys " " uid
      m_cpu_usr_sum[uid] += s_cpu_usr[uid]
      m_cpu_usr_name[uid] = s_cpu_usr_name[uid]
    }
    m_cpu_attr_sum += s_cpu_attr
    m_cpu_attr_cnt++
    if (s_cpu_has) { m_cpu_unattr_sum += max0(s_cpu - s_cpu_attr); m_cpu_unattr_cnt++ }
    m_cpu_overlap_sum += max0(s_cpu_attr - s_cpu)
    m_cpu_overlap_cnt++
    m_cpu_skipped_sum += s_cpu_skipped
    m_cpu_skipped_cnt++
  }
  if (s_mem_status == "ok" || s_mem_status == "partial") {
    m_mem_valid++
    if (s_mem_status == "partial") m_mem_partial = 1
    n = split(s_mem_usr_list, ma, " ")
    for (i = 1; i <= n; i++) {
      uid = ma[i]
      if (!(uid in m_mem_usr_sum)) m_mem_keys = m_mem_keys " " uid
      m_mem_usr_sum[uid] += s_mem_usr[uid]
      m_mem_usr_name[uid] = s_mem_usr_name[uid]
      if (s_mem_usr_pct_has[uid]) { m_mem_usr_pct_sum[uid] += s_mem_usr_pct[uid]; m_mem_usr_pct_has[uid] = 1 }
    }
    m_mem_attr_sum += s_mem_attr
    m_mem_attr_cnt++
    if (s_mem_used_has) { m_mem_unattr_sum += max0(s_mem_used - s_mem_attr); m_mem_unattr_cnt++ }
    m_mem_overlap_sum += max0(s_mem_attr - s_mem_used)
    m_mem_overlap_cnt++
    m_mem_skipped_sum += s_mem_skipped
    m_mem_skipped_cnt++
  }
}
function emit_cpu_users(   i, j, n, ku, t, first) {
  if (m_cpu_valid <= 0) {
    printf "\"CpuUserUsage\":{\"Status\":\"unavailable\",\"ValidSamples\":0,\"Users\":[]},"
    return
  }
  printf "\"CpuUserUsage\":{\"Status\":\"%s\",\"ValidSamples\":%d,\"Users\":[", (m_cpu_partial ? "partial" : "ok"), m_cpu_valid
  n = split(m_cpu_keys, ku, " ")
  for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) {
    if (m_cpu_usr_sum[ku[j]] > m_cpu_usr_sum[ku[i]] || (m_cpu_usr_sum[ku[j]] == m_cpu_usr_sum[ku[i]] && m_cpu_usr_name[ku[j]] < m_cpu_usr_name[ku[i]])) {
      t = ku[i]; ku[i] = ku[j]; ku[j] = t
    }
  }
  first = 1
  for (i = 1; i <= n; i++) {
    if (!first) printf ","
    first = 0
    printf "{\"Uid\":\"%s\",\"Name\":\"%s\",\"Percent\":%s}", jstr(ku[i]), jstr(m_cpu_usr_name[ku[i]]), jnum(avg(m_cpu_usr_sum[ku[i]], m_cpu_valid), 1)
  }
  printf "],\"UnattributedPercent\":%s,\"OverlapPercent\":%s,\"AttributedPercent\":%s,\"SkippedProcesses\":%s},", jnum(avg(m_cpu_unattr_sum, m_cpu_unattr_cnt), m_cpu_unattr_cnt > 0), jnum(avg(m_cpu_overlap_sum, m_cpu_overlap_cnt), m_cpu_overlap_cnt > 0), jnum(avg(m_cpu_attr_sum, m_cpu_attr_cnt), m_cpu_attr_cnt > 0), jnum(avg(m_cpu_skipped_sum, m_cpu_skipped_cnt), m_cpu_skipped_cnt > 0)
}
function emit_mem_users(   i, j, n, ku, t, first) {
  if (m_mem_valid <= 0) {
    printf "\"MemoryUserUsage\":{\"Status\":\"unavailable\",\"ValidSamples\":0,\"Users\":[]},"
    return
  }
  printf "\"MemoryUserUsage\":{\"Status\":\"%s\",\"ValidSamples\":%d,\"Users\":[", (m_mem_partial ? "partial" : "ok"), m_mem_valid
  n = split(m_mem_keys, ku, " ")
  for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) {
    if (m_mem_usr_sum[ku[j]] > m_mem_usr_sum[ku[i]] || (m_mem_usr_sum[ku[j]] == m_mem_usr_sum[ku[i]] && m_mem_usr_name[ku[j]] < m_mem_usr_name[ku[i]])) {
      t = ku[i]; ku[i] = ku[j]; ku[j] = t
    }
  }
  first = 1
  for (i = 1; i <= n; i++) {
    if (!first) printf ","
    first = 0
    printf "{\"Uid\":\"%s\",\"Name\":\"%s\",\"UsedMiB\":%s,\"Percent\":%s}", jstr(ku[i]), jstr(m_mem_usr_name[ku[i]]), jnum(avg(m_mem_usr_sum[ku[i]], m_mem_valid), 1), jnum(avg(m_mem_usr_pct_sum[ku[i]], m_mem_valid), m_mem_usr_pct_has[ku[i]])
  }
  printf "],\"UnattributedMiB\":%s,\"OverlapMiB\":%s,\"AttributedMiB\":%s,\"SkippedProcesses\":%s},", jnum(avg(m_mem_unattr_sum, m_mem_unattr_cnt), m_mem_unattr_cnt > 0), jnum(avg(m_mem_overlap_sum, m_mem_overlap_cnt), m_mem_overlap_cnt > 0), jnum(avg(m_mem_attr_sum, m_mem_attr_cnt), m_mem_attr_cnt > 0), jnum(avg(m_mem_skipped_sum, m_mem_skipped_cnt), m_mem_skipped_cnt > 0)
}
function emit_gpu_users(uuid,   i, j, n, ku, t, k1, k2, k, first) {
  n = split(m_gu_keys[uuid], ku, " ")
  for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) {
    k1 = uuid "\t" ku[j]
    k2 = uuid "\t" ku[i]
    if (m_gu_usr_sum[k1] > m_gu_usr_sum[k2] || (m_gu_usr_sum[k1] == m_gu_usr_sum[k2] && m_gu_usr_name[k1] < m_gu_usr_name[k2])) {
      t = ku[i]; ku[i] = ku[j]; ku[j] = t
    }
  }
  first = 1
  for (i = 1; i <= n; i++) {
    if (!first) printf ","
    first = 0
    k = uuid "\t" ku[i]
    printf "{\"Uid\":\"%s\",\"Name\":\"%s\",\"UsedMiB\":%s,\"Percent\":%s}", jstr(ku[i]), jstr(m_gu_usr_name[k]), jnum(avg(m_gu_usr_sum[k], m_gu_valid[uuid]), 1), jnum(avg(m_gu_usr_pct_sum[k], m_gu_valid[uuid]), m_gu_usr_pct_has[k])
  }
}
function emit_record(   i, n, first, uuid) {
  printf "{\"Version\":2,\"Record\":{\"Timestamp\":\"%s:00\",\"SampleCount\":%d,\"Servers\":[{", sp_minute, m_total
  printf "\"Id\":\"%s\",\"Label\":\"%s\",\"Host\":\"%s\",", jstr(sp_id), jstr(sp_label), jstr(sp_host)
  printf "\"OnlineSamples\":%d,\"TotalSamples\":%d,\"LatencyMs\":null,", m_online, m_total
  printf "\"Hostname\":\"%s\",", jstr(m_hostname)
  printf "\"CpuPercent\":%s,", jnum(avg(m_cpu_sum, m_cpu_cnt), m_cpu_cnt > 0)
  emit_cpu_users()
  printf "\"MemoryUsedMiB\":%s,\"MemoryTotalMiB\":%s,\"MemoryPercent\":%s,", jnum(avg(m_mem_used_sum, m_mem_used_cnt), m_mem_used_cnt > 0), jnum(avg(m_mem_total_sum, m_mem_total_cnt), m_mem_total_cnt > 0), jnum(avg(m_mem_percent_sum, m_mem_percent_cnt), m_mem_percent_cnt > 0)
  emit_mem_users()
  printf "\"LoadOne\":%s,\"LoadFive\":%s,\"LoadFifteen\":%s,", jnum(avg(m_load1_sum, m_load1_cnt), m_load1_cnt > 0), jnum(avg(m_load5_sum, m_load5_cnt), m_load5_cnt > 0), jnum(avg(m_load15_sum, m_load15_cnt), m_load15_cnt > 0)
  printf "\"UptimeSeconds\":%s,", jnum(m_uptime, m_uptime_has)
  printf "\"Gpus\":["
  first = 1
  for (i = 0; i <= m_g_maxidx; i++) {
    if (!m_g_has[i]) continue
    if (!first) printf ","
    first = 0
    printf "{\"Index\":%d,\"ValidSamples\":%d,\"Name\":\"%s\",\"Uuid\":\"%s\",", i, m_g_cnt[i], jstr(m_g_name[i]), jstr(m_g_uuid[i])
    printf "\"Utilization\":%s,\"MemoryUsedMiB\":%s,\"MemoryTotalMiB\":%s,", jnum(avg(m_g_util_sum[i], m_g_util_cnt[i]), m_g_util_cnt[i] > 0), jnum(avg(m_g_used_sum[i], m_g_used_cnt[i]), m_g_used_cnt[i] > 0), jnum(avg(m_g_total_sum[i], m_g_total_cnt[i]), m_g_total_cnt[i] > 0)
    printf "\"TemperatureC\":%s,\"PowerDrawW\":%s,\"PowerLimitW\":%s,\"FanPercent\":%s,", jnum(avg(m_g_temp_sum[i], m_g_temp_cnt[i]), m_g_temp_cnt[i] > 0), jnum(avg(m_g_pow_sum[i], m_g_pow_cnt[i]), m_g_pow_cnt[i] > 0), jnum(avg(m_g_plim_sum[i], m_g_plim_cnt[i]), m_g_plim_cnt[i] > 0), jnum(avg(m_g_fan_sum[i], m_g_fan_cnt[i]), m_g_fan_cnt[i] > 0)
    uuid = m_g_uuid[i]
    if (uuid == "" || m_gu_valid[uuid] <= 0) {
      printf "\"UserMemory\":{\"Status\":\"unavailable\",\"ValidSamples\":0,\"Users\":[]}"
    } else {
      printf "\"UserMemory\":{\"Status\":\"%s\",\"ValidSamples\":%d,\"Users\":[", (m_gu_partial[uuid] ? "partial" : "ok"), m_gu_valid[uuid]
      emit_gpu_users(uuid)
      printf "],\"UnattributedMiB\":%s,\"AttributedMiB\":%s,\"UnmappedProcesses\":%s}", jnum(avg(m_gu_unattr_sum[uuid], m_gu_unattr_cnt[uuid]), m_gu_unattr_cnt[uuid] > 0), jnum(avg(m_gu_attr_sum[uuid], m_gu_attr_cnt[uuid]), m_gu_attr_cnt[uuid] > 0), jnum(avg(m_gu_unmap_sum[uuid], m_gu_unmap_cnt[uuid]), m_gu_unmap_cnt[uuid] > 0)
    }
    printf "}"
  }
  printf "]}]}}"
  printf "\n"
}
BEGIN {
  m_total = 0
  m_online = 0
  m_uptime_has = 0
  m_uptime = 0
  m_hostname = ""
  m_g_maxidx = -1
  m_cpu_keys = ""
  m_mem_keys = ""
  reset_sample()
}
/^__SP_SAMPLE__$/ {
  if (s_started) finalize_sample()
  reset_sample()
  s_started = 1
  next
}
{
  if (in_gpus) {
    if ($0 != "") {
      nf = csvsplit($0, gfields)
      if (nf >= 10) {
        idx = gfields[1] + 0
        gsub(/^[ \t]+|[ \t]+$/, "", gfields[2])
        s_g_name[idx] = gfields[2]
        if (s_g_name[idx] == "") s_g_name[idx] = "NVIDIA GPU"
        gsub(/^[ \t]+|[ \t]+$/, "", gfields[3])
        s_g_uuid[idx] = gfields[3]
        if (s_g_uuid[idx] != "") s_g_uuid_to_idx[s_g_uuid[idx]] = idx
        gsub(/^[ \t]+|[ \t]+$/, "", gfields[4])
        if (isnum(gfields[4])) { s_g_util[idx] = gfields[4] + 0; s_g_util_has[idx] = 1 }
        gsub(/^[ \t]+|[ \t]+$/, "", gfields[5])
        if (isnum(gfields[5])) { s_g_used[idx] = gfields[5] + 0; s_g_used_has[idx] = 1 }
        gsub(/^[ \t]+|[ \t]+$/, "", gfields[6])
        if (isnum(gfields[6])) { s_g_total[idx] = gfields[6] + 0; s_g_total_has[idx] = 1 }
        gsub(/^[ \t]+|[ \t]+$/, "", gfields[7])
        if (isnum(gfields[7])) { s_g_temp[idx] = gfields[7] + 0; s_g_temp_has[idx] = 1 }
        gsub(/^[ \t]+|[ \t]+$/, "", gfields[8])
        if (isnum(gfields[8])) { s_g_pow[idx] = gfields[8] + 0; s_g_pow_has[idx] = 1 }
        gsub(/^[ \t]+|[ \t]+$/, "", gfields[9])
        if (isnum(gfields[9])) { s_g_plim[idx] = gfields[9] + 0; s_g_plim_has[idx] = 1 }
        gsub(/^[ \t]+|[ \t]+$/, "", gfields[10])
        if (isnum(gfields[10])) { s_g_fan[idx] = gfields[10] + 0; s_g_fan_has[idx] = 1 }
        if (!(idx in s_g_present)) { s_g_present[idx] = 1; s_g_list = s_g_list " " idx }
      }
    }
    next
  }
  if ($0 == "GPUS_BEGIN") { in_gpus = 1; next }
  if ($0 == "GPUS_END") { in_gpus = 0; next }
  eq = index($0, "=")
  if (eq <= 0) next
  key = substr($0, 1, eq - 1)
  value = substr($0, eq + 1)
  if (key == "HOSTNAME") { s_hostname = value; next }
  if (key == "CPU_PERCENT") { if (isnum(value)) { s_cpu = value + 0; s_cpu_has = 1 } next }
  if (key == "MEM_TOTAL_KIB") { if (isnum(value)) { s_mem_total = value + 0; s_mem_total_has = 1 } next }
  if (key == "MEM_USED_KIB") { if (isnum(value)) { s_mem_used = value + 0; s_mem_used_has = 1 } next }
  if (key == "MEM_PERCENT") { if (isnum(value)) { s_mem_percent = value + 0; s_mem_percent_has = 1 } next }
  if (key == "LOAD_1") { if (isnum(value)) { s_load1 = value + 0; s_load1_has = 1 } next }
  if (key == "LOAD_5") { if (isnum(value)) { s_load5 = value + 0; s_load5_has = 1 } next }
  if (key == "LOAD_15") { if (isnum(value)) { s_load15 = value + 0; s_load15_has = 1 } next }
  if (key == "UPTIME_SECONDS") { if (isnum(value)) { s_uptime = value + 0; s_uptime_has = 1 } next }
  if (key == "CPU_USER") {
    nv = split(value, f3, "\t")
    if (nv >= 3 && isnum(f3[3])) {
      uid = f3[1]
      s_cpu_usr[uid] = f3[3] + 0
      s_cpu_usr_name[uid] = f3[2]
      if (!(uid in s_cpu_usr_seen)) { s_cpu_usr_seen[uid] = 1; s_cpu_usr_list = s_cpu_usr_list " " uid }
      s_cpu_attr += f3[3] + 0
    }
    next
  }
  if (key == "MEMORY_USER") {
    nv = split(value, f3, "\t")
    if (nv >= 3 && isnum(f3[3])) {
      uid = f3[1]
      s_mem_usr[uid] = f3[3] + 0
      s_mem_usr_name[uid] = f3[2]
      if (!(uid in s_mem_usr_seen)) { s_mem_usr_seen[uid] = 1; s_mem_usr_list = s_mem_usr_list " " uid }
      if (s_mem_total_has && s_mem_total > 0) { s_mem_usr_pct[uid] = (f3[3] + 0) * 102400.0 / s_mem_total; s_mem_usr_pct_has[uid] = 1 }
      s_mem_attr += f3[3] + 0
    }
    next
  }
  if (key == "CPU_USER_STATUS") { if (value == "ok" || value == "partial" || value == "unavailable") s_cpu_status = value; next }
  if (key == "CPU_USER_SKIPPED") { if (isnum(value)) s_cpu_skipped = value + 0; next }
  if (key == "MEMORY_USER_STATUS") { if (value == "ok" || value == "partial" || value == "unavailable") s_mem_status = value; next }
  if (key == "MEMORY_USER_SKIPPED") { if (isnum(value)) s_mem_skipped = value + 0; next }
  if (key == "GPU_USER") {
    nv = split(value, f4, "\t")
    if (nv >= 4 && isnum(f4[4])) {
      uuid = f4[1]
      uid = f4[2]
      k = uuid "\t" uid
      s_gu_usr[k] = f4[4] + 0
      s_gu_usr_name[k] = f4[3]
      idx = s_g_uuid_to_idx[uuid]
      if (idx != "" && s_g_total_has[idx] && s_g_total[idx] > 0) { s_gu_usr_pct[k] = (f4[4] + 0) * 100.0 / s_g_total[idx]; s_gu_usr_pct_has[k] = 1 }
      if (!(k in s_gu_uid_seen)) { s_gu_uid_seen[k] = 1; s_gu_uid_list[uuid] = s_gu_uid_list[uuid] " " uid }
      s_gu_attr[uuid] += f4[4] + 0
    }
    next
  }
  if (key == "GPU_UNMAPPED") {
    nv = split(value, f2, "\t")
    if (nv >= 2 && isnum(f2[2])) s_gu_unmap[f2[1]] += f2[2] + 0
    next
  }
  if (key == "GPU_USER_STATUS") { if (value == "ok" || value == "partial" || value == "unavailable") s_gpu_status = value; next }
}
END {
  if (!s_started && m_total == 0) exit 0
  if (s_started) finalize_sample()
  emit_record()
}
'@

# The agent script embeds the sample script and the awk aggregator.  Identity
# defaults come from generation parameters; the per-loop config reload can
# override them (server_id / server_label / server_host / interval /
# retention_days).
function New-ServerPulseAgentScript {
    param(
        [Parameter(Mandatory)][string]$ServerId,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$ServerHost,
        [Parameter(Mandatory)][string]$SampleScript,
        [int]$IntervalSeconds = 5,
        [int]$RetentionDays = 30
    )
    $interval = [Math]::Max(1, [Math]::Min(3600, $IntervalSeconds))
    $retention = [Math]::Max(1, [Math]::Min(3650, $RetentionDays))
    $safeId = ConvertTo-ServerPulseAgentScriptValue $ServerId
    $safeLabel = ConvertTo-ServerPulseAgentScriptValue $Label
    $safeHost = ConvertTo-ServerPulseAgentScriptValue $ServerHost
    $script = @'
#!/bin/sh
# Server Pulse remote agent - generated by Server Pulse. Do not edit manually.
LC_ALL=C
export LC_ALL
umask 077

sp_base="$HOME/.serverpulse"
sp_state="$sp_base/state"
sp_records="$sp_base/records"
sp_interval=5
sp_retention_days=30
sp_server_id=""
sp_server_label=""
sp_server_host=""

sp_current=""

mkdir -p "$sp_state" "$sp_records" 2>/dev/null || exit 1
echo $$ > "$sp_state/pid" 2>/dev/null

sp_aggregate() {
  [ -z "$sp_current" ] && return 0
  [ -f "$sp_state/samples-$sp_current" ] || return 0
  sp_date=${sp_current%T*}
  awk -v sp_minute="$sp_current" -v sp_id="$sp_server_id" -v sp_label="$sp_server_label" -v sp_host="$sp_server_host" '
'@ + $script:ServerPulseAgentAwk + @'
' "$sp_state/samples-$sp_current" >> "$sp_records/$sp_date.v2.jsonl" 2>/dev/null
  rm -f "$sp_state/samples-$sp_current" 2>/dev/null
}

sp_finish() {
  sp_aggregate
  rm -f "$sp_state/pid" 2>/dev/null
  exit 0
}
trap 'sp_finish' TERM INT

sp_reload_config() {
  if [ -r "$sp_base/config" ]; then
    while IFS= read -r sp_line; do
      case "$sp_line" in
        interval=*) sp_interval=${sp_line#*=} ;;
        retention_days=*) sp_retention_days=${sp_line#*=} ;;
        server_id=*) sp_server_id=${sp_line#*=} ;;
        server_label=*) sp_server_label=${sp_line#*=} ;;
        server_host=*) sp_server_host=${sp_line#*=} ;;
      esac
    done < "$sp_base/config"
  fi
  case "$sp_interval" in *[!0-9]*|''|0*) sp_interval=5 ;; esac
  case "$sp_retention_days" in *[!0-9]*|''|0*) sp_retention_days=30 ;; esac
}

sp_prune() {
  case "$sp_retention_days" in *[!0-9]*|''|0*) return 0 ;; esac
  [ "$sp_retention_days" -lt 2 ] && return 0
  sp_cutoff=$(date -u -d "-$((sp_retention_days-1)) days" +%Y-%m-%d 2>/dev/null) || return 0
  for sp_file in "$sp_records"/*.v2.jsonl; do
    [ -e "$sp_file" ] || continue
    sp_base_name=${sp_file##*/}
    sp_date=${sp_base_name%.v2.jsonl}
    case "$sp_date" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) continue ;;
    esac
    if awk -v a="$sp_date" -v b="$sp_cutoff" 'BEGIN { exit !(a < b) }'; then
      rm -f "$sp_file" 2>/dev/null
    fi
  done
}

while :; do
  sp_reload_config
  sp_now=$(date -u +%Y-%m-%dT%H:%M 2>/dev/null)
  [ -z "$sp_now" ] && sp_now=$(date +%Y-%m-%dT%H:%M 2>/dev/null)
  [ -z "$sp_now" ] && sp_now="unknown"
  if [ -n "$sp_current" ] && [ "$sp_now" != "$sp_current" ]; then
    sp_aggregate
  fi
  sp_current=$sp_now
  (
    printf '__SP_SAMPLE__\n'
'@ + "`n" + $SampleScript + "`n" + @'
  ) > "$sp_state/sample.tmp" 2>/dev/null
  cat "$sp_state/sample.tmp" >> "$sp_state/samples-$sp_current" 2>/dev/null
  rm -f "$sp_state/sample.tmp" 2>/dev/null
  touch "$sp_state/heartbeat" 2>/dev/null
  sp_prune
  sleep "$sp_interval" 2>/dev/null || break
done
'@
    $script = $script.Replace('sp_interval=5', "sp_interval=$interval")
    $script = $script.Replace('sp_retention_days=30', "sp_retention_days=$retention")
    $script = $script.Replace('sp_server_id=""', "sp_server_id=""$safeId""")
    $script = $script.Replace('sp_server_label=""', "sp_server_label=""$safeLabel""")
    $script = $script.Replace('sp_server_host=""', "sp_server_host=""$safeHost""")
    return ConvertTo-ServerPulseShText $script
}

function Get-ServerPulseAgentStatusScript {
    param([string]$AgentFolder = '.serverpulse')
    $script = @"
sp="`$HOME/$AgentFolder"
if [ -d "`$sp" ]; then
  echo 'SP_AGENT_INSTALLED=1'
else
  echo 'SP_AGENT_INSTALLED=0'
  echo 'SP_AGENT_STATUS=stopped'
  exit 0
fi
if [ -f "`$sp/state/pid" ]; then
  sp_pid=`$(cat "`$sp/state/pid" 2>/dev/null)
  if [ -n "`$sp_pid" ] && kill -0 "`$sp_pid" 2>/dev/null; then
    echo 'SP_AGENT_STATUS=running'
    echo "SP_AGENT_PID=`$sp_pid"
    if [ -f "`$sp/state/heartbeat" ]; then
      sp_hb=`$(stat -c %Y "`$sp/state/heartbeat" 2>/dev/null)
      if [ -n "`$sp_hb" ]; then
        sp_now=`$(date +%s 2>/dev/null)
        if [ -n "`$sp_now" ] && [ "`$sp_now" -ge "`$sp_hb" ]; then echo "SP_AGENT_HB_AGE=`$((sp_now-sp_hb))"; fi
      fi
    fi
  else
    echo 'SP_AGENT_STATUS=stopped'
    rm -f "`$sp/state/pid" 2>/dev/null
  fi
else
  echo 'SP_AGENT_STATUS=stopped'
fi
"@
    return ConvertTo-ServerPulseShText $script
}

function Get-ServerPulseAgentStopScript {
    param([string]$AgentFolder = '.serverpulse')
    $script = @"
sp="`$HOME/$AgentFolder"
if [ -f "`$sp/state/pid" ]; then
  sp_pid=`$(cat "`$sp/state/pid" 2>/dev/null)
  if [ -n "`$sp_pid" ] && kill -0 "`$sp_pid" 2>/dev/null; then
    kill -TERM "`$sp_pid" 2>/dev/null
    sp_i=0
    while [ "`$sp_i" -lt 10 ] && kill -0 "`$sp_pid" 2>/dev/null; do sleep 1; sp_i=`$((sp_i+1)); done
    if kill -0 "`$sp_pid" 2>/dev/null; then kill -KILL "`$sp_pid" 2>/dev/null; fi
    rm -f "`$sp/state/pid" 2>/dev/null
  else
    rm -f "`$sp/state/pid" 2>/dev/null
  fi
fi
echo 'SP_AGENT_RESULT=stopped'
"@
    return ConvertTo-ServerPulseShText $script
}

function Get-ServerPulseAgentInjectScript {
    param(
        [Parameter(Mandatory)][string]$AgentScript,
        [Parameter(Mandatory)][string]$ConfigText,
        [string]$AgentFolder = '.serverpulse'
    )
    $script = @"
sp="`$HOME/$AgentFolder"
umask 077
mkdir -p "`$sp/state" "`$sp/records" 2>/dev/null || { echo 'SP_AGENT_RESULT=error'; echo 'SP_AGENT_ERROR=mkdir failed'; exit 0; }
cat > "`$sp/agent.sh" <<'SERVERPULSE_AGENT_EOF'
$AgentScript
SERVERPULSE_AGENT_EOF
cat > "`$sp/config" <<'SERVERPULSE_CONFIG_EOF'
$ConfigText
SERVERPULSE_CONFIG_EOF
chmod +x "`$sp/agent.sh" 2>/dev/null
if [ -f "`$sp/state/pid" ] && kill -0 "`$(cat "`$sp/state/pid" 2>/dev/null)" 2>/dev/null; then
  echo 'SP_AGENT_RESULT=already_running'
else
  ( cd "`$HOME" && if command -v setsid >/dev/null 2>&1; then nohup setsid sh "`$sp/agent.sh" >>"`$sp/agent.log" 2>&1 </dev/null & else nohup sh "`$sp/agent.sh" >>"`$sp/agent.log" 2>&1 </dev/null & fi )
  echo 'SP_AGENT_RESULT=started'
fi
"@
    return ConvertTo-ServerPulseShText $script
}

function Get-ServerPulseAgentConfigScript {
    param(
        [Parameter(Mandatory)][string]$ConfigText,
        [string]$AgentFolder = '.serverpulse'
    )
    $script = @"
sp="`$HOME/$AgentFolder"
cat > "`$sp/config" <<'SERVERPULSE_CONFIG_EOF'
$ConfigText
SERVERPULSE_CONFIG_EOF
if [ -f "`$sp/state/pid" ] && kill -0 "`$(cat "`$sp/state/pid" 2>/dev/null)" 2>/dev/null; then
  echo 'SP_AGENT_RESULT=config_updated'
  echo 'SP_AGENT_RUNNING=1'
else
  echo 'SP_AGENT_RESULT=config_updated'
  echo 'SP_AGENT_RUNNING=0'
fi
"@
    return ConvertTo-ServerPulseShText $script
}

function Get-ServerPulseAgentUninstallScript {
    param([string]$AgentFolder = '.serverpulse')
    $stop = Get-ServerPulseAgentStopScript -AgentFolder $AgentFolder
    $script = $stop + @"
sp="`$HOME/$AgentFolder"
rm -rf "`$sp"
echo 'SP_AGENT_RESULT=uninstalled'
"@
    return ConvertTo-ServerPulseShText $script
}

function Get-ServerPulseAgentMergePullScript {
    param(
        [AllowNull()][string]$CursorUtc,
        [string]$AgentFolder = '.serverpulse'
    )
    $script = @"
sp="`$HOME/$AgentFolder"
sp_cursor="$([string]$CursorUtc)"
sp_record_files=0
if [ -d "`$sp/records" ]; then
  for sp_file in "`$sp/records"/*.v2.jsonl; do
    [ -e "`$sp_file" ] || continue
    sp_base=`${sp_file##*/}
    sp_date=`${sp_base%.v2.jsonl}
    case "`$sp_date" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) continue ;;
    esac
    if [ -n "`$sp_cursor" ]; then
      sp_cursor_date=`${sp_cursor%T*}
      if awk -v a="`$sp_date" -v b="`$sp_cursor_date" 'BEGIN { exit !(a < b) }'; then continue; fi
    fi
    sp_record_files=`$((sp_record_files+1))
    echo "__SP_FILE__`$sp_date"
    cat "`$sp_file"
  done
fi
echo "SP_AGENT_RECORD_FILES=`$sp_record_files"
echo '__SP_DONE__'
"@
    return ConvertTo-ServerPulseShText $script
}

function Get-ServerPulseAgentCleanScript {
    param(
        [AllowNull()][string]$CursorUtc,
        [string]$AgentFolder = '.serverpulse'
    )
    $script = @"
sp="`$HOME/$AgentFolder"
sp_cursor="$([string]$CursorUtc)"
sp_cursor_date=`${sp_cursor%T*}
if [ -n "`$sp_cursor" ] && [ -d "`$sp/records" ]; then
  for sp_file in "`$sp/records"/*.v2.jsonl; do
    [ -e "`$sp_file" ] || continue
    sp_base=`${sp_file##*/}
    sp_date=`${sp_base%.v2.jsonl}
    case "`$sp_date" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) continue ;;
    esac
    if awk -v a="`$sp_date" -v b="`$sp_cursor_date" 'BEGIN { exit !(a < b) }'; then
      rm -f "`$sp_file" 2>/dev/null
      echo "SP_AGENT_CLEANED=`$sp_date"
    fi
  done
fi
echo '__SP_DONE__'
"@
    return ConvertTo-ServerPulseShText $script
}

function Invoke-ServerPulseAgentConnection {
    param(
        [Parameter(Mandatory)]$Server,
        [Parameter(Mandatory)][string]$Script,
        [string]$Password,
        [int]$TimeoutMs = 10000,
        [string]$AskPassPath,
        [string]$SshPath = 'ssh.exe'
    )
    return Invoke-ServerPulseServerConnection -Server $Server -Script $Script -AuthMode auto -Password $Password -TimeoutMs $TimeoutMs -AskPassPath $AskPassPath -SshPath $SshPath
}

function ConvertFrom-ServerPulseAgentOutput {
    param([Parameter(Mandatory)][string]$Output, [string[]]$Keys = @('STATUS','RESULT','PID','HB_AGE','INSTALLED','RUNNING','ERROR'))
    $fields = @{}
    foreach ($line in ($Output -split "`r?`n")) {
        $match = [regex]::Match($line.Trim(), '^SP_AGENT_([A-Z_]+)=(.*)$')
        if ($match.Success -and $Keys -contains $match.Groups[1].Value) {
            $fields[$match.Groups[1].Value] = $match.Groups[2].Value
        }
    }
    return $fields
}

function Get-ServerPulseAgentStatus {
    param(
        [Parameter(Mandatory)]$Server,
        [string]$Password,
        [int]$TimeoutMs = 8000,
        [string]$AskPassPath,
        [int]$IntervalSeconds = 5,
        [string]$SshPath = 'ssh.exe',
        [string]$AgentFolder = '.serverpulse'
    )
    $script = Get-ServerPulseAgentStatusScript -AgentFolder $AgentFolder
    $connection = Invoke-ServerPulseAgentConnection -Server $Server -Script $script -Password $Password -TimeoutMs $TimeoutMs -AskPassPath $AskPassPath -SshPath $SshPath
    if ($connection.Status -ne 'online') {
        return [PSCustomObject]@{ Status='error'; Installed=$false; Running=$false; Stale=$false; Pid=$null; HeartbeatAgeSeconds=$null; Error=[string]$connection.Error; AuthMode=[string]$connection.AuthMode }
    }
    $fields = ConvertFrom-ServerPulseAgentOutput $connection.Output
    $installed = ($fields['INSTALLED'] -eq '1')
    $running = ($fields['STATUS'] -eq 'running')
    $hbAge = $null
    $hbNumber = 0
    if ($running -and $fields.ContainsKey('HB_AGE') -and [int]::TryParse([string]$fields['HB_AGE'], [ref]$hbNumber)) { $hbAge = $hbNumber }
    $stale = $false
    if ($running -and $null -ne $hbAge -and $IntervalSeconds -gt 0 -and $hbAge -gt (3 * $IntervalSeconds + 30)) { $stale = $true }
    $status = if (-not $installed) { 'not_installed' } elseif ($running -and -not $stale) { 'running' } elseif ($running) { 'stale' } else { 'stopped' }
    return [PSCustomObject]@{
        Status=$status; Installed=$installed; Running=$running; Stale=$stale
        Pid=if ($fields.ContainsKey('PID')) { [string]$fields['PID'] } else { $null }
        HeartbeatAgeSeconds=$hbAge; Error=''; AuthMode=[string]$connection.AuthMode
    }
}

function Invoke-ServerPulseAgentControl {
    param(
        [Parameter(Mandatory)]$Server,
        [ValidateSet('inject','stop','restart','update-config','uninstall')][string]$Action,
        [string]$Password,
        [int]$TimeoutMs = 15000,
        [string]$AskPassPath,
        [int]$IntervalSeconds = 5,
        [int]$RetentionDays = 30,
        [string]$SshPath = 'ssh.exe',
        [string]$AgentFolder = '.serverpulse',
        [string]$SampleScriptPath
    )
    $sampleScript = if ([string]::IsNullOrWhiteSpace($SampleScriptPath)) { Get-ServerPulseSampleScript } else { ConvertTo-ServerPulseShText (Get-Content -LiteralPath $SampleScriptPath -Raw -Encoding UTF8) }
    $config = New-ServerPulseAgentConfigText -ServerId ([string]$Server.Id) -Label ([string]$Server.Label) -ServerHost ([string]$Server.SshTarget) -IntervalSeconds $IntervalSeconds -RetentionDays $RetentionDays
    switch ($Action) {
        'inject' {
            $agent = New-ServerPulseAgentScript -ServerId ([string]$Server.Id) -Label ([string]$Server.Label) -ServerHost ([string]$Server.SshTarget) -SampleScript $sampleScript -IntervalSeconds $IntervalSeconds -RetentionDays $RetentionDays
            $script = Get-ServerPulseAgentInjectScript -AgentScript $agent -ConfigText $config -AgentFolder $AgentFolder
        }
        'stop' { $script = Get-ServerPulseAgentStopScript -AgentFolder $AgentFolder }
        'restart' {
            $agent = New-ServerPulseAgentScript -ServerId ([string]$Server.Id) -Label ([string]$Server.Label) -ServerHost ([string]$Server.SshTarget) -SampleScript $sampleScript -IntervalSeconds $IntervalSeconds -RetentionDays $RetentionDays
            $script = (Get-ServerPulseAgentStopScript -AgentFolder $AgentFolder) + "`n" + (Get-ServerPulseAgentInjectScript -AgentScript $agent -ConfigText $config -AgentFolder $AgentFolder)
        }
        'update-config' { $script = Get-ServerPulseAgentConfigScript -ConfigText $config -AgentFolder $AgentFolder }
        'uninstall' { $script = Get-ServerPulseAgentUninstallScript -AgentFolder $AgentFolder }
    }
    $connection = Invoke-ServerPulseAgentConnection -Server $Server -Script $script -Password $Password -TimeoutMs $TimeoutMs -AskPassPath $AskPassPath -SshPath $SshPath
    if ($connection.Status -ne 'online') {
        return [PSCustomObject]@{ Action=$Action; Status='error'; Result=$null; Running=$null; Error=[string]$connection.Error; AuthMode=[string]$connection.AuthMode; Output='' }
    }
    $fields = ConvertFrom-ServerPulseAgentOutput $connection.Output
    $result = if ($fields.ContainsKey('RESULT')) { [string]$fields['RESULT'] } else { 'unknown' }
    $running = if ($fields.ContainsKey('RUNNING')) { $fields['RUNNING'] -eq '1' } else { $null }
    return [PSCustomObject]@{ Action=$Action; Status='ok'; Result=$result; Running=$running; Error=''; AuthMode=[string]$connection.AuthMode; Output=$connection.Output }
}

# --- Agent state (local agent-state.json) -----------------------------------

function New-ServerPulseAgentState {
    return [PSCustomObject]@{ Version=1; Servers=@{} }
}

function New-ServerPulseAgentServerEntry {
    param([Parameter(Mandatory)][string]$Id)
    return [PSCustomObject]@{
        Id=$Id; IntervalSeconds=5; RetentionDays=30; AutoRestoreOnStartup=$false
        MergeCursorUtc=$null; LastStatus='unknown'; LastStatusAt=$null; LastError=''
        LastMergeAt=$null; LastMergeSummary=$null
    }
}

function Get-ServerPulseAgentStatePath {
    param([Parameter(Mandatory)][string]$DataRoot)
    return Join-Path $DataRoot 'agent-state.json'
}

function Read-ServerPulseAgentState {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return New-ServerPulseAgentState }
    try {
        $value = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $value -or $value.PSObject.Properties.Name -notcontains 'Servers') { return New-ServerPulseAgentState }
        $servers = @{}
        $source = $value.Servers
        if ($null -ne $source) {
            if ($source -is [Collections.IDictionary]) { foreach ($key in @($source.Keys)) { $servers[[string]$key] = $source[$key] } }
            else { foreach ($property in @($source.PSObject.Properties)) { $servers[$property.Name] = $property.Value } }
        }
        return [PSCustomObject]@{ Version=1; Servers=$servers }
    } catch { return New-ServerPulseAgentState }
}

function Save-ServerPulseAgentState {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$State)
    Write-ServerPulseJsonAtomic -Path $Path -Value $State -Depth 12
}

function Get-ServerPulseAgentServerEntry {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Id)
    if ($State.Servers.ContainsKey([string]$Id)) { return $State.Servers[[string]$Id] }
    return $null
}

function Set-ServerPulseAgentServerEntry {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Id,
        [int]$IntervalSeconds = 5,
        [int]$RetentionDays = 30,
        [bool]$AutoRestoreOnStartup = $false
    )
    $entry = Get-ServerPulseAgentServerEntry $State $Id
    if ($null -eq $entry) {
        $entry = New-ServerPulseAgentServerEntry -Id $Id
        $State.Servers[[string]$Id] = $entry
    }
    $entry.IntervalSeconds = [Math]::Max(1, [Math]::Min(3600, $IntervalSeconds))
    $entry.RetentionDays = [Math]::Max(1, [Math]::Min(3650, $RetentionDays))
    $entry.AutoRestoreOnStartup = [bool]$AutoRestoreOnStartup
    return $entry
}

function Update-ServerPulseAgentStatusState {
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)]$StatusResult, [datetime]$Now = [DateTime]::UtcNow)
    $Entry.LastStatus = [string]$StatusResult.Status
    $Entry.LastStatusAt = $Now.ToString('o')
    $Entry.LastError = if ([string]$StatusResult.Error) { [string]$StatusResult.Error } else { '' }
}

# --- Merge engine -------------------------------------------------------------

function ConvertTo-ServerPulseLocalMinute {
    param([Parameter(Mandatory)]$UtcTimestampText)
    # ConvertFrom-Json (Windows PowerShell 5.1) turns ISO strings into
    # [datetime], so accept both representations.
    $text = if ($UtcTimestampText -is [datetime]) { $UtcTimestampText.ToString('yyyy-MM-ddTHH:mm:ss') } else { ([string]$UtcTimestampText).Trim() }
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($text, 'yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$parsed)) {
        return $null
    }
    $local = $parsed.ToLocalTime()
    return [datetime]::new($local.Year, $local.Month, $local.Day, $local.Hour, $local.Minute, 0)
}

function ConvertTo-ServerPulseHistoryMinute {
    param([Parameter(Mandatory)]$TimestampText)
    $text = if ($TimestampText -is [datetime]) { $TimestampText.ToString('yyyy-MM-ddTHH:mm:ss') } else { ([string]$TimestampText).Trim() }
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($text, 'yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return $null
    }
    return [datetime]::new($parsed.Year, $parsed.Month, $parsed.Day, $parsed.Hour, $parsed.Minute, 0)
}

function Resolve-ServerPulseAgentConflict {
    param($LocalEntry, $ServerEntry)
    # Keep the entry with more valid samples; a tie keeps the local record.
    $localSamples = 0; $serverSamples = 0
    if ($null -ne $LocalEntry -and $null -ne $LocalEntry.OnlineSamples) { [void][int]::TryParse([string]$LocalEntry.OnlineSamples, [ref]$localSamples) }
    if ($null -ne $ServerEntry -and $null -ne $ServerEntry.OnlineSamples) { [void][int]::TryParse([string]$ServerEntry.OnlineSamples, [ref]$serverSamples) }
    if ($serverSamples -gt $localSamples) { return 'server' }
    return 'local'
}

function ConvertFrom-ServerPulseAgentPull {
    param(
        [Parameter(Mandatory)][string]$Output,
        [Parameter(Mandatory)][string[]]$KnownServerIds,
        [AllowNull()][string]$CursorUtc
    )
    # Returns entries grouped by local minute plus statistics and the maximum
    # merged UTC minute. Pure function; no SSH or file access.
    $entries = [Collections.Generic.List[object]]::new()
    $pulledLines = 0; $corruptLines = 0; $droppedUnknown = 0; $recordFiles = 0; $skippedByCursor = 0
    $maxUtcMinute = $null
    foreach ($line in ($Output -split "`r?`n")) {
        $clean = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($clean) -or $clean -eq '__SP_DONE__' -or $clean.StartsWith('__SP_FILE__')) { continue }
        if ($clean.StartsWith('SP_AGENT_')) {
            $keyValue = $clean -split '=', 2
            if ($keyValue.Count -eq 2 -and $keyValue[0] -eq 'SP_AGENT_RECORD_FILES') { [void][int]::TryParse([string]$keyValue[1], [ref]$recordFiles) }
            continue
        }
        $pulledLines++
        try {
            $parsed = $clean | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $parsed -or $null -eq $parsed.Record) { $corruptLines++; continue }
            $utcText = if ($parsed.Record.Timestamp -is [datetime]) { $parsed.Record.Timestamp.ToString('yyyy-MM-ddTHH:mm:ss') } else { [string]$parsed.Record.Timestamp }
            if (-not $utcText.EndsWith(':00')) { $utcText = $utcText.Substring(0, [Math]::Min(16, $utcText.Length)) + ':00' }
            $utcMinute = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($utcText, 'yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$utcMinute)) { $corruptLines++; continue }
            if (-not [string]::IsNullOrWhiteSpace($CursorUtc)) {
                $cursorMinute = [datetime]::MinValue
                if ([datetime]::TryParseExact($CursorUtc.Trim(), 'yyyy-MM-ddTHH:mm', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$cursorMinute)) {
                    if ($utcMinute -le $cursorMinute) { $skippedByCursor++; continue }
                }
            }
            if ($null -eq $maxUtcMinute -or $utcMinute -gt $maxUtcMinute) { $maxUtcMinute = $utcMinute }
            $localMinute = ConvertTo-ServerPulseLocalMinute $utcText
            if ($null -eq $localMinute) { $corruptLines++; continue }
            $sampleCount = 1
            if ($null -ne $parsed.Record.SampleCount) { [void][int]::TryParse([string]$parsed.Record.SampleCount, [ref]$sampleCount) }
            foreach ($serverEntry in @($parsed.Record.Servers)) {
                if ($null -eq $serverEntry) { continue }
                if ([string]$serverEntry.Id -notin $KnownServerIds) { $droppedUnknown++; continue }
                $entries.Add([PSCustomObject]@{ Minute=$localMinute; UtcMinute=$utcMinute; Entry=$serverEntry; SourceLine=$clean; SampleCount=$sampleCount })
            }
        } catch { $corruptLines++ }
    }
    return [PSCustomObject]@{ Entries=@($entries); PulledLines=$pulledLines; CorruptLines=$corruptLines; DroppedUnknown=$droppedUnknown; RecordFiles=$recordFiles; SkippedByCursor=$skippedByCursor; MaxUtcMinute=$maxUtcMinute }
}

function Get-ServerPulseAgentDayPath {
    param([Parameter(Mandatory)][string]$HistoryDirectory, [Parameter(Mandatory)][datetime]$Minute)
    return Join-Path $HistoryDirectory ($Minute.ToString('yyyy-MM-dd') + '.v2.jsonl')
}

function Merge-ServerPulseAgentRecordsIntoHistory {
    param(
        [Parameter(Mandatory)][object[]]$Entries,
        [Parameter(Mandatory)][string]$HistoryDirectory
    )
    # Applies parsed server entries to the local history day files. Returns
    # per-day merge results. Caller must hold the history write lock.
    $dayResults = @{}
    foreach ($entry in $Entries) {
        $day = $entry.Minute.ToString('yyyy-MM-dd')
        if (-not $dayResults.ContainsKey($day)) {
            $dayResults[$day] = [PSCustomObject]@{ Day=$day; Lines=[Collections.Generic.List[string]]::new(); Added=0; Updated=0; Skipped=0; CorruptLines=0 }
        }
    }
    foreach ($day in @($dayResults.Keys | Sort-Object)) {
        $result = $dayResults[$day]
        $path = Join-Path $HistoryDirectory ($day + '.v2.jsonl')
        $existing = [Collections.Generic.List[object]]::new()
        if (Test-Path -LiteralPath $path) {
            foreach ($line in @(Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction SilentlyContinue)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try {
                    $parsed = $line | ConvertFrom-Json -ErrorAction Stop
                    if ($null -ne $parsed -and $null -ne $parsed.Record) { $existing.Add([PSCustomObject]@{ Text=$line; Record=$parsed.Record; Parsed=$parsed }) }
                    else { $result.CorruptLines++ }
                } catch { $result.CorruptLines++ }
            }
        }
        $dayEntries = @($Entries | Where-Object { $_.Minute.ToString('yyyy-MM-dd') -eq $day })
        foreach ($dayEntry in $dayEntries) {
            $minute = $dayEntry.Minute
            $target = $null
            foreach ($candidate in @($existing)) {
                $candidateMinute = ConvertTo-ServerPulseHistoryMinute $candidate.Record.Timestamp
                if ($null -ne $candidateMinute -and $candidateMinute -eq $minute) { $target = $candidate; break }
            }
            if ($null -eq $target) {
                $record = [PSCustomObject]@{ Timestamp=$minute.ToString('yyyy-MM-ddTHH:mm:00'); SampleCount=[int]$dayEntry.SampleCount; Servers=@($dayEntry.Entry) }
                $existing.Add([PSCustomObject]@{ Text=$null; Record=$record; Parsed=$null })
                $result.Added++
                continue
            }
            $servers = [Collections.Generic.List[object]]::new()
            foreach ($server in @($target.Record.Servers)) { $servers.Add($server) }
            $replaced = $false
            $existingIndex = -1
            for ($index = 0; $index -lt $servers.Count; $index++) {
                if ([string]$servers[$index].Id -eq [string]$dayEntry.Entry.Id) { $existingIndex = $index; break }
            }
            if ($existingIndex -ge 0) {
                $decision = Resolve-ServerPulseAgentConflict -LocalEntry $servers[$existingIndex] -ServerEntry $dayEntry.Entry
                if ($decision -eq 'server') { $servers[$existingIndex] = $dayEntry.Entry; $result.Updated++; $replaced = $true }
                else { $result.Skipped++ }
            } else {
                $servers.Add($dayEntry.Entry)
                $result.Added++
                $replaced = $true
            }
            if ($replaced) {
                $target.Record.Servers = @($servers)
                $target.Text = $null
                $target.Parsed = $null
            }
        }
        $outputLines = [Collections.Generic.List[string]]::new()
        foreach ($item in @($existing)) {
            if ($null -ne $item.Text) { $outputLines.Add([string]$item.Text) }
            else {
                $line = [PSCustomObject]@{ Version=2; Record=$item.Record } | ConvertTo-Json -Depth 16 -Compress
                $outputLines.Add($line)
            }
        }
        if (-not (Test-Path -LiteralPath $HistoryDirectory)) { [void](New-Item -ItemType Directory -Path $HistoryDirectory -Force) }
        $temp = Join-Path $HistoryDirectory ('.agent-merge-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
        try {
            [IO.File]::WriteAllLines($temp, @($outputLines), [Text.UTF8Encoding]::new($false))
            if (Test-Path -LiteralPath $path) {
                try { [IO.File]::Replace($temp, $path, $null) } catch { Move-Item -LiteralPath $temp -Destination $path -Force }
            } else { Move-Item -LiteralPath $temp -Destination $path -Force }
        } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
        $result.Lines = @($outputLines)
    }
    return $dayResults
}

# Merging pulls the server-side record files over one SSH connection, which
# is a much heavier operation than a status probe; give it a dedicated
# floor so short UI/collection timeouts never abort a legitimate merge.
function Resolve-ServerPulseAgentPullTimeout {
    param([int]$TimeoutMs = 0, [int]$FloorMs = 60000)
    return [Math]::Max($TimeoutMs, $FloorMs)
}

function Merge-ServerPulseAgentRecords {
    param(
        [Parameter(Mandatory)]$Server,
        [Parameter(Mandatory)][string]$HistoryDirectory,
        [Parameter(Mandatory)][string[]]$KnownServerIds,
        [AllowNull()][string]$CursorUtc,
        [string]$Password,
        [int]$TimeoutMs = 15000,
        [string]$AskPassPath,
        [switch]$CleanMerged,
        [string]$SshPath = 'ssh.exe',
        [string]$AgentFolder = '.serverpulse',
        [string]$SampleScriptPath
    )
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $pullTimeout = Resolve-ServerPulseAgentPullTimeout $TimeoutMs
    $pullScript = Get-ServerPulseAgentMergePullScript -CursorUtc $CursorUtc -AgentFolder $AgentFolder
    $connection = Invoke-ServerPulseAgentConnection -Server $Server -Script $pullScript -Password $Password -TimeoutMs $pullTimeout -AskPassPath $AskPassPath -SshPath $SshPath
    if ($connection.Status -ne 'online') {
        return [PSCustomObject]@{
            ServerId=[string]$Server.Id; ServerLabel=[string]$Server.Label; Error=[string]$connection.Error; AuthMode=[string]$connection.AuthMode
            PulledLines=0; Added=0; Updated=0; Skipped=0; DroppedUnknown=0; CorruptLines=0; CleanedFiles=0; DurationMs=0; RecordFiles=0; SkippedByCursor=0; MaxUtcMinute=$null
        }
    }
    $parsed = ConvertFrom-ServerPulseAgentPull -Output $connection.Output -KnownServerIds $KnownServerIds -CursorUtc $CursorUtc
    $dayResults = $null
    $lockAvailable = $null -ne (Get-Command Enter-ServerPulseHistoryWriteLock -ErrorAction SilentlyContinue)
    if ($parsed.Entries.Count -gt 0) {
        try {
            if ($lockAvailable) { Enter-ServerPulseHistoryWriteLock }
            $dayResults = Merge-ServerPulseAgentRecordsIntoHistory -Entries $parsed.Entries -HistoryDirectory $HistoryDirectory
        } finally {
            if ($lockAvailable) { Exit-ServerPulseHistoryWriteLock }
        }
    }
    $added = 0; $updated = 0; $skipped = 0
    if ($null -ne $dayResults) { foreach ($result in @($dayResults.Values)) { $added += [int]$result.Added; $updated += [int]$result.Updated; $skipped += [int]$result.Skipped } }
    $cleaned = 0
    if ($CleanMerged -and $null -ne $parsed.MaxUtcMinute) {
        $cleanScript = Get-ServerPulseAgentCleanScript -CursorUtc $parsed.MaxUtcMinute.ToString('yyyy-MM-ddTHH:mm') -AgentFolder $AgentFolder
        $cleanConnection = Invoke-ServerPulseAgentConnection -Server $Server -Script $cleanScript -Password $Password -TimeoutMs $pullTimeout -AskPassPath $AskPassPath -SshPath $SshPath
        if ($cleanConnection.Status -eq 'online') {
            foreach ($line in ($cleanConnection.Output -split "`r?`n")) {
                if ($line.Trim() -match '^SP_AGENT_CLEANED=(.+)$') { $cleaned++ }
            }
        }
    }
    $stopwatch.Stop()
    return [PSCustomObject]@{
        ServerId=[string]$Server.Id; ServerLabel=[string]$Server.Label; Error=''; AuthMode=[string]$connection.AuthMode
        PulledLines=[int]$parsed.PulledLines; Added=$added; Updated=$updated; Skipped=$skipped
        DroppedUnknown=[int]$parsed.DroppedUnknown; CorruptLines=[int]$parsed.CorruptLines; CleanedFiles=$cleaned
        DurationMs=[int]$stopwatch.ElapsedMilliseconds; RecordFiles=[int]$parsed.RecordFiles; SkippedByCursor=[int]$parsed.SkippedByCursor; MaxUtcMinute=$parsed.MaxUtcMinute
    }
}

# --- Startup tasks -------------------------------------------------------------

function Write-ServerPulseAgentLog {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Context, [Parameter(Mandatory)][string]$Message)
    try {
        $entry = '[{0}] {1}: {2}' -f [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss.fff'), $Context, $Message
        [IO.File]::AppendAllText($Path, $entry + "`r`n", [Text.UTF8Encoding]::new($true))
    } catch { }
}

function Invoke-ServerPulseStartupAgentTasks {
    param(
        [Parameter(Mandatory)][string]$AgentStatePath,
        [Parameter(Mandatory)][string]$HistoryDirectory,
        [Parameter(Mandatory)]$ServerStore,
        [hashtable]$SessionSecrets = @{},
        [string]$AskPassPath,
        [int]$TimeoutMs = 10000,
        [string]$ErrorLogPath,
        [bool]$AutoMergeOnStartup = $false,
        [string]$AgentFolder = '.serverpulse'
    )
    # Runs auto-restore and auto-merge once at application startup. Intended
    # for a background runspace; returns a summary object for tests/logs.
    $summary = [Collections.Generic.List[object]]::new()
    $state = Read-ServerPulseAgentState $AgentStatePath
    $serversById = @{}
    foreach ($server in @($ServerStore.Servers)) { $serversById[[string]$server.Id] = $server }
    $knownIds = @($serversById.Keys)
    foreach ($id in @($state.Servers.Keys)) {
        $entry = $state.Servers[$id]
        if (-not $serversById.ContainsKey($id)) { continue }
        $server = $serversById[$id]
        $password = Get-ServerPulseSessionSecret $SessionSecrets $server.Identity
        try {
            if ([bool]$entry.AutoRestoreOnStartup) {
                $statusResult = Get-ServerPulseAgentStatus -Server $server -Password $password -TimeoutMs $TimeoutMs -AskPassPath $AskPassPath -IntervalSeconds ([int]$entry.IntervalSeconds) -AgentFolder $AgentFolder
                if ($statusResult.Status -in @('stopped','not_installed')) {
                    $control = Invoke-ServerPulseAgentControl -Server $server -Action inject -Password $password -TimeoutMs $TimeoutMs -AskPassPath $AskPassPath -IntervalSeconds ([int]$entry.IntervalSeconds) -RetentionDays ([int]$entry.RetentionDays) -AgentFolder $AgentFolder
                    $summary.Add([PSCustomObject]@{ ServerId=$id; Task='restore'; Result=if($control.Status -eq 'ok'){[string]$control.Result}else{'error'}; Error=[string]$control.Error })
                } elseif ($statusResult.Status -eq 'error') {
                    $summary.Add([PSCustomObject]@{ ServerId=$id; Task='restore'; Result='error'; Error=[string]$statusResult.Error })
                }
            }
        } catch {
            if ($ErrorLogPath) { Write-ServerPulseAgentLog -Path $ErrorLogPath -Context 'agent auto-restore' -Message $_.Exception.ToString() }
            $summary.Add([PSCustomObject]@{ ServerId=$id; Task='restore'; Result='error'; Error=$_.Exception.Message })
        }
    }
    if ($AutoMergeOnStartup) {
        foreach ($id in @($state.Servers.Keys)) {
            if (-not $serversById.ContainsKey($id)) { continue }
            $server = $serversById[$id]
            $entry = $state.Servers[$id]
            $password = Get-ServerPulseSessionSecret $SessionSecrets $server.Identity
            try {
                $result = Merge-ServerPulseAgentRecords -Server $server -HistoryDirectory $HistoryDirectory -KnownServerIds $knownIds -CursorUtc ([string]$entry.MergeCursorUtc) -Password $password -TimeoutMs $TimeoutMs -AskPassPath $AskPassPath -AgentFolder $AgentFolder
                if (-not [string]$result.Error) {
                    $entry.MergeCursorUtc = if ($null -ne $result.MaxUtcMinute) { $result.MaxUtcMinute.ToString('yyyy-MM-ddTHH:mm') } else { $entry.MergeCursorUtc }
                    $entry.LastMergeAt = [DateTime]::UtcNow.ToString('o')
                    $entry.LastMergeSummary = $result | Select-Object PulledLines, Added, Updated, Skipped, DroppedUnknown, CorruptLines, CleanedFiles, DurationMs
                    $summary.Add([PSCustomObject]@{ ServerId=$id; Task='merge'; Result='ok'; Error='' })
                } else {
                    $summary.Add([PSCustomObject]@{ ServerId=$id; Task='merge'; Result='error'; Error=[string]$result.Error })
                }
            } catch {
                if ($ErrorLogPath) { Write-ServerPulseAgentLog -Path $ErrorLogPath -Context 'agent auto-merge' -Message $_.Exception.ToString() }
                $summary.Add([PSCustomObject]@{ ServerId=$id; Task='merge'; Result='error'; Error=$_.Exception.Message })
            }
        }
    }
    try { Save-ServerPulseAgentState $AgentStatePath $state } catch { }
    return [PSCustomObject]@{ Tasks=@($summary) }
}
