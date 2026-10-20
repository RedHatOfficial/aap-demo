#!/usr/bin/env bash
# Fast CLI contract test: a live-run invocation must never provision a target
# when the selected Kubernetes context does not match the active context.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT

fake_bin="$temp_dir/bin"
mkdir -p "$fake_bin"
command_log="$temp_dir/commands.log"

cat >"$fake_bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl %s\n' "$*" >> "$AO_ACCEPTANCE_COMMAND_LOG"
if [[ "$*" == "config current-context" ]]; then
  printf '%s\n' "actual-context"
fi
EOF
chmod +x "$fake_bin/kubectl"

cat >"$fake_bin/aap-demo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'aap-demo %s\n' "$*" >> "$AO_ACCEPTANCE_COMMAND_LOG"
exit 99
EOF
chmod +x "$fake_bin/aap-demo"

run_cli() {
  PATH="$fake_bin:$PATH" AO_ACCEPTANCE_COMMAND_LOG="$command_log" \
    "$repo_root/test/ao-acceptance/run.sh" --artifact-dir "$temp_dir/artifacts" "$@"
}

assert_contains() {
  local text=$1 expected=$2
  if [[ "$text" != *"$expected"* ]]; then
    printf 'expected output to contain: %s\nactual output: %s\n' "$expected" "$text" >&2
    exit 1
  fi
}

assert_no_provisioning() {
  if [[ -f "$command_log" ]] && grep -Eq '^aap-demo (deploy|enable )' "$command_log"; then
    printf 'validate safeguard invoked provisioning:\n' >&2
    cat "$command_log" >&2
    exit 1
  fi
}

help_output=$(run_cli --help)
assert_contains "$help_output" "Run AO live acceptance checks"

if invalid_output=$(run_cli --mode destroy 2>&1); then
  printf 'invalid mode unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$invalid_output" "invalid choice"

if validate_output=$(run_cli --mode validate --context deliberately-missing 2>&1); then
  printf 'validate with a mismatched context unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$validate_output" "selected context does not match"
assert_no_provisioning

if alias_output=$(run_cli --skip-provision --context deliberately-missing 2>&1); then
  printf 'skip-provision with a mismatched context unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$alias_output" "selected context does not match"
assert_no_provisioning

printf 'AO acceptance CLI safeguards passed\n'
