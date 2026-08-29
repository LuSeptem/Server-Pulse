use chrono::{DateTime, Local, NaiveDateTime};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

pub const AWK_AGGREGATOR: &str = r#"function jstr(s) {
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
  in_disks = 0
  delete s_cpu_usr
  delete s_cpu_usr_name
  delete s_cpu_usr_pcount
  delete s_cpu_usr_seen
  delete s_mem_usr
  delete s_mem_usr_name
  delete s_mem_usr_pcount
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
  delete s_gu_usr_pcount
  delete s_gu_usr_pct
  delete s_gu_usr_pct_has
  delete s_gu_uid_seen
  delete s_gu_uid_list
  delete s_gu_attr
  delete s_gu_unmap
  s_d_list = ""
  delete s_d_dev
  delete s_d_total
  delete s_d_used
  delete s_d_seen
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
          if (s_gu_usr_pcount[key] > m_gu_usr_max_pcount[key]) m_gu_usr_max_pcount[key] = s_gu_usr_pcount[key]
          if (s_gu_usr_pct_has[key]) { m_gu_usr_pct_sum[key] += s_gu_usr_pct[key]; m_gu_usr_pct_has[key] = 1 }
        }
      }
    }
    nd = split(s_d_list, di, " ")
    for (i = 1; i <= nd; i++) {
      mnt = di[i]
      if (!(mnt in m_d_seen)) { m_d_seen[mnt] = 1; m_d_keys = m_d_keys " " mnt }
      m_d_cnt[mnt]++
      m_d_total_sum[mnt] += s_d_total[mnt]
      m_d_used_sum[mnt] += s_d_used[mnt]
      m_d_dev[mnt] = s_d_dev[mnt]
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
      if (s_cpu_usr_pcount[uid] > m_cpu_usr_max_pcount[uid]) m_cpu_usr_max_pcount[uid] = s_cpu_usr_pcount[uid]
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
      if (s_mem_usr_pcount[uid] > m_mem_usr_max_pcount[uid]) m_mem_usr_max_pcount[uid] = s_mem_usr_pcount[uid]
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
function emit_cpu_users(   i, j, n, ku, t, first, pc) {
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
    pc = m_cpu_usr_max_pcount[ku[i]] > 0 ? m_cpu_usr_max_pcount[ku[i]] : 1
    printf "{\"Uid\":\"%s\",\"Name\":\"%s\",\"Percent\":%s,\"ProcessCount\":%d}", jstr(ku[i]), jstr(m_cpu_usr_name[ku[i]]), jnum(avg(m_cpu_usr_sum[ku[i]], m_cpu_valid), 1), pc
  }
  printf "],\"UnattributedPercent\":%s,\"OverlapPercent\":%s,\"AttributedPercent\":%s,\"SkippedProcesses\":%s},", jnum(avg(m_cpu_unattr_sum, m_cpu_unattr_cnt), m_cpu_unattr_cnt > 0), jnum(avg(m_cpu_overlap_sum, m_cpu_overlap_cnt), m_cpu_overlap_cnt > 0), jnum(avg(m_cpu_attr_sum, m_cpu_attr_cnt), m_cpu_attr_cnt > 0), jnum(avg(m_cpu_skipped_sum, m_cpu_skipped_cnt), m_cpu_skipped_cnt > 0)
}
function emit_mem_users(   i, j, n, ku, t, first, pc) {
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
    pc = m_mem_usr_max_pcount[ku[i]] > 0 ? m_mem_usr_max_pcount[ku[i]] : 1
    printf "{\"Uid\":\"%s\",\"Name\":\"%s\",\"UsedMiB\":%s,\"Percent\":%s,\"ProcessCount\":%d}", jstr(ku[i]), jstr(m_mem_usr_name[ku[i]]), jnum(avg(m_mem_usr_sum[ku[i]], m_mem_valid), 1), jnum(avg(m_mem_usr_pct_sum[ku[i]], m_mem_valid), m_mem_usr_pct_has[ku[i]]), pc
  }
  printf "],\"UnattributedMiB\":%s,\"OverlapMiB\":%s,\"AttributedMiB\":%s,\"SkippedProcesses\":%s},", jnum(avg(m_mem_unattr_sum, m_mem_unattr_cnt), m_mem_unattr_cnt > 0), jnum(avg(m_mem_overlap_sum, m_mem_overlap_cnt), m_mem_overlap_cnt > 0), jnum(avg(m_mem_attr_sum, m_mem_attr_cnt), m_mem_attr_cnt > 0), jnum(avg(m_mem_skipped_sum, m_mem_skipped_cnt), m_mem_skipped_cnt > 0)
}
function emit_gpu_users(uuid,   i, j, n, ku, t, k1, k2, k, first, pc) {
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
    pc = m_gu_usr_max_pcount[k] > 0 ? m_gu_usr_max_pcount[k] : 1
    printf "{\"Uid\":\"%s\",\"Name\":\"%s\",\"UsedMiB\":%s,\"Percent\":%s,\"ProcessCount\":%d}", jstr(ku[i]), jstr(m_gu_usr_name[k]), jnum(avg(m_gu_usr_sum[k], m_gu_valid[uuid]), 1), jnum(avg(m_gu_usr_pct_sum[k], m_gu_valid[uuid]), m_gu_usr_pct_has[k]), pc
  }
}
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
  printf "]"
  emit_disks()
  printf "}]}}"
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
  delete m_cpu_usr_max_pcount
  delete m_mem_usr_max_pcount
  delete m_gu_usr_max_pcount
  m_d_keys = ""
  delete m_d_seen
  delete m_d_cnt
  delete m_d_total_sum
  delete m_d_used_sum
  delete m_d_dev
  reset_sample()
}
/^__SP_SAMPLE__$/ {
  if (s_started) finalize_sample()
  reset_sample()
  s_started = 1
  next
}
{
  if ($0 == "GPUS_END") { in_gpus = 0; next }
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
      s_cpu_usr_pcount[uid] = (nv >= 4 && isnum(f3[4])) ? f3[4] + 0 : 1
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
      s_mem_usr_pcount[uid] = (nv >= 4 && isnum(f3[4])) ? f3[4] + 0 : 1
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
      s_gu_usr_pcount[k] = (nv >= 5 && isnum(f4[5])) ? f4[5] + 0 : 1
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
}"#;

