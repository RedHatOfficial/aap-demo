#!/usr/bin/env bash
# Multi-host aap-demo destroy/deploy/addon test orchestrator
#
# Usage:
#   ./scripts/multi-host-test.sh [options]
#
# Options:
#   --dry-run           Print planned actions without executing
#   --host NAME         Run only one host from config (mac, linux-vm, windows)
#   --skip-addons       Destroy + deploy + diagnose only
#   --only-addons       Skip destroy/deploy; enable addons on running cluster
#   --strict            Fail on missing prerequisites
#   --pr NUMBER         Checkout GitHub PR on each host before test (gh pr checkout, or git fetch)
#   --skip-local-cache  Skip save-before-destroy and load-on-deploy (local-cache addon)
#   --config PATH       Config file (default: ~/.aap-demo/test-hosts.yaml)
#
# Requires: yq (v4), ssh (for remote hosts)
# On macOS use Homebrew bash 5+ if /bin/bash is 3.2 (associative arrays).
#
# See: .cursor/skills/aap-demo-multi-host-test/SKILL.md

set -euo pipefail

CONFIG_FILE="${HOME}/.aap-demo/test-hosts.yaml"
REPORT_DIR="${HOME}/.aap-demo/test-reports"
RESULTS_FILE=""

DRY_RUN=false
HOST_FILTER=""
SKIP_ADDONS=false
ONLY_ADDONS=false
STRICT=false
PR_NUMBER=""
USE_LOCAL_CACHE=true

DEFAULT_ADDON_ORDER="setup-pah mcp-server portal ao apme-eap product-demos product-demo-satellite local-cache"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \?//'
  exit "${1:-0}"
}

log() { printf '[multi-host-test] %s\n' "$*"; }
warn() { printf '[multi-host-test] WARN: %s\n' "$*" >&2; }
die() {
  printf '[multi-host-test] ERROR: %s\n' "$*" >&2
  exit 1
}

result_set() {
  # result_set host.phase value
  echo "${1}=${2}" >>"$RESULTS_FILE"
}

result_get() {
  local key="$1" default="${2:-skipped}"
  local val
  val=$(grep -m1 "^${key}=" "$RESULTS_FILE" 2>/dev/null | cut -d= -f2- || true)
  echo "${val:-$default}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --host)
      shift
      HOST_FILTER="${1:-}"
      [ -n "$HOST_FILTER" ] || die "--host requires a name"
      ;;
    --skip-addons) SKIP_ADDONS=true ;;
    --only-addons) ONLY_ADDONS=true ;;
    --strict) STRICT=true ;;
    --pr)
      shift
      PR_NUMBER="${1:-}"
      [ -n "$PR_NUMBER" ] || die "--pr requires a pull request number"
      ;;
    --skip-local-cache) USE_LOCAL_CACHE=false ;;
    --config)
      shift
      CONFIG_FILE="${1:-}"
      [ -n "$CONFIG_FILE" ] || die "--config requires a path"
      ;;
    -h | --help) usage 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
  shift
done

if [ "$SKIP_ADDONS" = true ] && [ "$ONLY_ADDONS" = true ]; then
  die "Cannot use --skip-addons and --only-addons together"
fi

command -v yq >/dev/null 2>&1 || die "yq v4 required — install: brew install yq"

[ -f "$CONFIG_FILE" ] || die "Config not found: $CONFIG_FILE — copy machines.example.yaml to ~/.aap-demo/test-hosts.yaml"

_cfg() {
  yq eval "$1" "$CONFIG_FILE" 2>/dev/null
}

if [ "$STRICT" = false ]; then
  cfg_strict=$(_cfg '.defaults.strict // false')
  [ "$cfg_strict" = "true" ] && STRICT=true
fi

