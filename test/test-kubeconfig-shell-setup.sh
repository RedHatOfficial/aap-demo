#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
paths_file="${repo_root}/includes/aap-demo-paths.sh"
cli="${repo_root}/aap-demo.sh"

grep -Fq 'aap_demo_offer_kubeconfig_shell_setup' "$paths_file" "$cli"
grep -Fq 'KUBECONFIG_FROM_ENV' "$cli"
grep -Fq 'quiet' "$paths_file"
grep -Fq 'zsh' "$paths_file"
grep -Fq 'fish' "$paths_file"
grep -Fq 'powershell' "$paths_file"

test_home="$(mktemp -d)"
trap 'rm -rf "$test_home"' EXIT
mkdir -p "$test_home/.aap-demo"
printf 'apiVersion: v1\n' >"$test_home/.aap-demo/kubeconfig.microshift"

HOME="$test_home" AAP_DEMO_DIR="$test_home/.aap-demo" \
  AAP_DEMO_KUBECONFIG="$test_home/.aap-demo/kubeconfig.microshift" \
  bash -c 'source "$1"; aap_demo_offer_kubeconfig_shell_setup false ""' _ "$paths_file" </dev/null

[ ! -e "$test_home/.aap-demo/.kubeconfig-shell-setup" ]

run_interactive() {
  local answer=$1
  local inherited=${2:-}
  local quiet=${3:-false}

  export TEST_INHERITED="$inherited"
  export TEST_QUIET="$quiet"
  set +o pipefail
  # shellcheck disable=SC2016
  printf '%s\n' "$answer" | {
    sleep 0.1
    cat
  } \
    | script -q /dev/null bash -c \
      'source "$TEST_PATHS_FILE"; aap_demo_offer_kubeconfig_shell_setup "$TEST_QUIET" "$TEST_INHERITED" < /dev/tty' 2>&1
  local status=${PIPESTATUS[2]}
  set -o pipefail
  return "$status"
}

export TEST_PATHS_FILE="$paths_file"

prepare_case() {
  local name=$1

  export HOME="$test_home/home-$name"
  export AAP_DEMO_DIR="$test_home/state-$name"
  export AAP_DEMO_KUBECONFIG="$test_home/kubeconfig-$name"
  unset PROFILE ZDOTDIR XDG_CONFIG_HOME
  mkdir -p "$HOME" "$AAP_DEMO_DIR"
  printf 'apiVersion: v1\n' >"$AAP_DEMO_KUBECONFIG"
}

prepare_case bash-quote
export SHELL=/bin/bash
export AAP_DEMO_KUBECONFIG="$test_home/kube'config/kubeconfig"
mkdir -p "$(dirname "$AAP_DEMO_KUBECONFIG")"
printf 'apiVersion: v1\n' >"$AAP_DEMO_KUBECONFIG"

run_interactive y >/dev/null
profile="$HOME/.bashrc"
expected_export="export KUBECONFIG=\"$AAP_DEMO_KUBECONFIG\""
grep -Fqx "$expected_export" "$profile"
actual_kubeconfig="$(bash -c 'unset KUBECONFIG; source "$1"; printf "%s" "$KUBECONFIG"' _ "$profile")"
[ "$actual_kubeconfig" = "$AAP_DEMO_KUBECONFIG" ]

prepare_case zsh
export SHELL=/bin/zsh
export ZDOTDIR="$test_home/zsh"
run_interactive y >/dev/null
grep -Fqx "export KUBECONFIG=\"$AAP_DEMO_KUBECONFIG\"" "$ZDOTDIR/.zshrc"

prepare_case fish
export SHELL=/usr/bin/fish
export XDG_CONFIG_HOME="$test_home/fish-config"
run_interactive y >/dev/null
grep -Fqx "set -gx KUBECONFIG \"$AAP_DEMO_KUBECONFIG\"" \
  "$XDG_CONFIG_HOME/fish/config.fish"

prepare_case powershell
export SHELL=/usr/bin/pwsh
export AAP_DEMO_KUBECONFIG="$test_home/powershell/kube'config"
export PROFILE="$test_home/powershell/profile.ps1"
mkdir -p "$(dirname "$AAP_DEMO_KUBECONFIG")"
printf 'apiVersion: v1\n' >"$AAP_DEMO_KUBECONFIG"
run_interactive y >/dev/null
powershell_path="${AAP_DEMO_KUBECONFIG//\'/\'\'}"
grep -Fqx "\$env:KUBECONFIG = '$powershell_path'" "$PROFILE"

prepare_case declined
export SHELL=/bin/bash
run_interactive n >/dev/null
[ -e "$AAP_DEMO_DIR/.kubeconfig-shell-setup" ]
[ ! -e "$HOME/.bashrc" ]

prepare_case inherited
export SHELL=/bin/bash
run_interactive y inherited-kubeconfig
[ ! -e "$AAP_DEMO_DIR/.kubeconfig-shell-setup" ]
[ ! -e "$HOME/.bashrc" ]

prepare_case quiet
export SHELL=/bin/bash
run_interactive y "" true
[ ! -e "$AAP_DEMO_DIR/.kubeconfig-shell-setup" ]
[ ! -e "$HOME/.bashrc" ]

prepare_case idempotent
export SHELL=/bin/bash
run_interactive y >/dev/null
second_output="$(run_interactive n)"
[ -z "$second_output" ]

echo "PASS: kubeconfig shell setup honors non-interactive mode and shell detection"