fn sanitize_agent_value(val: &str) -> String {
    val.replace(['\r', '\n', '\t', '"', '\\'], " ")
}

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
    // Frozen: the daily attribution scan must never be scheduled, even if an
    // older client state or UI still requests it.
    let scan_on = scan_enabled && !crate::DISK_ATTRIBUTION_FROZEN;
    format!(
        "interval={}\nretention_days={}\nserver_id={}\nserver_label={}\nserver_host={}\nscan_enabled={}\nscan_hour={}\n",
        interval,
        retention,
        sanitize_agent_value(server_id),
        sanitize_agent_value(label),
        sanitize_agent_value(server_host),
        if scan_on { 1 } else { 0 },
        scan_hour
    )
}

pub fn generate_agent_script(
    server_id: &str,
    label: &str,
    server_host: &str,
    interval_seconds: u32,
    retention_days: u32,
    scan_enabled: bool,
    scan_hour: u32,
    sample_script: &str,
) -> String {
    let interval = interval_seconds.clamp(1, 3600);
    let retention = retention_days.clamp(1, 3650);
    let safe_id = sanitize_agent_value(server_id);
    let safe_label = sanitize_agent_value(label);
    let safe_host = sanitize_agent_value(server_host);

    format!(
        r#"#!/bin/sh
# Server Pulse remote agent - generated by Server Pulse. Do not edit manually.
LC_ALL=C
export LC_ALL
umask 077

sp_base="$HOME/.serverpulse"
sp_state="$sp_base/state"
sp_records="$sp_base/records"
sp_interval={interval}
sp_retention_days={retention}
sp_server_id="{safe_id}"
sp_server_label="{safe_label}"
sp_server_host="{safe_host}"
sp_scan_enabled={scan_enabled}
sp_scan_hour={scan_hour}

sp_current=""

mkdir -p "$sp_state" "$sp_records" 2>/dev/null || exit 1
echo $$ > "$sp_state/pid" 2>/dev/null

sp_aggregate() {{
  [ -z "$sp_current" ] && return 0
  [ -f "$sp_state/samples-$sp_current" ] || return 0
  sp_date=${{sp_current%T*}}
  awk -v sp_minute="$sp_current" -v sp_id="$sp_server_id" -v sp_label="$sp_server_label" -v sp_host="$sp_server_host" '
{awk}
' "$sp_state/samples-$sp_current" >> "$sp_records/$sp_date.v2.jsonl" 2>/dev/null
  rm -f "$sp_state/samples-$sp_current" 2>/dev/null
}}

sp_finish() {{
  sp_aggregate
  rm -f "$sp_state/pid" 2>/dev/null
  exit 0
}}
trap 'sp_finish' TERM INT

sp_reload_config() {{
  if [ -r "$sp_base/config" ]; then
    while IFS= read -r sp_line; do
      case "$sp_line" in
        interval=*) sp_interval=${{sp_line#*=}} ;;
        retention_days=*) sp_retention_days=${{sp_line#*=}} ;;
        server_id=*) sp_server_id=${{sp_line#*=}} ;;
        server_label=*) sp_server_label=${{sp_line#*=}} ;;
        server_host=*) sp_server_host=${{sp_line#*=}} ;;
        scan_enabled=*) sp_scan_enabled=${{sp_line#*=}} ;;
        scan_hour=*) sp_scan_hour=${{sp_line#*=}} ;;
      esac
    done < "$sp_base/config"
  fi
  case "$sp_interval" in *[!0-9]*|''|0*) sp_interval=5 ;; esac
  case "$sp_retention_days" in *[!0-9]*|''|0*) sp_retention_days=30 ;; esac
  case "$sp_scan_enabled" in 1) ;; *) sp_scan_enabled=0 ;; esac
  case "$sp_scan_hour" in *[!0-9]*|'') sp_scan_hour=3 ;; esac
}}

sp_prune() {{
  case "$sp_retention_days" in *[!0-9]*|''|0*) return 0 ;; esac
  [ "$sp_retention_days" -lt 2 ] && return 0
  sp_cutoff=$(date -u -d "-$((sp_retention_days-1)) days" +%Y-%m-%d 2>/dev/null) || return 0
  for sp_file in "$sp_records"/*.v2.jsonl; do
    [ -e "$sp_file" ] || continue
    sp_base_name=${{sp_file##*/}}
    sp_date=${{sp_base_name%.v2.jsonl}}
    case "$sp_date" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) continue ;;
    esac
    if awk -v a="$sp_date" -v b="$sp_cutoff" 'BEGIN {{ exit !(a < b) }}'; then
      rm -f "$sp_file" 2>/dev/null
    fi
  done
}}

