#!/usr/bin/env bash
# Shared aap-demo version metadata (semver + git build info).

_AAP_DEMO_VERSION_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_AAP_DEMO_VERSION_REPO_ROOT="$(cd "${_AAP_DEMO_VERSION_SCRIPT_DIR}/.." && pwd)"

_aap_demo_version_load() {
  local _root="${1:-}"
  if [ -z "$_root" ] || [ ! -f "${_root}/VERSION" ]; then
    _root="$_AAP_DEMO_VERSION_REPO_ROOT"
  fi

  AAP_DEMO_REPO_ROOT="$_root"
  AAP_DEMO_VERSION="$(
    tr -d '[:space:]' <"${AAP_DEMO_REPO_ROOT}/VERSION" 2>/dev/null || echo "0.0.0-dev"
  )"
  AAP_DEMO_GIT_SHA="$(git -C "$AAP_DEMO_REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
  AAP_DEMO_GIT_SHA_FULL="$(git -C "$AAP_DEMO_REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")"
  AAP_DEMO_GIT_BRANCH="$(git -C "$AAP_DEMO_REPO_ROOT" branch --show-current 2>/dev/null || echo "unknown")"
  AAP_DEMO_GIT_DATE="$(git -C "$AAP_DEMO_REPO_ROOT" log -1 --format=%cd --date=iso-strict 2>/dev/null || echo "unknown")"
  AAP_DEMO_GIT_REMOTE="$(git -C "$AAP_DEMO_REPO_ROOT" remote get-url origin 2>/dev/null || echo "")"

  export AAP_DEMO_REPO_ROOT AAP_DEMO_VERSION AAP_DEMO_GIT_SHA AAP_DEMO_GIT_SHA_FULL
  export AAP_DEMO_GIT_BRANCH AAP_DEMO_GIT_DATE AAP_DEMO_GIT_REMOTE
}

aap_demo_reload_version() {
  _aap_demo_version_load "${SCRIPT_DIR:-}"
}

if [ -z "${_AAP_DEMO_VERSION_LOADED:-}" ]; then
  _AAP_DEMO_VERSION_LOADED=1
  _aap_demo_version_load "${SCRIPT_DIR:-}"
fi

aap_demo_version_short() {
  printf '%s (%s)' "$AAP_DEMO_VERSION" "$AAP_DEMO_GIT_SHA"
}

aap_demo_version_line() {
  printf 'aap-demo %s | %s | %s | %s' \
    "$AAP_DEMO_VERSION" "$AAP_DEMO_GIT_SHA" "$AAP_DEMO_GIT_DATE" "$AAP_DEMO_GIT_BRANCH"
}

aap_demo_print_version() {
  printf 'aap-demo %s\n' "$AAP_DEMO_VERSION"
  printf '  built:    %s\n' "$AAP_DEMO_GIT_DATE"
  printf '  commit:   %s\n' "$AAP_DEMO_GIT_SHA_FULL"
  printf '  branch:   %s\n' "$AAP_DEMO_GIT_BRANCH"
  printf '  source:   %s\n' "$AAP_DEMO_REPO_ROOT"
  if [ -n "$AAP_DEMO_GIT_REMOTE" ]; then
    printf '  repo:     %s\n' "$AAP_DEMO_GIT_REMOTE"
  fi
}
