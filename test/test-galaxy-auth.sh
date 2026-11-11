#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export HOME="$TEST_DIR/home"
export AAP_DEMO_DIR="$HOME/.aap-demo"
export AAP_DEMO_VAULT_FILE="$HOME/.ansible/conf/env.yml"
export AAP_DEMO_VAULT_PASSWORD_FILE="$HOME/.ansible/conf/.vaultpass.txt"
mkdir -p "$TEST_DIR/bin"

cat >"$TEST_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
token=$(cat)
if [ "${TEST_SSO_UNREACHABLE:-false}" = true ]; then
  exit 7
fi
case "$token" in
  compatible-token) printf '{"access_token":"discarded"}\n200' ;;
  no-access-token) printf '{}\n200' ;;
  malformed-response) printf 'not-json\n200' ;;
  server-error) printf '{"error":"temporarily_unavailable"}\n503' ;;
  *) printf '{"error":"invalid_grant"}\n400' ;;
esac
EOF
chmod +x "$TEST_DIR/bin/curl"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TEST_DIR/bin/xdg-open"
chmod +x "$TEST_DIR/bin/xdg-open"
export PATH="$TEST_DIR/bin:$PATH"

_err() { printf 'ERROR: %s\n' "$*" >&2; }
# shellcheck source=../includes/galaxy-auth.sh
source "$REPO_ROOT/includes/galaxy-auth.sh"

aap_demo_vault_set aap_demo.redhat.offline_token compatible-token
set +e
prepare_galaxy_credentials >/dev/null
rc=$?
set -e
[ "$rc" -eq 1 ]
if aap_demo_vault_get aap_demo.galaxy.offline_token >/dev/null 2>&1; then
  echo "FAIL: Customer Portal token was copied into Automation Hub credentials" >&2
  exit 1
fi

aap_demo_vault_set aap_demo.galaxy.offline_token compatible-token
GALAXY_TOKEN=""
prepare_galaxy_credentials >/dev/null
[ "$GALAXY_TOKEN" = compatible-token ]
[ "$(aap_demo_vault_get ah_offline_token)" = compatible-token ]

for invalid_response in no-access-token malformed-response server-error; do
  rc=0
  galaxy_offline_token_status "$invalid_response" || rc=$?
  [ "$rc" -eq 2 ]
done

aap_demo_vault_set aap_demo.galaxy.offline_token rejected-token
aap_demo_vault_set aap_demo.redhat.offline_token rejected-token
AAP_DEMO_ANSIBLE_VAULT=""
AAP_DEMO_VAULT_PYTHON=""
GALAXY_TOKEN=""
set +e
prepare_galaxy_credentials >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL: rejected Automation Hub token was accepted" >&2
  exit 1
fi
set +e
aap_demo_vault_get aap_demo.galaxy.offline_token >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL: rejected Automation Hub token remained in the Vault" >&2
  exit 1
fi

export TEST_SSO_UNREACHABLE=true
aap_demo_vault_set aap_demo.galaxy.offline_token compatible-token
GALAXY_TOKEN=""
set +e
prepare_galaxy_credentials >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ]
unset TEST_SSO_UNREACHABLE

# Wrong passwords must stop before prompting or replacing the original ciphertext.
cp "$AAP_DEMO_VAULT_PASSWORD_FILE" "$TEST_DIR/correct-password"
printf 'incorrect-password\n' >"$AAP_DEMO_VAULT_PASSWORD_FILE"
cp "$AAP_DEMO_VAULT_FILE" "$TEST_DIR/original-vault"
export AAP_DEMO_SECRET_PROMPT_DEVICE="$TEST_DIR/must-not-read"
export AAP_DEMO_SECRET_PROMPT_OUTPUT="$TEST_DIR/prompt"
rc=0
ensure_galaxy_credentials >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ]
cmp "$AAP_DEMO_VAULT_FILE" "$TEST_DIR/original-vault"
test ! -e "$TEST_DIR/prompt"
mv "$TEST_DIR/correct-password" "$AAP_DEMO_VAULT_PASSWORD_FILE"

