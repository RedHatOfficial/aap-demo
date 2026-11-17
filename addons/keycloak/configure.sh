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
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}

for arg in "$@"; do
  case "$arg" in
    --apply | --map-groups | -h | --help)
      [ "${previous_arg:-}" = "--target" ] && {
        echo "ERROR: --target requires a value" >&2
        exit 1
      }
      case "$arg" in
        --apply) APPLY=true ;;
        --map-groups) MAP_GROUPS=true ;;
        -h | --help)
          usage
          exit 0
          ;;
      esac
      ;;
    --target=*) TARGET="${arg#*=}" ;;
    --target) : ;;
    *)
      if [ "${previous_arg:-}" = "--target" ]; then
        case "$arg" in
          --*)
            echo "ERROR: --target requires a value" >&2
            exit 1
            ;;
          *) TARGET="$arg" ;;
        esac
      else
        echo "ERROR: unknown argument: $arg" >&2
        usage >&2
        exit 1
      fi
      ;;
  esac
  previous_arg="$arg"
done

[ "${previous_arg:-}" != "--target" ] || {
  echo "ERROR: --target requires a value" >&2
  exit 1
}

case "$TARGET" in aap | ao | all) ;; *)
  echo "ERROR: --target must be aap, ao, or all" >&2
  exit 1
  ;;
esac

for cmd in kubectl jq curl; do require_cmd "$cmd"; done
KEYCLOAK_INSECURE_TLS="${KEYCLOAK_INSECURE_TLS:-false}"
KEYCLOAK_CA_FILE="${KEYCLOAK_CA_FILE:-}"
if [ -z "$KEYCLOAK_CA_FILE" ]; then
  for _candidate_ca in \
    "${AAP_DEMO_CONFIG_DIR:-${HOME}/.aap-demo}/crc-ingress-ca.crt" \
    "${HOME}/.local/state/aap-demo/certs/crc-ingress-ca.crt"; do
    if [ -s "$_candidate_ca" ]; then
      KEYCLOAK_CA_FILE="$_candidate_ca"
      break
    fi
  done
fi
case "$KEYCLOAK_INSECURE_TLS" in
  true) CURL_TLS_ARGS=(-k) ;;
  false)
    if [ -n "$KEYCLOAK_CA_FILE" ] && [ ! -s "$KEYCLOAK_CA_FILE" ]; then
      echo "ERROR: KEYCLOAK_CA_FILE does not exist or is empty: ${KEYCLOAK_CA_FILE}" >&2
      exit 1
    fi
    CURL_TLS_ARGS=()
    [ -s "$KEYCLOAK_CA_FILE" ] && CURL_TLS_ARGS+=(--cacert "$KEYCLOAK_CA_FILE")
    ;;
  *)
    echo "ERROR: KEYCLOAK_INSECURE_TLS must be true or false" >&2
    exit 1
    ;;
esac
AAP_VERIFY_SSL=true
[ "$KEYCLOAK_INSECURE_TLS" != true ] || AAP_VERIFY_SSL=false

curl_local() { curl "${CURL_TLS_ARGS[@]}" "$@"; }

if [ "$TARGET" != ao ]; then
  [ -s "$STATE_DIR/aap-client-secret" ] || {
    echo "ERROR: missing $STATE_DIR/aap-client-secret; enable Keycloak first" >&2
    exit 1
  }
fi
if [ "$TARGET" != aap ]; then
  [ -s "$STATE_DIR/ao-client-secret" ] || {
    echo "ERROR: missing $STATE_DIR/ao-client-secret; enable Keycloak first" >&2
    exit 1
  }
fi

read_secret() { tr -d '\r\n' <"$1"; }

route_host() {
  kubectl get route "$1" -n "$2" -o jsonpath='{.spec.host}'
}

