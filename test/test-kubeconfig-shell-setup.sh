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
grep -Fq './test/test-kubeconfig-shell-setup.sh' "${repo_root}/.github/workflows/test.yaml"

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
  local tty_command='source "$TEST_PATHS_FILE"; aap_demo_offer_kubeconfig_shell_setup "$TEST_QUIET" "$TEST_INHERITED" < /dev/tty'
  local quoted_tty_command

  printf -v quoted_tty_command '%q' "$tty_command"

  export TEST_INHERITED="$inherited"
  export TEST_QUIET="$quiet"
  set +o pipefail
  # shellcheck disable=SC2016
  {
    sleep 0.2
    printf '%s\n' "$answer"
    sleep 0.2
  } \
    | if script -q -c true /dev/null </dev/null >/dev/null 2>&1; then
      script -q -c "bash -c $quoted_tty_command" /dev/null
    else
      script -q /dev/null bash -c "$tty_command"
    fi 2>&1
  local status=${PIPESTATUS[1]}
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
printf -v escaped_path '%q' "$AAP_DEMO_KUBECONFIG"
expected_export="export KUBECONFIG=$escaped_path"
grep -Fqx "$expected_export" "$profile"
actual_kubeconfig="$(bash -c 'unset KUBECONFIG; source "$1"; printf "%s" "$KUBECONFIG"' _ "$profile")"
[ "$actual_kubeconfig" = "$AAP_DEMO_KUBECONFIG" ]

prepare_case shell-metacharacters
export SHELL=/bin/bash
export AAP_DEMO_KUBECONFIG="$test_home/kube\$config-\$(touch pwned)"
mkdir -p "$(dirname "$AAP_DEMO_KUBECONFIG")"
printf 'apiVersion: v1\n' >"$AAP_DEMO_KUBECONFIG"
run_interactive y >/dev/null
profile="$HOME/.bashrc"
actual_kubeconfig="$(cd "$test_home" && bash -c 'unset KUBECONFIG; source "$1"; printf "%s" "$KUBECONFIG"' _ "$profile")"
[ "$actual_kubeconfig" = "$AAP_DEMO_KUBECONFIG" ]
[ ! -e "$test_home/pwned" ]

prepare_case preconfigured
export SHELL=/bin/bash
printf 'export KUBECONFIG="%s"\n' "$AAP_DEMO_KUBECONFIG" >"$HOME/.bashrc"
preconfigured_output="$(run_interactive n)"
[[ "$preconfigured_output" != *"Add KUBECONFIG to"* ]]
[ -e "$AAP_DEMO_DIR/.kubeconfig-shell-setup" ]

prepare_case zsh
export SHELL=/bin/zsh
export ZDOTDIR="$test_home/zsh"
run_interactive y >/dev/null
printf -v escaped_path '%q' "$AAP_DEMO_KUBECONFIG"
grep -Fqx "export KUBECONFIG=$escaped_path" "$ZDOTDIR/.zshrc"
zsh_kubeconfig="$(zsh -f -c 'unset KUBECONFIG; source "$1"; print -r -- "$KUBECONFIG"' _ "$ZDOTDIR/.zshrc")"
[ "$zsh_kubeconfig" = "$AAP_DEMO_KUBECONFIG" ]

prepare_case fish
export SHELL=/usr/bin/fish
export XDG_CONFIG_HOME="$test_home/fish-config"
export AAP_DEMO_KUBECONFIG="$test_home/fish/kube'\\config"
mkdir -p "$(dirname "$AAP_DEMO_KUBECONFIG")"
printf 'apiVersion: v1\n' >"$AAP_DEMO_KUBECONFIG"
run_interactive y >/dev/null
fish_path="${AAP_DEMO_KUBECONFIG//\\/\\\\}"
fish_path="${fish_path//\'/\\\'}"
grep -Fqx "set -gx KUBECONFIG '$fish_path'" \
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

rm -f "$AAP_DEMO_DIR/.kubeconfig-shell-setup"
run_interactive y >/dev/null
[ "$(grep -Fc '# aap-demo kubeconfig' "$PROFILE")" -eq 1 ]

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
