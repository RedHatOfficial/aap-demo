#!/usr/bin/env bash
# Configure Keycloak as an OIDC provider for local AAP and AO instances.
# Dev/test only. Dry-run unless --apply is supplied.

set -euo pipefail

KEYCLOAK_NAMESPACE="${KEYCLOAK_NAMESPACE:-aap-demo-keycloak}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-aap-lab}"
STATE_DIR="${KEYCLOAK_STATE_DIR:-${HOME}/.aap-demo/keycloak}"
NAMESPACE="${NAMESPACE:-aap-operator}"
TARGET="all"
APPLY=false
MAP_GROUPS=false

usage() {
  cat <<'EOF'
Usage: aap-demo keycloak configure [--target aap|ao|all] [--map-groups] [--apply]

Configure local Keycloak OIDC consumers. Dry-run is default.
--apply       Create or update consumer configuration
--target      Configure aap, ao, or both (default: all)
--map-groups  Align Keycloak groups with AO groups and AAP authenticator maps
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required command not found: $1" >&2; exit 1; }
}

for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=true ;;
    --map-groups) MAP_GROUPS=true ;;
    --target=*) TARGET="${arg#*=}" ;;
    --target) : ;;
    -h|--help) usage; exit 0 ;;
    *)
      if [ "${previous_arg:-}" = "--target" ]; then TARGET="$arg";
      else echo "ERROR: unknown argument: $arg" >&2; usage >&2; exit 1; fi
      ;;
  esac
  previous_arg="$arg"
done

case "$TARGET" in aap|ao|all) ;; *) echo "ERROR: --target must be aap, ao, or all" >&2; exit 1 ;; esac

for cmd in kubectl jq curl; do require_cmd "$cmd"; done
[ -s "$STATE_DIR/aap-client-secret" ] || { echo "ERROR: missing $STATE_DIR/aap-client-secret; enable Keycloak first" >&2; exit 1; }
[ -s "$STATE_DIR/ao-client-secret" ] || { echo "ERROR: missing $STATE_DIR/ao-client-secret; enable Keycloak first" >&2; exit 1; }

read_secret() { tr -d '\r\n' < "$1"; }

route_host() {
  kubectl get route "$1" -n "$2" -o jsonpath='{.spec.host}' 2>/dev/null || true
}

KEYCLOAK_HOST="$(route_host keycloak "$KEYCLOAK_NAMESPACE")"
[ -n "$KEYCLOAK_HOST" ] || { echo "ERROR: Keycloak route not found; run: aap-demo enable keycloak" >&2; exit 1; }
ISSUER="https://${KEYCLOAK_HOST}/realms/${KEYCLOAK_REALM}"

PUBLIC_KEY="$(curl -skf "${ISSUER}" | jq -r '.public_key // empty')"
[ -n "$PUBLIC_KEY" ] || { echo "ERROR: Keycloak realm public key unavailable" >&2; exit 1; }

AAP_HOST="$(route_host aap "$NAMESPACE")"
AO_HOST="$(kubectl get route -n automation-orchestrator -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)"

[ "$TARGET" = ao ] || [ -n "$AAP_HOST" ] || { echo "ERROR: AAP route not found in namespace $NAMESPACE" >&2; exit 1; }
[ "$TARGET" = aap ] || [ -n "$AO_HOST" ] || { echo "ERROR: AO route not found" >&2; exit 1; }

AAP_NAME="${KEYCLOAK_AAP_AUTHENTICATOR_NAME:-Keycloak lab}"
AO_NAME="${KEYCLOAK_AO_PROVIDER_NAME:-Keycloak lab}"
AAP_SECRET="$(read_secret "$STATE_DIR/aap-client-secret")"
AO_SECRET="$(read_secret "$STATE_DIR/ao-client-secret")"

AAP_PAYLOAD="$(jq -nc \
  --arg name "$AAP_NAME" --arg issuer "$ISSUER" --arg key "$AAP_SECRET" --arg public_key "$PUBLIC_KEY" \
  '{name:$name,enabled:true,create_objects:true,remove_users:false,type:"ansible_base.authentication.authenticator_plugins.keycloak",configuration:{ACCESS_TOKEN_URL:($issuer+"/protocol/openid-connect/token"),AUTHORIZATION_URL:($issuer+"/protocol/openid-connect/auth"),GROUPS_CLAIM:"groups",KEY:"aap-demo-aap",PUBLIC_KEY:$public_key,SECRET:$key}}')"

AO_PAYLOAD="$(jq -nc \
  --arg name "$AO_NAME" --arg issuer "$ISSUER" --arg client_secret "$AO_SECRET" --arg redirect "https://${AO_HOST}/api/v1/auth/oidc/callback" \
  '{name:$name,enabled:true,configuration:{provider_type:"oidc",idp_type:"custom",auto_discovery:true,issuer_url:$issuer,client_id:"aap-demo-ao",client_secret:$client_secret,redirect_uri:$redirect,scopes:"openid profile email groups",claim_mapping:{subject:"sub",email:"email",username:"preferred_username",first_name:"given_name",last_name:"family_name"},group_jmespath_expression:"groups[*]",group_mapping_entries:[],allow_all_authenticated:true,enable_rp_initiated_logout:true,disable_tls_verify:true}}')"