_managed_by="$(kubectl get namespace "$KEYCLOAK_NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')" || {
  echo "ERROR: Keycloak namespace not found; run: aap-demo enable keycloak" >&2
  exit 1
}
_managed_part="$(kubectl get namespace "$KEYCLOAK_NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}')" || {
  echo "ERROR: unable to inspect Keycloak namespace ownership" >&2
  exit 1
}
[ "$_managed_by" = "aap-demo-keycloak" ] && [ "$_managed_part" = "aap-demo" ] || {
  echo "ERROR: refusing to configure unowned namespace ${KEYCLOAK_NAMESPACE}" >&2
  exit 1
}

KEYCLOAK_HOST="$(route_host keycloak "$KEYCLOAK_NAMESPACE")"
[ -n "$KEYCLOAK_HOST" ] || {
  echo "ERROR: Keycloak route not found; run: aap-demo enable keycloak" >&2
  exit 1
}
ISSUER="https://${KEYCLOAK_HOST}/realms/${KEYCLOAK_REALM}"

PUBLIC_KEY="$(curl_local -f "${ISSUER}" | jq -r '.public_key // empty')"
[ -n "$PUBLIC_KEY" ] || {
  echo "ERROR: Keycloak realm public key unavailable" >&2
  exit 1
}

AAP_HOST=""
AO_HOST=""
if [ "$TARGET" != ao ]; then
  AAP_HOST="$(route_host aap "$NAMESPACE")"
  [ -n "$AAP_HOST" ] || {
    echo "ERROR: AAP route not found in namespace $NAMESPACE" >&2
    exit 1
  }
fi
if [ "$TARGET" != aap ]; then
  AO_HOST="$(kubectl get route -n automation-orchestrator -o jsonpath='{.items[0].spec.host}')"
  [ -n "$AO_HOST" ] || {
    echo "ERROR: AO route not found" >&2
    exit 1
  }
fi

AAP_NAME="${KEYCLOAK_AAP_AUTHENTICATOR_NAME:-Keycloak lab}"
AO_NAME="${KEYCLOAK_AO_PROVIDER_NAME:-Keycloak lab}"
AAP_SECRET=""
AO_SECRET=""
[ "$TARGET" = ao ] || AAP_SECRET="$(read_secret "$STATE_DIR/aap-client-secret")"
[ "$TARGET" = aap ] || AO_SECRET="$(read_secret "$STATE_DIR/ao-client-secret")"
AO_REDIRECT_URI="${KEYCLOAK_AO_REDIRECT_URI:-}"
if [ -z "$AO_REDIRECT_URI" ] && [ -s "$STATE_DIR/ao-redirect-uri" ]; then
  AO_REDIRECT_URI="$(read_secret "$STATE_DIR/ao-redirect-uri")"
fi
AO_REDIRECT_URI="${AO_REDIRECT_URI:-https://${AO_HOST}/api/v1/auth/oidc/callback}"

AAP_PAYLOAD="$(jq -nc \
  --arg name "$AAP_NAME" --arg issuer "$ISSUER" --arg key "$AAP_SECRET" --arg public_key "$PUBLIC_KEY" \
  --argjson verify_ssl "$AAP_VERIFY_SSL" \
  '{name:$name,enabled:true,create_objects:true,remove_users:false,type:"ansible_base.authentication.authenticator_plugins.keycloak",configuration:{ACCESS_TOKEN_URL:($issuer+"/protocol/openid-connect/token"),AUTHORIZATION_URL:($issuer+"/protocol/openid-connect/auth"),GROUPS_CLAIM:"groups",KEY:"aap-demo-aap",PUBLIC_KEY:$public_key,SECRET:$key,ADDITIONAL_UNVERIFIED_ARGS:{VERIFY_SSL:$verify_ssl}}}')"

