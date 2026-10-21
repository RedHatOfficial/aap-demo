#!/usr/bin/env bash
# Usage: APME_SOURCE_REPO=owner/repo APME_SOURCE_REF=latest|<full-sha> \
#        GH_TOKEN=... fetch-plugin-artifact.sh <output-directory>
# Defaults: ansible/ansible-rhdh-plugins, latest. APME_ARTIFACT_NAME is optional.
# Outputs: plugin-pack.tar.gz and artifact.env (eight shell-safe exports).
# APME_PACK_FILENAME is the normalized output filename; format is oci or npm.
# Command overrides are executable paths, not shell fragments, for offline tests:
# APME_GH_CMD, APME_UNZIP_CMD, APME_TAR_CMD, APME_SHA256_CMD (sha256sum interface).
set -euo pipefail

die() {
  printf 'APME artifact resolver: %s\n' "$*" >&2
  exit 1
}
[[ $# == 1 && -n "$1" ]] || die 'usage: fetch-plugin-artifact.sh <output-directory>'
mkdir -p -- "$1"
output="$(cd "$1" && pwd)"
work=''
cleanup() {
  local status=$?
  if [[ $status != 0 ]]; then
    rm -f -- "$output/artifact.env" "$output/plugin-pack.tar.gz"
  fi
  [[ -z "$work" ]] || rm -rf -- "$work"
  return "$status"
}
trap cleanup EXIT
# A failed refresh must not leave an older artifact looking like a success.
rm -f -- "$output/artifact.env" "$output/plugin-pack.tar.gz"
work="$(mktemp -d "$output/.apme-resolve.XXXXXX")"

APME_SOURCE_REPO="${APME_SOURCE_REPO:-ansible/ansible-rhdh-plugins}"
APME_SOURCE_REF="${APME_SOURCE_REF:-latest}"
[[ "$APME_SOURCE_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die 'invalid source repository; use owner/repo'
[[ "$APME_SOURCE_REF" == latest || "$APME_SOURCE_REF" =~ ^[0-9a-f]{40}$ ]] || die 'source ref must be latest or a full 40-character commit SHA'
[[ -n "${GH_TOKEN:-}" ]] || die 'GH_TOKEN is required for GitHub artifact access'
export GH_TOKEN
gh_cmd="${APME_GH_CMD:-gh}"
unzip_cmd="${APME_UNZIP_CMD:-unzip}"
tar_cmd="${APME_TAR_CMD:-tar}"
for tool in "$gh_cmd" "$unzip_cmd" "$tar_cmd" jq; do
  command -v "$tool" >/dev/null 2>&1 || die "required command unavailable: $tool"
done
if [[ -n "${APME_SHA256_CMD:-}" ]]; then
  hash_cmd=("$APME_SHA256_CMD")
elif command -v sha256sum >/dev/null 2>&1; then
  hash_cmd=(sha256sum)
else
  hash_cmd=(shasum -a 256)
fi
command -v "${hash_cmd[0]}" >/dev/null 2>&1 || die 'a SHA256 digest tool is required'

digest() {
  local result
  result="$("${hash_cmd[@]}" "$1")" || die 'SHA256 digest calculation failed'
  result="${result%% *}"
  [[ "$result" =~ ^[0-9a-f]{64}$ ]] || die 'invalid SHA256 digest output'
  printf 'sha256:%s\n' "$result"
}
api() {
  "$gh_cmd" api "$@" || die 'GitHub API request failed'
}

run_filters=(--raw-field status=success --raw-field per_page=100)
branch=''
if [[ "$APME_SOURCE_REF" == latest ]]; then
  api "repos/$APME_SOURCE_REPO" >"$work/repo.json"
  branch="$(jq -er '.default_branch | strings | select(length > 0)' "$work/repo.json")" || die 'GitHub repository has no default branch'
  run_filters+=(--raw-field "branch=$branch")
else
  run_filters+=(--raw-field "head_sha=$APME_SOURCE_REF")
fi
api "repos/$APME_SOURCE_REPO/actions/runs" --method GET --paginate "${run_filters[@]}" >"$work/runs.json"
# Recheck API filters locally, sort explicitly, and use all pages. Never fall
# back to an older run just because the selected run has unusable artifacts.
run="$(jq -ces --arg ref "$APME_SOURCE_REF" --arg branch "$branch" '
  [.[] | .workflow_runs[]
    | select(.status == "completed" and .conclusion == "success")
    | select(if $ref == "latest" then .head_branch == $branch else .head_sha == $ref end)]
  | if all(.[]; .created_at | if type == "string" then
      test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
      else false end) then . else error("invalid run timestamp") end
  | sort_by([.created_at, .id]) | last | select(. != null)
' "$work/runs.json")" || die "no successful run for $APME_SOURCE_REPO ref $APME_SOURCE_REF"
APME_RUN_ID="$(jq -er '.id | numbers | select(. > 0 and floor == .)' <<<"$run")" || die 'invalid GitHub run ID'
APME_SOURCE_SHA="$(jq -er '.head_sha | strings | select(test("^[0-9a-f]{40}$"))' <<<"$run")" || die 'selected run has an invalid source SHA'
jq -e '.created_at | strings | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' <<<"$run" >/dev/null || die 'selected run has an invalid timestamp'

api "repos/$APME_SOURCE_REPO/actions/runs/$APME_RUN_ID/artifacts" --method GET --paginate --raw-field per_page=100 >"$work/artifacts.json"
candidates="$(jq -ces --arg name "${APME_ARTIFACT_NAME:-}" '
  [.[] | .artifacts[] | select(.expired == false)
    | select(if $name != "" then .name == $name else (.name | test("apme|plugin"; "i")) end)]
' "$work/artifacts.json")" || die 'invalid GitHub artifacts response'
count="$(jq 'length' <<<"$candidates")"
if [[ "$count" != 1 ]]; then
  names="$(jq -rs '[.[] | .artifacts[].name] | tojson' "$work/artifacts.json")" || die 'invalid artifact candidate names'
  die "zero or ambiguous artifact matches ($count) for '${APME_ARTIFACT_NAME:-apme|plugin}'; candidate names (including expired): $names"
fi
artifact="$(jq '.[0]' <<<"$candidates")"
APME_ARTIFACT_ID="$(jq -er '.id | numbers | select(. > 0 and floor == .)' <<<"$artifact")" || die 'invalid GitHub artifact ID'
APME_ARTIFACT_NAME="$(jq -er '.name | strings | select(length > 0 and (contains("\u0000") | not))' <<<"$artifact")" || die 'invalid GitHub artifact name'
zip_digest="$(jq -er '
  if .digest == null then "" else
    .digest | select(type == "string") | select(test("^sha256:[0-9a-f]{64}$"))
  end
' <<<"$artifact")" || die 'invalid GitHub artifact ZIP digest'
api "repos/$APME_SOURCE_REPO/actions/artifacts/$APME_ARTIFACT_ID/zip" >"$work/artifact.zip"
if [[ -n "$zip_digest" ]]; then
  [[ "$(digest "$work/artifact.zip")" == "$zip_digest" ]] || die 'GitHub artifact ZIP digest mismatch'
fi

# Stream only the selected file from the ZIP into our temporary directory.
# No ZIP-controlled path or symlink is ever materialized on the host.
"$unzip_cmd" -Z1 "$work/artifact.zip" >"$work/zip-entries" || die 'invalid artifact ZIP'
safe_paths() {
  local path
  while IFS= read -r path; do
    case "$path" in
      /* | *\\* | ../* | */../* | */.. | ..) die "unsafe archive path: $path" ;;
    esac
  done <"$1"
}
safe_paths "$work/zip-entries"
packs=()
while IFS= read -r entry; do
  [[ "$entry" != *.tar.gz ]] || packs+=("$entry")
done <"$work/zip-entries"
[[ ${#packs[@]} == 1 ]] || die "artifact ZIP must contain exactly one .oci.tar.gz or .tar.gz pack (found ${#packs[@]})"
# unzip -p treats these characters as patterns even when shell-quoted.
case "${packs[0]}" in *['*?[]']*) die 'unsafe wildcard in ZIP pack filename' ;; esac
"$unzip_cmd" -p "$work/artifact.zip" "${packs[0]}" >"$work/plugin-pack.tar.gz" || die 'ZIP plugin pack extraction failed'
APME_PACK_SHA256="$(digest "$work/plugin-pack.tar.gz")"
"$tar_cmd" -tzf "$work/plugin-pack.tar.gz" >"$work/outer-list" || die 'invalid plugin pack archive'
safe_paths "$work/outer-list"

# Use the exact archive spelling (including an optional ./ prefix) for reads.
member() {
  awk -v wanted="$2" '
    function canonical(path, parts, count, i, result) {
      count = split(path, parts, "/")
      result = ""
      for (i = 1; i <= count; i++)
        if (parts[i] != "" && parts[i] != ".")
          result = result (result == "" ? "" : "/") parts[i]
      return result
    }
    BEGIN { wanted = canonical(wanted) }
    canonical($0) == wanted { print }
  ' "$1"
}
read_member() {
  local archive="$1" listing="$2" wanted="$3" match
  match="$(member "$listing" "$wanted")"
  [[ -n "$match" && "$match" != *$'\n'* ]] || die "missing or duplicate archive member: $wanted"
  "$tar_cmd" -xOf "$archive" "$match" || die "unreadable archive member: $wanted"
}
validate_package_identity() {
  local package_json="$1" plugin="$2" scoped="@ansible/${2#ansible-}"
  # Upstream dynamic exports use @ansible/<name>-dynamic; source packages
  # omit -dynamic, and older packs use the flattened ansible-<name> spelling.
  # Match the complete identity, never just a filename, basename, or scope.
  jq -es --arg plugin "$plugin" --arg scoped "$scoped" '
    length == 1 and (.[0] | type == "object" and
      (.name == $plugin or .name == ($plugin + "-dynamic") or
       .name == $scoped or .name == ($scoped + "-dynamic")))
  ' "$package_json" >/dev/null || die "invalid package.json identity for $plugin (expected $scoped or its dynamic/flattened variant)"
}
required_plugins=(
  ansible-plugin-scaffolder-backend-module-backstage-rhaap
  ansible-backstage-plugin-catalog-backend-module-rhaap
  ansible-plugin-backstage-self-service
  ansible-backstage-plugin-auth-backend-module-rhaap-provider
  ansible-plugin-backstage-apme
  ansible-backstage-plugin-catalog-backend-module-apme
)
validate_oci_paths() {
  # Entry types come from tar's verbose listing; names come from its separate
  # name-only listing, so spaces in filenames are not parsed as metadata.
  # Track implicit parents as directories too. With whiteouts and links denied,
  # stable types make the validated package identities survive later layers.
  awk -F '\t' -v roots="${required_plugins[*]}" '
    function conflict(path) {
      print "conflicting OCI filesystem entry: " path > "/dev/stderr"
      exit 1
    }
    BEGIN {
      count = split(roots, names, " ")
      for (i = 1; i <= count; i++) required[names[i]] = 1
    }
    NF != 2 { conflict("invalid typed archive listing") }
    {
      type = $1
      count = split($2, parts, "/")
      path = ""
      root = ""
      for (i = 1; i <= count; i++) {
        if (parts[i] == "" || parts[i] == ".") continue
        if (root == "") root = parts[i]
        if (!(root in required)) break
        if (path != "") {
          if (path in kinds && kinds[path] != "d") conflict(path)
          kinds[path] = "d"
        }
        path = path (path == "" ? "" : "/") parts[i]
      }
      if (!(root in required)) next
      if (type != "d" && type != "-") conflict(path)
      if (path == root && type != "d") conflict(path)
      if (path in kinds && kinds[path] != type) conflict(path)
      kinds[path] = type
    }
  ' "$work/typed-paths" || die 'conflicting OCI filesystem replacements'
}
missing=()
if [[ -n "$(member "$work/outer-list" manifest.json)" || -n "$(member "$work/outer-list" index.json)" ]]; then
  APME_PACK_FORMAT=oci
  if [[ -n "$(member "$work/outer-list" manifest.json)" ]]; then
    read_member "$work/plugin-pack.tar.gz" "$work/outer-list" manifest.json >"$work/manifest.json"
    jq -er '
      select(type == "array" and length == 1) | .[0].Layers
      | select(type == "array" and length > 0)
      | select(all(.[]; type == "string" and length > 0)) | .[]
    ' "$work/manifest.json" >"$work/layers" || die 'invalid or ambiguous OCI/Docker manifest'
  else
    read_member "$work/plugin-pack.tar.gz" "$work/outer-list" index.json >"$work/index.json"
    manifest_digest="$(jq -er '.manifests | select(length == 1) | .[0].digest | strings | select(test("^sha256:[0-9a-f]{64}$"))' "$work/index.json")" || die 'invalid or ambiguous OCI index'
    read_member "$work/plugin-pack.tar.gz" "$work/outer-list" "blobs/sha256/${manifest_digest#sha256:}" >"$work/manifest.json"
    [[ "$(digest "$work/manifest.json")" == "$manifest_digest" ]] || die 'OCI manifest digest mismatch'
    jq -er '
      .layers | select(type == "array" and length > 0)
      | select(all(.[]; .digest | type == "string" and test("^sha256:[0-9a-f]{64}$")))
      | .[].digest | "blobs/sha256/" + ltrimstr("sha256:")
    ' "$work/manifest.json" >"$work/layers" || die 'invalid OCI layers'
  fi
  : >"$work/typed-paths"
  : >"$work/verified-plugins"
  while IFS= read -r layer; do
    [[ "$layer" =~ ^[A-Za-z0-9_./-]+$ ]] || die 'unsafe OCI layer path'
    printf '%s\n' "$layer" >"$work/layer-path"
    safe_paths "$work/layer-path"
    read_member "$work/plugin-pack.tar.gz" "$work/outer-list" "$layer" >"$work/layer.tar"
    if [[ "$layer" =~ ^blobs/sha256/([0-9a-f]{64})$ ]]; then
      expected="sha256:${BASH_REMATCH[1]}"
      [[ "$(digest "$work/layer.tar")" == "$expected" ]] || die 'OCI layer digest mismatch'
    fi
    "$tar_cmd" -tf "$work/layer.tar" >"$work/layer-list" || die 'invalid OCI layer archive'
    safe_paths "$work/layer-list"
    "$tar_cmd" -tvf "$work/layer.tar" >"$work/layer-verbose" || die 'invalid OCI layer entry types'
    cut -c1 "$work/layer-verbose" >"$work/layer-types"
    [[ "$(wc -l <"$work/layer-types")" == "$(wc -l <"$work/layer-list")" ]] || die 'invalid OCI typed archive listing'
    paste "$work/layer-types" "$work/layer-list" >>"$work/typed-paths"
    validate_oci_paths
    # Whiteouts can remove plugins found in an earlier layer. Reject such packs
    # rather than claim completeness from a union of their filenames.
    if grep -Eq '(^|/)\.wh\.' "$work/layer-list"; then die 'unsupported OCI whiteout in plugin pack'; fi
    for plugin in "${required_plugins[@]}"; do
      if [[ -n "$(member "$work/layer-list" "$plugin/package.json")" ]]; then
        read_member "$work/layer.tar" "$work/layer-list" "$plugin/package.json" >"$work/package.json"
        validate_package_identity "$work/package.json" "$plugin"
        printf '%s\n' "$plugin" >>"$work/verified-plugins"
      fi
    done
  done <"$work/layers"
  for plugin in "${required_plugins[@]}"; do
    grep -Fxq "$plugin" "$work/verified-plugins" || missing+=("$plugin")
  done
else
  APME_PACK_FORMAT=npm
  for plugin in "${required_plugins[@]}"; do
    matches=()
    while IFS= read -r entry; do
      base="${entry##*/}"
      case "$base" in "$plugin"-dynamic-*.tgz) matches+=("$entry") ;; esac
    done <"$work/outer-list"
    if [[ ${#matches[@]} == 0 ]]; then
      missing+=("$plugin")
      continue
    fi
    [[ ${#matches[@]} == 1 ]] || die "ambiguous npm packages for $plugin"
    [[ "${matches[0]}" =~ ^[A-Za-z0-9_./-]+$ ]] || die 'unsafe npm package path'
    read_member "$work/plugin-pack.tar.gz" "$work/outer-list" "${matches[0]#./}" >"$work/package.tgz"
    "$tar_cmd" -tzf "$work/package.tgz" >"$work/package-list" || die "invalid npm archive for $plugin"
    safe_paths "$work/package-list"
    read_member "$work/package.tgz" "$work/package-list" package/package.json >"$work/package.json"
    validate_package_identity "$work/package.json" "$plugin"
  done
fi
[[ ${#missing[@]} == 0 ]] || die "missing required plugins: ${missing[*]}"

APME_PACK_FILENAME='plugin-pack.tar.gz'
{
  for key in APME_SOURCE_REPO APME_SOURCE_SHA APME_RUN_ID APME_ARTIFACT_ID APME_ARTIFACT_NAME \
    APME_PACK_FILENAME APME_PACK_FORMAT APME_PACK_SHA256; do
    printf 'export %s=%q\n' "$key" "${!key}"
  done
} >"$work/artifact.env"
mv -- "$work/plugin-pack.tar.gz" "$output/plugin-pack.tar.gz"
# Metadata is the completion marker and is published only after validation.
mv -- "$work/artifact.env" "$output/artifact.env"
printf 'Resolved %s@%s run %s artifact %s (%s, %s)\n' \
  "$APME_SOURCE_REPO" "$APME_SOURCE_SHA" "$APME_RUN_ID" "$APME_ARTIFACT_ID" "$APME_PACK_FORMAT" "$APME_PACK_SHA256"