sp_maybe_scan() {{
  [ "$sp_scan_enabled" = "1" ] || return 0
  sp_today=$(date +%Y-%m-%d 2>/dev/null) || return 0
  [ -f "$sp_state/last-scan-day" ] && [ "$(cat "$sp_state/last-scan-day" 2>/dev/null)" = "$sp_today" ] && return 0
  sp_hour=$(date +%H 2>/dev/null) || return 0
  case "$sp_hour" in *[!0-9]*|'') return 0 ;; esac
  [ "$sp_hour" -lt "$sp_scan_hour" ] && return 0
  [ -f "$sp_base/scan.sh" ] || return 0
  echo "$sp_today" > "$sp_state/last-scan-day" 2>/dev/null
  export SERVERPULSE_SERVER_ID="$sp_server_id"
  ( cd "$HOME" && if command -v setsid >/dev/null 2>&1; then nohup setsid sh "$sp_base/scan.sh" >>"$sp_base/scan.log" 2>&1 </dev/null & else nohup sh "$sp_base/scan.sh" >>"$sp_base/scan.log" 2>&1 </dev/null & fi )
}}

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
{sample}
  ) > "$sp_state/sample.tmp" 2>/dev/null
  if ! grep -q '^CPU_PERCENT=' "$sp_state/sample.tmp" 2>/dev/null; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] sample failed: $(wc -c < "$sp_state/sample.tmp" 2>/dev/null || echo 0) bytes" >> "$sp_base/agent.log" 2>/dev/null
  fi
  cat "$sp_state/sample.tmp" >> "$sp_state/samples-$sp_current" 2>/dev/null
  rm -f "$sp_state/sample.tmp" 2>/dev/null
  touch "$sp_state/heartbeat" 2>/dev/null
  sp_maybe_scan
  sp_prune
  sleep "$sp_interval" 2>/dev/null || break
done
"#,
        interval = interval,
        retention = retention,
        safe_id = safe_id,
        safe_label = safe_label,
        safe_host = safe_host,
        // Frozen: sp_scan_enabled is forced to 0 so the embedded scheduler
        // (`sp_maybe_scan`) can never fire, regardless of requested config.
        scan_enabled = if scan_enabled && !crate::DISK_ATTRIBUTION_FROZEN { 1 } else { 0 },
        scan_hour = scan_hour.clamp(0, 23),
        awk = AWK_AGGREGATOR,
        sample = sample_script.trim_end()
    )
}

pub fn generate_agent_status_script() -> &'static str {
    r#"sp="$HOME/.serverpulse"
if [ -d "$sp" ]; then
  echo 'SP_AGENT_INSTALLED=1'
else
  echo 'SP_AGENT_INSTALLED=0'
  echo 'SP_AGENT_STATUS=stopped'
  exit 0