QUIET=$(_cfg '.defaults.quiet // true')
# Skip sudo/keychain ingress CA import during unattended matrix runs (CLI uses CURL_CA_BUNDLE).
TRUST_CA=$(_cfg '.defaults.trust_ca // false')
DESTROY_RESET=$(_cfg '.defaults.destroy_reset // false')
SYNC_REPO=$(_cfg '.defaults.sync_repo // false')
GIT_REMOTE=$(_cfg '.defaults.git_remote // "origin"')
DEFAULT_REPO=$(_cfg '.defaults.repo_path // "~/Documents/GitHub/aap-demo"')

if [ -z "$PR_NUMBER" ]; then
  PR_NUMBER=$(_cfg '.defaults.pr // ""')
  [ "$PR_NUMBER" = '""' ] && PR_NUMBER=""
fi

if [ -n "$PR_NUMBER" ] && ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  die "PR must be a number, got: $PR_NUMBER"
fi

[ "$GIT_REMOTE" = '""' ] && GIT_REMOTE="origin"

if [ "$USE_LOCAL_CACHE" = true ]; then
  cfg_lc=$(_cfg '.defaults.use_local_cache // true')
  [ "$cfg_lc" = "false" ] && USE_LOCAL_CACHE=false
fi

_host_field() {
  local host="$1" field="$2"
  _cfg ".hosts.${host}.${field} // \"\""
}

_host_repo() {
  local host="$1" repo
  repo=$(_host_field "$host" repo_path)
  if [ -z "$repo" ] || [ "$repo" = '""' ]; then
    repo="$DEFAULT_REPO"
  fi
  echo "${repo/#\~/$HOME}"
}

_host_shell() {
  local shell
  shell=$(_host_field "$1" shell)
  if [ -z "$shell" ] || [ "$shell" = '""' ]; then
    echo "bash"
  else
    echo "$shell"
  fi
}

_ssh_target() {
  local host="$1" user target
  user=$(_host_field "$host" user)
  target=$(_host_field "$host" host)
  [ -n "$user" ] && [ -n "$target" ] || die "Host $host: missing user or host for SSH"
  echo "${user}@${target}"
}

_ssh_identity_opt() {
  local host="$1" identity
  identity=$(_host_field "$host" identity_file)
  if [ -n "$identity" ] && [ "$identity" != '""' ]; then
    identity="${identity/#\~/$HOME}"
    printf '%s\n' "-i" "$identity"
  fi
}

_run_local_bash() {
  local repo="$1" cmd="$2"
  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] local bash: cd $repo && $cmd"
    return 0
  fi
  (cd "$repo" && eval "$cmd")
}

_run_ssh_bash() {
  local host="$1" repo="$2" cmd="$3"
  local target remote_cmd
  target=$(_ssh_target "$host")
  remote_cmd="cd $(printf '%q' "$repo") && ${cmd}"
  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] ssh bash ${target}: ${remote_cmd}"
    return 0
  fi
  # shellcheck disable=SC2046
  ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
    $(_ssh_identity_opt "$host") "$target" "bash -lc $(printf '%q' "$remote_cmd")"
}

_run_ssh_powershell() {
  local host="$1" repo="$2" cmd="$3"
  local target ps_cmd
  target=$(_ssh_target "$host")
  ps_cmd="Set-Location '${repo}'; ${cmd}"
  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] ssh powershell ${target}: ${ps_cmd}"
    return 0
  fi
  # shellcheck disable=SC2046
  ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
    $(_ssh_identity_opt "$host") "$target" \
    powershell -NoProfile -NonInteractive -Command "$ps_cmd"
}

