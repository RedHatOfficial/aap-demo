#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export XDG_CONFIG_HOME="$TEST_DIR/config"
SCRIPT_DIR="$REPO_ROOT"
source "$REPO_ROOT/includes/state-service.sh"

aap_demo_dashboard_autostart_install
entry="$XDG_CONFIG_HOME/autostart/aap-demo-dashboard.desktop"
grep -Fx "Exec=bash \"$REPO_ROOT/scripts/aap-demo-dashboard-login.sh\"" "$entry"
if command -v desktop-file-validate >/dev/null; then
  desktop-file-validate "$entry"
fi
aap_demo_dashboard_autostart_install
test "$(find "$XDG_CONFIG_HOME/autostart" -type f | wc -l)" -eq 1
aap_demo_dashboard_autostart_remove
test ! -e "$entry"
echo "PASS: desktop entry installs idempotently and is removed on disable"

# Run the actual launcher against an isolated checkout with fake service state.
mkdir -p "$TEST_DIR/repo/scripts" "$TEST_DIR/repo/includes"
cp "$REPO_ROOT/scripts/aap-demo-dashboard-login.sh" "$TEST_DIR/repo/scripts/"
cat >"$TEST_DIR/repo/includes/state-service.sh" <<'EOF'
aap_demo_service_managed() { test "$ENABLED" = yes; }
EOF
cat >"$TEST_DIR/repo/aap-demo.sh" <<'EOF'
printf '%s\n' "$*" >>"$LOG"
EOF
export LOG="$TEST_DIR/launch.log"
ENABLED=no bash "$TEST_DIR/repo/scripts/aap-demo-dashboard-login.sh"
test ! -e "$LOG"
ENABLED=yes bash "$TEST_DIR/repo/scripts/aap-demo-dashboard-login.sh"
test "$(cat "$LOG")" = dashboard
echo "PASS: graphical login opens the dashboard only when recovery is enabled"