fi
if [ -f "$sp/state/pid" ]; then
  sp_pid=$(cat "$sp/state/pid" 2>/dev/null)
  if [ -n "$sp_pid" ] && kill -0 "$sp_pid" 2>/dev/null; then
    echo 'SP_AGENT_STATUS=running'
    echo "SP_AGENT_PID=$sp_pid"
    if [ -f "$sp/state/heartbeat" ]; then
      sp_hb=$(stat -c %Y "$sp/state/heartbeat" 2>/dev/null)
      if [ -n "$sp_hb" ]; then
        sp_now=$(date +%s 2>/dev/null)
        if [ -n "$sp_now" ] && [ "$sp_now" -ge "$sp_hb" ]; then echo "SP_AGENT_HB_AGE=$((sp_now-sp_hb))"; fi
      fi
    fi
  else
    echo 'SP_AGENT_STATUS=stopped'
    rm -f "$sp/state/pid" 2>/dev/null
  fi
else
  echo 'SP_AGENT_STATUS=stopped'
fi"#
}

pub fn generate_agent_stop_script() -> &'static str {
    r#"sp="$HOME/.serverpulse"
if [ -f "$sp/state/pid" ]; then
  sp_pid=$(cat "$sp/state/pid" 2>/dev/null)
  if [ -n "$sp_pid" ] && kill -0 "$sp_pid" 2>/dev/null; then
    kill -TERM "$sp_pid" 2>/dev/null
    sp_i=0
    while [ "$sp_i" -lt 10 ] && kill -0 "$sp_pid" 2>/dev/null; do sleep 1; sp_i=$((sp_i+1)); done
    if kill -0 "$sp_pid" 2>/dev/null; then kill -KILL "$sp_pid" 2>/dev/null; fi
    rm -f "$sp/state/pid" 2>/dev/null
  else
    rm -f "$sp/state/pid" 2>/dev/null
  fi
fi
echo 'SP_AGENT_RESULT=stopped'"#
}

pub fn generate_agent_inject_script(agent_script: &str, config_text: &str, scan_script: &str) -> String {
    format!(
        r#"sp="$HOME/.serverpulse"
umask 077
mkdir -p "$sp/state" "$sp/records" 2>/dev/null || {{ echo 'SP_AGENT_RESULT=error'; echo 'SP_AGENT_ERROR=mkdir failed'; exit 0; }}
cat > "$sp/agent.sh" <<'SERVERPULSE_AGENT_EOF'
{agent}
SERVERPULSE_AGENT_EOF
cat > "$sp/config" <<'SERVERPULSE_CONFIG_EOF'
{config}
SERVERPULSE_CONFIG_EOF
cat > "$sp/scan.sh" <<'SERVERPULSE_SCAN_EOF'
{scan}
SERVERPULSE_SCAN_EOF
chmod +x "$sp/scan.sh" 2>/dev/null
chmod +x "$sp/agent.sh" 2>/dev/null
if [ -f "$sp/state/pid" ] && kill -0 "$(cat "$sp/state/pid" 2>/dev/null)" 2>/dev/null; then
  echo 'SP_AGENT_RESULT=already_running'
else
  ( cd "$HOME" && if command -v setsid >/dev/null 2>&1; then nohup setsid sh "$sp/agent.sh" >>"$sp/agent.log" 2>&1 </dev/null & else nohup sh "$sp/agent.sh" >>"$sp/agent.log" 2>&1 </dev/null & fi )
  echo 'SP_AGENT_RESULT=started'
fi"#,
        agent = agent_script,
        config = config_text,
        scan = scan_script.trim_end()
    )
}

pub fn generate_agent_config_script(config_text: &str) -> String {
    format!(
        r#"sp="$HOME/.serverpulse"
cat > "$sp/config" <<'SERVERPULSE_CONFIG_EOF'
{config}
SERVERPULSE_CONFIG_EOF
if [ -f "$sp/state/pid" ] && kill -0 "$(cat "$sp/state/pid" 2>/dev/null)" 2>/dev/null; then
  echo 'SP_AGENT_RESULT=config_updated'
  echo 'SP_AGENT_RUNNING=1'
else
  echo 'SP_AGENT_RESULT=config_updated'
  echo 'SP_AGENT_RUNNING=0'
fi"#,
        config = config_text
    )
}

pub fn generate_agent_uninstall_script() -> &'static str {
    r#"sp="$HOME/.serverpulse"
if [ -f "$sp/state/pid" ]; then
  sp_pid=$(cat "$sp/state/pid" 2>/dev/null)
  if [ -n "$sp_pid" ] && kill -0 "$sp_pid" 2>/dev/null; then
    kill -TERM "$sp_pid" 2>/dev/null
    sp_i=0
    while [ "$sp_i" -lt 10 ] && kill -0 "$sp_pid" 2>/dev/null; do sleep 1; sp_i=$((sp_i+1)); done
    if kill -0 "$sp_pid" 2>/dev/null; then kill -KILL "$sp_pid" 2>/dev/null; fi
    rm -f "$sp/state/pid" 2>/dev/null
  fi
