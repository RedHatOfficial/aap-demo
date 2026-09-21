#!/usr/bin/env bash
# End-to-end test for temp swap on this host (Fedora/RHEL).
# Run in your terminal: ./scripts/test-temp-swap-flow.sh
set -euo pipefail

export PATH="${HOME}/.local/bin:${PATH}"
cd "$(dirname "$0")/.."

echo "========== Step 1: Remove temp swap =========="
./scripts/enable-temp-swap.sh disable || true

echo ""
echo "========== Step 2: Swap after disable =========="
./scripts/enable-temp-swap.sh status

echo ""
echo "========== Step 3: Test enable-temp-swap.sh (PR) =========="
AAP_SWAP_SIZE_GB=16 ./scripts/enable-temp-swap.sh enable

echo ""
echo "========== Step 4: Remove again before create test =========="
./scripts/enable-temp-swap.sh disable
./scripts/enable-temp-swap.sh status

echo ""
echo "========== Step 5: aap-demo create with AAP_ENABLE_TEMP_SWAP =========="
export QUIET=true
export AAP_ENABLE_TEMP_SWAP=true
export AAP_SWAP_SIZE_GB=16
export CRC_CPUS=8
export CRC_MEMORY=14336
export CRC_DISK=120
export CRC_PV_SIZE=70
aap-demo create

echo ""
echo "========== Step 6: Final swap status =========="
./scripts/enable-temp-swap.sh status
aap-demo status | head -15

echo ""
echo "========== TEST COMPLETE =========="
