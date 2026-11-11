#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export HOME="$TEST_DIR/home %space's"
export AAP_DEMO_DIR="$HOME/.aap-demo"
export AAP_DEMO_VAULT_FILE="$HOME/.ansible/conf/env.yml"
export AAP_DEMO_VAULT_PASSWORD_FILE="$HOME/.ansible/conf/.vaultpass.txt"
mkdir -p "$TEST_DIR/bin"

cat >"$TEST_DIR/bin/uname" <<'EOF'
#!/usr/bin/env bash
echo Linux
EOF
cat >"$TEST_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_CURL_ARGS"
token=$(cat)
if [ "${TEST_SSO_UNREACHABLE:-false}" = true ]; then exit 7; fi
case "$token" in
  customer-portal-fixture | automation-hub-fixture | rotated-hub-fixture)
    printf '{"access_token":"discarded"}\n200' ;;
  *) printf '{"error":"invalid_grant"}\n400' ;;
esac
EOF
cat >"$TEST_DIR/bin/crontab" <<'EOF'
#!/usr/bin/env bash
if [ "${TEST_CRONTAB_FAILURE:-false}" = true ]; then
  echo 'crontab: permission denied' >&2
  exit 1
fi
if [ "$1" = -l ]; then
  if [ ! -f "$TEST_CRONTAB" ]; then
    echo 'no crontab for fixture-user' >&2
    exit 1
  fi
  cat "$TEST_CRONTAB"
else
  cp "$1" "$TEST_CRONTAB"
fi
EOF
cat >"$TEST_DIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_SYSTEMCTL_LOG"
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$TEST_DIR/bin/xdg-open"
chmod +x "$TEST_DIR/bin/xdg-open"
chmod +x "$TEST_DIR/bin/uname" "$TEST_DIR/bin/curl" "$TEST_DIR/bin/systemctl" "$TEST_DIR/bin/crontab"
export PATH="$TEST_DIR/bin:$PATH"
export TEST_SYSTEMCTL_LOG="$TEST_DIR/systemctl.log"
export TEST_CRONTAB="$TEST_DIR/crontab"
export TEST_CURL_ARGS="$TEST_DIR/curl-args"

_err() { printf 'ERROR: %s\n' "$*" >&2; }
# shellcheck source=../includes/credential-vault.sh
source "$REPO_ROOT/includes/credential-vault.sh"
aap_demo_vault_set aap_demo.redhat.offline_token customer-portal-fixture
aap_demo_vault_set aap_demo.galaxy.offline_token automation-hub-fixture

output=$(bash "$REPO_ROOT/scripts/aap-demo-token-keepalive.sh" run)
grep -q 'Customer Portal offline token is live' <<<"$output"
grep -q 'Automation Hub offline token is live' <<<"$output"
if grep -q 'fixture\|discarded' <<<"$output"; then
  echo "FAIL: keepalive output exposed token material" >&2
  exit 1
fi

bash "$REPO_ROOT/scripts/aap-demo-token-keepalive.sh" enable >/dev/null
timer="$HOME/.config/systemd/user/aap-demo-token-keepalive.timer"
service="$HOME/.config/systemd/user/aap-demo-token-keepalive.service"
test -f "$timer"
test -f "$service"
grep -q '^Persistent=true$' "$timer"
grep -q 'enable --now aap-demo-token-keepalive.timer' "$TEST_SYSTEMCTL_LOG"

"$REPO_ROOT/aap-demo.sh" credentials keepalive status >/dev/null
"$REPO_ROOT/aap-demo.sh" credentials keepalive disable >/dev/null
test ! -e "$timer"
test ! -e "$service"

# Setup installs exactly one marked cron entry and preserves unrelated jobs.
printf '15 3 * * * echo unrelated-job\n' >"$TEST_CRONTAB"
"$REPO_ROOT/aap-demo.sh" credentials keepalive setup >"$TEST_DIR/setup-output"
cp "$TEST_CRONTAB" "$TEST_DIR/first-crontab"
"$REPO_ROOT/aap-demo.sh" credentials keepalive setup >>"$TEST_DIR/setup-output"
cmp "$TEST_CRONTAB" "$TEST_DIR/first-crontab"
test "$(grep -c '^0 0 \*/4 \* \* ' "$TEST_CRONTAB")" -eq 1
grep -q '^15 3 \* \* \* echo unrelated-job$' "$TEST_CRONTAB"
if grep -q 'fixture\|discarded' "$TEST_CRONTAB" "$TEST_CURL_ARGS" "$TEST_DIR/setup-output"; then
  echo "FAIL: cron, curl arguments or setup output exposed token material" >&2
  exit 1
