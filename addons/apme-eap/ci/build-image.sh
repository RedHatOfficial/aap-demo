#!/usr/bin/env bash
# Build a verified upstream pack locally; only --push publishes to Quay.
# Disable inherited tracing before handling any credentials.
set +x
set -euo pipefail

die() {
  printf 'APME image build: %s\n' "$*" >&2
  exit 1
}
usage() {
  cat <<'USAGE'
Usage: build-image.sh [--source-ref latest|<full-sha>] [--source-repo owner/repo]
                      [--tag <tag>] [--pack-sha256 sha256:<digest>]
                      [--output-dir <directory>] [--push]
Requires GH_TOKEN and Podman. Only --push requires QUAY_USERNAME/QUAY_TOKEN.
Optional: BASE_IMAGE, REGISTRY_REDHAT_USERNAME/REGISTRY_REDHAT_PASSWORD.
Replay: source a trusted artifact.env; APME_SOURCE_SHA and APME_PACK_SHA256
pin the next resolution and verify the downloaded pack again.
USAGE
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_repo="${APME_SOURCE_REPO:-ansible/ansible-rhdh-plugins}"
source_ref="${APME_SOURCE_REF:-${APME_SOURCE_SHA:-latest}}"
expected_pack_sha="${APME_PACK_SHA256:-}"
base_image="${BASE_IMAGE:-registry.redhat.io/rhdh/rhdh-hub-rhel9:1.9}"
image_repo=quay.io/aapdemo/apme-eap
tag=''
output=''
push=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-ref | --source-repo | --tag | --pack-sha256 | --output-dir)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "missing value for $1"
      case "$1" in
        --source-ref) source_ref="$2" ;;
        --source-repo) source_repo="$2" ;;
        --tag) tag="$2" ;;
        --pack-sha256) expected_pack_sha="$2" ;;
        --output-dir) output="$2" ;;
      esac
      shift 2
      ;;
    --push)
      push=true
      shift
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ "$source_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die 'invalid source repository; use owner/repo'
[[ "$source_ref" == latest || "$source_ref" =~ ^[0-9a-f]{40}$ ]] || die 'source ref must be latest or a full 40-character commit SHA'
[[ -z "$tag" || "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die 'invalid image tag'
[[ -z "$expected_pack_sha" || "$expected_pack_sha" =~ ^sha256:[0-9a-f]{64}$ ]] || die 'invalid expected pack SHA256'
if "$push"; then
  [[ -n "${QUAY_USERNAME:-}" && -n "${QUAY_TOKEN:-}" ]] || die '--push requires QUAY_USERNAME and QUAY_TOKEN'
fi
if [[ -n "${REGISTRY_REDHAT_USERNAME:-}${REGISTRY_REDHAT_PASSWORD:-}" ]]; then
  [[ -n "${REGISTRY_REDHAT_USERNAME:-}" && -n "${REGISTRY_REDHAT_PASSWORD:-}" ]] || die 'provide both Red Hat registry credentials'
fi
for tool in podman jq; do
  command -v "$tool" >/dev/null 2>&1 || die "required command unavailable: $tool"
done

# Retain only the verified pack and provenance, including on build/push failure.
# Never delete a caller-supplied output directory.
umask 077
if [[ -z "$output" ]]; then
  output="$(mktemp -d "${TMPDIR:-/tmp}/apme-image.XXXXXX")"
fi
mkdir -p -- "$output"
output="$(cd "$output" && pwd)"
context=''
auth_dir=''
cleanup() {
  local status=$?
  [[ -z "$context" ]] || rm -rf -- "$context"
  [[ -z "$auth_dir" ]] || rm -rf -- "$auth_dir"
  return "$status"
}
trap cleanup EXIT
APME_SOURCE_REPO="$source_repo" APME_SOURCE_REF="$source_ref" \
  bash "$script_dir/fetch-plugin-artifact.sh" "$output"
# This metadata was generated locally by the resolver, never taken from the ZIP.
# shellcheck disable=SC1091
source "$output/artifact.env"
if [[ -n "$expected_pack_sha" && "$expected_pack_sha" != "$APME_PACK_SHA256" ]]; then
  die 'downloaded pack does not match the recorded SHA256'
fi
[[ "$APME_PACK_FORMAT" == oci || "$APME_PACK_FORMAT" == npm ]] || die 'unsupported resolved pack format'
pack_hex="${APME_PACK_SHA256#sha256:}"
immutable_tag="apme-${APME_SOURCE_SHA}-${pack_hex:0:12}"
image="$image_repo:$immutable_tag"
alias_image=''
if [[ -n "$tag" && "$tag" != "$immutable_tag" ]]; then
  alias_image="$image_repo:$tag"
fi
printf 'Artifact metadata: %s/artifact.env\n' "$output"

context="$(mktemp -d "$output/.context.XXXXXX")"
mkdir -p "$context/ci"
cp "$output/plugin-pack.tar.gz" "$context/plugin-pack.tar.gz"
cp "$script_dir/extract-plugin-pack.py" "$context/ci/extract-plugin-pack.py"

# Use a standard credential helper that reads the environment and discards
# stores. Podman login normally persists passwords even with --password-stdin;
# this helper keeps credentials in process pipes, including during login.
# The helper script and auth configuration themselves contain no credentials.
auth_dir="$(mktemp -d "$output/.auth.XXXXXX")"
mkdir -p "$auth_dir/bin"
cat >"$auth_dir/bin/docker-credential-apme-env" <<'HELPER'
#!/usr/bin/env bash
set +x
set -euo pipefail
case "${1:-}" in
  get)
    registry="$(cat)"
    case "$registry" in
      quay.io) jq -en '{Username: env.QUAY_USERNAME, Secret: env.QUAY_TOKEN} | select(.Username != null and .Secret != null)' ;;
      registry.redhat.io) jq -en '{Username: env.REGISTRY_REDHAT_USERNAME, Secret: env.REGISTRY_REDHAT_PASSWORD} | select(.Username != null and .Secret != null)' ;;
      *) exit 1 ;;
    esac
    ;;
  store | erase) cat >/dev/null ;;
  *) exit 1 ;;