fi
rm -rf "$sp"
echo 'SP_AGENT_RESULT=uninstalled'"#
}

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

pub fn generate_agent_pull_script(cursor_utc: Option<&str>) -> String {
    let cursor = cursor_utc.unwrap_or("");
    // Frozen: attribution files never cross the wire — merges stay
    // history-only and the scan data keeps living on the server, untouched.
    let attribution_section = if crate::DISK_ATTRIBUTION_FROZEN {
        String::new()
    } else {
        r#"
if [ -d "$sp/attribution" ]; then
  for sp_file in "$sp/attribution"/*.jsonl; do
    [ -e "$sp_file" ] || continue
    sp_base=${sp_file##*/}
    case "$sp_base" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].jsonl) ;;
      *) continue ;;
    esac
    echo "__SP_ATTR_FILE__${sp_base%.jsonl}"
    cat "$sp_file"
  done
fi"#
            .to_owned()
    };
    format!(
        r#"sp="$HOME/.serverpulse"
sp_cursor="{cursor}"
sp_record_files=0
if [ -d "$sp/records" ]; then
  for sp_file in "$sp/records"/*.v2.jsonl; do
    [ -e "$sp_file" ] || continue
    sp_base=${{sp_file##*/}}
    sp_date=${{sp_base%.v2.jsonl}}
    case "$sp_date" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) continue ;;
    esac
    if [ -n "$sp_cursor" ]; then
      sp_cursor_date=${{sp_cursor%T*}}
      if awk -v a="$sp_date" -v b="$sp_cursor_date" 'BEGIN {{ exit !(a < b) }}'; then continue; fi
    fi
    sp_record_files=$((sp_record_files+1))
    echo "__SP_FILE__$sp_date"
    cat "$sp_file"
  done
fi
{attribution_section}
echo "SP_AGENT_RECORD_FILES=$sp_record_files"
echo '__SP_DONE__'"#,
        cursor = cursor,
        attribution_section = attribution_section
    )
}

pub fn generate_agent_clean_script(cursor_utc: &str) -> String {
    // Frozen: remote attribution data is preserved, so the clean script only
    // prunes metric record files and never touches the attribution directory.
    let attribution_section = if crate::DISK_ATTRIBUTION_FROZEN {
        String::new()
    } else {
        r#"
if [ -n "$sp_cursor" ] && [ -d "$sp/attribution" ]; then
  for sp_file in "$sp/attribution"/*.jsonl; do
    [ -e "$sp_file" ] || continue
    sp_base=${sp_file##*/}
    sp_date=${sp_base%.jsonl}
    case "$sp_date" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) continue ;;
    esac
    if awk -v a="$sp_date" -v b="$sp_cursor_date" 'BEGIN { exit !(a < b) }'; then
      rm -f "$sp_file" 2>/dev/null
      echo "SP_AGENT_CLEANED_ATTR=$sp_date"
    fi
  done
fi"#
            .to_owned()
    };
    format!(
        r#"sp="$HOME/.serverpulse"
sp_cursor="{cursor}"
sp_cursor_date=${{sp_cursor%T*}}
if [ -n "$sp_cursor" ] && [ -d "$sp/records" ]; then
  for sp_file in "$sp/records"/*.v2.jsonl; do
    [ -e "$sp_file" ] || continue
    sp_base=${{sp_file##*/}}
    sp_date=${{sp_base%.v2.jsonl}}
    case "$sp_date" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) continue ;;
    esac
    if awk -v a="$sp_date" -v b="$sp_cursor_date" 'BEGIN {{ exit !(a < b) }}'; then
      rm -f "$sp_file" 2>/dev/null
      echo "SP_AGENT_CLEANED=$sp_date"
    fi
  done
fi
{attribution_section}
echo '__SP_DONE__'"#,
        cursor = cursor_utc,
        attribution_section = attribution_section
    )
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AgentStatus {
    Running,
    Stopped,
    Stale,
    NotInstalled,
    Checking,
    Unknown,
}

impl AgentStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Running => "running",
            Self::Stopped => "stopped",
            Self::Stale => "stale",
            Self::NotInstalled => "not_installed",
            Self::Checking => "checking",
            Self::Unknown => "unknown",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentStatusInfo {
    pub status: AgentStatus,
    pub pid: Option<u32>,
    pub heartbeat_age_seconds: Option<u64>,
    pub installed: bool,
    pub error: Option<String>,
}

