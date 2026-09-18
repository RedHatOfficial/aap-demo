#!/usr/bin/env bash
# Verify VERSION was bumped when merging changes to main.
#
# Usage:
#   ./scripts/check-version-bump.sh [base-ref]
#   ./scripts/check-version-bump.sh --fix [base-ref]
#
# Default base-ref: origin/main
#
# Policy:
#   - If the diff vs base changes any file other than VERSION (and automated
#     exclusions), VERSION must exist and be exactly one patch above the base.
#   - VERSION-only changes are allowed (release prep PRs).
set -euo pipefail

_err() {
  printf 'ERROR: %s\n' "$*" >&2
}

_note() {
  printf 'check-version-bump: %s\n' "$*"
}

AUTO_FIX=0
if [ "${1:-}" = "--fix" ]; then
  AUTO_FIX=1
  shift
fi

if [ "$#" -gt 1 ]; then
  _err "Usage: $0 [--fix] [base-ref]"
  exit 2
fi

BASE_REF="${1:-origin/main}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="${REPO_ROOT}/VERSION"

# Paths that may change without requiring a VERSION bump.
EXCLUDE_PATTERN='^(VERSION|\.secrets\.baseline)$'

read_version() {
  local _file="$1"
  if [ ! -f "$_file" ]; then
    echo ""
    return 0
  fi
  tr -d '[:space:]' <"$_file"
}

valid_semver() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]
}

bump_patch() {
  local _version="$1"
  if [[ "$_version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)([-+].*)?$ ]]; then
    printf '%s.%s.%s\n' \
      "${BASH_REMATCH[1]}" \
      "${BASH_REMATCH[2]}" \
      "$((10#${BASH_REMATCH[3]} + 1))"
  else
    return 1
  fi
}

cd "$REPO_ROOT"

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  _err "Not a git repository: ${REPO_ROOT}"
  exit 1
fi

if ! git rev-parse --verify "${BASE_REF}" &>/dev/null; then
  _note "Base ref ${BASE_REF} not found — skipping version bump check"
  exit 0
fi

OLD_VERSION="$(git show "${BASE_REF}:VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
NEW_VERSION="$(read_version "$VERSION_FILE")"

if [ -z "$OLD_VERSION" ]; then
  OLD_VERSION="0.0.0"
  _note "No VERSION on ${BASE_REF}; treating base as ${OLD_VERSION}"
fi

if [ -z "$NEW_VERSION" ]; then
  _err "Missing VERSION file at repo root"
  exit 1
fi

if ! valid_semver "$NEW_VERSION"; then
  _err "VERSION must be semver (e.g. 1.0.0), got: ${NEW_VERSION}"
  exit 1
fi

if ! valid_semver "$OLD_VERSION"; then
  _note "Base VERSION is not semver (${OLD_VERSION}); skipping comparison"
  exit 0
fi

EXPECTED_VERSION="$(bump_patch "$OLD_VERSION")" || {
  _err "Cannot calculate the next patch version from base: ${OLD_VERSION}"
  exit 1
}

REQUIRES_BUMP=0
while IFS= read -r _path; do
  [ -z "$_path" ] && continue
  if [[ "$_path" =~ $EXCLUDE_PATTERN ]]; then
    continue
  fi
  REQUIRES_BUMP=1
  break
done < <(git diff --name-only "${BASE_REF}...HEAD" 2>/dev/null || true)

# A pre-commit hook runs before the new commit exists, so include staged files
# in addition to the committed branch diff.  --fix is used only by the local
# hook; CI keeps validation-only behavior.
if [ "$REQUIRES_BUMP" -eq 0 ]; then
  while IFS= read -r _path; do
    [ -z "$_path" ] && continue
    if [[ "$_path" =~ $EXCLUDE_PATTERN ]]; then
      continue
    fi
    REQUIRES_BUMP=1
    break
  done < <(git diff --cached --name-only 2>/dev/null || true)
fi

if [ "$REQUIRES_BUMP" -eq 0 ]; then
  _note "No user-facing changes (only VERSION/exclusions) — OK (${OLD_VERSION})"
  exit 0
fi

if [ "$AUTO_FIX" -eq 1 ] && [ "$NEW_VERSION" != "$EXPECTED_VERSION" ]; then
  printf '%s\n' "$EXPECTED_VERSION" >"$VERSION_FILE"
  git add -- "$VERSION_FILE"
  NEW_VERSION="$EXPECTED_VERSION"
  _note "Automatically set VERSION: ${OLD_VERSION} -> ${NEW_VERSION}"
fi

if [ "$NEW_VERSION" != "$EXPECTED_VERSION" ]; then
  _err "VERSION must be exactly one patch above the base when merging code changes"
  _err "  base (${BASE_REF}): ${OLD_VERSION}"
  _err "  HEAD:              ${NEW_VERSION}"
  _err "  expected:          ${EXPECTED_VERSION}"
  exit 1
fi

_note "VERSION bump OK: ${OLD_VERSION} -> ${NEW_VERSION}"
exit 0