run_on_host() {
  local host="$1" cmd="$2"
  local htype shell repo
  htype=$(_host_field "$host" type)
  [ -z "$htype" ] || [ "$htype" = '""' ] && htype="local"
  shell=$(_host_shell "$host")
  repo=$(_host_repo "$host")

  case "$htype" in
    local)
      case "$shell" in
        bash) _run_local_bash "$repo" "$cmd" ;;
        powershell) die "Local powershell not supported — use ssh to Windows host" ;;
        *) die "Host $host: unknown shell $shell" ;;
      esac
      ;;
    ssh)
      case "$shell" in
        bash) _run_ssh_bash "$host" "$repo" "$cmd" ;;
        powershell) _run_ssh_powershell "$host" "$repo" "$cmd" ;;
        *) die "Host $host: unknown shell $shell" ;;
      esac
      ;;
    *) die "Host $host: unknown type $htype" ;;
  esac
}

_env_prefix_bash() {
  local mode="${1:-}"
  local parts=""
  [ "$QUIET" = "true" ] && parts="${parts}export QUIET=true; "
  [ "$TRUST_CA" != "true" ] && parts="${parts}export AAP_DEMO_TRUST_CA=false; "
  if [ "$mode" = "load_cache" ] && [ "$USE_LOCAL_CACHE" = true ]; then
    parts="${parts}export AAP_DEMO_LOAD_CACHE=1; "
  fi
  echo "$parts"
}

_env_prefix_ps() {
  local mode="${1:-}"
  local parts=""
  [ "$QUIET" = "true" ] && parts="${parts}\$env:QUIET = 'true'; "
  [ "$TRUST_CA" != "true" ] && parts="${parts}\$env:AAP_DEMO_TRUST_CA = 'false'; "
  if [ "$mode" = "load_cache" ] && [ "$USE_LOCAL_CACHE" = true ]; then
    parts="${parts}\$env:AAP_DEMO_LOAD_CACHE = '1'; "
  fi
  echo "$parts"
}

_aap_invoke_bash() {
  local aap_cmd="$1" subcmd="$2" extra="${3:-}" mode="${4:-}"
  echo "$(_env_prefix_bash "$mode")${aap_cmd} ${subcmd}${extra:+ ${extra}}"
}

_aap_invoke_ps() {
  local aap_cmd="$1" subcmd="$2" extra="${3:-}" mode="${4:-}"
  echo "$(_env_prefix_ps "$mode")${aap_cmd} ${subcmd}${extra:+ ${extra}}"
}

host_matches_filter() {
  local host="$1"
  [ -z "$HOST_FILTER" ] || [ "$host" = "$HOST_FILTER" ]
}

get_addon_order() {
  local count
  count=$(_cfg '.addon_order | length' 2>/dev/null || echo 0)
  if [ "$count" != "0" ] && [ -n "$count" ]; then
    yq eval '.addon_order | .[]' "$CONFIG_FILE"
  else
    for a in $DEFAULT_ADDON_ORDER; do echo "$a"; done
  fi
}

_pr_local_branch() {
  echo "pr-${PR_NUMBER}-multi-host-test"
}

_pr_checkout_cmd_bash() {
  local pr="$1" remote="$2" branch
  branch=$(_pr_local_branch)
  cat <<EOF
if command -v gh >/dev/null 2>&1; then
  gh pr checkout ${pr}
else
  git fetch ${remote} pull/${pr}/head:${branch} && git checkout ${branch}
fi
EOF
}

_pr_checkout_cmd_ps() {
  local pr="$1" remote="$2" branch
  branch=$(_pr_local_branch)
  cat <<EOF
if (Get-Command gh -ErrorAction SilentlyContinue) {
  gh pr checkout ${pr}
} else {
  git fetch ${remote} pull/${pr}/head:${branch}; if (\$LASTEXITCODE -ne 0) { exit 1 }
  git checkout ${branch}; if (\$LASTEXITCODE -ne 0) { exit 1 }
}
EOF
}

