param(
    [Parameter(Mandatory)]
    [string]$ConfigPath,
    [switch]$RuntimeInput
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'ServerPulse.Core.ps1')
. (Join-Path $PSScriptRoot 'ServerPulse.Ssh.ps1')

$config = Get-ServerPulseConfig -Path $ConfigPath
$runtime = if ($RuntimeInput) {
    $runtimeText = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($runtimeText)) { throw '运行时服务器输入为空' }
    $parsedRuntime=$runtimeText | ConvertFrom-Json
    $runtimeText=$null
    $parsedRuntime
} else { $null }
$remoteScript = @'
#!/bin/sh
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
       { key=$1 SUBSEP $2; if (key in first) { delta=$4-first[key]; if (delta >= 0) cpu[$3]+=delta } memory[$3]+=$5 }
       END { for (uid in cpu) print uid, cpu[uid] > cpu_file; for (uid in memory) print uid, memory[uid] > memory_file }' \
      cpu_file="$metrics_tmp/cpu-users" memory_file="$metrics_tmp/memory-users" \
      "$metrics_tmp/processes-1" "$metrics_tmp/processes-2" 2>/dev/null || process_status=partial

  if [ -f "$metrics_tmp/cpu-users" ]; then
    while read user_id ticks; do
      [ -n "$user_id" ] || continue
      user_percent=$(awk -v ticks="$ticks" -v total_delta_doubled="$total_delta_doubled" 'BEGIN { if (total_delta_doubled > 0) printf "%.3f", ticks*200/total_delta_doubled; else print "0.000" }')
      printf 'CPU_USER=%s\t%s\t%s\n' "$user_id" "$(user_name "$user_id")" "$user_percent"
    done < "$metrics_tmp/cpu-users"
  fi
  if [ -f "$metrics_tmp/memory-users" ]; then
    while read user_id rss_pages; do
      [ -n "$user_id" ] || continue
      user_mib=$(awk -v pages="$rss_pages" -v bytes="$page_size" 'BEGIN { printf "%.3f", pages*bytes/1048576 }')
      printf 'MEMORY_USER=%s\t%s\t%s\n' "$user_id" "$(user_name "$user_id")" "$user_mib"
    done < "$metrics_tmp/memory-users"
  fi
fi
echo "CPU_USER_STATUS=$process_status"
echo "CPU_USER_SKIPPED=$process_skipped"
echo "MEMORY_USER_STATUS=$process_status"
echo "MEMORY_USER_SKIPPED=$process_skipped"

echo "GPUS_BEGIN"
gpu_query_status=unavailable
if command -v nvidia-smi >/dev/null 2>&1; then
  if [ -n "$metrics_tmp" ] && nvidia-smi --query-gpu=index,name,uuid,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit,fan.speed --format=csv,noheader,nounits > "$metrics_tmp/gpus" 2>/dev/null; then
    cat "$metrics_tmp/gpus"
  fi
fi
echo "GPUS_END"

if [ -n "$metrics_tmp" ] && [ -f "$metrics_tmp/gpus" ]; then
  : > "$metrics_tmp/gpu-users"
  : > "$metrics_tmp/gpu-unmapped"
  if nvidia-smi --query-compute-apps=gpu_uuid,pid,used_gpu_memory --format=csv,noheader,nounits > "$metrics_tmp/gpu-processes" 2>/dev/null; then
    gpu_query_status=ok
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
        gpu_uid=$(awk '/^Uid:/ { print $2; exit }' "/proc/$gpu_pid/status" 2>/dev/null)
      fi
      if [ -n "$gpu_uid" ]; then
        printf '%s\t%s\t%s\n' "$gpu_uuid" "$gpu_uid" "$gpu_memory" >> "$metrics_tmp/gpu-users"
      else
        printf '%s\n' "$gpu_uuid" >> "$metrics_tmp/gpu-unmapped"
        gpu_query_status=partial
      fi
    done < "$metrics_tmp/gpu-processes"

    awk -F '\t' '{ total[$1 SUBSEP $2]+=$3 } END { for (key in total) { split(key, fields, SUBSEP); print fields[1] "\t" fields[2] "\t" total[key] } }' \
      "$metrics_tmp/gpu-users" > "$metrics_tmp/gpu-user-totals" 2>/dev/null || gpu_query_status=partial
    while IFS="$shell_tab" read gpu_uuid user_id user_mib; do
      [ -n "$gpu_uuid" ] || continue
      printf 'GPU_USER=%s\t%s\t%s\t%s\n' "$gpu_uuid" "$user_id" "$(user_name "$user_id")" "$user_mib"
    done < "$metrics_tmp/gpu-user-totals"
    awk '{ count[$0]++ } END { for (uuid in count) print uuid "\t" count[uuid] }' "$metrics_tmp/gpu-unmapped" 2>/dev/null | \
      while IFS="$shell_tab" read gpu_uuid count; do
        [ -n "$gpu_uuid" ] && printf 'GPU_UNMAPPED=%s\t%s\n' "$gpu_uuid" "$count"
      done
  fi
