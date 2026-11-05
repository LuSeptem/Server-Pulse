#!/bin/sh
# Exercise the actual workspace setup and GPU sampler when temporary storage fails.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_parent=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd)
test_tmp=$(mktemp -d "$test_parent/serverpulse-temp-test.XXXXXX")
case "$test_tmp" in
  "$test_parent"/serverpulse-temp-test.??????) ;;
  *) exit 1 ;;
esac
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM
awk '/^create_metrics_tmp\(\)|^metrics_tmp=\$\(mktemp / { active=1 }
     /^user_database=/ { active=0 }
     active { print }' "$repo_root/assets/serverpulse-sample.sh" > "$test_tmp/setup.sh"
sed -n '/^echo "GPUS_BEGIN"$/,/^echo "GPU_USER_STATUS=/p' \
  "$repo_root/assets/serverpulse-sample.sh" > "$test_tmp/gpu.sh"

for scenario in root_full preferred invalid_preferred unusable_directory all_failed all_failed_partial; do
  (
    fixture="$test_tmp/$scenario"
    mkdir -p "$fixture/preferred" "$fixture/disk" "$fixture/shm"
    TMPDIR="$fixture/preferred"
    export TMPDIR
    mktemp() {
      case "$scenario:$2" in
        "preferred:$TMPDIR/"*) command mktemp -d "$fixture/preferred/serverpulse.XXXXXX" ;;
        "unusable_directory:$TMPDIR/"*)
          : > "$fixture/not-a-directory"
          printf '%s\n' "$fixture/not-a-directory"
          ;;
        invalid_preferred:/tmp/*|unusable_directory:/tmp/*)
          command mktemp -d "$fixture/disk/serverpulse.XXXXXX"
          ;;
        root_full:/dev/shm/*) command mktemp -d "$fixture/shm/serverpulse.XXXXXX" ;;
        *) return 1 ;;
      esac
    }
    nvidia-smi() {
      case "$*" in
        --query-gpu=*)
          if [ "$scenario" = all_failed_partial ]; then
            printf 'Unable to determine the device handle: Unknown Error\n'
            return 1
          fi
          printf '0,NVIDIA RTX 3090,GPU-test-0,12,1024,24576,30,20,350,0\n'
          printf '2,NVIDIA RTX 3090,GPU-test-2,0,0,24576,31,20,350,0\n'
          ;;
        -L)
          printf 'GPU 0: NVIDIA RTX 3090 (UUID: GPU-test-0)\nGPU 2: NVIDIA RTX 3090 (UUID: GPU-test-2)\n'
          return 1
          ;;
        '-i 0 --query-gpu='*) printf '0,NVIDIA RTX 3090,GPU-test-0,12,1024,24576,30,20,350,0\n' ;;
        '-i 2 --query-gpu='*) printf '2,NVIDIA RTX 3090,GPU-test-2,0,0,24576,31,20,350,0\n' ;;
        --query-compute-apps=*) return 0 ;;
        *) return 1 ;;
      esac
    }
    shell_tab=$(printf '\t')
    . "$test_tmp/setup.sh"
    . "$test_tmp/gpu.sh" > "$fixture/output"
    count=$(awk -F, 'NF >= 10 && $1 ~ /^[0-9]+$/ { n++ } END { print n+0 }' "$fixture/output")
    if [ "$count" -ne 2 ]; then
      echo "FAIL $scenario: expected 2 GPU cards despite unavailable temp storage, got $count"
      exit 1
    fi
    case "$scenario:$metrics_tmp" in
      "root_full:$fixture/shm/"*|"preferred:$fixture/preferred/"*|\
      "invalid_preferred:$fixture/disk/"*|"unusable_directory:$fixture/disk/"*|all_failed:|all_failed_partial:) ;;
      *) echo "FAIL $scenario: wrong temporary workspace selection"; exit 1 ;;
    esac
    if [ "$scenario" = all_failed_partial ]; then gpu_status=partial; else gpu_status=ok; fi
    grep -qx "GPU_QUERY_STATUS=$gpu_status" "$fixture/output"
    if [ -z "$metrics_tmp" ]; then
      grep -qx 'GPU_USER_STATUS=unavailable' "$fixture/output"
    else
      grep -qx 'GPU_USER_STATUS=ok' "$fixture/output"
    fi
    echo "PASS $scenario: 2 visible GPUs and correct temporary workspace"
  )
done