print_plan() {
  echo "Keycloak OIDC configuration plan"
  echo "  Issuer: ${ISSUER}"
  [ "$TARGET" = ao ] || echo "  AAP: ${AAP_HOST} (${AAP_NAME})"
  [ "$TARGET" = aap ] || echo "  AO:  ${AO_HOST} (${AO_NAME})"
  if [ "$APPLY" != true ]; then
    echo "  Mode: dry-run (use --apply to create or update)"
  else
    echo "  Mode: apply"
  fi
  [ "$MAP_GROUPS" = true ] && echo "  Group mapping: enabled"
}

print_plan
[ "$APPLY" = true ] || exit 0

if [ "$TARGET" != ao ]; then
  AAP_PASSWORD="$(kubectl get secret aap-admin-password -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)"
  AAP_AUTH="$(mktemp "${TMPDIR:-/tmp}/aap-demo-curl.XXXXXX")"
  chmod 600 "$AAP_AUTH"
  trap 'rm -f "$AAP_AUTH"' EXIT
  printf 'user = "admin:%s"\n' "$AAP_PASSWORD" > "$AAP_AUTH"
  AAP_BASE="https://${AAP_HOST}/api/gateway/v1/authenticators/"
  AAP_LIST="$(curl -skf "$AAP_BASE" --config "$AAP_AUTH" 2>/dev/null || true)"
  AAP_ID="$(printf '%s' "$AAP_LIST" | jq -r --arg n "$AAP_NAME" '(.results // .authenticators // [])[] | select(.name==$n) | .id' | head -n1)"
  if [ -n "$AAP_ID" ]; then
    curl -skf -X PATCH "${AAP_BASE}${AAP_ID}/" --config "$AAP_AUTH" -H 'Content-Type: application/json' -d "$AAP_PAYLOAD" >/dev/null
    echo "✓ Updated AAP authenticator: ${AAP_NAME}"
  else
    curl -skf -X POST "$AAP_BASE" --config "$AAP_AUTH" -H 'Content-Type: application/json' -d "$AAP_PAYLOAD" >/dev/null
    echo "✓ Created AAP authenticator: ${AAP_NAME}"
  fi
  echo "  Update Keycloak client redirect URI with callback shown by AAP Gateway, if required."

  if [ "$MAP_GROUPS" = true ]; then
    AAP_MAP_BASE="https://${AAP_HOST}/api/gateway/v1/authenticator_maps/"
    AAP_GROUP_MAPS=(
      "aap-admins|is_superuser|||true"
      "aap-auditors|role|Platform Auditor||false"
      "aap-operators|organization|Organization Admin|AAP Demo|false"
      "aap-developers|organization|Organization Member|AAP Demo|false"
    )
    AAP_MAP_LIST="$(curl -skf "$AAP_MAP_BASE?authenticator=${AAP_ID}" --config "$AAP_AUTH")"
    for map_spec in "${AAP_GROUP_MAPS[@]}"; do
      IFS='|' read -r group map_type role organization revoke <<<"$map_spec"
      map_name="Keycloak ${group}"
      map_payload="$(jq -nc --arg name "$map_name" --arg group "$group" --arg type "$map_type" --arg role "$role" --arg organization "$organization" --argjson authenticator "$AAP_ID" --argjson revoke "$revoke" \
        '{name:$name,authenticator:$authenticator,map_type:$type,triggers:{groups:{has_or:[$group]}},role:(if $role=="" then null else $role end),organization:(if $organization=="" then null else $organization end),team:null,revoke:$revoke}')"
      map_id="$(printf '%s' "$AAP_MAP_LIST" | jq -r --arg name "$map_name" '.results[] | select(.name==$name) | .id' | head -n1)"
      if [ -n "$map_id" ]; then
        curl -skf -X PATCH "${AAP_MAP_BASE}${map_id}/" --config "$AAP_AUTH" -H 'Content-Type: application/json' -d "$map_payload" >/dev/null
        echo "✓ Updated AAP group map: ${group}"
      else
        curl -skf -X POST "$AAP_MAP_BASE" --config "$AAP_AUTH" -H 'Content-Type: application/json' -d "$map_payload" >/dev/null
        echo "✓ Created AAP group map: ${group}"
      fi
    done
  fi
fi