AO_PAYLOAD="$(jq -nc \
  --arg name "$AO_NAME" --arg issuer "$ISSUER" --arg client_secret "$AO_SECRET" --arg redirect "$AO_REDIRECT_URI" \
  --argjson disable_tls_verify "$([ "$KEYCLOAK_INSECURE_TLS" = true ] && echo true || echo false)" \
  '{name:$name,enabled:true,configuration:{provider_type:"oidc",idp_type:"custom",auto_discovery:true,issuer_url:$issuer,client_id:"aap-demo-ao",client_secret:$client_secret,redirect_uri:$redirect,scopes:"openid",claim_mapping:{subject:"sub",email:"email",username:"preferred_username",first_name:"given_name",last_name:"family_name"},group_jmespath_expression:"groups[*]",group_mapping_entries:[],allow_all_authenticated:true,enable_rp_initiated_logout:true,disable_tls_verify:$disable_tls_verify}}')"

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
  if [ "$MAP_GROUPS" = true ]; then
    echo "  Group mapping: enabled"
  fi
}

print_plan
[ "$APPLY" = true ] || exit 0

REQUEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aap-demo-keycloak-configure.XXXXXX")"
chmod 700 "$REQUEST_DIR"
cleanup_request_files() { rm -rf "$REQUEST_DIR"; }
trap cleanup_request_files EXIT

ensure_aap_ca_trust() {
  [ "$KEYCLOAK_INSECURE_TLS" = false ] || return 0
  [ -s "$KEYCLOAK_CA_FILE" ] || return 0
  require_cmd openssl

  local aap_cr current_secret bundle_secret existing_bundle merged_bundle
  aap_cr="$(kubectl get aap -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "$aap_cr" ] || {
    echo "ERROR: no AAP custom resource found in namespace ${NAMESPACE}" >&2
    exit 1
  }
  current_secret="$(kubectl get aap "$aap_cr" -n "$NAMESPACE" -o jsonpath='{.spec.bundle_cacert_secret}' 2>/dev/null || true)"
  bundle_secret="${current_secret:-bundle-ca-secret}"
  existing_bundle="$REQUEST_DIR/existing-bundle-ca.crt"
  merged_bundle="$REQUEST_DIR/bundle-ca.crt"
  : >"$existing_bundle"

  if kubectl get secret "$bundle_secret" -n "$NAMESPACE" >/dev/null 2>&1; then
    local encoded_bundle
    encoded_bundle="$(kubectl get secret "$bundle_secret" -n "$NAMESPACE" -o jsonpath='{.data.bundle-ca\.crt}')"
    [ -n "$encoded_bundle" ] || {
      echo "ERROR: Secret ${bundle_secret} has no bundle-ca.crt key; refusing to replace it" >&2
      exit 1
    }
    printf '%s' "$encoded_bundle" | base64 -d >"$existing_bundle" || {
      echo "ERROR: could not decode bundle-ca.crt from Secret ${bundle_secret}" >&2
      exit 1
    }
  elif [ -n "$current_secret" ]; then
    echo "ERROR: AAP references missing CA bundle Secret ${current_secret}" >&2
    exit 1
  fi

  local cert_dir="$REQUEST_DIR/ingress-certs" existing_dir="$REQUEST_DIR/existing-certs"
  mkdir -p "$cert_dir" "$existing_dir"
  split_certificates() {
    local input="$1" output_dir="$2"
    awk -v dir="$output_dir" '
      /-----BEGIN CERTIFICATE-----/ { total++; active=1; file=sprintf("%s/cert-%04d.pem", dir, total) }
      active { print > file }
      /-----END CERTIFICATE-----/ { close(file); active=0 }
      END { if (active) exit 1 }
    ' "$input"
  }
  split_certificates "$KEYCLOAK_CA_FILE" "$cert_dir" || {
    echo "ERROR: KEYCLOAK_CA_FILE is not a valid PEM certificate bundle: ${KEYCLOAK_CA_FILE}" >&2
    exit 1
  }
  [ -n "$(find "$cert_dir" -type f -name 'cert-*.pem' -print -quit)" ] || {
    echo "ERROR: KEYCLOAK_CA_FILE contains no PEM certificates: ${KEYCLOAK_CA_FILE}" >&2
    exit 1
  }

  local fingerprints="$REQUEST_DIR/ca-fingerprints" cert fingerprint
  : >"$fingerprints"
  if [ -s "$existing_bundle" ]; then
    split_certificates "$existing_bundle" "$existing_dir" || {
      echo "ERROR: existing CA bundle Secret ${bundle_secret} is not valid PEM" >&2
      exit 1
    }
    [ -n "$(find "$existing_dir" -type f -name 'cert-*.pem' -print -quit)" ] || {
      echo "ERROR: existing CA bundle Secret ${bundle_secret} contains no PEM certificates" >&2
      exit 1
    }
    cat "$existing_bundle" >"$merged_bundle"
    while IFS= read -r cert; do
      fingerprint="$(openssl x509 -in "$cert" -noout -fingerprint -sha256 | sed 's/^[^=]*=//')"
      printf '%s\n' "$fingerprint" >>"$fingerprints"
    done < <(find "$existing_dir" -type f -name 'cert-*.pem' -print | sort)
  else
    : >"$merged_bundle"
  fi
  while IFS= read -r cert; do
    fingerprint="$(openssl x509 -in "$cert" -noout -fingerprint -sha256 | sed 's/^[^=]*=//')"
    if ! grep -Fqx "$fingerprint" "$fingerprints"; then
      cat "$cert" >>"$merged_bundle"
      printf '%s\n' "$fingerprint" >>"$fingerprints"
    fi
  done < <(find "$cert_dir" -type f -name 'cert-*.pem' -print | sort)

  kubectl create secret generic "$bundle_secret" -n "$NAMESPACE" \
    --from-file="bundle-ca.crt=$merged_bundle" --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null
  if [ "$current_secret" != "$bundle_secret" ]; then
    kubectl patch aap "$aap_cr" -n "$NAMESPACE" --type=merge \
      -p "$(jq -nc --arg secret "$bundle_secret" '{spec:{bundle_cacert_secret:$secret}}')" >/dev/null
  fi

  local gateway_deployments deployment
  gateway_deployments="$(kubectl get deployments -n "$NAMESPACE" -l app.kubernetes.io/component=aap-gateway -o name)"
  [ -n "$gateway_deployments" ] || {
    echo "ERROR: unable to find the AAP Gateway deployment to verify CA bundle rollout" >&2
    exit 1
  }
  while IFS= read -r deployment; do
    [ -n "$deployment" ] || continue
    kubectl rollout status "$deployment" -n "$NAMESPACE" --timeout="${AAP_GATEWAY_ROLLOUT_TIMEOUT:-5m}"
  done <<<"$gateway_deployments"
  echo "✓ AAP Gateway trusts the Keycloak ingress CA (TLS verification remains enabled)"
}

