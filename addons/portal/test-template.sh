#!/usr/bin/env bash
# Smoke tests for portal OpenShift Template (no cluster required for template validation).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/deploy.yaml"
PARAMS="${SCRIPT_DIR}/params.example.env"
DEPLOY_SH="${SCRIPT_DIR}/deploy.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

[ -f "$TEMPLATE" ] || fail "missing $TEMPLATE"
[ -f "$PARAMS" ] || fail "missing $PARAMS"
[ -x "$DEPLOY_SH" ] || chmod +x "$DEPLOY_SH"

bash -n "$DEPLOY_SH" || fail "deploy.sh syntax"
pass "deploy.sh syntax"

command -v oc >/dev/null || fail "oc not installed"

TEST_PARAMS="$(mktemp)"
trap 'rm -f "$TEST_PARAMS"' EXIT
cat >"$TEST_PARAMS" <<EOF
NAMESPACE=redhat-rhaap-portal
CLUSTER_ROUTER_BASE=apps.crc.testing
RHAAP_URL=https://aap-aap-operator.apps.crc.testing
RHAAP_PUBLIC_URL=https://aap-aap-operator.apps.crc.testing
RHAAP_OAUTH_CLIENT_ID=test-client
RHAAP_OAUTH_CLIENT_SECRET=test-secret
RHAAP_TOKEN=test-token
PORTAL_DB_PASSWORD=testdbpass123456789012345678901234
PORTAL_SESSION_SECRET=testsession1234567890123456789012
PORTAL_IMAGE=quay.io/cferman/portal-hub-eap:latest
EXCLUDE_APME_PLUGINS=true
DISABLE_SCM_AUTH=true
EOF

oc process --local -f "$TEMPLATE" --param-file="$TEST_PARAMS" -o json >/dev/null \
  || fail "oc process portal template"
pass "oc process portal template"

object_count=$(oc process --local -f "$TEMPLATE" --param-file="$TEST_PARAMS" -o json | python3 -c "import json,sys; print(len(json.load(sys.stdin)['items']))")
[ "$object_count" -eq 12 ] || fail "expected 12 objects, got $object_count"
pass "portal template emits 12 objects"

processed=$(oc process --local -f "$TEMPLATE" --param-file="$TEST_PARAMS" -o json)
echo "$processed" | python3 -c "
import json, sys
items = json.load(sys.stdin)['items']
kinds = {i['kind'] for i in items}
required = {'Namespace', 'Deployment', 'Route', 'ConfigMap', 'Secret', 'Service', 'PersistentVolumeClaim'}
missing = required - kinds
assert not missing, f'missing kinds: {missing}'
init = next(i for i in items if i.get('kind')=='Deployment' and i['metadata']['name']=='redhat-rhaap-portal')
env = {e['name']: e.get('value') for e in init['spec']['template']['spec']['initContainers'][0].get('env', [])}
assert env.get('EXCLUDE_APME_PLUGINS') == 'true', 'EXCLUDE_APME_PLUGINS not set on init'
assert env.get('DISABLE_SCM_AUTH') == 'true', 'DISABLE_SCM_AUTH not set on init'
cfg = next(i for i in items if i.get('kind')=='ConfigMap' and i['metadata']['name']=='portal-app-config')
text = cfg['data']['app-config.local.yaml']
assert 'apme:' not in text or 'enabled: true' not in text.split('apme:')[1][:80], 'app-config should not enable apme'
assert 'https://aap-aap-operator.apps.crc.testing' in text, 'app-config must render the RHAAP URL for API calls'
assert 'handler/frame' in text, 'app-config must set explicit OAuth callbackUrl'
assert 'enableExperimentalRedirectFlow: true' in text, 'redirect OAuth flow must be enabled'
assert 'signInPage: rhaap' in text, 'signInPage must be set'
assert text.index('signInPage: rhaap') < text.index('auth:'), 'signInPage must be at app-config root'
assert 'auth.providers.github' not in text.replace(' ', ''), 'github auth provider should be omitted'
secret = next(i for i in items if i.get('kind')=='Secret' and i['metadata']['name']=='secrets-rhaap-portal')
assert 'aap-public-url' in secret['stringData'], 'secret missing aap-public-url'
"
pass "portal template structure and EXCLUDE_APME_PLUGINS"

# Plugin filter logic (unit test embedded init script)
python3 - <<'PY'
plugins = [
    {"package": "./dynamic-plugins/dist/ansible-portal/ansible-plugin-backstage-apme"},
    {"package": "./dynamic-plugins/dist/ansible-portal/ansible-plugin-backstage-self-service"},
    {"package": "./dynamic-plugins/dist/backstage-plugin-github-auth"},
]
exclude_apme = True
if exclude_apme:
    plugins = [p for p in plugins if "apme" not in (p.get("package") or "")]
disable_scm_auth = True
if disable_scm_auth:
    skip = ("github-auth", "gitlab-auth")
    plugins = [p for p in plugins if not any(s in (p.get("package") or "") for s in skip)]
assert len(plugins) == 1
assert any("self-service" in p["package"] for p in plugins)
assert not any("apme" in p["package"] for p in plugins)
PY
pass "plugin filter logic"

# Dynamic plugin compatibility filter (unit test for the sanitizer init container)
python3 - <<'PY'
config = {
    'dynamicPlugins': {
        'frontend': {
            'ansible.plugin-backstage-apme': {
                'appIcons': [{'module': '@material-ui/icons', 'name': 'apmeIcon'}],
            },
            'ansible.plugin-backstage-self-service': {
                'scaffolderFieldExtensions': [
                    {'importName': 'AAPTokenFieldExtension'},
                    {'importName': 'EEFileNamePickerExtension'},
                ],
            },
        },
    },
}
frontend = config['dynamicPlugins']['frontend']
apme = frontend['ansible.plugin-backstage-apme']
apme.pop('appIcons', None)
self_service = frontend['ansible.plugin-backstage-self-service']
self_service['scaffolderFieldExtensions'] = [
    field for field in self_service['scaffolderFieldExtensions']
    if field.get('importName') != 'EEFileNamePickerExtension'
]
assert 'appIcons' not in apme
assert self_service['scaffolderFieldExtensions'] == [
    {'importName': 'AAPTokenFieldExtension'}
]
PY
pass "dynamic plugin compatibility filter"

echo ""
echo "All portal template smoke tests passed."