fi
echo "GPU_USER_STATUS=$gpu_query_status"
'@

$corePath = Join-Path $PSScriptRoot 'ServerPulse.Core.ps1'
$sshModulePath = Join-Path $PSScriptRoot 'ServerPulse.Ssh.ps1'
$servers = if ($null -ne $runtime) { @($runtime.Servers) } else {
    @($config.Servers | ForEach-Object {
        [PSCustomObject]@{Id=[string]$_.id;Label=[string]$_.label;Source='seed';SshTarget=[string]$_.host;HostName=[string]$_.host;Port=22;User='';AuthMode='passwordless';Password=$null}
    })
}
$timeoutMs = if ($null -ne $runtime -and $runtime.SshTimeoutMs) { [int]$runtime.SshTimeoutMs } else { $config.SshTimeoutMs }
$askPassPath = if ($null -ne $runtime) { [string]$runtime.AskPassPath } else { '' }
$jobs = foreach ($server in $servers) {
    $serverJson = $server | ConvertTo-Json -Compress
    $job=Start-Job -ScriptBlock {
        param($ServerJson, $Script, $TimeoutMs, $CorePath, $SshModulePath, $AskPassPath)
        $ErrorActionPreference = 'Stop'
        . $CorePath
        . $SshModulePath
        $server = $ServerJson | ConvertFrom-Json
        $started = [Diagnostics.Stopwatch]::StartNew()
        try {
            $authMode = if ([string]$server.AuthMode -in @('auto','passwordless','password')) { [string]$server.AuthMode } else { 'auto' }
            $connection = Invoke-ServerPulseServerConnection -Server $server -Script $Script -AuthMode $authMode -Password ([string]$server.Password) -TimeoutMs $TimeoutMs -AskPassPath $AskPassPath
            $server.Password = $null
            if ($connection.Status -ne 'online') {
                return [PSCustomObject]@{
                    Id=[string]$server.Id;Label=[string]$server.Label;Host=[string]$server.SshTarget;Status=[string]$connection.Status
                    AuthMode=[string]$connection.AuthMode;CheckedAt=[DateTime]::UtcNow.ToString('o');LatencyMs=$null;Metrics=$null;Error=[string]$connection.Error
                }
            }
            [PSCustomObject]@{
                Id        = [string]$server.Id
                Label     = [string]$server.Label
                Host      = [string]$server.SshTarget
                Status    = 'online'
                AuthMode  = [string]$connection.AuthMode
                CheckedAt = [DateTime]::UtcNow.ToString('o')
                LatencyMs = [int]$started.ElapsedMilliseconds
                Metrics   = ConvertFrom-ServerMetricsOutput -Output $connection.Output
                Error     = $null
            }
        } catch {
            [PSCustomObject]@{
                Id        = [string]$server.Id
                Label     = [string]$server.Label
                Host      = [string]$server.SshTarget
                Status    = 'offline'
                AuthMode  = [string]$server.AuthMode
                CheckedAt = [DateTime]::UtcNow.ToString('o')
                LatencyMs = $null
                Metrics   = $null
                Error     = $_.Exception.Message
            }
        }
    } -ArgumentList $serverJson, $remoteScript, $timeoutMs, $corePath, $sshModulePath, $askPassPath
    $server.Password=$null;$serverJson=$null
    $job
}

$results = foreach ($job in $jobs) {
    Receive-Job -Job $job -Wait -AutoRemoveJob
}

[PSCustomObject]@{
    GeneratedAt = [DateTime]::UtcNow.ToString('o')
    Servers     = @($results)
} | ConvertTo-Json -Depth 12 -Compress