if [ "$TARGET" != ao ]; then
  ensure_aap_ca_trust
fi

if [ "$TARGET" != ao ]; then
  AAP_PASSWORD="$(kubectl get secret aap-admin-password -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)"
  AAP_AUTH="$REQUEST_DIR/aap-curl.conf"
  printf 'user = "admin:%s"\n' "$AAP_PASSWORD" >"$AAP_AUTH"
  AAP_BASE="https://${AAP_HOST}/api/gateway/v1/authenticators/"
  AAP_LIST="$(curl_local -f "$AAP_BASE" --config "$AAP_AUTH")"
  AAP_ID="$(printf '%s' "$AAP_LIST" | jq -r --arg n "$AAP_NAME" '(.results // .authenticators // [])[] | select(.name==$n) | .id' | head -n1)"
  AAP_BODY="$REQUEST_DIR/aap.json"
  printf '%s' "$AAP_PAYLOAD" >"$AAP_BODY"
  if [ -n "$AAP_ID" ]; then
    curl_local -f -X PATCH "${AAP_BASE}${AAP_ID}/" --config "$AAP_AUTH" -H 'Content-Type: application/json' --data-binary "@$AAP_BODY" >/dev/null
    echo "✓ Updated AAP authenticator: ${AAP_NAME}"
  else
    AAP_RESPONSE="$(curl_local -f -X POST "$AAP_BASE" --config "$AAP_AUTH" -H 'Content-Type: application/json' --data-binary "@$AAP_BODY")"
    AAP_ID="$(printf '%s' "$AAP_RESPONSE" | jq -r '.id // empty')"
    [ -n "$AAP_ID" ] || {
      echo "ERROR: AAP authenticator creation returned no ID" >&2
      exit 1
    }
    echo "✓ Created AAP authenticator: ${AAP_NAME}"
  fi

  AAP_DETAIL="$(curl_local -f "${AAP_BASE}${AAP_ID}/" --config "$AAP_AUTH")"
  AAP_SLUG="$(printf '%s' "$AAP_DETAIL" | jq -r '.slug // empty')"
  [ -n "$AAP_SLUG" ] || {
    echo "ERROR: AAP authenticator response did not include its callback slug" >&2
    exit 1
  }
  AAP_CALLBACK_OVERRIDE="${KEYCLOAK_AAP_REDIRECT_URI:-}"
  if [ -z "$AAP_CALLBACK_OVERRIDE" ] && [ -s "$STATE_DIR/aap-redirect-uri" ]; then
    AAP_CALLBACK_OVERRIDE="$(read_secret "$STATE_DIR/aap-redirect-uri")"
  fi
  AAP_CALLBACK_URL="${AAP_CALLBACK_OVERRIDE:-https://${AAP_HOST}/api/gateway/social/complete/${AAP_SLUG}/}"

  KC_ADMIN_PASSWORD_FILE="$STATE_DIR/admin-password"
  [ -s "$KC_ADMIN_PASSWORD_FILE" ] || {
    echo "ERROR: missing $KC_ADMIN_PASSWORD_FILE; enable Keycloak first" >&2
    exit 1
  }
  KC_BASE="https://${KEYCLOAK_HOST}"
  KC_TOKEN="$(curl_local -f -X POST "${KC_BASE}/realms/master/protocol/openid-connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'client_id=admin-cli' \
    --data-urlencode 'grant_type=password' \
    --data-urlencode 'username=admin' \
    --data-urlencode "password@${KC_ADMIN_PASSWORD_FILE}" | jq -r '.access_token // empty')"
  [ -n "$KC_TOKEN" ] || {
    echo "ERROR: unable to authenticate to the Keycloak admin API" >&2
    exit 1
  }
  KC_ADMIN_AUTH="$REQUEST_DIR/keycloak-admin-curl.conf"
  printf 'header = "Authorization: Bearer %s"\n' "$KC_TOKEN" >"$KC_ADMIN_AUTH"
  KC_CLIENT_LIST="$(curl_local -f "${KC_BASE}/admin/realms/${KEYCLOAK_REALM}/clients?clientId=aap-demo-aap" --config "$KC_ADMIN_AUTH")"
  KC_CLIENT_ID="$(printf '%s' "$KC_CLIENT_LIST" | jq -r 'if length == 1 then .[0].id else empty end')"
  [ -n "$KC_CLIENT_ID" ] || {
    echo "ERROR: Keycloak client aap-demo-aap was not found uniquely" >&2
    exit 1
  }
  KC_CLIENT="$(curl_local -f "${KC_BASE}/admin/realms/${KEYCLOAK_REALM}/clients/${KC_CLIENT_ID}" --config "$KC_ADMIN_AUTH")"
  KC_CLIENT="$(printf '%s' "$KC_CLIENT" | jq --arg callback "$AAP_CALLBACK_URL" --arg logout "https://${AAP_HOST}/" \
    '.redirectUris=[$callback] | .attributes["post.logout.redirect.uris"]=$logout')"
  printf '%s' "$KC_CLIENT" >"$REQUEST_DIR/keycloak-aap-client.json"
  curl_local -f -X PUT "${KC_BASE}/admin/realms/${KEYCLOAK_REALM}/clients/${KC_CLIENT_ID}" \
    --config "$KC_ADMIN_AUTH" -H 'Content-Type: application/json' \
    --data-binary "@$REQUEST_DIR/keycloak-aap-client.json" >/dev/null
  echo "✓ Set AAP Gateway callback: ${AAP_CALLBACK_URL}"

  if [ "$MAP_GROUPS" = true ]; then
    AAP_MAP_BASE="https://${AAP_HOST}/api/gateway/v1/authenticator_maps/"
    AAP_GROUP_MAPS=(
      "aap-admins|is_superuser|||true"
      "aap-auditors|role|Platform Auditor||false"
      "aap-operators|organization|Organization Admin|AAP Demo|false"
      "aap-developers|organization|Organization Member|AAP Demo|false"
    )
    AAP_MAP_LIST="$(curl_local -f "$AAP_MAP_BASE?authenticator=${AAP_ID}" --config "$AAP_AUTH")"
    for map_spec in "${AAP_GROUP_MAPS[@]}"; do
      IFS='|' read -r group map_type role organization revoke <<<"$map_spec"
      map_name="Keycloak ${group}"
      map_payload="$(jq -nc --arg name "$map_name" --arg group "$group" --arg type "$map_type" --arg role "$role" --arg organization "$organization" --argjson authenticator "$AAP_ID" --argjson revoke "$revoke" \
        '{name:$name,authenticator:$authenticator,map_type:$type,triggers:{groups:{has_or:[$group]}},role:(if $role=="" then null else $role end),organization:(if $organization=="" then null else $organization end),team:null,revoke:$revoke}')"
      map_id="$(printf '%s' "$AAP_MAP_LIST" | jq -r --arg name "$map_name" '.results[] | select(.name==$name) | .id' | head -n1)"
      if [ -n "$map_id" ]; then
        printf '%s' "$map_payload" >"$REQUEST_DIR/aap-map.json"
        curl_local -f -X PATCH "${AAP_MAP_BASE}${map_id}/" --config "$AAP_AUTH" -H 'Content-Type: application/json' --data-binary "@$REQUEST_DIR/aap-map.json" >/dev/null
        echo "✓ Updated AAP group map: ${group}"
      else
        printf '%s' "$map_payload" >"$REQUEST_DIR/aap-map.json"
        curl_local -f -X POST "$AAP_MAP_BASE" --config "$AAP_AUTH" -H 'Content-Type: application/json' --data-binary "@$REQUEST_DIR/aap-map.json" >/dev/null
        echo "✓ Created AAP group map: ${group}"
      fi
    done
  fi
