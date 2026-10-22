#!/usr/bin/env bash
# =============================================================================
# kubeconfig-guard.sh — Refuse cluster commands aimed at a remote API
# =============================================================================
#
# The shell export from `aap-demo` points KUBECONFIG at
# ~/.aap-demo/kubeconfig.microshift. `oc login` updates that file's current
# context, so later aap-demo commands can deploy onto a different cluster.
# Cluster commands stop unless the current API server is local OpenShift Local.
#
# =============================================================================

if [ -n "${_AAP_DEMO_KUBECONFIG_GUARD_LOADED:-}" ]; then
  return 0
fi
_AAP_DEMO_KUBECONFIG_GUARD_LOADED=1

# Host portion of a kubeconfig server URL, lowercased and without port.
aap_demo_server_host() {
  local server="$1"
  server="${server#*://}"
  server="${server%%/*}"
  server="${server##*@}"
  if [ "${server#\[}" != "$server" ]; then
    server="${server#\[}"
    server="${server%%\]*}"
  else
    server="${server%%:*}"
  fi
  printf '%s' "$server" | tr '[:upper:]' '[:lower:]'
}

# crc ip can hang when the daemon is unhealthy. Bound the wait.
aap_demo_crc_api_ip() {
  command -v crc >/dev/null 2>&1 || return 0
  local output pid i
  output=$(mktemp "${TMPDIR:-/tmp}/aap-demo-crc-ip.XXXXXX") || return 0
  crc ip >"$output" 2>/dev/null &
  pid=$!
  i=0
  while [ "$i" -lt 20 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    i=$((i + 1))
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -f "$output"
    return 0
  fi
  wait "$pid" 2>/dev/null || true
  tr -cd '0-9A-Fa-f.:' <"$output" || true
  rm -f "$output"
}

aap_demo_accept_api_ip() {
  local ip="$1"
  if printf '%s' "$ip" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    printf '%s\n' "$ip"
    return 0
  fi
  case "$ip" in
    *:*:*)
      printf '%s\n' "$ip" | tr '[:upper:]' '[:lower:]'
      ;;
  esac
}

# One local API host per line. Does not trust arbitrary servers stored in the
# active kubeconfig: `oc login` writes those.
aap_demo_local_api_hosts() {
  local crc_kc servers server host ip
  printf '%s\n' localhost 127.0.0.1 ::1 api.crc.testing

  ip=$(aap_demo_crc_api_ip || true)
  aap_demo_accept_api_ip "$ip" || true

  crc_kc="${HOME}/.crc/machines/crc/kubeconfig"
  if [ -s "$crc_kc" ] && command -v kubectl >/dev/null 2>&1; then
    servers=$(kubectl --kubeconfig "$crc_kc" config view \
      -o jsonpath='{range .clusters[*]}{.cluster.server}{"\n"}{end}' 2>/dev/null || true)
    while IFS= read -r server; do
      host=$(aap_demo_server_host "$server")
      [ -n "$host" ] && printf '%s\n' "$host"
    done <<EOF
$servers
EOF
  fi
}

aap_demo_host_is_local() {
  local host="$1"
  local candidate
  [ -n "$host" ] || return 1
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    [ "$candidate" = "$host" ] && return 0
  done <<EOF
$(aap_demo_local_api_hosts)
EOF
  return 1
}

aap_demo_current_api_server() {
  [ -n "${KUBECONFIG:-}" ] && [ -s "$KUBECONFIG" ] || return 0
  command -v kubectl >/dev/null 2>&1 || return 0
  kubectl --kubeconfig "$KUBECONFIG" config view --minify \
    -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true
}

aap_demo_context_api_server() {
  local name="$1"
  kubectl --kubeconfig "$KUBECONFIG" config view --context="$name" --minify \
    -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true
}

# Local context to suggest, when one still points at OpenShift Local.
aap_demo_local_context_name() {
  local names name server host
  names=$(kubectl --kubeconfig "$KUBECONFIG" config get-contexts -o name 2>/dev/null || true)
  for name in microshift aap-demo; do
    printf '%s\n' "$names" | grep -Fxq -- "$name" || continue
    server=$(aap_demo_context_api_server "$name")
    host=$(aap_demo_server_host "$server")
    if aap_demo_host_is_local "$host"; then
      printf '%s\n' "$name"
      return 0
    fi
  done
  return 1
}

aap_demo_print_remote_kubeconfig_error() {
  local context="$1"
  local server="$2"
  local suggestion="$3"

  printf '\033[0;31mERROR:\033[0m Kubeconfig points at a remote cluster.\n' >&2
  printf '  Current context: %s\n' "$context" >&2
  printf '  API server:      %s\n' "$server" >&2
  printf '  Kubeconfig:      %s\n' "$KUBECONFIG" >&2
  printf '\n' >&2
  printf 'oc login updates the current context of this file. aap-demo stopped\n' >&2
  printf 'before it could read or change that cluster.\n' >&2
  printf '\n' >&2
  if [ -n "$suggestion" ]; then
    printf 'Switch back to the local context:\n' >&2
    printf '  kubectl config use-context %q\n' "$suggestion" >&2
    printf '\n' >&2
    printf 'Or run one command with that context:\n' >&2
    printf '  aap-demo --context %q <command>\n' "$suggestion" >&2
  else
    printf 'This file has no local OpenShift Local context. Set it aside, then\n' >&2
    printf 'refresh or recreate the local cluster:\n' >&2
    printf '  mv %q %q\n' "$KUBECONFIG" "${KUBECONFIG}.remote" >&2
    printf '  aap-demo kubeconfig\n' >&2
  fi
  printf '\n' >&2
  printf 'To target this API server on purpose:\n' >&2
  printf '  AAP_DEMO_ALLOW_REMOTE_KUBECONFIG=true aap-demo <command>\n' >&2
}

# Return 0 when the current context may be used. Commands that never talk to
# the Kubernetes API, and an explicit override, skip the check.
aap_demo_reject_remote_kubeconfig() {
  local server host context suggestion
  case "${AAP_DEMO_ALLOW_REMOTE_KUBECONFIG:-}" in
    1 | true | TRUE | yes | YES) return 0 ;;
  esac
  case "${COMMAND:-}" in
    kubeconfig | ssh | stop | redhat-status | rh-status) return 0 ;;
  esac

  server=$(aap_demo_current_api_server)
  [ -n "$server" ] || return 0
  host=$(aap_demo_server_host "$server")
  if aap_demo_host_is_local "$host"; then
    return 0
  fi

  context=$(kubectl --kubeconfig "$KUBECONFIG" config current-context 2>/dev/null || echo "(unknown)")
  suggestion=$(aap_demo_local_context_name || true)
  aap_demo_print_remote_kubeconfig_error "$context" "$server" "$suggestion"
  return 1
}
