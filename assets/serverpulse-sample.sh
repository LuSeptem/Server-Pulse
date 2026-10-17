#!/bin/sh
# Server Pulse protocol v2 canonical remote sampler.
# Keep this file POSIX sh and LF-only. It is used by both live collection
# and the future server-side agent.
LC_ALL=C
export LC_ALL
umask 077
echo "PROTOCOL_VERSION=2"
shell_tab=$(printf '\t')

snapshot_processes() {
  output=$1
  meta=$2
  skipped=0
  : > "$output" 2>/dev/null || return 1
  for process_dir in /proc/[0-9]*; do
    [ -d "$process_dir" ] || continue
    pid=${process_dir##*/}
    IFS= read -r process_stat < "$process_dir/stat" 2>/dev/null || {
      skipped=$((skipped+1))
      continue
    }
    process_fields=${process_stat##*) }
    set -- $process_fields
    [ "$#" -ge 22 ] || {
      skipped=$((skipped+1))
      continue
    }
    user_id=
    while IFS="$shell_tab " read -r status_key status_value status_rest; do
      if [ "$status_key" = "Uid:" ]; then
        user_id=$status_value
        break
      fi
    done < "$process_dir/status" 2>/dev/null
    case "$user_id:${12}:${13}:${20}:${22}" in
      *[!0-9:-]*|:*|*::* )
        skipped=$((skipped+1))
        continue
        ;;
    esac
    printf '%s %s %s %s %s\n' "$pid" "${20}" "$user_id" "$(( ${12} + ${13} ))" "${22}" >> "$output"
  done
  printf '%s\n' "$skipped" > "$meta"
}

user_name() {
  resolved_name=
  if [ -n "$user_database" ] && [ -r "$user_database" ]; then
    while IFS=: read -r account_name account_password account_uid account_gid account_gecos account_home account_shell; do
      if [ "$account_uid" = "$1" ]; then
        resolved_name=$account_name
        break
      fi
    done < "$user_database"
  fi
  if [ -n "$resolved_name" ]; then
    printf '%s' "$resolved_name" | tr '\t\r\n' '   '
  else
    printf 'UID %s' "$1"
  fi
}

metrics_tmp=$(mktemp -d "${TMPDIR:-/tmp}/serverpulse.XXXXXX" 2>/dev/null || true)
if [ -n "$metrics_tmp" ]; then
  trap 'rm -rf "$metrics_tmp"' EXIT HUP INT TERM
fi

user_database=
if [ -n "$metrics_tmp" ] && command -v getent >/dev/null 2>&1 && getent passwd > "$metrics_tmp/passwd" 2>/dev/null; then
  user_database="$metrics_tmp/passwd"
elif [ -r /etc/passwd ]; then
  user_database=/etc/passwd
fi

read_cpu_sample() {
  IFS=' ' read -r cpu_label cpu_user cpu_nice cpu_system cpu_idle cpu_wait cpu_irq cpu_softirq cpu_steal cpu_rest < /proc/stat
  sampled_total=$((cpu_user+cpu_nice+cpu_system+cpu_idle+cpu_wait+cpu_irq+cpu_softirq+cpu_steal))
  sampled_idle=$((cpu_idle+cpu_wait))
}

process_collection=0
read_cpu_sample
total_before_1=$sampled_total
idle_before_1=$sampled_idle
if [ -n "$metrics_tmp" ] && snapshot_processes "$metrics_tmp/processes-1" "$metrics_tmp/skipped-1"; then
  process_collection=1
fi
read_cpu_sample
total_after_1=$sampled_total
idle_after_1=$sampled_idle
sleep 0.2
read_cpu_sample
total_before_2=$sampled_total
idle_before_2=$sampled_idle
if [ "$process_collection" -eq 1 ] && snapshot_processes "$metrics_tmp/processes-2" "$metrics_tmp/skipped-2"; then
  process_collection=2
fi
read_cpu_sample
total_after_2=$sampled_total
idle_after_2=$sampled_idle

total_delta_doubled=$((total_before_2+total_after_2-total_before_1-total_after_1))
idle_delta_doubled=$((idle_before_2+idle_after_2-idle_before_1-idle_after_1))
cpu=$(awk -v dt="$total_delta_doubled" -v di="$idle_delta_doubled" 'BEGIN { if (dt > 0) { value=(dt-di)*100/dt; if (value < 0) value=0; if (value > 100) value=100; printf "%.1f", value } else print "0.0" }')
mem_total=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
mem_available=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
mem_used=$((mem_total-mem_available))
mem_percent=$(awk -v u="$mem_used" -v t="$mem_total" 'BEGIN { if (t > 0) printf "%.1f", u*100/t; else print "0.0" }')
set -- $(cat /proc/loadavg)
echo "HOSTNAME=$(hostname)"
echo "CPU_PERCENT=$cpu"
echo "MEM_TOTAL_KIB=$mem_total"
echo "MEM_USED_KIB=$mem_used"
echo "MEM_PERCENT=$mem_percent"
echo "LOAD_1=$1"
echo "LOAD_5=$2"
echo "LOAD_15=$3"
echo "UPTIME_SECONDS=$(cut -d. -f1 /proc/uptime)"

process_status=unavailable
process_skipped=0
page_size=$(getconf PAGESIZE 2>/dev/null || true)
if [ "$process_collection" -eq 2 ] && [ -n "$page_size" ]; then
  skipped_1=$(cat "$metrics_tmp/skipped-1" 2>/dev/null || echo 0)
  skipped_2=$(cat "$metrics_tmp/skipped-2" 2>/dev/null || echo 0)
  process_skipped=$((skipped_1+skipped_2))
  if [ "$process_skipped" -eq 0 ]; then process_status=ok; else process_status=partial; fi
  awk 'NR==FNR { first[$1 SUBSEP $2]=$4; next }
       {
         key=$1 SUBSEP $2;
         if (key in first) {
           delta=$4-first[key];
           if (delta > 0) { cpu[$3]+=delta; cpu_pcount[$3]++ }
         }
         if ($5 > 0) { memory[$3]+=$5; mem_pcount[$3]++ }
       }
       END {
         for (uid in cpu) print uid, cpu[uid], (cpu_pcount[uid] > 0 ? cpu_pcount[uid] : 1) > cpu_file;
         for (uid in memory) print uid, memory[uid], (mem_pcount[uid] > 0 ? mem_pcount[uid] : 1) > memory_file
       }' \
      cpu_file="$metrics_tmp/cpu-users" memory_file="$metrics_tmp/memory-users" \
      "$metrics_tmp/processes-1" "$metrics_tmp/processes-2" 2>/dev/null || process_status=partial

  if [ -f "$metrics_tmp/cpu-users" ]; then
    while read user_id ticks pcount; do
      [ -n "$user_id" ] || continue
      user_percent=$(awk -v ticks="$ticks" -v total_delta_doubled="$total_delta_doubled" 'BEGIN { if (total_delta_doubled > 0) printf "%.3f", ticks*200/total_delta_doubled; else print "0.000" }')
      printf 'CPU_USER=%s\t%s\t%s\t%s\n' "$user_id" "$(user_name "$user_id")" "$user_percent" "${pcount:-1}"
    done < "$metrics_tmp/cpu-users"
  fi
  if [ -f "$metrics_tmp/memory-users" ]; then
    while read user_id rss_pages pcount; do
      [ -n "$user_id" ] || continue
      user_mib=$(awk -v pages="$rss_pages" -v bytes="$page_size" 'BEGIN { printf "%.3f", pages*bytes/1048576 }')
      printf 'MEMORY_USER=%s\t%s\t%s\t%s\n' "$user_id" "$(user_name "$user_id")" "$user_mib" "${pcount:-1}"
    done < "$metrics_tmp/memory-users"
  fi
fi
echo "CPU_USER_STATUS=$process_status"
echo "CPU_USER_SKIPPED=$process_skipped"
echo "MEMORY_USER_STATUS=$process_status"
echo "MEMORY_USER_SKIPPED=$process_skipped"

echo "GPUS_BEGIN"
gpu_query_status=unavailable
gpu_metrics_status=
if command -v nvidia-smi >/dev/null 2>&1; then
  gpu_metrics_status=unavailable
  if [ -n "$metrics_tmp" ]; then
    gpu_fields=index,name,uuid,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit,fan.speed
    if nvidia-smi --query-gpu="$gpu_fields" --format=csv,noheader,nounits > "$metrics_tmp/gpus-raw" 2>/dev/null; then
      gpu_metrics_status=ok
    else
      # A single inaccessible device can fail the entire query. -L still
      # lists healthy devices on these drivers, even when it exits nonzero.
      # Query indices individually: UUID lookup can itself enumerate all devices
      # and fail on the same broken card. Keep valid rows from the bulk query.
      gpu_metrics_status=partial
      nvidia-smi -L > "$metrics_tmp/gpu-list" 2>/dev/null || true
      sed -n 's/^GPU \([0-9][0-9]*\):.*/\1/p' \
        "$metrics_tmp/gpu-list" > "$metrics_tmp/gpu-ids"
      while IFS= read -r gpu_id; do
        [ -n "$gpu_id" ] || continue
        nvidia-smi -i "$gpu_id" --query-gpu="$gpu_fields" --format=csv,noheader,nounits \
          >> "$metrics_tmp/gpus-raw" 2>/dev/null || true
      done < "$metrics_tmp/gpu-ids"
    fi
    # Driver diagnostics may appear on stdout. Only emit metric rows, once
    # per GPU index, so partial output and retries cannot duplicate cards.
    awk -F, 'NF >= 10 && $1 ~ /^[[:space:]]*[0-9]+[[:space:]]*$/ {
      index_key = $1 + 0;
      if (!seen[index_key]++) print
    }' "$metrics_tmp/gpus-raw" > "$metrics_tmp/gpus"
    if [ "$gpu_metrics_status" != ok ] && [ ! -s "$metrics_tmp/gpus" ]; then
      gpu_metrics_status=unavailable
    fi
    cat "$metrics_tmp/gpus"
  fi