fi

if [ "$TARGET" != aap ]; then
  AO_PASSWORD="$(kubectl get secret automation-orchestrator-initial-admin-password -n automation-orchestrator -o jsonpath='{.data.password}' | base64 -d)"
  printf '%s' "$(jq -nc --arg p "$AO_PASSWORD" '{username:"admin",password:$p}')" >"$REQUEST_DIR/ao-login.json"
  AO_TOKEN="$(curl_local -f -X POST "https://${AO_HOST}/api/v1/auth/login" -H 'Content-Type: application/json' --data-binary "@$REQUEST_DIR/ao-login.json" | jq -r .access_token)"
  [ -n "$AO_TOKEN" ] && [ "$AO_TOKEN" != null ] || {
    echo "ERROR: AO admin login failed" >&2
    exit 1
  }
  AO_AUTH="$REQUEST_DIR/ao-curl.conf"
  printf 'header = "Authorization: Bearer %s"\n' "$AO_TOKEN" >"$AO_AUTH"
  AO_BASE="https://${AO_HOST}/api/v1/identity_providers"
  AO_LIST="$(curl_local -f "$AO_BASE" --config "$AO_AUTH")"
  AO_GROUP_LIST="$(curl_local -f "https://${AO_HOST}/api/v1/groups" --config "$AO_AUTH")"
  AO_ID="$(printf '%s' "$AO_LIST" | jq -r --arg n "$AO_NAME" '.resources[] | select(.name==$n) | .id' | head -n1)"
  if [ -n "$AO_ID" ]; then
    if [ "$MAP_GROUPS" = true ]; then
      AO_GROUPS_PAYLOAD='[]'
      for group in aap-admins aap-operators aap-auditors aap-developers; do
        group_id="$(printf '%s' "$AO_GROUP_LIST" | jq -r --arg name "$group" '.resources[] | select(.name==$name) | .id' | head -n1)"
        if [ -z "$group_id" ]; then
          printf '%s' "$(jq -nc --arg name "$group" '{name:$name,description:"Keycloak lab group"}')" >"$REQUEST_DIR/ao-group.json"
          group_id="$(curl_local -f -X POST "https://${AO_HOST}/api/v1/groups" --config "$AO_AUTH" -H 'Content-Type: application/json' --data-binary "@$REQUEST_DIR/ao-group.json" | jq -r .id)"
          echo "✓ Created AO group: ${group}"
        fi
        AO_GROUPS_PAYLOAD="$(printf '%s' "$AO_GROUPS_PAYLOAD" | jq --arg value "$group" --arg id "$group_id" '. + [{idp_group_value:$value,mapped_group_id:$id}]')"
      done
      AO_CURRENT="$(curl_local -f "${AO_BASE}/${AO_ID}" --config "$AO_AUTH")"
      AO_PAYLOAD="$(printf '%s' "$AO_CURRENT" | jq --argjson mappings "$AO_GROUPS_PAYLOAD" --arg scopes "openid" '{name,enabled,configuration:(.configuration | del(.client_secret) | .scopes=$scopes | .group_mapping_entries=$mappings | .allow_all_authenticated=false)}')"
      echo "  AO group mappings: $(printf '%s' "$AO_PAYLOAD" | jq '.configuration.group_mapping_entries | length')"
    fi
    printf '%s' "$AO_PAYLOAD" >"$REQUEST_DIR/ao.json"
    AO_RESPONSE="$(curl_local -f -X PATCH "${AO_BASE}/${AO_ID}" --config "$AO_AUTH" -H 'Content-Type: application/json' --data-binary "@$REQUEST_DIR/ao.json")"
    [ "$MAP_GROUPS" != true ] || echo "  AO response group mappings: $(printf '%s' "$AO_RESPONSE" | jq '.configuration.group_mapping_entries | length')"
    echo "✓ Updated AO identity provider: ${AO_NAME}"
  else
    if [ "$MAP_GROUPS" = true ]; then
      AO_GROUPS_PAYLOAD='[]'
      for group in aap-admins aap-operators aap-auditors aap-developers; do
        group_id="$(printf '%s' "$AO_GROUP_LIST" | jq -r --arg name "$group" '.resources[] | select(.name==$name) | .id' | head -n1)"
        if [ -z "$group_id" ]; then
          printf '%s' "$(jq -nc --arg name "$group" '{name:$name,description:"Keycloak lab group"}')" >"$REQUEST_DIR/ao-group.json"
          group_id="$(curl_local -f -X POST "https://${AO_HOST}/api/v1/groups" --config "$AO_AUTH" -H 'Content-Type: application/json' --data-binary "@$REQUEST_DIR/ao-group.json" | jq -r .id)"
          echo "✓ Created AO group: ${group}"
        fi
        AO_GROUPS_PAYLOAD="$(printf '%s' "$AO_GROUPS_PAYLOAD" | jq --arg value "$group" --arg id "$group_id" '. + [{idp_group_value:$value,mapped_group_id:$id}]')"
      done
      AO_PAYLOAD="$(printf '%s' "$AO_PAYLOAD" | jq --argjson mappings "$AO_GROUPS_PAYLOAD" '.configuration.group_mapping_entries=$mappings | .configuration.allow_all_authenticated=false')"
    fi
    printf '%s' "$AO_PAYLOAD" >"$REQUEST_DIR/ao.json"
    curl_local -f -X POST "$AO_BASE" --config "$AO_AUTH" -H 'Content-Type: application/json' --data-binary "@$REQUEST_DIR/ao.json" >/dev/null
    echo "✓ Created AO identity provider: ${AO_NAME}"
  fi
fi

echo "✓ Keycloak OIDC consumer configuration complete"
