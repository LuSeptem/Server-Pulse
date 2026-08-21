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
      if (fstype ~ /^(nfs|nfs4|cifs|smbfs|smb2|ncpfs|9p|autofs|tmpfs|devtmpfs|overlay|squashfs|proc|sysfs|devpts|mqueue|hugetlbfs|securityfs|debugfs|tracefs|configfs|fusectl|fuse|efivarfs|bpf|nsfs|ramfs|cgroup)/) next
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
    printf "{\"kind\":\"diskAttribution\",\"serverId\":\"%s\",\"scannedAt\":\"%s\",\"mount\":\"%s\",\"device\":\"%s\",\"fsType\":\"%s\",\"totalMib\":%.0f,\"usedMib\":%.0f,\"percent\":%.2f,\"status\":\"%s\",\"durationSeconds\":%d,\"skippedEntries\":%d,\"users\":[", jstr(serverid), finished, jstr(mnt), jstr(dev), jstr(fstype), total / 1024, used / 1024, pct, status, dur + 0, skipped + 0
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
