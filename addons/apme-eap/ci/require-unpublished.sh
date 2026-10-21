#!/usr/bin/env bash
# Usage: require-unpublished.sh <qualified-image:tag> [skopeo inspect options...]
# Only an explicit registry MANIFEST_UNKNOWN/NAME_UNKNOWN permits publication.
# Authentication, transport and unrecognized errors fail closed.
set +x
set -euo pipefail
[[ $# -ge 1 && -n "$1" ]] || {
  printf 'Image reference required\n' >&2
  exit 1
}
image="$1"
shift
error_file="$(mktemp "${TMPDIR:-/tmp}/apme-publication.XXXXXX")"
trap 'rm -f -- "$error_file"' EXIT
if skopeo inspect --raw "$@" "docker://$image" >/dev/null 2>"$error_file"; then
  printf 'Immutable image already exists: %s; refusing to overwrite. Reuse its digest or publish new plugin inputs.\n' "$image" >&2
  exit 1
fi
if ! grep -Eiq '(^|[^a-z_])(manifest unknown|name unknown)(:|[[:space:]]|$)' "$error_file"; then
  # Do not echo an arbitrary registry error: it may contain credential material.
  printf 'Cannot confirm immutable image is absent: %s; check registry connectivity and pull permission before retrying.\n' "$image" >&2
  exit 1
fi
