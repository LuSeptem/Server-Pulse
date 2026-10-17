#!/bin/sh
# Exercise the canonical sampler's GPU section with deterministic driver failures.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_parent=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd)
test_tmp=$(mktemp -d "$test_parent/serverpulse-gpu-test.XXXXXX")
case "$test_tmp" in
  "$test_parent"/serverpulse-gpu-test.??????) ;;
  *) echo "Unexpected temporary directory"; exit 1 ;;
esac
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM
sed -n '/^echo "GPUS_BEGIN"$/,/^echo "GPU_USER_STATUS=/p' \
  "$repo_root/assets/serverpulse-sample.sh" > "$test_tmp/gpu-section.sh"

nvidia-smi() {
  case "$*" in
    --query-gpu=*)
      if [ "$scenario" = healthy ]; then
        printf '0, NVIDIA RTX 3090, GPU-test-0, 12, 1024, 24576, 30, 20, 350, 0\n'
        return 0
      fi
      # Some drivers emit valid rows before failing on another device.
      if [ "$scenario" = partial_output ]; then
        printf '0, NVIDIA RTX 3090, GPU-test-0, 12, 1024, 24576, 30, 20, 350, 0\n'
      fi
      printf 'Unable to determine the device handle: Unknown Error\n'
      return 1
      ;;
    -L)
      printf 'GPU 0: NVIDIA RTX 3090 (UUID: GPU-test-0)\n'
      printf 'GPU 2: NVIDIA RTX 3090 (UUID: GPU-test-2)\n'
      printf 'Unable to determine the device handle: Unknown Error\n'
      return 1
      ;;
    '-i 0 --query-gpu='*)
      [ "$scenario" != unavailable ] || return 1
      printf '0, NVIDIA RTX 3090, GPU-test-0, 12, 1024, 24576, 30, 20, 350, 0\n'
      ;;
    '-i 2 --query-gpu='*)
      [ "$scenario" != unavailable ] || return 1
      printf '2, NVIDIA RTX 3090, GPU-test-2, 34, 2048, 24576, 31, 21, 350, 0\n'
      ;;
    --query-compute-apps=*)
      if [ "$scenario" = healthy ] || [ "$scenario" = partial_output ]; then
        printf 'GPU-test-0, 420000001, 256\nGPU-test-0, 420000002, 512\n'
      fi
      [ "$scenario" = healthy ]
      ;;
    '-i 0 --query-compute-apps='*)
      printf 'GPU-test-0, 420000001, 256\nGPU-test-0, 420000002, 512\n'
      if [ "$scenario" = unmapped ]; then
        printf 'GPU-test-0, 420000099, 128\n'
      fi
      [ "$scenario" != partial_process_output ]
      ;;
    '-i 2 --query-compute-apps='*)
      [ "$scenario" != per_device_failure ]
      ;;
    *) return 1 ;;
  esac
}

for scenario in failed_bulk partial_output unavailable healthy per_device_failure unmapped partial_process_output; do
  metrics_tmp="$test_tmp/$scenario"
  mkdir "$metrics_tmp"
  shell_tab=$(printf '\t')
  printf '420000001 1 1000 0 1\n420000002 1 1000 0 1\n' > "$metrics_tmp/processes-2"
  user_name() { printf 'test-user'; }
  . "$test_tmp/gpu-section.sh" > "$metrics_tmp/output"
  count=$(awk -F, 'NF >= 10 && $1 ~ /^[0-9]+$/ {n++} END {print n+0}' "$metrics_tmp/output")
  case "$scenario" in
    healthy) expected=1; status=ok ;;
    unavailable) expected=0; status=unavailable ;;
    *) expected=2; status=partial ;;
  esac
  if [ "$count" -ne "$expected" ]; then
    echo "FAIL $scenario: expected $expected visible GPU cards, got $count"
    exit 1
  fi
  grep -q "^GPU_QUERY_STATUS=$status$" "$metrics_tmp/output" || {
    echo "FAIL $scenario: missing GPU query status $status"
    exit 1
  }
  if grep -q 'Unknown Error' "$metrics_tmp/output"; then
    echo "FAIL $scenario: driver diagnostics leaked into protocol"
    exit 1
  fi
  if [ "$scenario" != unavailable ]; then
    expected_user=$(printf 'GPU_USER=GPU-test-0\t1000\ttest-user\t768\t2')
    grep -qx "$expected_user" "$metrics_tmp/output" || {
      echo "FAIL $scenario: occupied GPU 0 has no correct per-user memory/process count"
      exit 1
    }
    case "$scenario" in
      partial_process_output) user_status=partial ;;
      *) user_status=ok ;;
    esac
    grep -qx "GPU_USER_STATUS_0=$user_status" "$metrics_tmp/output" || {
      echo "FAIL $scenario: wrong GPU 0 attribution status"
      exit 1
    }
    if [ "$scenario" != healthy ]; then
      if [ "$scenario" = per_device_failure ]; then empty_status=unavailable; else empty_status=ok; fi
      grep -qx "GPU_USER_STATUS_2=$empty_status" "$metrics_tmp/output" || {
        echo "FAIL $scenario: empty/failed GPU 2 attribution status is incorrect"
        exit 1
      }
    fi
    if [ "$scenario" = unmapped ]; then
      grep -qx "$(printf 'GPU_UNMAPPED=GPU-test-0\t1')" "$metrics_tmp/output"
    fi
  fi
  case "$scenario" in
    unavailable) overall=unavailable ;;
    per_device_failure|unmapped|partial_process_output) overall=partial ;;
    *) overall=ok ;;
  esac
  grep -qx "GPU_USER_STATUS=$overall" "$metrics_tmp/output"
  echo "PASS $scenario ($count GPU cards, $status)"
done

# Run the actual server-agent aggregator over a new frame and a legacy frame.
# Per-device status must not leak into the next sample or dilute user totals.
tr -d '\r' < "$repo_root/src-tauri/crates/serverpulse-core/src/agent.rs" |
  sed -n '/^pub const AWK_AGGREGATOR:/,/^}"#;/p' |
  sed '1s/^.*r#"//;$s/"#;$//' > "$test_tmp/agent.awk"
{
  printf '__SP_SAMPLE__\nHOSTNAME=test\nCPU_PERCENT=1\n'
  cat "$test_tmp/per_device_failure/output"
  printf '__SP_SAMPLE__\nHOSTNAME=test\nCPU_PERCENT=1\n'
  sed '/^GPU_USER_STATUS_[0-9]/d; /^GPU_USER=/d; s/^GPU_USER_STATUS=.*/GPU_USER_STATUS=unavailable/' \
    "$test_tmp/per_device_failure/output"
} | awk -v sp_minute='2026-10-17T10:00' -f "$test_tmp/agent.awk" > "$test_tmp/history.json"
node - "$test_tmp/history.json" <<'JS'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const record = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
const gpus = record.Record.Servers[0].Gpus
const good = gpus.find(gpu => gpu.Index === 0).UserMemory
assert.equal(good.Status, 'ok')
assert.equal(good.ValidSamples, 1)
assert.equal(good.Users[0].UsedMiB, 768)
assert.equal(good.Users[0].ProcessCount, 2)
assert.equal(gpus.find(gpu => gpu.Index === 2).UserMemory.Status, 'unavailable')
console.log('PASS agent history per-GPU attribution and legacy status reset')
JS