sync_repo_on_host() {
  local host="$1" shell repo remote pr_cmd
  shell=$(_host_shell "$host")
  repo=$(_host_repo "$host")
  remote=$(_host_field "$host" git_remote)
  [ -z "$remote" ] || [ "$remote" = '""' ] && remote="$GIT_REMOTE"

  if [ -n "$PR_NUMBER" ]; then
    log "Checkout PR #${PR_NUMBER} on $host (remote: ${remote})"
    if [ "$shell" = "powershell" ]; then
      pr_cmd=$(_pr_checkout_cmd_ps "$PR_NUMBER" "$remote")
    else
      pr_cmd=$(_pr_checkout_cmd_bash "$PR_NUMBER" "$remote")
    fi
    if [ "$DRY_RUN" = true ]; then
      log "[dry-run] $host: checkout PR #${PR_NUMBER} in $repo"
      return 0
    fi
    run_on_host "$host" "$pr_cmd" || {
      warn "$host: PR #${PR_NUMBER} checkout failed (install gh or ensure git remote ${remote} is configured)"
      [ "$STRICT" = true ] && return 1
    }
    return 0
  fi

  if [ "$SYNC_REPO" = "true" ]; then
    if [ "$DRY_RUN" = true ]; then
      log "[dry-run] $host: git pull in $repo"
    else
      run_on_host "$host" "git pull" || warn "$host: git pull failed"
    fi
  fi
  return 0
}

_cluster_running_cmd_bash() {
  echo 'crc status 2>/dev/null | grep -qi Running'
}

_cluster_running_cmd_ps() {
  echo '((crc status 2>&1) -match "Running")'
}

save_local_cache_before_destroy() {
  local host="$1"
  local shell aap_cmd
  [ "$USE_LOCAL_CACHE" = true ] || return 0

  shell=$(_host_shell "$host")
  aap_cmd=$(_host_field "$host" aap_cmd)
  aap_cmd=${aap_cmd:-aap-demo}

  log "Save local-cache before destroy: $host"
  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] $host: aap-demo enable local-cache save (if CRC running)"
    return 0
  fi

  local running_cmd
  if [ "$shell" = "powershell" ]; then
    running_cmd=$(_cluster_running_cmd_ps)
  else
    running_cmd=$(_cluster_running_cmd_bash)
  fi

  if ! run_on_host "$host" "$running_cmd"; then
    warn "$host: CRC not running — skipping local-cache save"
    result_set "${host}.local_cache_save" skipped
    return 0
  fi

  if [ "$shell" = "powershell" ]; then
    run_on_host "$host" "$(_aap_invoke_ps "$aap_cmd" enable "local-cache save")" || {
      warn "$host: local-cache save failed (bash/CRC hosts only today)"
      result_set "${host}.local_cache_save" fail
      [ "$STRICT" = true ] && return 1
      return 0
    }
  else
    run_on_host "$host" "$(_aap_invoke_bash "$aap_cmd" enable "local-cache save")" || {
      warn "$host: local-cache save failed"
      result_set "${host}.local_cache_save" fail
      [ "$STRICT" = true ] && return 1
      return 0
    }
  fi

  result_set "${host}.local_cache_save" pass
  return 0
}

preflight_host() {
  local host="$1"
  local shell repo aap_cmd
  log "Preflight: $host"
  shell=$(_host_shell "$host")
  repo=$(_host_repo "$host")
  aap_cmd=$(_host_field "$host" aap_cmd)
  aap_cmd=${aap_cmd:-aap-demo}

  sync_repo_on_host "$host" || return 1

  if [ "$shell" = "powershell" ]; then
    run_on_host "$host" "$(_aap_invoke_ps "$aap_cmd" version)" || return 1
  else
    run_on_host "$host" "$(_aap_invoke_bash "$aap_cmd" version)" || return 1
    run_on_host "$host" "command -v crc >/dev/null && { command -v kubectl >/dev/null || command -v oc >/dev/null; }" || {
      warn "$host: crc/kubectl missing"
      [ "$STRICT" = true ] && return 1
    }
  fi

  local pull_required
  pull_required=$(_cfg '.defaults.pull_secret_required // true')
  if [ "$pull_required" = "true" ]; then
    if [ "$shell" = "powershell" ]; then
      run_on_host "$host" "if (-not (Test-Path \"\$env:USERPROFILE\\.aap-demo\\pull-secret.txt\") -and -not (Test-Path \"\$env:USERPROFILE\\.aap-demo\\pull-secret.json\")) { exit 1 }" || {
        warn "$host: pull secret missing"
        [ "$STRICT" = true ] && return 1
      }
    else
      run_on_host "$host" "test -f ~/.aap-demo/pull-secret.txt || test -f ~/.aap-demo/pull-secret.json" || {
        warn "$host: pull secret missing"
        [ "$STRICT" = true ] && return 1
      }
      run_on_host "$host" "test -f ~/.aap-demo/galaxy-token" || {
        warn "$host: galaxy-token missing (setup-pah will fail)"
        [ "$STRICT" = true ] && return 1
      }
    fi
  fi
  return 0
}

