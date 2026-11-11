#!/usr/bin/env bash
# Shared Ansible Vault-backed credential storage for aap-demo.

if [ -n "${_AAP_DEMO_CREDENTIAL_VAULT_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_CREDENTIAL_VAULT_LOADED=1
if ! declare -f _err >/dev/null 2>&1; then
  _err() { printf 'ERROR: %s\n' "$*" >&2; }
fi

_AAP_DEMO_VAULT_PATHS_EXPLICIT=false
if [ -n "${AAP_DEMO_VAULT_FILE+x}" ] || [ -n "${AAP_DEMO_VAULT_PASSWORD_FILE+x}" ]; then
  _AAP_DEMO_VAULT_PATHS_EXPLICIT=true
fi
AAP_DEMO_VAULT_FILE="${AAP_DEMO_VAULT_FILE:-$HOME/.ansible/conf/env.yml}"
AAP_DEMO_VAULT_PASSWORD_FILE="${AAP_DEMO_VAULT_PASSWORD_FILE:-$HOME/.ansible/conf/.vaultpass.txt}"
AAP_DEMO_PREVIOUS_VAULT_FILE="${AAP_DEMO_PREVIOUS_VAULT_FILE:-$HOME/.ansible/conf/env-aap-demo.yml}"
AAP_DEMO_PREVIOUS_VAULT_PASSWORD_FILE="${AAP_DEMO_PREVIOUS_VAULT_PASSWORD_FILE:-$HOME/.ansible/conf/.vaultpass-aap-demo.txt}"
AAP_DEMO_LEGACY_VAULT_FILE="${AAP_DEMO_LEGACY_VAULT_FILE:-$HOME/.ansible/conf/env_microshift.yml}"
AAP_DEMO_LEGACY_VAULT_PASSWORD_FILE="${AAP_DEMO_LEGACY_VAULT_PASSWORD_FILE:-$HOME/.ansible/conf/.vaultpass_microshift.txt}"
AAP_DEMO_SECRET_PROMPT_DEVICE="${AAP_DEMO_SECRET_PROMPT_DEVICE:-/dev/tty}"
AAP_DEMO_SECRET_PROMPT_OUTPUT="${AAP_DEMO_SECRET_PROMPT_OUTPUT:-/dev/tty}"
AAP_DEMO_VAULT_PYTHON="${AAP_DEMO_VAULT_PYTHON:-}"
AAP_DEMO_ANSIBLE_VAULT="${AAP_DEMO_ANSIBLE_VAULT:-}"

_aap_demo_private_mode() {
  chmod 600 "$1"
}

_aap_demo_vault_require_tools() {
  local candidate current_python current_vault

  if [ -n "$AAP_DEMO_ANSIBLE_VAULT" ]; then
    if ! "$AAP_DEMO_ANSIBLE_VAULT" --version >/dev/null 2>&1; then
      _err "Configured ansible-vault executable is not usable: $AAP_DEMO_ANSIBLE_VAULT"
      return 1
    fi
  else
    current_vault=$(command -v ansible-vault 2>/dev/null || true)
    for candidate in "$current_vault" /usr/bin/ansible-vault /usr/local/bin/ansible-vault \
      /opt/homebrew/bin/ansible-vault; do
      [ -n "$candidate" ] && [ -x "$candidate" ] || continue
      if "$candidate" --version >/dev/null 2>&1; then
        AAP_DEMO_ANSIBLE_VAULT="$candidate"
        break
      fi
    done
    if [ -z "$AAP_DEMO_ANSIBLE_VAULT" ]; then
      _err "ansible-vault is required for encrypted credential storage"
      return 1
    fi
  fi

  if [ -n "$AAP_DEMO_VAULT_PYTHON" ]; then
    if "$AAP_DEMO_VAULT_PYTHON" -c 'import yaml' >/dev/null 2>&1; then
      return 0
    fi
    _err "Configured Vault Python cannot import PyYAML: $AAP_DEMO_VAULT_PYTHON"
    return 1
  fi

  current_python=$(command -v python3 2>/dev/null || true)
  for candidate in "$current_python" /usr/bin/python3 /usr/local/bin/python3 /opt/homebrew/bin/python3; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    if "$candidate" -c 'import yaml' >/dev/null 2>&1; then
      AAP_DEMO_VAULT_PYTHON="$candidate"
      return 0
    fi
  done

  _err "Python PyYAML is required for encrypted credential storage"
  return 1
}

_aap_demo_vault_migrate_legacy() {
  [ "$_AAP_DEMO_VAULT_PATHS_EXPLICIT" = false ] || return 0
  local config_dir source_file source_password plain_target plain_source merged encrypted
  local -a source_files source_passwords
  source_files=("$AAP_DEMO_PREVIOUS_VAULT_FILE" "$AAP_DEMO_LEGACY_VAULT_FILE")
  source_passwords=("$AAP_DEMO_PREVIOUS_VAULT_PASSWORD_FILE" "$AAP_DEMO_LEGACY_VAULT_PASSWORD_FILE")
  config_dir=$(dirname "$AAP_DEMO_VAULT_FILE")
  mkdir -p "$config_dir"
  chmod 700 "$config_dir"

  if [ -e "$AAP_DEMO_VAULT_PASSWORD_FILE" ] || [ -L "$AAP_DEMO_VAULT_PASSWORD_FILE" ]; then
    [ -s "$AAP_DEMO_VAULT_PASSWORD_FILE" ] || {
      _err "Existing Vault password file is empty or unusable; it was not changed"
      return 1
    }
  else
    if [ -e "$AAP_DEMO_VAULT_FILE" ]; then
      _err "Vault exists without its password file: $AAP_DEMO_VAULT_FILE"
      return 1
    fi
    local index
    for index in "${!source_files[@]}"; do
      if [ -s "${source_files[$index]}" ] && [ -s "${source_passwords[$index]}" ]; then
        cp "${source_passwords[$index]}" "$AAP_DEMO_VAULT_PASSWORD_FILE"
        _aap_demo_private_mode "$AAP_DEMO_VAULT_PASSWORD_FILE"
        break
      fi
    done
  fi

  local index
  for index in "${!source_files[@]}"; do
    source_file="${source_files[$index]}"
    source_password="${source_passwords[$index]}"
    [ -s "$source_file" ] || continue
    [ -s "$source_password" ] || {
      _err "Legacy Vault exists without its password file: $source_file"
      return 1
    }
    [ -s "$AAP_DEMO_VAULT_PASSWORD_FILE" ] || return 0
    _aap_demo_vault_require_tools || return 1

    plain_target=$(mktemp "${config_dir}/.env.target.XXXXXX")
    plain_source=$(mktemp "${config_dir}/.env.source.XXXXXX")
    merged=$(mktemp "${config_dir}/.env.merged.XXXXXX")
    encrypted=$(mktemp "${config_dir}/.env.vault.XXXXXX")
    chmod 600 "$plain_target" "$plain_source" "$merged" "$encrypted"

    if [ -s "$AAP_DEMO_VAULT_FILE" ]; then
      if ! "$AAP_DEMO_ANSIBLE_VAULT" view --vault-password-file "$AAP_DEMO_VAULT_PASSWORD_FILE" \
        "$AAP_DEMO_VAULT_FILE" >"$plain_target"; then
        rm -f "$plain_target" "$plain_source" "$merged" "$encrypted"
        _err "Unable to decrypt $AAP_DEMO_VAULT_FILE; legacy credentials were not changed"
        return 1
      fi
    else
      printf '{}\n' >"$plain_target"
    fi
    if ! "$AAP_DEMO_ANSIBLE_VAULT" view --vault-password-file "$source_password" \
      "$source_file" >"$plain_source"; then
      rm -f "$plain_target" "$plain_source" "$merged" "$encrypted"
      _err "Unable to decrypt legacy Vault: $source_file"
      return 1
    fi

    if ! "$AAP_DEMO_VAULT_PYTHON" - "$plain_target" "$plain_source" >"$merged" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    target = yaml.safe_load(stream) or {}
with open(sys.argv[2], encoding="utf-8") as stream:
    source = yaml.safe_load(stream) or {}
if not isinstance(target, dict) or not isinstance(source, dict):
    raise SystemExit("Vault roots must be YAML mappings")

def merge_missing(destination, incoming):
    for key, value in incoming.items():
        if key not in destination:
            destination[key] = value
        elif isinstance(destination[key], dict) and isinstance(value, dict):
            merge_missing(destination[key], value)

legacy = source.get("aap_demo")
if isinstance(legacy, dict):
    current = target.setdefault("aap_demo", {})
    if not isinstance(current, dict):
        raise SystemExit("Existing aap_demo Vault entry must be a mapping")
    merge_missing(current, legacy)
yaml.safe_dump(target, sys.stdout, default_flow_style=False, sort_keys=True)
PY
    then
      rm -f "$plain_target" "$plain_source" "$merged" "$encrypted"
      _err "Unable to merge legacy Vault data"
      return 1
    fi

    if ! "$AAP_DEMO_ANSIBLE_VAULT" encrypt --vault-password-file "$AAP_DEMO_VAULT_PASSWORD_FILE" \
      --output "$encrypted" "$merged" >/dev/null; then
      rm -f "$plain_target" "$plain_source" "$merged" "$encrypted"
      _err "Unable to encrypt merged Vault data"
      return 1
    fi
    rm -f "$plain_target" "$plain_source" "$merged"
    mv "$encrypted" "$AAP_DEMO_VAULT_FILE"
    _aap_demo_private_mode "$AAP_DEMO_VAULT_FILE"
    rm -f "$source_file" "$source_password"
    echo "✓ Migrated credentials into $AAP_DEMO_VAULT_FILE" >&2
  done
}

_aap_demo_vault_ensure_password_file() {
  _aap_demo_vault_migrate_legacy || return 1
  local config_dir
  config_dir=$(dirname "$AAP_DEMO_VAULT_PASSWORD_FILE")
  mkdir -p "$config_dir"
  chmod 700 "$config_dir"

  if [ -e "$AAP_DEMO_VAULT_PASSWORD_FILE" ] || [ -L "$AAP_DEMO_VAULT_PASSWORD_FILE" ]; then
    [ -s "$AAP_DEMO_VAULT_PASSWORD_FILE" ] || {
      _err "Existing Vault password file is empty or unusable; it was not changed"
      return 1
    }
    _aap_demo_private_mode "$AAP_DEMO_VAULT_PASSWORD_FILE"
    return 0
  fi
  if [ -s "$AAP_DEMO_VAULT_FILE" ]; then
    _err "Vault exists without its password file: $AAP_DEMO_VAULT_PASSWORD_FILE"
    return 1
  fi
  # Exclusive creation protects a shared password created concurrently by another product.
  if ! "$AAP_DEMO_VAULT_PYTHON" - "$AAP_DEMO_VAULT_PASSWORD_FILE" <<'PY'
import os
import secrets
import sys

fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as stream:
    stream.write(secrets.token_urlsafe(48) + "\n")
PY
  then
    _err "Unable to generate the Ansible Vault password file"
    return 1
  fi
  _aap_demo_private_mode "$AAP_DEMO_VAULT_PASSWORD_FILE"
}

_aap_demo_vault_ensure_file() {
  _aap_demo_vault_require_tools || return 1
  _aap_demo_vault_ensure_password_file || return 1

  local vault_dir
  vault_dir=$(dirname "$AAP_DEMO_VAULT_FILE")
  mkdir -p "$vault_dir"
  chmod 700 "$vault_dir"

  if [ -s "$AAP_DEMO_VAULT_FILE" ]; then
    _aap_demo_private_mode "$AAP_DEMO_VAULT_FILE"
    return 0
  fi

  local plain encrypted
  plain=$(mktemp "${vault_dir}/.env-aap-demo.plain.XXXXXX")
  encrypted=$(mktemp "${vault_dir}/.env-aap-demo.vault.XXXXXX")
  chmod 600 "$plain" "$encrypted"
  printf 'aap_demo: {}\n' >"$plain"
  if ! "$AAP_DEMO_ANSIBLE_VAULT" encrypt \
    --vault-password-file "$AAP_DEMO_VAULT_PASSWORD_FILE" \
    --output "$encrypted" "$plain" >/dev/null; then
    rm -f "$plain" "$encrypted"
    _err "Failed to initialize encrypted credential file"
    return 1
  fi
  rm -f "$plain"
  mv "$encrypted" "$AAP_DEMO_VAULT_FILE"
  _aap_demo_private_mode "$AAP_DEMO_VAULT_FILE"
}

aap_demo_vault_get() {
  local key="$1" plain
  [ "$key" != "aap_demo.galaxy.offline_token" ] || key=ah_offline_token
  _aap_demo_vault_require_tools || return 2
  _aap_demo_vault_migrate_legacy || return 2
  [ -s "$AAP_DEMO_VAULT_FILE" ] || return 1
  [ -s "$AAP_DEMO_VAULT_PASSWORD_FILE" ] || {
    _err "Vault password file is missing: $AAP_DEMO_VAULT_PASSWORD_FILE"
    return 2
  }
  chmod 700 "$(dirname "$AAP_DEMO_VAULT_FILE")" || return 2
  _aap_demo_private_mode "$AAP_DEMO_VAULT_FILE" || return 2
  _aap_demo_private_mode "$AAP_DEMO_VAULT_PASSWORD_FILE" || return 2

  # A decryption error must not look like a missing token and trigger replacement.
  plain=$("$AAP_DEMO_ANSIBLE_VAULT" view \
    --vault-password-file "$AAP_DEMO_VAULT_PASSWORD_FILE" \
    "$AAP_DEMO_VAULT_FILE" 2>/dev/null) || {
      _err "Unable to decrypt $AAP_DEMO_VAULT_FILE; check its Vault password file"
      return 2
    }
  AAP_DEMO_SECRET_KEY="$key" "$AAP_DEMO_VAULT_PYTHON" -c '
import os
import sys
import yaml

try:
    value = yaml.safe_load(sys.stdin) or {}
except yaml.YAMLError:
    print("ERROR: Invalid YAML in credential Vault", file=sys.stderr)
    raise SystemExit(2)
if not isinstance(value, dict):
    print("ERROR: Credential Vault root must be a YAML mapping", file=sys.stderr)
    raise SystemExit(2)
key = os.environ["AAP_DEMO_SECRET_KEY"]
if key == "ah_offline_token" and key not in value:
    key = "aap_demo.galaxy.offline_token"
for part in key.split("."):
    if not isinstance(value, dict) or part not in value:
        raise SystemExit(1)
    value = value[part]
if not isinstance(value, str) or not value:
    raise SystemExit(1)
sys.stdout.write(value)
' <<<"$plain"
}

aap_demo_vault_import_file() {
  local key="$1" path="$2" value
  [ -s "$path" ] || return 1
  value=$(cat "$path") || return 1
  [ -n "$value" ] || return 1
  aap_demo_vault_set "$key" "$value" || return 1
  rm -f "$path"
}

aap_demo_pull_secret_get() {
  local path value key="aap_demo.redhat.pull_secret"
  value=$(aap_demo_vault_get "$key" 2>/dev/null || true)
  if [ -n "$value" ]; then
    printf '%s' "$value"
    return 0
  fi
  for path in "${AAP_DEMO_DIR:-$HOME/.aap-demo}/pull-secret" \
    "${AAP_DEMO_DIR:-$HOME/.aap-demo}/pull-secret.txt" \
    "${AAP_DEMO_DIR:-$HOME/.aap-demo}/pull-secret.json"; do
    [ -s "$path" ] || continue
    aap_demo_vault_import_file "$key" "$path" || return 1
    aap_demo_vault_get "$key"
    return
  done
  if [ -n "${PULL_SECRET_PATH:-}" ] && [ -s "$PULL_SECRET_PATH" ]; then
    value=$(cat "$PULL_SECRET_PATH") || return 1
    aap_demo_vault_set "$key" "$value" || return 1
    printf '%s' "$value"
    return 0
  fi
  return 1
}

aap_demo_pull_secret_fetch_redhat() {
  local offline_token token_response access_token pull_secret
  local vault_key="aap_demo.redhat.pull_secret"
  local token_url="https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token"
  local pull_secret_url="https://api.openshift.com/api/accounts_mgmt/v1/access_token"
  local credential_vault_dir

  _aap_demo_vault_require_tools || return 1
  offline_token=$(aap_demo_vault_get "aap_demo.redhat.offline_token" 2>/dev/null || true)
  [ -n "$offline_token" ] || return 1
  command -v curl >/dev/null 2>&1 || {
    _err "curl is required to retrieve the OpenShift pull secret"
    return 1
  }

  credential_vault_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=secure-curl.sh
  source "${credential_vault_dir}/secure-curl.sh"

  token_response=$(printf '%s' "$offline_token" | curl --silent --show-error --fail \
    --connect-timeout 15 --max-time 45 \
    --request POST \
    --data-urlencode "grant_type=refresh_token" \
    --data-urlencode "client_id=rhsm-api" \
    --data-urlencode "refresh_token@-" \
    "$token_url") || {
      unset offline_token token_response
      _err "Could not exchange the Red Hat offline token for pull-secret access"
      return 1
    }
  unset offline_token

  access_token=$("$AAP_DEMO_VAULT_PYTHON" -c '
import json
import sys

value = json.load(sys.stdin).get("access_token", "")
if not value:
    raise SystemExit(1)
sys.stdout.write(value)
' <<<"$token_response") || {
    unset token_response access_token
    _err "Red Hat SSO returned an invalid token response"
    return 1
  }
  unset token_response

  pull_secret=$(curl --silent --show-error --fail \
    --connect-timeout 15 --max-time 45 \
    --request POST \
    -H "Accept: application/json" \
    -H "Authorization: Bearer $access_token" \
    "$pull_secret_url") || {
      unset access_token pull_secret
      _err "Could not retrieve the OpenShift pull secret from Red Hat"
      return 1
    }
  unset access_token

  pull_secret=$("$AAP_DEMO_VAULT_PYTHON" -c '
import json
import sys

value = json.load(sys.stdin)
if not isinstance(value, dict) or not isinstance(value.get("auths"), dict) or not value["auths"]:
    raise SystemExit(1)
sys.stdout.write(json.dumps(value, separators=(",", ":")))
' <<<"$pull_secret") || {
    unset pull_secret
    _err "Red Hat returned an invalid OpenShift pull secret"
    return 1
  }

  aap_demo_vault_set "$vault_key" "$pull_secret" || {
    unset pull_secret
    return 1
  }
  printf '%s' "$pull_secret"
  unset pull_secret
}

# Return the Satellite lab admin password, generating and storing it in the
# encrypted Vault on first use so it is never hardcoded in the repo. Every
# caller (installer, content, status, APD wiring) reads from this single source.
aap_demo_satellite_admin_password() {
  local key="aap_demo.satellite.admin_password" value
  value=$(aap_demo_vault_get "$key" 2>/dev/null || true)
  if [ -n "$value" ]; then
    printf '%s' "$value"
    return 0
  fi
  _aap_demo_vault_require_tools || return 1
  value=$("$AAP_DEMO_VAULT_PYTHON" -c 'import secrets; print(secrets.token_urlsafe(24))') || return 1
  aap_demo_vault_set "$key" "$value" || return 1
  printf '%s' "$value"
}

aap_demo_vault_set() {
  local key="$1"
  local value="$2"
  [ "$key" != "aap_demo.galaxy.offline_token" ] || key=ah_offline_token
  _aap_demo_vault_ensure_file || return 1

  local vault_dir plain encrypted
  vault_dir=$(dirname "$AAP_DEMO_VAULT_FILE")
  plain=$(mktemp "${vault_dir}/.env-aap-demo.plain.XXXXXX")
  encrypted=$(mktemp "${vault_dir}/.env-aap-demo.vault.XXXXXX")
  chmod 600 "$plain" "$encrypted"

  if ! "$AAP_DEMO_ANSIBLE_VAULT" view \
    --vault-password-file "$AAP_DEMO_VAULT_PASSWORD_FILE" \
    "$AAP_DEMO_VAULT_FILE" >"$plain"; then
    rm -f "$plain" "$encrypted"
    _err "Unable to decrypt $AAP_DEMO_VAULT_FILE"
    return 1
  fi

  if ! AAP_DEMO_SECRET_KEY="$key" "$AAP_DEMO_VAULT_PYTHON" - "$plain" 3< <(printf '%s' "$value") <<'PY'
import os
import sys
import yaml

path = sys.argv[1]
with open(3, encoding="utf-8", closefd=False) as secret_stream:
    secret_value = secret_stream.read()
with open(path, encoding="utf-8") as stream:
    data = yaml.safe_load(stream) or {}
target = data
parts = os.environ["AAP_DEMO_SECRET_KEY"].split(".")
for part in parts[:-1]:
    child = target.get(part)
    if not isinstance(child, dict):
        child = {}
        target[part] = child
    target = child
target[parts[-1]] = secret_value
if parts == ["ah_offline_token"]:
    legacy = data.get("aap_demo", {})
    if isinstance(legacy, dict) and isinstance(legacy.get("galaxy"), dict):
        legacy["galaxy"].pop("offline_token", None)
with open(path, "w", encoding="utf-8") as stream:
    yaml.safe_dump(data, stream, default_flow_style=False, sort_keys=True)
PY
  then
    rm -f "$plain" "$encrypted"
    _err "Unable to update encrypted credentials"
    return 1
  fi

  if ! "$AAP_DEMO_ANSIBLE_VAULT" encrypt \
    --vault-password-file "$AAP_DEMO_VAULT_PASSWORD_FILE" \
    --output "$encrypted" "$plain" >/dev/null; then
    rm -f "$plain" "$encrypted"
    _err "Unable to encrypt updated credentials"
    return 1
  fi
  rm -f "$plain"
  mv "$encrypted" "$AAP_DEMO_VAULT_FILE"
  _aap_demo_private_mode "$AAP_DEMO_VAULT_FILE"
}

aap_demo_vault_delete() {
  local key="$1"
  [ "$key" != "aap_demo.galaxy.offline_token" ] || key=ah_offline_token
  [ -s "$AAP_DEMO_VAULT_FILE" ] || return 0
  [ -s "$AAP_DEMO_VAULT_PASSWORD_FILE" ] || return 1
  _aap_demo_vault_require_tools || return 1

  local vault_dir plain encrypted
  vault_dir=$(dirname "$AAP_DEMO_VAULT_FILE")
  plain=$(mktemp "${vault_dir}/.env-aap-demo.plain.XXXXXX")
  encrypted=$(mktemp "${vault_dir}/.env-aap-demo.vault.XXXXXX")
  chmod 600 "$plain" "$encrypted"

  if ! "$AAP_DEMO_ANSIBLE_VAULT" view \
    --vault-password-file "$AAP_DEMO_VAULT_PASSWORD_FILE" \
    "$AAP_DEMO_VAULT_FILE" >"$plain"; then
    rm -f "$plain" "$encrypted"
    _err "Unable to decrypt $AAP_DEMO_VAULT_FILE"
    return 1
  fi

  if ! AAP_DEMO_SECRET_KEY="$key" "$AAP_DEMO_VAULT_PYTHON" - "$plain" <<'PY'
import os
import sys
import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    data = yaml.safe_load(stream) or {}
target = data
parts = os.environ["AAP_DEMO_SECRET_KEY"].split(".")
for part in parts[:-1]:
    target = target.get(part)
    if not isinstance(target, dict):
        break
else:
    if isinstance(target, dict):
        target.pop(parts[-1], None)
if parts == ["ah_offline_token"]:
    legacy = data.get("aap_demo", {})
    if isinstance(legacy, dict) and isinstance(legacy.get("galaxy"), dict):
        legacy["galaxy"].pop("offline_token", None)
with open(path, "w", encoding="utf-8") as stream:
    yaml.safe_dump(data, stream, default_flow_style=False, sort_keys=True)
PY
  then
    rm -f "$plain" "$encrypted"
    _err "Unable to update encrypted credentials"
    return 1
  fi

  if ! "$AAP_DEMO_ANSIBLE_VAULT" encrypt \
    --vault-password-file "$AAP_DEMO_VAULT_PASSWORD_FILE" \
    --output "$encrypted" "$plain" >/dev/null; then
    rm -f "$plain" "$encrypted"
    _err "Unable to encrypt updated credentials"
    return 1
  fi
  rm -f "$plain"
  mv "$encrypted" "$AAP_DEMO_VAULT_FILE"
  _aap_demo_private_mode "$AAP_DEMO_VAULT_FILE"
}

# Removes only the aap-demo-managed entries from the shared Vault. The Vault
# file ($AAP_DEMO_VAULT_FILE) and its password file
# ($AAP_DEMO_VAULT_PASSWORD_FILE) are shared with other products and projects,
# so they are never deleted -- even when no aap-demo data remains. Only the
# aap-demo-lineage legacy Vault files are removed entirely.
aap_demo_vault_remove_managed() {
  local vault_dir
  vault_dir=$(dirname "$AAP_DEMO_VAULT_FILE")

  if [ -s "$AAP_DEMO_VAULT_FILE" ]; then
    aap_demo_vault_delete "ah_offline_token" || return 1
    aap_demo_vault_delete "aap_demo" || return 1
  fi

  rm -f -- \
    "$vault_dir/env-aap-demo.yml" \
    "$vault_dir/.vaultpass-aap-demo.txt" \
    "$vault_dir/env_microshift.yml" \
    "$vault_dir/.vaultpass_microshift.txt"
  rmdir "$vault_dir" 2>/dev/null || true
  rmdir "$(dirname "$vault_dir")" 2>/dev/null || true
}