pub fn parse_agent_status_output(output: &str, stale_threshold_secs: u64) -> AgentStatusInfo {
    let mut fields = HashMap::new();
    for line in output.lines() {
        let clean = line.trim();
        if let Some((k, v)) = clean.split_once('=') {
            if let Some(key_tail) = k.strip_prefix("SP_AGENT_") {
                fields.insert(key_tail.to_owned(), v.to_owned());
            }
        }
    }

    let installed = fields.get("INSTALLED").map(|v| v == "1").unwrap_or(false);
    let pid = fields.get("PID").and_then(|v| v.parse::<u32>().ok());
    let hb_age = fields.get("HB_AGE").and_then(|v| v.parse::<u64>().ok());

    let raw_status = fields.get("STATUS").map(String::as_str).unwrap_or("unknown");
    let status = match raw_status {
        "running" => {
            if let Some(age) = hb_age {
                if age > stale_threshold_secs {
                    AgentStatus::Stale
                } else {
                    AgentStatus::Running
                }
            } else {
                AgentStatus::Running
            }
        }
        "stopped" => {
            if installed {
                AgentStatus::Stopped
            } else {
                AgentStatus::NotInstalled
            }
        }
        _ => {
            if !installed {
                AgentStatus::NotInstalled
            } else {
                AgentStatus::Unknown
            }
        }
    };

    AgentStatusInfo {
        status,
        pid,
        heartbeat_age_seconds: hb_age,
        installed,
        error: fields.get("ERROR").cloned(),
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentPulledEntry {
    /// Legacy local-time fields retained for callers that still display the
    /// pulled entry directly. History persistence must use the UTC fields.
    pub local_minute: String, // e.g. "2026-08-19T19:30:00"
    pub local_day: String,    // e.g. "2026-08-19"
    pub utc_minute: String,   // e.g. "2026-08-19T11:30"
    /// Canonical storage partition and timestamp for newly merged history.
    pub utc_day: String,       // e.g. "2026-08-19"
    pub utc_timestamp: String, // e.g. "2026-08-19T11:30:00Z"
    pub entry: serde_json::Value,
    pub sample_count: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentPullResult {
    pub entries: Vec<AgentPulledEntry>,
    pub pulled_lines: usize,
    pub corrupt_lines: usize,
    pub dropped_unknown: usize,
    pub record_files: usize,
    pub skipped_by_cursor: usize,
    pub max_utc_minute: Option<String>,
}

pub fn parse_agent_pull_output(
    output: &str,
    known_server_ids: &[String],
    cursor_utc: Option<&str>,
) -> AgentPullResult {
    let mut entries = Vec::new();
    let mut pulled_lines = 0;
    let mut corrupt_lines = 0;
    let mut dropped_unknown = 0;
    let mut record_files = 0;
    let mut skipped_by_cursor = 0;
    let mut max_utc_minute: Option<String> = None;

    let cursor_parsed = cursor_utc.and_then(|c| {
        NaiveDateTime::parse_from_str(c.trim(), "%Y-%m-%dT%H:%M").ok()
            .or_else(|| NaiveDateTime::parse_from_str(c.trim(), "%Y-%m-%dT%H:%M:%S").ok())
    });

    for line in output.lines() {
        let clean = line.trim();
        if clean.is_empty()
            || clean == "__SP_DONE__"
            || clean.starts_with("__SP_FILE__")
            || clean.starts_with("__SP_ATTR_FILE__")
        {
            continue;
        }
        if clean.starts_with("SP_AGENT_") {
            if let Some((k, v)) = clean.split_once('=') {
                if k == "SP_AGENT_RECORD_FILES" {
                    if let Ok(cnt) = v.parse::<usize>() {
                        record_files = cnt;
                    }
                }
            }
            continue;
        }
        // Disk-attribution JSON lines (no "Record" key) belong to
        // parse_agent_attribution_output; they are neither pulled records nor
        // corruption, so skip them without counting.
        let Ok(json_obj) = serde_json::from_str::<serde_json::Value>(clean) else {
            corrupt_lines += 1;
            continue;
        };
        if json_obj.get("Record").is_none()
            && json_obj.get("kind").and_then(|v| v.as_str()) == Some("diskAttribution")
        {
            continue;
        }
        let Some(record) = json_obj.get("Record") else {
            corrupt_lines += 1;
            continue;
        };
        // Only well-formed minute records count as pulled lines.
        pulled_lines += 1;

        let ts_str = record.get("Timestamp").and_then(|v| v.as_str()).unwrap_or_default();
        let sample_count = record.get("SampleCount").and_then(|v| v.as_u64()).unwrap_or(1);

        // Parse UTC timestamp
        let (utc_naive, local_dt) = if let Ok(dt) = DateTime::parse_from_rfc3339(ts_str) {
            (dt.naive_utc(), dt.with_timezone(&Local))
        } else if let Ok(naive) = NaiveDateTime::parse_from_str(ts_str, "%Y-%m-%dT%H:%M:%S") {
            let utc_dt = naive.and_utc();
            let local = utc_dt.with_timezone(&Local);
            (naive, local)
        } else if let Ok(naive) = NaiveDateTime::parse_from_str(ts_str, "%Y-%m-%dT%H:%M") {
            let utc_dt = naive.and_utc();
            let local = utc_dt.with_timezone(&Local);
            (naive, local)
        } else {
            corrupt_lines += 1;
            continue;
        };

        if let Some(cursor_dt) = cursor_parsed {
            if utc_naive <= cursor_dt {
                skipped_by_cursor += 1;
                continue;
            }
        }

        let utc_min_str = utc_naive.format("%Y-%m-%dT%H:%M").to_string();
        let utc_day = utc_naive.format("%Y-%m-%d").to_string();
        let utc_timestamp = utc_naive.format("%Y-%m-%dT%H:%M:00Z").to_string();
        if max_utc_minute.as_ref().map(|m| &utc_min_str > m).unwrap_or(true) {
            max_utc_minute = Some(utc_min_str.clone());
        }

        let local_minute = local_dt.format("%Y-%m-%dT%H:%M:00").to_string();
        let local_day = local_dt.format("%Y-%m-%d").to_string();

        let servers_list = record.get("Servers").and_then(|v| v.as_array());
        if let Some(servers) = servers_list {
            for server in servers {
                let id = server.get("Id").and_then(|v| v.as_str()).unwrap_or_default();
                if !known_server_ids.is_empty() && !known_server_ids.iter().any(|k| k == id) {
                    dropped_unknown += 1;
                    continue;
                }
                entries.push(AgentPulledEntry {
                    local_minute: local_minute.clone(),
                    local_day: local_day.clone(),
                    utc_minute: utc_min_str.clone(),
                    utc_day: utc_day.clone(),
                    utc_timestamp: utc_timestamp.clone(),
                    entry: server.clone(),
                    sample_count,
                });
            }
        }
    }

    AgentPullResult {
        entries,
        pulled_lines,
        corrupt_lines,
        dropped_unknown,
        record_files,
        skipped_by_cursor,
        max_utc_minute,
    }
}

/// True when `day` matches the canonical `YYYY-MM-DD` shape (digits with
/// dashes at fixed positions). Used to keep hostile remote markers from
/// becoming file-path components.
pub fn is_valid_day_shape(day: &str) -> bool {
    let b = day.as_bytes();
    b.len() == 10
        && b[4] == b'-'
        && b[7] == b'-'
        && b.iter().enumerate().all(|(i, c)| {
            i == 4 || i == 7 || c.is_ascii_digit()
        })
}

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
            // Only accept canonical YYYY-MM-DD payloads; anything else is
            // treated as "no current day" so following lines are skipped.
            if is_valid_day_shape(day) {
                current_day = Some(day.to_owned());
            } else {
                current_day = None;
            }
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
        match super::parse_disk_attribution_line(clean) {
            Ok(_) => rows.push((day, clean.to_owned())),
            Err(_) => corrupt += 1,
        }
    }
    (rows, corrupt)
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct MergeStats {
    pub added_minutes: usize,
    pub updated_servers: usize,
    pub skipped_servers: usize,
}

pub fn merge_agent_day_entries(
    existing_lines: &[String],
    entries: &[AgentPulledEntry],
) -> (Vec<String>, MergeStats) {
    let mut stats = MergeStats::default();
    let mut minute_map: HashMap<String, (serde_json::Value, u64, Vec<serde_json::Value>)> = HashMap::new();
    let mut minute_order: Vec<String> = Vec::new();

    // Parse existing lines
    for line in existing_lines {
        let clean = line.trim();
        if clean.is_empty() {
            continue;
        }
        if let Ok(mut val) = serde_json::from_str::<serde_json::Value>(clean) {
            if let Some(record) = val.get_mut("Record") {
                let ts = record.get("Timestamp").and_then(|v| v.as_str()).unwrap_or_default().to_owned();
                let sample_count = record.get("SampleCount").and_then(|v| v.as_u64()).unwrap_or(1);
                let servers = record.get("Servers").and_then(|v| v.as_array()).cloned().unwrap_or_default();
                if !minute_map.contains_key(&ts) {
                    minute_order.push(ts.clone());
                }
                minute_map.insert(ts, (val, sample_count, servers));
            }
        }
    }

    // Merge pulled entries
    for item in entries {
        let ts = &item.utc_timestamp;
        if let Some((_container, _sc, servers)) = minute_map.get_mut(ts) {
            // Minute exists: check server conflict
            let item_server_id = item.entry.get("Id").and_then(|v| v.as_str()).unwrap_or_default();
            let mut found_idx = None;
            for (idx, s) in servers.iter().enumerate() {
                if s.get("Id").and_then(|v| v.as_str()).unwrap_or_default() == item_server_id {
                    found_idx = Some(idx);
                    break;
                }
            }

            if let Some(idx) = found_idx {
                let local_samples = servers[idx].get("OnlineSamples").and_then(|v| v.as_u64()).unwrap_or(0);
                let server_samples = item.entry.get("OnlineSamples").and_then(|v| v.as_u64()).unwrap_or(0);
                if server_samples > local_samples {
                    servers[idx] = item.entry.clone();
                    stats.updated_servers += 1;
                } else {
                    stats.skipped_servers += 1;
                }
            } else {
                servers.push(item.entry.clone());
                stats.updated_servers += 1;
            }
        } else {
            // New minute record
            minute_order.push(ts.clone());
            let new_record = serde_json::json!({
                "Version": 2,
                "Record": {
                    "Timestamp": ts,
                    "SampleCount": item.sample_count,
                    "Servers": [item.entry.clone()],
                }
            });
            minute_map.insert(ts.clone(), (new_record, item.sample_count, vec![item.entry.clone()]));
            stats.added_minutes += 1;
        }
    }

    minute_order.sort();

    let mut result_lines = Vec::new();
    for ts in minute_order {
        if let Some((mut container, sc, servers)) = minute_map.remove(&ts) {
            if let Some(record) = container.get_mut("Record") {
                if let Some(obj) = record.as_object_mut() {
                    obj.insert("Timestamp".to_owned(), serde_json::Value::String(ts));
                    obj.insert("SampleCount".to_owned(), serde_json::Value::Number(sc.into()));
                    obj.insert("Servers".to_owned(), serde_json::Value::Array(servers));
                }
            }
            if let Ok(line_str) = serde_json::to_string(&container) {
                result_lines.push(line_str);
            }
        }
    }

    (result_lines, stats)
}

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

    #[test]
    fn rejects_non_day_attribution_file_marker() {
        // Hostile/path-like day payloads must not be accepted as a current
        // day; following lines are skipped entirely (no rows, no corrupt).
        let output = concat!(
            "__SP_ATTR_FILE__../evil\n",
            "{\"kind\":\"diskAttribution\",\"serverId\":\"s1\",\"scannedAt\":\"2026-08-20T03:12:45Z\",\"mount\":\"/data\",\"status\":\"ok\",\"skippedEntries\":0,\"users\":[]}\n",
            "__SP_ATTR_FILE__2026-8-20\n",
            "{\"kind\":\"diskAttribution\",\"serverId\":\"s1\",\"scannedAt\":\"2026-08-20T03:12:45Z\",\"mount\":\"/data\",\"status\":\"ok\",\"skippedEntries\":0,\"users\":[]}\n",
            "__SP_DONE__\n",
        );
        let (rows, corrupt) = parse_agent_attribution_output(output);
        assert_eq!(rows.len(), 0);
        assert_eq!(corrupt, 0);
    }

    #[test]
    fn pull_parser_skips_attribution_output() {
        // Mixed pull output: one valid minute record, one attribution file
        // marker, one attribution JSON line, one genuinely broken line.
        let output = concat!(
            "__SP_FILE__2026-08-19\n",
            "{\"Version\":2,\"Record\":{\"Timestamp\":\"2026-08-19T10:00:00Z\",\"SampleCount\":12,\"Servers\":[{\"Id\":\"s1\",\"OnlineSamples\":12}]}}\n",
            "__SP_ATTR_FILE__2026-08-20\n",
            "{\"kind\":\"diskAttribution\",\"serverId\":\"s1\",\"scannedAt\":\"2026-08-20T03:12:45Z\",\"mount\":\"/data\",\"status\":\"ok\",\"skippedEntries\":0,\"users\":[]}\n",
            "{not json at all\n",
            "__SP_DONE__\n",
        );
        let known = vec!["s1".to_string()];
        let result = parse_agent_pull_output(output, &known, None);
        assert_eq!(result.pulled_lines, 1);
        assert_eq!(result.corrupt_lines, 1);
        assert_eq!(result.entries.len(), 1);
    }

    #[test]
    fn awk_aggregator_emits_disks_contract() {
        // Cheap contract pin: the AWK aggregator's emit_disks must keep the
        // canonical TotalMiB/UsedMiB keys that history consumers rely on.
        assert!(AWK_AGGREGATOR.contains("TotalMiB"));
        assert!(AWK_AGGREGATOR.contains("UsedMiB"));
        assert!(AWK_AGGREGATOR.contains("\\\"Disks\\\""));
    }
}