destroy_deploy_host() {
  local host="$1"
  local shell aap_cmd reset_arg=""
  shell=$(_host_shell "$host")
  aap_cmd=$(_host_field "$host" aap_cmd)
  aap_cmd=${aap_cmd:-aap-demo}
  [ "$DESTROY_RESET" = "true" ] && reset_arg="--reset"

  save_local_cache_before_destroy "$host" || return 1

  log "Destroy: $host"
  if [ "$shell" = "powershell" ]; then
    run_on_host "$host" "$(_aap_invoke_ps "$aap_cmd" destroy "$reset_arg")"
  else
    run_on_host "$host" "$(_aap_invoke_bash "$aap_cmd" destroy "$reset_arg")"
  fi
  result_set "${host}.destroy" pass

  log "Deploy: $host"
  if [ "$shell" = "powershell" ]; then
    run_on_host "$host" "$(_aap_invoke_ps "$aap_cmd" deploy "" load_cache)"
  else
    run_on_host "$host" "$(_aap_invoke_bash "$aap_cmd" deploy "" load_cache)"
  fi
  result_set "${host}.deploy" pass

  log "Diagnose: $host"
  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] $host: aap-demo diagnose"
    result_set "${host}.diagnose" pass
    return 0
  fi

  local diag_out diag_rc=0
  if [ "$shell" = "powershell" ]; then
    diag_out=$(run_on_host "$host" "$(_aap_invoke_ps "$aap_cmd" diagnose)" 2>&1) || diag_rc=$?
  else
    diag_out=$(run_on_host "$host" "$(_aap_invoke_bash "$aap_cmd" diagnose)" 2>&1) || diag_rc=$?
  fi

  if echo "$diag_out" | grep -q '✗'; then
    result_set "${host}.diagnose" fail
    warn "$host: diagnose reported failures"
    [ "$STRICT" = true ] && return 1
    return 0
  fi

  if [ "$diag_rc" -ne 0 ]; then
    result_set "${host}.diagnose" fail
    return 1
  fi

  result_set "${host}.diagnose" pass
  return 0
}

verify_addon() {
  local host="$1" addon="$2"
  local ns="${NAMESPACE:-aap-operator}" check_cmd=""

  case "$addon" in
    setup-pah) check_cmd="test -f ~/.aap-demo/galaxy-token" ;;
    mcp-server)
      check_cmd="kubectl get ansiblemcpserver -n ${ns} >/dev/null 2>&1 && kubectl get pods -n ${ns} -l app.kubernetes.io/name=aap-mcp-server --no-headers 2>/dev/null | grep -q Running"
      ;;
    portal)
      check_cmd="kubectl get deployment -n redhat-rhaap-portal --no-headers 2>/dev/null | grep -q . && kubectl get route -n redhat-rhaap-portal --no-headers 2>/dev/null | grep -q ."
      ;;
    ao)
      check_cmd="kubectl get namespace automation-orchestrator >/dev/null 2>&1 && kubectl get pods -n automation-orchestrator --no-headers 2>/dev/null | grep -q Running"
      ;;
    apme-eap) check_cmd="kubectl get pods -n apme --no-headers 2>/dev/null | grep -q Running" ;;
    product-demos) check_cmd="kubectl get aap -n ${ns} >/dev/null 2>&1" ;;
    product-demo-satellite) check_cmd="true" ;;
    local-cache) check_cmd="test -d ~/.aap-demo/local-cache && ls ~/.aap-demo/local-cache/*/*.tar >/dev/null 2>&1" ;;
    *)
      warn "No verify check for addon: $addon"
      return 0
      ;;
  esac

  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] verify $host/$addon: $check_cmd"
    return 0
  fi

  if run_on_host "$host" "$check_cmd"; then
    result_set "${host}.addon.${addon}" pass
    return 0
  fi
  result_set "${host}.addon.${addon}" fail
  return 1
}