if [ "$TARGET" != aap ]; then
  AO_PASSWORD="$(kubectl get secret automation-orchestrator-initial-admin-password -n automation-orchestrator -o jsonpath='{.data.password}' | base64 -d)"
  CSRF="$(curl -sk "https://${AO_HOST}/api/v1/auth/csrf_token" | jq -r .csrf_token)"
  AO_TOKEN="$(curl -sk -X POST "https://${AO_HOST}/api/v1/auth/login" -H 'Content-Type: application/json' -H "X-CSRF-Token: ${CSRF}" -d "$(jq -nc --arg p "$AO_PASSWORD" '{username:"admin",password:$p}')" | jq -r .access_token)"
  [ -n "$AO_TOKEN" ] && [ "$AO_TOKEN" != null ] || { echo "ERROR: AO admin login failed" >&2; exit 1; }
  AO_BASE="https://${AO_HOST}/api/v1/identity_providers"
  AO_LIST="$(curl -skf "$AO_BASE" -H "Authorization: Bearer ${AO_TOKEN}")"
  AO_GROUP_LIST="$(curl -skf "https://${AO_HOST}/api/v1/groups" -H "Authorization: Bearer ${AO_TOKEN}")"
  AO_ID="$(printf '%s' "$AO_LIST" | jq -r --arg n "$AO_NAME" '.resources[] | select(.name==$n) | .id' | head -n1)"
  if [ -n "$AO_ID" ]; then
    if [ "$MAP_GROUPS" = true ]; then
      AO_GROUPS_PAYLOAD='[]'
      for group in aap-admins aap-operators aap-auditors aap-developers; do
        group_id="$(printf '%s' "$AO_GROUP_LIST" | jq -r --arg name "$group" '.resources[] | select(.name==$name) | .id' | head -n1)"
        if [ -z "$group_id" ]; then
          group_id="$(curl -skf -X POST "https://${AO_HOST}/api/v1/groups" -H 'Content-Type: application/json' -H "Authorization: Bearer ${AO_TOKEN}" -d "$(jq -nc --arg name "$group" '{name:$name,description:"Keycloak lab group"}')" | jq -r .id)"
          echo "✓ Created AO group: ${group}"
        fi
        AO_GROUPS_PAYLOAD="$(printf '%s' "$AO_GROUPS_PAYLOAD" | jq --arg value "$group" --arg id "$group_id" '. + [{idp_group_value:$value,mapped_group_id:$id}]')"
      done
      AO_CURRENT="$(curl -skf "${AO_BASE}/${AO_ID}" -H "Authorization: Bearer ${AO_TOKEN}")"
      AO_PAYLOAD="$(printf '%s' "$AO_CURRENT" | jq --argjson mappings "$AO_GROUPS_PAYLOAD" '{name,enabled,configuration:(.configuration | del(.client_secret) | .group_mapping_entries=$mappings | .allow_all_authenticated=false)}')"
      echo "  AO group mappings: $(printf '%s' "$AO_PAYLOAD" | jq '.configuration.group_mapping_entries | length')"
    fi
    AO_RESPONSE="$(curl -skf -X PATCH "${AO_BASE}/${AO_ID}" -H 'Content-Type: application/json' -H "Authorization: Bearer ${AO_TOKEN}" -d "$AO_PAYLOAD")"
    [ "$MAP_GROUPS" != true ] || echo "  AO response group mappings: $(printf '%s' "$AO_RESPONSE" | jq '.configuration.group_mapping_entries | length')"
    echo "✓ Updated AO identity provider: ${AO_NAME}"
  else
    if [ "$MAP_GROUPS" = true ]; then
      AO_GROUPS_PAYLOAD='[]'
      for group in aap-admins aap-operators aap-auditors aap-developers; do
        group_id="$(printf '%s' "$AO_GROUP_LIST" | jq -r --arg name "$group" '.resources[] | select(.name==$name) | .id' | head -n1)"
        if [ -z "$group_id" ]; then
          group_id="$(curl -skf -X POST "https://${AO_HOST}/api/v1/groups" -H 'Content-Type: application/json' -H "Authorization: Bearer ${AO_TOKEN}" -d "$(jq -nc --arg name "$group" '{name:$name,description:"Keycloak lab group"}')" | jq -r .id)"
          echo "✓ Created AO group: ${group}"
        fi
        AO_GROUPS_PAYLOAD="$(printf '%s' "$AO_GROUPS_PAYLOAD" | jq --arg value "$group" --arg id "$group_id" '. + [{idp_group_value:$value,mapped_group_id:$id}]')"
      done
      AO_PAYLOAD="$(printf '%s' "$AO_PAYLOAD" | jq --argjson mappings "$AO_GROUPS_PAYLOAD" '.configuration.group_mapping_entries=$mappings | .configuration.allow_all_authenticated=false')"
    fi
    curl -skf -X POST "$AO_BASE" -H 'Content-Type: application/json' -H "Authorization: Bearer ${AO_TOKEN}" -d "$AO_PAYLOAD" >/dev/null
    echo "✓ Created AO identity provider: ${AO_NAME}"
  fi
fi

echo "✓ Keycloak OIDC consumer configuration complete"