# Invalid/empty new tokens are retried; only the final validated value is stored.
aap_demo_vault_delete ah_offline_token
printf '\nrejected-token\ncompatible-token\n' >"$TEST_DIR/input"
export AAP_DEMO_SECRET_PROMPT_DEVICE="$TEST_DIR/input"
ensure_galaxy_credentials >"$TEST_DIR/output" 2>&1
[ "$(aap_demo_vault_get ah_offline_token)" = compatible-token ]
grep -q 'expired or revoked' "$TEST_DIR/output"
test "$(grep -o 'Automation Hub offline token (hidden)' "$TEST_DIR/prompt" | wc -l)" -eq 3
if grep -q 'compatible-token\|rejected-token\|discarded' "$TEST_DIR/output" "$TEST_DIR/prompt"; then
  echo "FAIL: prompt or validation exposed token material" >&2
  exit 1
fi

# A valid stored value never opens the prompt or rewrites the Vault.
rm -f "$TEST_DIR/prompt"
cp "$AAP_DEMO_VAULT_FILE" "$TEST_DIR/original-vault"
ensure_galaxy_credentials >/dev/null
test ! -e "$TEST_DIR/prompt"
cmp "$AAP_DEMO_VAULT_FILE" "$TEST_DIR/original-vault"
[ "$(aap_demo_vault_get aap_demo.redhat.offline_token)" = rejected-token ]

# A transient failure preserves a stored token and never prompts.
export TEST_SSO_UNREACHABLE=true
rc=0
ensure_galaxy_credentials >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ]
test ! -e "$TEST_DIR/prompt"
cmp "$AAP_DEMO_VAULT_FILE" "$TEST_DIR/original-vault"
unset TEST_SSO_UNREACHABLE

# A missing password is an error, never a reason to generate a replacement.
mv "$AAP_DEMO_VAULT_PASSWORD_FILE" "$TEST_DIR/correct-password"
rc=0
ensure_galaxy_credentials >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ]
test ! -e "$AAP_DEMO_VAULT_PASSWORD_FILE"
cmp "$AAP_DEMO_VAULT_FILE" "$TEST_DIR/original-vault"
mv "$TEST_DIR/correct-password" "$AAP_DEMO_VAULT_PASSWORD_FILE"

# Rejected stored tokens prompt again and preserve unrelated secrets.
aap_demo_vault_set ah_offline_token rejected-token
printf 'compatible-token\n' >"$TEST_DIR/input"
ensure_galaxy_credentials >/dev/null 2>&1
[ "$(aap_demo_vault_get ah_offline_token)" = compatible-token ]
[ "$(aap_demo_vault_get aap_demo.redhat.offline_token)" = rejected-token ]

# Legacy plaintext imports are validated before saving, and retained on failure.
aap_demo_vault_delete ah_offline_token
mkdir -p "$(dirname "$GALAXY_TOKEN_FILE")"
printf 'rejected-token' >"$GALAXY_TOKEN_FILE"
rc=0
prepare_galaxy_credentials >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ]
test -f "$GALAXY_TOKEN_FILE"
if aap_demo_vault_get ah_offline_token >/dev/null; then
  echo "FAIL: invalid legacy import was saved" >&2
  exit 1
fi
printf 'compatible-token' >"$GALAXY_TOKEN_FILE"
prepare_galaxy_credentials >/dev/null
test ! -e "$GALAXY_TOKEN_FILE"
[ "$(aap_demo_vault_get ah_offline_token)" = compatible-token ]

# Actual older Vaults remain readable; updating their token adopts the new key.
printf 'existing_setting: keep-me\naap_demo:\n  galaxy:\n    offline_token: compatible-token\n' \
  >"$TEST_DIR/legacy.yml"
"$AAP_DEMO_ANSIBLE_VAULT" encrypt --vault-password-file "$AAP_DEMO_VAULT_PASSWORD_FILE" \
  --output "$AAP_DEMO_VAULT_FILE" "$TEST_DIR/legacy.yml" >/dev/null
[ "$(aap_demo_vault_get ah_offline_token)" = compatible-token ]
aap_demo_vault_set ah_offline_token compatible-token
[ "$(aap_demo_vault_get aap_demo.galaxy.offline_token)" = compatible-token ]
"$AAP_DEMO_ANSIBLE_VAULT" view --vault-password-file "$AAP_DEMO_VAULT_PASSWORD_FILE" \
  "$AAP_DEMO_VAULT_FILE" |
  "$AAP_DEMO_VAULT_PYTHON" -c '
import sys
import yaml

data = yaml.safe_load(sys.stdin)
assert data["existing_setting"] == "keep-me"
assert data["ah_offline_token"] == "compatible-token"
assert "offline_token" not in data["aap_demo"]["galaxy"]
'

echo "PASS: tokens are validated, retried securely, and preserved on Vault or SSO failures"