enable_addons_host() {
  local host="$1"
  local shell aap_cmd addon sat_url enable_cmd
  shell=$(_host_shell "$host")
  aap_cmd=$(_host_field "$host" aap_cmd)
  aap_cmd=${aap_cmd:-aap-demo}
  sat_url=$(_cfg '.prerequisites.satellite.url // ""')

  while IFS= read -r addon; do
    [ -n "$addon" ] || continue
    log "Enable addon $addon on $host"

    if [ "$addon" = "product-demo-satellite" ] && [ -n "$sat_url" ] && [ "$sat_url" != '""' ]; then
      if [ "$shell" = "powershell" ]; then
        enable_cmd="\$env:SATELLITE_URL = '${sat_url}'; $(_aap_invoke_ps "$aap_cmd" enable "$addon")"
      else
        enable_cmd="export SATELLITE_URL='${sat_url}'; $(_aap_invoke_bash "$aap_cmd" enable "$addon")"
      fi
    else
      if [ "$shell" = "powershell" ]; then
        enable_cmd="$(_aap_invoke_ps "$aap_cmd" enable "$addon")"
      else
        enable_cmd="$(_aap_invoke_bash "$aap_cmd" enable "$addon")"
      fi
    fi

    if ! run_on_host "$host" "$enable_cmd"; then
      result_set "${host}.addon.${addon}" fail
      [ "$STRICT" = true ] && return 1
      continue
    fi

    if ! verify_addon "$host" "$addon"; then
      [ "$STRICT" = true ] && return 1
    fi

    log "Post-addon diagnose: $host / $addon"
    if [ "$shell" = "powershell" ]; then
      run_on_host "$host" "$(_aap_invoke_ps "$aap_cmd" diagnose)" >/dev/null 2>&1 || warn "$host: diagnose warnings after $addon"
    else
      run_on_host "$host" "$(_aap_invoke_bash "$aap_cmd" diagnose)" >/dev/null 2>&1 || warn "$host: diagnose warnings after $addon"
    fi
  done <<EOF
$(get_addon_order)
EOF
  return 0
}