fi
echo "GPUS_END"
[ -z "$gpu_metrics_status" ] || echo "GPU_QUERY_STATUS=$gpu_metrics_status"

if [ -n "$metrics_tmp" ] && [ -s "$metrics_tmp/gpus" ]; then
  : > "$metrics_tmp/gpu-users"
  : > "$metrics_tmp/gpu-unmapped"
  gpu_process_fields=gpu_uuid,pid,used_gpu_memory
  gpu_process_success=0
  awk -F, '{ print $1 + 0 }' "$metrics_tmp/gpus" > "$metrics_tmp/gpu-readable-ids"
  if nvidia-smi --query-compute-apps="$gpu_process_fields" --format=csv,noheader,nounits > "$metrics_tmp/gpu-processes-raw" 2>/dev/null; then
    gpu_query_status=ok
    gpu_process_success=1
    while read -r gpu_id; do
      printf 'GPU_USER_STATUS_%s=ok\n' "$gpu_id"
    done < "$metrics_tmp/gpu-readable-ids"
  else
    # Process queries can fail on the same inaccessible card as metrics.
    # Retry only the readable indices, including GPUs with no compute process.
    gpu_query_status=ok
    while read -r gpu_id; do
      if nvidia-smi -i "$gpu_id" --query-compute-apps="$gpu_process_fields" --format=csv,noheader,nounits > "$metrics_tmp/gpu-processes-device" 2>/dev/null; then
        gpu_device_status=ok
        gpu_process_success=1
      else
        gpu_query_status=partial
        gpu_device_status=unavailable
        if awk -F, 'NF == 3 && $2 ~ /^[[:space:]]*[0-9]+[[:space:]]*$/ { found=1 } END { exit !found }' "$metrics_tmp/gpu-processes-device"; then
          gpu_device_status=partial
        fi
      fi
      printf 'GPU_USER_STATUS_%s=%s\n' "$gpu_id" "$gpu_device_status"
      cat "$metrics_tmp/gpu-processes-device" >> "$metrics_tmp/gpu-processes-raw"
    done < "$metrics_tmp/gpu-readable-ids"
  fi
  # Failed queries can contain diagnostics or repeat rows returned by retries.
  # Keep one row per UUID/PID; multiple processes of the same user still sum.
  awk -F, 'NF == 3 && $2 ~ /^[[:space:]]*[0-9]+[[:space:]]*$/ {
    for (i=1; i<=3; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i);
    rows[$1 SUBSEP $2]=$1 "," $2 "," $3
  } END { for (key in rows) print rows[key] }' "$metrics_tmp/gpu-processes-raw" > "$metrics_tmp/gpu-processes"
  if [ "$gpu_process_success" -eq 0 ] && [ ! -s "$metrics_tmp/gpu-processes" ]; then
    gpu_query_status=unavailable
  fi
  if [ "$gpu_query_status" != unavailable ]; then
    while IFS=, read gpu_uuid gpu_pid gpu_memory extra; do
      gpu_uuid=$(printf '%s' "$gpu_uuid" | awk '{$1=$1; print}')
      gpu_pid=$(printf '%s' "$gpu_pid" | awk '{$1=$1; print}')
      gpu_memory=$(printf '%s' "$gpu_memory" | awk '{$1=$1; print}')
      case "$gpu_pid:$gpu_memory" in
        *[!0-9.:]*|:*|*::* )
          printf '%s\n' "$gpu_uuid" >> "$metrics_tmp/gpu-unmapped"
          gpu_query_status=partial
          continue
          ;;
      esac
      gpu_uid=$(awk -v wanted_pid="$gpu_pid" '$1 == wanted_pid { print $3; exit }' "$metrics_tmp/processes-2" 2>/dev/null)
      if [ -z "$gpu_uid" ]; then
        gpu_uid=$(awk '/^Uid:/ { print $2; exit }' "/proc/$gpu_pid/status" 2>/dev/null || true)
      fi
      if [ -n "$gpu_uid" ]; then
        printf '%s\t%s\t%s\n' "$gpu_uuid" "$gpu_uid" "$gpu_memory" >> "$metrics_tmp/gpu-users"
      else
        printf '%s\n' "$gpu_uuid" >> "$metrics_tmp/gpu-unmapped"
        gpu_query_status=partial
      fi
    done < "$metrics_tmp/gpu-processes"

    awk -F '\t' '{ total[$1 SUBSEP $2]+=$3; pcount[$1 SUBSEP $2]++ } END { for (key in total) { split(key, fields, SUBSEP); print fields[1] "\t" fields[2] "\t" total[key] "\t" pcount[key] } }' \
      "$metrics_tmp/gpu-users" > "$metrics_tmp/gpu-user-totals" 2>/dev/null || gpu_query_status=partial
    while IFS="$shell_tab" read gpu_uuid user_id user_mib pcount; do
      [ -n "$gpu_uuid" ] || continue
      printf 'GPU_USER=%s\t%s\t%s\t%s\t%s\n' "$gpu_uuid" "$user_id" "$(user_name "$user_id")" "$user_mib" "${pcount:-1}"
    done < "$metrics_tmp/gpu-user-totals"
    awk '{ count[$0]++ } END { for (uuid in count) print uuid "\t" count[uuid] }' "$metrics_tmp/gpu-unmapped" 2>/dev/null | \
      while IFS="$shell_tab" read gpu_uuid count; do
        [ -n "$gpu_uuid" ] && printf 'GPU_UNMAPPED=%s\t%s\n' "$gpu_uuid" "$count"
      done
  fi
