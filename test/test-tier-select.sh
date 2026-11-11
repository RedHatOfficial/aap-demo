#!/usr/bin/env bash
# Regression test for scripts/aap-demo-tier-select.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TIER_SCRIPT="${REPO_ROOT}/scripts/aap-demo-tier-select.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_tier() {
  local env_vars=() args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      *=*) env_vars+=("$1"); shift ;;
      *) args+=("$1"); shift ;;
    esac
  done
  env NO_COLOR=1 AAP_DEMO_TIER_NO_EXEC=1 "${env_vars[@]}" bash "$TIER_SCRIPT" ${args[@]+"${args[@]}"}
}

# --- Both tiers supported: explicit menu choice honored ---------------------
out=$(run_tier TIER_VCPUS=16 TIER_RAM_GB=64 TIER_DISK_GB=500 AAP_DEMO_TIER_CHOICE=1)
echo "$out" | grep -q "SELECTED_PRESET=openshift" || fail "high-tier choice 1 should select openshift"
echo "$out" | grep -q "web console" || fail "menu should mention the web console"

out=$(run_tier TIER_VCPUS=16 TIER_RAM_GB=64 TIER_DISK_GB=500 AAP_DEMO_TIER_CHOICE=2)
echo "$out" | grep -q "SELECTED_PRESET=microshift" || fail "high-tier choice 2 should select microshift"

out=$(run_tier TIER_VCPUS=16 TIER_RAM_GB=64 TIER_DISK_GB=500 AAP_DEMO_TIER_CHOICE=sno)
echo "$out" | grep -q "SELECTED_PRESET=openshift" || fail "choice 'sno' should select openshift"

# --- Non-interactive default: SNO when supported ----------------------------
out=$(run_tier TIER_VCPUS=16 TIER_RAM_GB=64 TIER_DISK_GB=500 --yes)
echo "$out" | grep -q "SELECTED_PRESET=openshift" || fail "--yes should default to SNO"

# --- Interactive input validation: bad input then valid ----------------------
out=$(printf 'bogus\n1\n' | run_tier TIER_VCPUS=16 TIER_RAM_GB=64 TIER_DISK_GB=500 2>&1)
echo "$out" | grep -q "Invalid choice" || fail "invalid menu input should warn"
echo "$out" | grep -q "SELECTED_PRESET=openshift" || fail "valid retry should select openshift"

# --- Forced tier -------------------------------------------------------------
out=$(run_tier TIER_VCPUS=16 TIER_RAM_GB=64 TIER_DISK_GB=500 --tier microshift)
echo "$out" | grep -q "SELECTED_PRESET=microshift" || fail "--tier microshift should select microshift"

if run_tier TIER_VCPUS=4 TIER_RAM_GB=8 TIER_DISK_GB=50 --tier sno >/dev/null 2>&1; then
  fail "--tier sno below minimums must fail"
fi

if run_tier TIER_VCPUS=16 TIER_RAM_GB=64 TIER_DISK_GB=500 --tier banana >/dev/null 2>&1; then
  fail "--tier banana must fail validation"
fi

# --- Fallback: below SNO thresholds, above MicroShift minimums ---------------
out=$(run_tier TIER_VCPUS=4 TIER_RAM_GB=8 TIER_DISK_GB=50 2>&1)
echo "$out" | grep -q "SELECTED_PRESET=microshift" || fail "mid-tier host should fall back to microshift"
echo "$out" | grep -qi "Insufficient resources for Single Node OpenShift" || fail "fallback should warn about SNO"

# --- Boundary: exact SNO minimums are supported ------------------------------
out=$(run_tier TIER_VCPUS=8 TIER_RAM_GB=16 TIER_DISK_GB=100 AAP_DEMO_TIER_CHOICE=1)
echo "$out" | grep -q "SELECTED_PRESET=openshift" || fail "exact SNO minimums should be supported"

# --- Boundary: exact MicroShift minimums fall back ---------------------------
out=$(run_tier TIER_VCPUS=2 TIER_RAM_GB=2 TIER_DISK_GB=10 2>&1)
echo "$out" | grep -q "SELECTED_PRESET=microshift" || fail "exact MicroShift minimums should deploy microshift"

# --- Insufficient for everything ---------------------------------------------
if run_tier TIER_VCPUS=1 TIER_RAM_GB=1 TIER_DISK_GB=5 >/tmp/tier-low.out 2>&1; then
  fail "below MicroShift minimums must exit non-zero"
fi
grep -q "vCPUs: 1 detected, 2 required" /tmp/tier-low.out || fail "error should list missing vCPUs"
grep -q "RAM: 1GB detected, 2GB required" /tmp/tier-low.out || fail "error should list missing RAM"
grep -q "Disk: 5GB available, 10GB required" /tmp/tier-low.out || fail "error should list missing disk"

# --- Dry run never deploys ---------------------------------------------------
out=$(run_tier TIER_VCPUS=16 TIER_RAM_GB=64 TIER_DISK_GB=500 --tier sno --dry-run)
echo "$out" | grep -q "DRY-RUN: CRC_PRESET=openshift" || fail "dry-run should print the command"

echo "PASS: tier selection handles SNO, MicroShift fallback, and insufficient resources"