fi
"$AAP_DEMO_VAULT_PYTHON" - "$HOME/.ansible/conf" "$AAP_DEMO_VAULT_FILE" "$AAP_DEMO_VAULT_PASSWORD_FILE" <<'PY'
import os
import stat
import sys

for path, mode in zip(sys.argv[1:], (0o700, 0o600, 0o600)):
    assert stat.S_IMODE(os.stat(path).st_mode) == mode
PY
head -n 1 "$AAP_DEMO_VAULT_FILE" | grep -q '^\$ANSIBLE_VAULT;'

# Replay the scheduled command with an empty environment, after rotating the token.
# This proves the job looks up the Vault dynamically rather than embedding a token.
aap_demo_vault_set ah_offline_token rotated-hub-fixture
cron_line=$(grep '# aap-demo-hub-token-keepalive$' "$TEST_CRONTAB")
cron_command="${cron_line#0 0 \*/4 \* \* }"
cron_command="${cron_command//\\%/%}"
env -i TEST_CRONTAB="$TEST_CRONTAB" TEST_CURL_ARGS="$TEST_CURL_ARGS" \
  bash -c "$cron_command" >"$TEST_DIR/cron-output"
grep -q 'Automation Hub offline token is live' "$TEST_DIR/cron-output"
if grep -q 'fixture\|discarded' "$TEST_DIR/cron-output"; then
  echo "FAIL: cron output exposed token material" >&2
  exit 1
fi

export TEST_SSO_UNREACHABLE=true
rc=0
bash "$REPO_ROOT/scripts/aap-demo-token-keepalive.sh" run-hub >/dev/null || rc=$?
test "$rc" -eq 2
unset TEST_SSO_UNREACHABLE
test "$(aap_demo_vault_get ah_offline_token)" = rotated-hub-fixture

export TEST_CRONTAB_FAILURE=true
rc=0
bash "$REPO_ROOT/scripts/aap-demo-token-keepalive.sh" setup >/dev/null 2>&1 || rc=$?
test "$rc" -ne 0
cmp "$TEST_CRONTAB" "$TEST_DIR/first-crontab"
unset TEST_CRONTAB_FAILURE

"$REPO_ROOT/aap-demo.sh" credentials keepalive status | grep -q '0 0 \*/4'
"$REPO_ROOT/aap-demo.sh" credentials keepalive disable >/dev/null
test "$(cat "$TEST_CRONTAB")" = '15 3 * * * echo unrelated-job'

# No existing crontab is a valid first-time setup, not a read error.
rm -f "$TEST_CRONTAB"
bash "$REPO_ROOT/scripts/aap-demo-token-keepalive.sh" setup >/dev/null
test "$(grep -c '# aap-demo-hub-token-keepalive$' "$TEST_CRONTAB")" -eq 1

# A fresh setup creates an encrypted Vault only after validating hidden input.
printf 'automation-hub-fixture\n' >"$TEST_DIR/input"
AAP_DEMO_VAULT_FILE="$TEST_DIR/new conf/env.yml" \
  AAP_DEMO_VAULT_PASSWORD_FILE="$TEST_DIR/new conf/.vaultpass.txt" \
  AAP_DEMO_SECRET_PROMPT_DEVICE="$TEST_DIR/input" \
  AAP_DEMO_SECRET_PROMPT_OUTPUT="$TEST_DIR/prompt" \
  bash "$REPO_ROOT/scripts/aap-demo-token-keepalive.sh" setup >"$TEST_DIR/fresh-output"
"$AAP_DEMO_ANSIBLE_VAULT" view --vault-password-file "$TEST_DIR/new conf/.vaultpass.txt" \
  "$TEST_DIR/new conf/env.yml" |
  "$AAP_DEMO_VAULT_PYTHON" -c '
import sys
import yaml

assert yaml.safe_load(sys.stdin)["ah_offline_token"] == "automation-hub-fixture"
'
if grep -q 'fixture\|discarded' "$TEST_CRONTAB" "$TEST_DIR/fresh-output" "$TEST_DIR/prompt"; then
  echo "FAIL: fresh setup exposed token material" >&2
  exit 1
fi

echo "PASS: keepalive scheduling is idempotent, Vault-backed, dynamic, and secret-free"
