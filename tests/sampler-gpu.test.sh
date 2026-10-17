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
      [ "$scenario" = healthy ]
      ;;
    *) return 1 ;;
  esac
}

for scenario in failed_bulk partial_output unavailable healthy; do
  metrics_tmp="$test_tmp/$scenario"
  mkdir "$metrics_tmp"
  shell_tab=$(printf '\t')
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
  echo "PASS $scenario ($count GPU cards, $status)"
done