write_report() {
  local ts host addon passed json_file md_file
  ts=$(date -u +"%Y%m%dT%H%M%SZ")
  mkdir -p "$REPORT_DIR"
  json_file="${REPORT_DIR}/${ts}.json"
  md_file="${REPORT_DIR}/${ts}.md"

  {
    echo "{"
    echo "  \"timestamp\": \"${ts}\","
    echo "  \"config\": \"${CONFIG_FILE}\","
    if [ -n "$PR_NUMBER" ]; then
      echo "  \"pr\": ${PR_NUMBER},"
    else
      echo "  \"pr\": null,"
    fi
    echo "  \"dry_run\": ${DRY_RUN},"
    echo "  \"hosts\": {"
    local first_host=true host_list
    host_list=$(yq eval '.hosts | keys | .[]' "$CONFIG_FILE")
    while IFS= read -r host; do
      [ -n "$host" ] || continue
      host_matches_filter "$host" || continue
      [ "$first_host" = true ] || echo ","
      first_host=false
      printf '    "%s": {\n' "$host"
      printf '      "destroy": "%s",\n' "$(result_get "${host}.destroy")"
      printf '      "deploy": "%s",\n' "$(result_get "${host}.deploy")"
      printf '      "diagnose": "%s",\n' "$(result_get "${host}.diagnose")"
      printf '      "local_cache_save": "%s",\n' "$(result_get "${host}.local_cache_save")"
      printf '      "addons": {'
      local first_addon=true
      while IFS= read -r addon; do
        [ -n "$addon" ] || continue
        [ "$first_addon" = true ] || printf ', '
        first_addon=false
        printf '"%s": "%s"' "$addon" "$(result_get "${host}.addon.${addon}")"
      done <<EOF
$(get_addon_order)
EOF
      printf '}\n    }'
    done <<EOF
${host_list}
EOF
    echo ""
    echo "  }"
    echo "}"
  } >"$json_file"

  {
    echo "# aap-demo multi-host test — ${ts}"
    echo ""
    echo "| Host | Destroy | Deploy | Diagnose | Addons passed |"
    echo "|------|---------|--------|----------|---------------|"
    while IFS= read -r host; do
      [ -n "$host" ] || continue
      host_matches_filter "$host" || continue
      passed=0
      while IFS= read -r addon; do
        [ -n "$addon" ] || continue
        [ "$(result_get "${host}.addon.${addon}")" = "pass" ] && passed=$((passed + 1))
      done <<EOF
$(get_addon_order)
EOF
      total=$(get_addon_order | wc -l | tr -d ' ')
      echo "| ${host} | $(result_get "${host}.destroy") | $(result_get "${host}.deploy") | $(result_get "${host}.diagnose") | ${passed}/${total} |"
    done <<EOF
${host_list}
EOF
    echo ""
    echo "JSON: \`${json_file}\`"
  } >"$md_file"

  log "Report: $md_file"
  log "JSON:   $json_file"
  cat "$md_file"
}

main() {
  local host failures=0 matched=0
  RESULTS_FILE=$(mktemp)
  trap 'rm -f "$RESULTS_FILE"' EXIT

  log "Config: $CONFIG_FILE"
  [ "$DRY_RUN" = true ] && log "Mode: dry-run"
  [ -n "$HOST_FILTER" ] && log "Host filter: $HOST_FILTER"
  [ -n "$PR_NUMBER" ] && log "PR under test: #${PR_NUMBER}"
  [ "$USE_LOCAL_CACHE" = true ] && log "Local-cache: save before destroy, load on deploy"
  [ "$USE_LOCAL_CACHE" = false ] && log "Local-cache: disabled (--skip-local-cache or use_local_cache: false)"

  while IFS= read -r host; do
    [ -n "$host" ] || continue
    host_matches_filter "$host" || continue
    matched=$((matched + 1))
    log "========== $host =========="
    local start_ts end_ts
    start_ts=$(date +%s)

    if ! preflight_host "$host"; then
      result_set "${host}.preflight" fail
      failures=$((failures + 1))
      [ "$STRICT" = true ] && continue
    fi

    if [ "$ONLY_ADDONS" = false ]; then
      destroy_deploy_host "$host" || failures=$((failures + 1))
    fi

    if [ "$SKIP_ADDONS" = false ]; then
      enable_addons_host "$host" || failures=$((failures + 1))
    fi

    end_ts=$(date +%s)
    log "$host completed in $((end_ts - start_ts))s"
  done <<EOF
$(yq eval '.hosts | keys | .[]' "$CONFIG_FILE")
EOF

  [ "$matched" -gt 0 ] || die "No hosts matched filter: ${HOST_FILTER:-all}"

  write_report

  if [ "$failures" -gt 0 ]; then
    die "$failures host phase(s) failed"
  fi
  log "All hosts completed successfully"
}

main "$@"