fi
echo "GPU_USER_STATUS=$gpu_query_status"

echo "DISKS_BEGIN"
df -kTP 2>/dev/null | awk '
NR > 1 {
  if (NF >= 7) { dev = $1; fstype = $2; total = $3; used = $4; mount = $7 }
  else if (NF == 6) { dev = $1; fstype = ""; total = $2; used = $3; mount = $6 }
  else { next }
  if (dev ~ /^(tmpfs|devtmpfs|overlay|shm|none|udev|squashfs|cgroup|ramfs|aufs|proc|sysfs|devpts|mqueue|hugetlbfs|binfmt_misc|configfs|securityfs|pstore|debugfs|tracefs|bpf|autofs|efivarfs|nsfs)/) next
  if (fstype ~ /^(tmpfs|devtmpfs|overlay|squashfs|proc|sysfs|devpts|mqueue|hugetlbfs|securityfs|debugfs|tracefs|configfs|fusectl|efivarfs|bpf|nsfs|ramfs|cgroup|autofs|binfmt_misc|pstore|iso9660)/) next
  if (mount ~ /^\/(proc|sys|dev|run|boot\/efi)(\/|$)/) next
  if (total + 0 <= 0) next
  printf "%s\t%s\t%s\t%s\t%s\n", dev, mount, total, used, fstype
}'
echo "DISKS_END"