esac
HELPER
chmod 700 "$auth_dir/bin/docker-credential-apme-env"
export PATH="$auth_dir/bin:$PATH"
build_cmd=(podman build)
if [[ -n "${REGISTRY_REDHAT_USERNAME:-}" ]]; then
  printf '%s\n' '{"auths":{},"credHelpers":{"registry.redhat.io":"apme-env"}}' >"$auth_dir/auth.json"
  printf '%s\n' "$REGISTRY_REDHAT_PASSWORD" | podman login \
    --authfile "$auth_dir/auth.json" --username "$REGISTRY_REDHAT_USERNAME" \
    --password-stdin registry.redhat.io
  build_cmd+=(--authfile "$auth_dir/auth.json")
fi
"${build_cmd[@]}" --file "$script_dir/../Containerfile.ci" \
  --build-arg "BASE_IMAGE=$base_image" \
  --build-arg "PLUGIN_PACK_SHA256=$APME_PACK_SHA256" \
  --build-arg "PLUGIN_PACK_FORMAT=$APME_PACK_FORMAT" \
  --label "org.opencontainers.image.source=https://github.com/$APME_SOURCE_REPO" \
  --label "org.opencontainers.image.revision=$APME_SOURCE_SHA" \
  --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --label "io.apme.artifact.id=$APME_ARTIFACT_ID" \
  --label "io.apme.pack.sha256=$APME_PACK_SHA256" \
  --tag "$image" "$context"
local_digest="$(podman image inspect --format '{{.Id}}' "$image")"
# Podman versions can expose .Id as either bare hex or a prefixed digest.
if [[ "$local_digest" =~ ^[0-9a-f]{64}$ ]]; then
  local_digest="sha256:$local_digest"
fi
[[ "$local_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die 'invalid local image digest'
printf 'Local image: %s\nLocal image digest (config): %s\n' "$image" "$local_digest"

if "$push"; then
  printf '%s\n' '{"auths":{},"credHelpers":{"quay.io":"apme-env"}}' >"$auth_dir/auth.json"
  printf '%s\n' "$QUAY_TOKEN" | podman login --authfile "$auth_dir/auth.json" \
    --username "$QUAY_USERNAME" --password-stdin quay.io
  podman push --authfile "$auth_dir/auth.json" --digestfile "$context/immutable.digest" \
    "$image" "docker://$image"
  registry_digest="$(cat "$context/immutable.digest")"
  [[ "$registry_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die 'invalid pushed image digest'
  printf 'Published immutable image: %s\nRegistry digest: %s\nImage reference: %s@%s\n' \
    "$image" "$registry_digest" "$image_repo" "$registry_digest"
  if [[ -n "$alias_image" ]]; then
    podman tag "$image" "$alias_image"
    podman push --authfile "$auth_dir/auth.json" --digestfile "$context/alias.digest" \
      "$alias_image" "docker://$alias_image"
    alias_digest="$(cat "$context/alias.digest")"
    [[ "$alias_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die 'invalid pushed alias digest'
    printf 'Published alias image: %s\nAlias registry digest: %s\n' \
      "$alias_image" "$alias_digest"
  fi
fi
printf 'Artifact metadata: %s/artifact.env\n' "$output"
