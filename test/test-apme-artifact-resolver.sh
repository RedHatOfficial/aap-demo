#!/usr/bin/env bash
# Offline resolver contract tests. Only GitHub and ZIP transport are stubbed;
# jq selection, tar inspection, checksums, and sourcing metadata run for real.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
resolver="${repo_root}/addons/apme-eap/ci/fetch-plugin-artifact.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
export FIXTURE_DIR="$work" API_LOG="$work/api.log"
export APME_GH_CMD="$work/bin/gh" APME_UNZIP_CMD="$work/bin/unzip"
export GH_TOKEN=offline-test-token
export APME_SOURCE_REPO=ansible/ansible-rhdh-plugins
plugins=(
  ansible-plugin-scaffolder-backend-module-backstage-rhaap
  ansible-backstage-plugin-catalog-backend-module-rhaap
  ansible-plugin-backstage-self-service
  ansible-backstage-plugin-auth-backend-module-rhaap-provider
  ansible-plugin-backstage-apme
  ansible-backstage-plugin-catalog-backend-module-apme
)

cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == api && -n "${GH_TOKEN:-}" ]] || exit 91
shift
endpoint="$1"
shift
printf '%s\n' "$endpoint" >>"$API_LOG"
[[ "${API_FAIL:-}" != yes ]] || exit 92
case "$endpoint" in
  repos/ansible/ansible-rhdh-plugins | repos/ansible/apme)
    printf '{"default_branch":"%s"}\n' "${DEFAULT_BRANCH:-main}"
    ;;
  repos/*/actions/runs)
    [[ " $* " == *' --paginate '* && " $* " == *' --method GET '* ]] || exit 93
    # Emit two API pages, deliberately leaving the newest run on page two.
    jq '{workflow_runs: .workflow_runs[:3]}' "$FIXTURE_DIR/runs.json"
    jq '{workflow_runs: .workflow_runs[3:]}' "$FIXTURE_DIR/runs.json"
    ;;
  repos/*/actions/runs/*/artifacts)
    [[ " $* " == *' --paginate '* ]] || exit 94
    jq '{artifacts: .artifacts[:2]}' "$FIXTURE_DIR/artifacts.json"
    jq '{artifacts: .artifacts[2:]}' "$FIXTURE_DIR/artifacts.json"
    ;;
  repos/*/actions/artifacts/*/zip)
    if [[ -n "${ZIP_PAYLOAD:-}" ]]; then cat "$ZIP_PAYLOAD"; else printf 'fixture ZIP bytes'; fi
    ;;
  *) printf 'Unexpected endpoint: %s\n' "$endpoint" >&2; exit 95 ;;
esac
STUB
cat >"$work/bin/unzip" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "${UNZIP_FAIL:-}" != yes ]] || exit 96
case "$1" in
  -Z1) cat "$FIXTURE_DIR/zip-entries" ;;
  -p)
    [[ "$3" == "${PACK_ENTRY:-nested/plugins.oci.tar.gz}" ]] || exit 97
    cat "$FIXTURE_DIR/pack.tar.gz"
    ;;
  *) exit 98 ;;
esac
STUB
cat >"$work/bin/bad-hash" <<'STUB'
#!/usr/bin/env bash
printf 'invalid-digest\n'
STUB
chmod +x "$work/bin/gh" "$work/bin/unzip" "$work/bin/bad-hash"

make_pack() {
  local format="$1" count="${2:-6}" plugin i
  export APME_PACK_FORMAT="$format"
  rm -rf "$work/pack" "$work/layer" "$work/npm"
  mkdir -p "$work/pack" "$work/layer" "$work/npm/package"
  for ((i = 0; i < count; i++)); do
    plugin="${plugins[$i]}"
    if [[ "$format" == oci ]]; then
      mkdir -p "$work/layer/$plugin"
      printf '{"name":"%s"}\n' "$plugin" >"$work/layer/$plugin/package.json"
    else
      printf '{"name":"%s"}\n' "$plugin" >"$work/npm/package/package.json"
      tar -czf "$work/pack/${plugin}-dynamic-1.0.0.tgz" -C "$work/npm" package
    fi
  done
  if [[ "$format" == oci ]]; then
    tar -cf "$work/pack/layer.tar" -C "$work/layer" .
    printf '[{"Layers":["layer.tar"]}]\n' >"$work/pack/manifest.json"
  fi
  tar -czf "$work/pack.tar.gz" -C "$work/pack" .
}

reset_case() {
  cp "$repo_root/test/fixtures/apme-artifact-runs.json" "$work/runs.json"
  cp "$repo_root/test/fixtures/apme-artifacts.json" "$work/artifacts.json"
  : >"$API_LOG"
  rm -rf "$work/output with spaces"
  export APME_SOURCE_REF=latest APME_SOURCE_REPO=ansible/ansible-rhdh-plugins
  unset APME_ARTIFACT_NAME APME_SHA256_CMD API_FAIL UNZIP_FAIL DEFAULT_BRANCH PACK_ENTRY
  unset ZIP_PAYLOAD APME_PACK_FORMAT
  export APME_UNZIP_CMD="$work/bin/unzip"
  printf 'nested/plugins.oci.tar.gz\nreadme.txt\n' >"$work/zip-entries"
  make_pack oci
  unset APME_PACK_FORMAT
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}
assert_equal() { [[ "$1" == "$2" ]] || fail "expected '$1', got '$2'"; }
assert_log() { grep -Fq "$1" "$API_LOG" || fail "missing API request: $1"; }
run_success() {
  bash "$resolver" "$work/output with spaces" >"$work/stdout" 2>"$work/stderr" || {
    cat "$work/stderr" >&2
    fail 'resolver rejected a valid artifact'
  }
  [[ ! -s "$work/stderr" ]] || fail "unexpected stderr: $(cat "$work/stderr")"
  [[ -f "$work/output with spaces/plugin-pack.tar.gz" ]] || fail 'normalized pack missing'
  cmp "$work/pack.tar.gz" "$work/output with spaces/plugin-pack.tar.gz" || fail 'pack bytes changed'
  # Verify all eight values are exported, not merely assigned in the shell.
  # shellcheck disable=SC2016 # $1 must be expanded by the clean child shell.
  env -i PATH="$PATH" bash -c 'source "$1"; env' _ "$work/output with spaces/artifact.env" >"$work/exported"
  local key
  for key in APME_SOURCE_REPO APME_SOURCE_SHA APME_RUN_ID APME_ARTIFACT_ID APME_ARTIFACT_NAME \
    APME_PACK_FILENAME APME_PACK_FORMAT APME_PACK_SHA256; do
    grep -q "^${key}=" "$work/exported" || fail "$key is not exported"
  done
  # shellcheck disable=SC1091
  source "$work/output with spaces/artifact.env"
  assert_equal plugin-pack.tar.gz "$APME_PACK_FILENAME"
  assert_equal "sha256:$(shasum -a 256 "$work/pack.tar.gz" | cut -d ' ' -f 1)" "$APME_PACK_SHA256"
}
run_failure() {
  local expected="$1"
  if bash "$resolver" "$work/output with spaces" >"$work/stdout" 2>"$work/stderr"; then
    fail "resolver accepted invalid input ($expected)"
  fi
  grep -Fqi "$expected" "$work/stderr" || fail "missing diagnostic '$expected': $(cat "$work/stderr")"
  [[ ! -e "$work/output with spaces/artifact.env" ]] || fail 'failure left usable metadata'
  [[ ! -e "$work/output with spaces/plugin-pack.tar.gz" ]] || fail 'failure left a usable pack'
}
update_artifacts() {
  jq "$1" "$work/artifacts.json" >"$work/updated.json"
  mv "$work/updated.json" "$work/artifacts.json"
}
update_runs() {
  jq "$1" "$work/runs.json" >"$work/updated.json"
  mv "$work/updated.json" "$work/runs.json"
}
passed=0
pass() {
  passed=$((passed + 1))
  printf 'PASS: %s\n' "$1"
}

rewrite_identity() {
  local format="$1" json="$2" plugin="${plugins[4]}"
  if [[ "$format" == npm ]]; then
    printf '%s\n' "$json" >"$work/npm/package/package.json"
    tar -czf "$work/pack/${plugin}-dynamic-1.0.0.tgz" -C "$work/npm" package
  else
    printf '%s\n' "$json" >"$work/layer/$plugin/package.json"
    tar -cf "$work/pack/layer.tar" -C "$work/layer" .
  fi
  tar -czf "$work/pack.tar.gz" -C "$work/pack" .
}

review_identity_tests() {
  local format json name
  for format in npm oci; do
    for json in '{"name":"unrelated-package"}' '{}' '{"name":"@other/plugin-backstage-apme-dynamic"}'; do
      reset_case
      make_pack "$format"
      rewrite_identity "$format" "$json"
      run_failure 'identity'
      pass "$format rejects incorrect or missing package identity: $json"
    done
    for name in '@ansible/plugin-backstage-apme-dynamic' '@ansible/plugin-backstage-apme' 'ansible-plugin-backstage-apme-dynamic'; do
      reset_case
      make_pack "$format"
      rewrite_identity "$format" "{\"name\":\"$name\"}"
      run_success
      pass "$format accepts the expected upstream identity: $name"
    done
  done
}

add_replacement_layer() {
  tar -cf "$work/pack/replacement.tar" -C "$work/replacement" .
  printf '[{"Layers":["layer.tar","replacement.tar"]}]\n' >"$work/pack/manifest.json"
  tar -czf "$work/pack.tar.gz" -C "$work/pack" .
}

review_layer_tests() {
  local plugin="${plugins[4]}"
  reset_case
  mkdir -p "$work/replacement"
  printf 'replacement file\n' >"$work/replacement/$plugin"
  add_replacement_layer
  run_failure 'conflicting OCI'
  pass 'later regular file cannot replace a required OCI plugin directory'

  reset_case
  rm -rf "$work/replacement"
  mkdir -p "$work/replacement/$plugin/package.json"
  add_replacement_layer
  run_failure 'conflicting OCI'
  pass 'later directory cannot replace the validated OCI package.json file'

  reset_case
  rm -rf "$work/replacement"
  mkdir -p "$work/replacement"
  ln -s "${plugins[0]}" "$work/replacement/$plugin"
  add_replacement_layer
  run_failure 'conflicting OCI'
  pass 'later symlink cannot replace a required OCI plugin directory'

  reset_case
  # The original layer deliberately omits all directory entries.
  tar -cf "$work/pack/layer.tar" -C "$work/layer" "${plugins[@]/%//package.json}"
  rm -rf "$work/replacement"
  mkdir -p "$work/replacement"
  printf 'replacement file\n' >"$work/replacement/$plugin"
  add_replacement_layer
  run_failure 'conflicting OCI'
  pass 'implicit parent directories are protected against later OCI file replacements'

  reset_case
  mkdir -p "$work/layer/$plugin/dist"
  printf 'plugin code\n' >"$work/layer/$plugin/dist/index.js"
  tar -cf "$work/pack/layer.tar" -C "$work/layer" .
  rm -rf "$work/replacement"
  mkdir -p "$work/replacement/$plugin"
  printf 'replacement file\n' >"$work/replacement/$plugin/dist"
  add_replacement_layer
  run_failure 'conflicting OCI'
  pass 'later regular file cannot replace an OCI plugin subdirectory'

  reset_case
  rm -rf "$work/replacement"
  mkdir -p "$work/replacement/$plugin"
  printf '{"name":"unrelated-package"}\n' >"$work/replacement/$plugin/package.json"
  add_replacement_layer
  run_failure 'identity'
  pass 'later OCI package.json replacements must retain the expected identity'

  reset_case
  rm -rf "$work/replacement"
  mkdir -p "$work/replacement"
  printf 'replacement file\n' >"$work/replacement/$plugin"
  tar -cf "$work/pack/replacement.tar" -C "$work/replacement" "././$plugin"
  printf '[{"Layers":["layer.tar","replacement.tar"]}]\n' >"$work/pack/manifest.json"
  tar -czf "$work/pack.tar.gz" -C "$work/pack" .
  run_failure 'conflicting OCI'
  pass 'dot path aliases cannot hide OCI directory replacements'

  reset_case
  rm -rf "$work/replacement"
  mkdir -p "$work/replacement/$plugin"
  printf '{"name":"@ansible/plugin-backstage-apme-dynamic"}\n' >"$work/replacement/$plugin/package.json"
  add_replacement_layer
  run_success
  pass 'compatible directory merges and valid regular-file updates remain supported'
}

# These groups let review regressions reproduce independently before either fix.
case "${APME_RESOLVER_TEST_GROUP:-all}" in
  identity)
    review_identity_tests
    printf 'PASS: %s identity regression tests\n' "$passed"
    exit
    ;;
  layers)
    review_layer_tests
    printf 'PASS: %s layer regression tests\n' "$passed"
    exit
    ;;
  all)
    review_identity_tests
    review_layer_tests
    ;;
  *) fail 'unknown resolver test group' ;;
esac

reset_case
run_success
assert_equal 301 "$APME_ARTIFACT_ID"
pass 'default OCI selection ignores simultaneous npm packs and Docker/image records'

reset_case
make_pack npm
run_success
assert_equal 306 "$APME_ARTIFACT_ID"
pass 'npm format selects the npm tarball when both pack formats are present'

reset_case
export APME_PACK_FORMAT=invalid
run_failure 'oci or npm'
pass 'invalid requested format fails with the allowed values'

for format in oci npm; do
  reset_case
  make_pack "$format"
  export ZIP_PAYLOAD="$work/pack.tar.gz" UNZIP_FAIL=yes
  payload_hash="$(shasum -a 256 "$ZIP_PAYLOAD" | cut -d ' ' -f 1)"
  export payload_hash
  update_artifacts '(.artifacts[] | select(.id == 301 or .id == 306)).digest = ("sha256:" + env.payload_hash)'
  run_success
  assert_equal "$format" "$APME_PACK_FORMAT"
  pass "raw $format gzip artifact verifies transport digest without invoking unzip"
done

reset_case
export ZIP_PAYLOAD="$work/pack.tar.gz"
update_artifacts '.artifacts[2].digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000"'
run_failure digest
pass 'raw gzip transport still rejects a mismatched GitHub digest'

reset_case
make_pack oci 4
export ZIP_PAYLOAD="$work/pack.tar.gz"
run_failure 'ansible-plugin-backstage-apme'
pass 'raw gzip transport still requires all six plugins'

reset_case
update_artifacts '.artifacts[2].digest = false'
run_failure 'digest'
pass 'a boolean digest is malformed metadata, not an absent legacy digest'

reset_case
update_artifacts '.artifacts[2].digest = ""'
run_failure 'digest'
pass 'an explicitly empty artifact digest is rejected'

reset_case
run_success
assert_equal 30 "$APME_RUN_ID"
assert_equal 3333333333333333333333333333333333333333 "$APME_SOURCE_SHA"
assert_equal 301 "$APME_ARTIFACT_ID"
assert_equal oci "$APME_PACK_FORMAT"
assert_log repos/ansible/ansible-rhdh-plugins/actions/runs/30/artifacts
assert_log repos/ansible/ansible-rhdh-plugins/actions/artifacts/301/zip
pass 'latest chooses newest successful default-branch run across API pages and emits verified OCI metadata'

reset_case
export APME_SOURCE_REF=1111111111111111111111111111111111111111
run_success
assert_equal 20 "$APME_RUN_ID"
assert_equal 1111111111111111111111111111111111111111 "$APME_SOURCE_SHA"
assert_log repos/ansible/ansible-rhdh-plugins/actions/runs/20/artifacts
pass 'exact SHA chooses newest matching successful run, including nondefault branches'

reset_case
export DEFAULT_BRANCH=release
run_success
assert_equal 20 "$APME_RUN_ID"
pass 'latest discovers the actual default branch'

reset_case
export APME_SOURCE_REPO=ansible/apme
run_success
assert_log repos/ansible/apme/actions/artifacts/301/zip
assert_equal ansible/apme "$APME_SOURCE_REPO"
pass 'supports configurable upstream repository'

reset_case
export PACK_ENTRY=nested/plugins.tar.gz
printf '%s\n' "$PACK_ENTRY" >"$work/zip-entries"
make_pack npm
run_success
assert_equal npm "$APME_PACK_FORMAT"
pass 'normalizes a plain tar.gz containing six npm packages and emits its checksum'

reset_case
export APME_ARTIFACT_NAME="release pack; '\$(touch SHOULD_NOT_EXIST)"
update_artifacts '.artifacts[2].name = env.APME_ARTIFACT_NAME'
run_success
assert_equal "release pack; '\$(touch SHOULD_NOT_EXIST)" "$APME_ARTIFACT_NAME"
[[ ! -e SHOULD_NOT_EXIST ]] || fail 'metadata executed shell content'
pass 'exact artifact names round-trip safely through sourced shell metadata'

reset_case
update_artifacts '.artifacts[2].expired = true'
run_failure 'candidate'
pass 'expired and unknown-expiry artifacts are rejected'

reset_case
export APME_ARTIFACT_NAME=apme-expired
run_failure apme-expired
pass 'an explicit artifact name cannot select an expired artifact'

reset_case
update_artifacts '.artifacts += [{id: 305, name: "plugins-other-oci", expired: false, created_at: "2026-10-21T10:00:00Z", digest: null}]'
run_failure ambiguous
grep -Fq early-access-plugins "$work/stderr" || fail 'first candidate absent from diagnostic'
grep -Fq plugins-other "$work/stderr" || fail 'second candidate absent from diagnostic'
grep -Fq APME_ARTIFACT_NAME "$work/stderr" || fail 'ambiguity must explain the exact-name override'
pass 'ambiguous selection reports all matching names'

reset_case
export APME_ARTIFACT_NAME=not-present
run_failure not-present
grep -Fq early-access-plugins "$work/stderr" || fail 'available candidates absent from diagnostic'
pass 'missing exact artifact reports available candidate names'

reset_case
update_runs '.workflow_runs = []'
run_failure 'run'
pass 'no successful run fails closed'

reset_case
export APME_SOURCE_REF=3333333
run_failure 'SHA'
pass 'abbreviated SHA is rejected'

reset_case
export APME_SOURCE_REF=4444444444444444444444444444444444444444
run_failure 'run'
pass 'exact SHA never falls back to a different commit'

reset_case
update_runs '(.workflow_runs[] | select(.id == 30)).head_sha = null'
run_failure 'SHA'
pass 'missing source SHA on the newest run cannot fall back to an older run'

reset_case
export API_FAIL=yes
run_failure 'GitHub'
pass 'API failures are fatal'

reset_case
export UNZIP_FAIL=yes
run_failure 'ZIP'
pass 'invalid ZIP or extraction failure is fatal'

reset_case
printf 'readme.txt\n' >"$work/zip-entries"
run_failure 'exactly one'
pass 'ZIP without a pack is rejected'

reset_case
printf 'one.oci.tar.gz\ntwo.tar.gz\n' >"$work/zip-entries"
run_failure 'exactly one'
pass 'multiple plugin packs are rejected'

reset_case
printf '../plugins.tar.gz\n' >"$work/zip-entries"
run_failure 'unsafe'
pass 'ZIP traversal names are rejected before extraction'

reset_case
printf 'broken gzip' >"$work/pack.tar.gz"
run_failure 'archive'
pass 'corrupt plugin pack is rejected'

reset_case
make_pack npm 4
run_failure 'ansible-plugin-backstage-apme'
grep -Fq ansible-backstage-plugin-catalog-backend-module-apme "$work/stderr" || fail 'second missing plugin absent'
pass 'four-plugin npm artifact clearly identifies both missing APME plugins'

reset_case
make_pack oci 4
run_failure 'ansible-plugin-backstage-apme'
pass 'four-plugin OCI artifact fails closed'

reset_case
export APME_SHA256_CMD="$work/bin/bad-hash"
run_failure 'digest'
pass 'malformed checksum output is rejected'

reset_case
update_artifacts '.artifacts[2].digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000"'
run_failure 'digest'
pass 'GitHub artifact ZIP digest mismatch is rejected'

reset_case
zip_hash="$(printf 'fixture ZIP bytes' | shasum -a 256 | cut -d ' ' -f 1)"
export zip_hash
update_artifacts '.artifacts[2].digest = ("sha256:" + env.zip_hash)'
run_success
pass 'GitHub ZIP digest is verified independently of the normalized pack digest'

reset_case
run_success
update_artifacts '.artifacts = []'
run_failure 'candidate'
pass 'a failed rerun removes stale success outputs'

reset_case
printf '[{"Layers":["layer.tar", null]}]\n' >"$work/pack/manifest.json"
tar -czf "$work/pack.tar.gz" -C "$work/pack" .
run_failure 'manifest'
pass 'OCI manifest cannot silently discard malformed layer entries'

reset_case
printf 'not JSON\n' >"$work/layer/${plugins[0]}/package.json"
tar -cf "$work/pack/layer.tar" -C "$work/layer" .
tar -czf "$work/pack.tar.gz" -C "$work/pack" .
run_failure 'package.json'
pass 'OCI plugin names alone cannot disguise invalid plugin content'

reset_case
make_pack npm
printf 'not a package\n' >"$work/pack/${plugins[0]}-dynamic-1.0.0.tgz"
tar -czf "$work/pack.tar.gz" -C "$work/pack" .
run_failure 'npm archive'
pass 'npm package names alone cannot disguise a corrupt inner archive'

reset_case
make_pack npm
cp "$work/pack/${plugins[0]}-dynamic-1.0.0.tgz" "$work/pack/${plugins[0]}-dynamic-2.0.0.tgz"
tar -czf "$work/pack.tar.gz" -C "$work/pack" .
run_failure 'ambiguous npm'
pass 'multiple versions of the same required npm plugin are rejected'

reset_case
printf '[{"Layers":["missing.tar"]}]\n' >"$work/pack/manifest.json"
tar -czf "$work/pack.tar.gz" -C "$work/pack" .
run_failure 'member'
pass 'OCI manifests must refer to existing layers'

reset_case
printf 'nested/plugins[1].tar.gz\n' >"$work/zip-entries"
run_failure 'unsafe'
pass 'unzip wildcard patterns cannot select ambiguous archive entries'

reset_case
unset GH_TOKEN
run_failure GH_TOKEN
export GH_TOKEN=offline-test-token
pass 'missing GitHub credentials fail before API access'

reset_case
unset APME_SOURCE_REPO APME_SOURCE_REF
run_success
assert_equal ansible/ansible-rhdh-plugins "$APME_SOURCE_REPO"
assert_equal 30 "$APME_RUN_ID"
pass 'default source repository and latest selection match the publishing plan'

reset_case
cp "$repo_root/addons/apme-eap/plugin_packs/apme-prototype-plugins-8593383-20260718025043.oci.tar.gz" "$work/pack.tar.gz"
run_success
assert_equal oci "$APME_PACK_FORMAT"
pass 'checked-in real six-plugin OCI pack passes layer inspection and digest checks'

make_oci_layout() {
  local config_hash manifest_hash
  mkdir -p "$work/pack/blobs/sha256"
  oci_layer_hash="$(shasum -a 256 "$work/pack/layer.tar" | cut -d ' ' -f 1)"
  mv "$work/pack/layer.tar" "$work/pack/blobs/sha256/$oci_layer_hash"
  printf '{}\n' >"$work/config.json"
  config_hash="$(shasum -a 256 "$work/config.json" | cut -d ' ' -f 1)"
  cp "$work/config.json" "$work/pack/blobs/sha256/$config_hash"
  jq -n --arg layer "$oci_layer_hash" --arg config "$config_hash" --argjson bad "${1:-false}" \
    '{schemaVersion: 2, config: {digest: ("sha256:" + $config)}, layers: [{digest: ("sha256:" + $layer)}]}
     | if $bad then .layers = [null] + .layers else . end' >"$work/oci-manifest.json"
  manifest_hash="$(shasum -a 256 "$work/oci-manifest.json" | cut -d ' ' -f 1)"
  cp "$work/oci-manifest.json" "$work/pack/blobs/sha256/$manifest_hash"
  jq -n --arg hash "$manifest_hash" '{schemaVersion: 2, manifests: [{digest: ("sha256:" + $hash)}]}' >"$work/pack/index.json"
  rm "$work/pack/manifest.json"
  tar -czf "$work/pack.tar.gz" -C "$work/pack" .
}

reset_case
make_oci_layout
run_success
assert_equal oci "$APME_PACK_FORMAT"
pass 'pure OCI layout follows and verifies manifest and layer digests'

reset_case
make_oci_layout
printf 'corruption\n' >>"$work/pack/blobs/sha256/$oci_layer_hash"
tar -czf "$work/pack.tar.gz" -C "$work/pack" .
run_failure 'digest'
pass 'pure OCI layer content must match its descriptor digest'

reset_case
make_oci_layout true
run_failure 'layers'
pass 'pure OCI descriptors cannot silently discard invalid layer entries'

reset_case
update_runs '(.workflow_runs[] | select(.id == 30)).created_at = null'
run_failure 'run'
pass 'an invalid run timestamp cannot silently cause an older run to be selected'

reset_case
zip -q -j "$work/transport.zip" "$work/pack.tar.gz"
export ZIP_PAYLOAD="$work/transport.zip" APME_UNZIP_CMD=unzip
run_success
pass 'real ZIP transport extracts the selected pack without changing its bytes'

printf 'PASS: %s resolver tests\n' "$passed"
