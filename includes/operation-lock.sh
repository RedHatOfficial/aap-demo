#!/usr/bin/env bash

if [ -n "${_AAP_DEMO_OPERATION_LOCK_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_OPERATION_LOCK_LOADED=1

AAP_DEMO_LOCK_DIR="${AAP_DEMO_LOCK_DIR:-${AAP_DEMO_DIR:-$HOME/.aap-demo}/operation.lock}"
_AAP_DEMO_LOCK_HELD=false

aap_demo_command_requires_lock() {
  case "${1:-}" in
    repair | clean | maintenance | destroy | stop | start | restart | create | setup | update | config \
      | redeploy | redeploy-all | kubeconfig | idle | fleet | enable | disable \
      | wire | deploy | deploy-all)
      return 0
      ;;
    *) return 1 ;;
  esac
}

_aap_demo_lock_owner_value() {
  local key="$1"
  [ -f "$AAP_DEMO_LOCK_DIR/owner" ] || return 0
  sed -n "s/^${key}=//p" "$AAP_DEMO_LOCK_DIR/owner" | head -1
}

_aap_demo_remove_stale_lock() {
  rm -f "$AAP_DEMO_LOCK_DIR/owner"
  rmdir "$AAP_DEMO_LOCK_DIR" 2>/dev/null
}

_aap_demo_release_operation_lock() {
  [ "$_AAP_DEMO_LOCK_HELD" = true ] || return 0
  local owner_token
  owner_token=$(_aap_demo_lock_owner_value token)
  if [ "$owner_token" = "${AAP_DEMO_LOCK_TOKEN:-}" ]; then
    _aap_demo_remove_stale_lock || true
  fi
  _AAP_DEMO_LOCK_HELD=false
}

aap_demo_acquire_operation_lock() {
  local command="${1:-unknown}"
  local owner_pid owner_command owner_started owner_token attempt

  if [ "${AAP_DEMO_DISABLE_LOCK:-false}" = true ]; then
    return 0
  fi

  mkdir -p "$(dirname "$AAP_DEMO_LOCK_DIR")"
  for attempt in 1 2; do
    if mkdir "$AAP_DEMO_LOCK_DIR" 2>/dev/null; then
      AAP_DEMO_LOCK_TOKEN="${AAP_DEMO_LOCK_TOKEN:-$$-$(date +%s)-$RANDOM}"
      export AAP_DEMO_LOCK_TOKEN
      umask 077
      {
        printf 'pid=%s\n' "$$"
        printf 'token=%s\n' "$AAP_DEMO_LOCK_TOKEN"
        printf 'command=%s\n' "$command"
        printf 'started=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      } >"$AAP_DEMO_LOCK_DIR/owner"
      _AAP_DEMO_LOCK_HELD=true
      trap _aap_demo_release_operation_lock EXIT
      return 0
    fi

    owner_token=$(_aap_demo_lock_owner_value token)
    if [ -n "${AAP_DEMO_LOCK_TOKEN:-}" ] && [ "$owner_token" = "$AAP_DEMO_LOCK_TOKEN" ]; then
      return 0
    fi

    owner_pid=$(_aap_demo_lock_owner_value pid)
    if [[ "$owner_pid" =~ ^[0-9]+$ ]] \
      && { kill -0 "$owner_pid" 2>/dev/null || [ -d "/proc/$owner_pid" ]; }; then
      owner_command=$(_aap_demo_lock_owner_value command)
      owner_started=$(_aap_demo_lock_owner_value started)
      echo "ERROR: Another aap-demo operation is already running." >&2
      echo "  PID:     $owner_pid" >&2
      echo "  Command: ${owner_command:-unknown}" >&2
      echo "  Started: ${owner_started:-unknown}" >&2
      return 1
    fi

    if ! _aap_demo_remove_stale_lock; then
      echo "ERROR: Cannot remove stale operation lock: $AAP_DEMO_LOCK_DIR" >&2
      return 1
    fi
  done

  echo "ERROR: Cannot acquire aap-demo operation lock: $AAP_DEMO_LOCK_DIR" >&2
  return 1
}
