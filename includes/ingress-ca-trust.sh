#!/usr/bin/env bash
# =============================================================================
# ingress-ca-trust.sh — Trust the MicroShift ingress CA on the local machine
# =============================================================================
#
# Mirrors PowerShell Install-AapIngressCaTrust for bash/Linux/macOS.
# Saves the CA to ~/.aap-demo/crc-ingress-ca.crt and exports CURL_CA_BUNDLE /
# SSL_CERT_FILE for CLI tools.
#
# Usage:
#   source "${SCRIPT_DIR}/includes/ingress-ca-trust.sh"
#   install_ingress_ca_trust
#
# Skip automatic import: AAP_DEMO_TRUST_CA=false
#
# =============================================================================

if [ -n "${_INGRESS_CA_TRUST_LOADED:-}" ]; then return 0; fi
_INGRESS_CA_TRUST_LOADED=1

_INGRESS_CA_ANCHOR_NAME='crc-ingress-ca.crt'
_INGRESS_CA_NSS_NICKNAME='crc-ingress-ca'
_INGRESS_CA_RHEL_ANCHOR="/etc/pki/ca-trust/source/anchors/${_INGRESS_CA_ANCHOR_NAME}"
_INGRESS_CA_DEBIAN_ANCHOR="/usr/local/share/ca-certificates/${_INGRESS_CA_ANCHOR_NAME}"

get_ingress_ca_cert_path() {
  local ca_dir="${AAP_DEMO_CONFIG_DIR:-${HOME}/.aap-demo}"
  echo "${ca_dir}/${_INGRESS_CA_ANCHOR_NAME}"
}

_ingress_ca_fingerprint() {
  local path="$1"
  openssl x509 -in "$path" -noout -fingerprint -sha256 2>/dev/null \
    | sed -E 's/sha256 [Ff]ingerprint=//' | tr -d ':' | tr '[:lower:]' '[:upper:]'
}

_ingress_ca_trust_list_contains() {
  local fingerprint="$1"
  command -v trust &>/dev/null || return 1
  trust list --filter=ca-anchors 2>/dev/null | tr -d ':' | grep -qi "$fingerprint"
}

_ingress_ca_installed_fingerprint_linux() {
  if [ -f "$_INGRESS_CA_RHEL_ANCHOR" ]; then
    _ingress_ca_fingerprint "$_INGRESS_CA_RHEL_ANCHOR"
    return 0
  fi
  if [ -f "$_INGRESS_CA_DEBIAN_ANCHOR" ]; then
    _ingress_ca_fingerprint "$_INGRESS_CA_DEBIAN_ANCHOR"
    return 0
  fi
  return 1
}

_ingress_ca_installed_fingerprint_macos() {
  local fp
  fp=$(security find-certificate -a -p -c "ingress-ca" /Library/Keychains/System.keychain 2>/dev/null \
    | awk '/BEGIN CERTIFICATE/{p=1} p{print} /END CERTIFICATE/{exit}' \
    | openssl x509 -noout -fingerprint -sha256 2>/dev/null \
    | sed -E 's/sha256 [Ff]ingerprint=//' | tr -d ':' | tr '[:lower:]' '[:upper:]')
  if [ -n "$fp" ]; then
    echo "$fp"
    return 0
  fi
}

_ingress_ca_in_trust_store() {
  local path="$1"
  local fingerprint installed_fingerprint

  [ -f "$path" ] || return 1
  grep -q 'BEGIN CERTIFICATE' "$path" || return 1

  fingerprint=$(_ingress_ca_fingerprint "$path")
  [ -n "$fingerprint" ] || return 1

  if [[ "$(uname)" == "Darwin" ]]; then
    installed_fingerprint=$(_ingress_ca_installed_fingerprint_macos)
  else
    installed_fingerprint=$(_ingress_ca_installed_fingerprint_linux)
    if [ -z "$installed_fingerprint" ] && _ingress_ca_trust_list_contains "$fingerprint"; then
      return 0
    fi
  fi

  [ -n "$installed_fingerprint" ] && [ "$fingerprint" = "$installed_fingerprint" ]
}

_ingress_ca_nss_db_paths() {
  # Chrome/Chromium use NSS, not system ca-trust. Chromium prefers ~/.pki/nssdb
  # when it exists, otherwise ~/.local/share/pki/nssdb (since M146).
  if [ -d "${HOME}/.pki/nssdb" ]; then
    echo "sql:${HOME}/.pki/nssdb"
  fi
  if [ -d "${HOME}/.local/share/pki/nssdb" ]; then
    echo "sql:${HOME}/.local/share/pki/nssdb"
  fi
  # Firefox keeps a cert9.db per profile — enumerate all profiles.
  if [ -d "${HOME}/.mozilla/firefox" ]; then
    while IFS= read -r -d '' profile_dir; do
      [ -f "${profile_dir}/cert9.db" ] && echo "sql:${profile_dir}"
    done < <(find "${HOME}/.mozilla/firefox" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  fi
}

_ingress_ca_nss_cert_fingerprint() {
  local db="$1"
  certutil -d "$db" -L -n "$_INGRESS_CA_NSS_NICKNAME" -a 2>/dev/null \
    | awk '/BEGIN CERTIFICATE/{p=1} p{print} /END CERTIFICATE/{exit}' \
    | openssl x509 -noout -fingerprint -sha256 2>/dev/null \
    | sed -E 's/sha256 [Ff]ingerprint=//' | tr -d ':' | tr '[:lower:]' '[:upper:]'
}

_ingress_ca_in_nss_store() {
  local path="$1"
  local db expected_fp installed_fp

  command -v certutil &>/dev/null || return 1

  expected_fp=$(_ingress_ca_fingerprint "$path")
  [ -n "$expected_fp" ] || return 1

  # No NSS DB yet — browser has not created one; import will initialize trust.
  if [ -z "$(_ingress_ca_nss_db_paths)" ]; then
    return 1
  fi

  while IFS= read -r db; do
    [ -n "$db" ] || continue
    installed_fp=$(_ingress_ca_nss_cert_fingerprint "$db")
    [ "$installed_fp" = "$expected_fp" ] || return 1
  done < <(_ingress_ca_nss_db_paths)

  return 0
}

_ingress_ca_fully_trusted() {
  local path="$1"

  _ingress_ca_in_trust_store "$path" || return 1
  if [[ "$(uname)" == "Darwin" ]]; then
    return 0
  fi
  _ingress_ca_in_nss_store "$path" || return 1
}

_ingress_ca_export_env() {
  local ca_path="$1"
  export CURL_CA_BUNDLE="$ca_path"
  export SSL_CERT_FILE="$ca_path"
}

_fetch_ingress_ca_from_cluster() {
  local dest="$1"

  # Primary: extract the CA from the router-certs-default secret chain (works without SSH)
  if command -v kubectl &>/dev/null; then
    local chain
    chain=$(kubectl get secret router-certs-default -n openshift-ingress \
      -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null)
    if [ -n "$chain" ]; then
      # The chain is leaf + CA; extract the last cert (the self-signed ingress-ca)
      echo "$chain" | awk '
        /BEGIN CERTIFICATE/ { p=1; buf="" }
        p { buf = buf $0 "\n" }
        /END CERTIFICATE/ { last = buf; p=0 }
        END { printf "%s", last }
      ' >"$dest"
      [ -s "$dest" ] && grep -q 'BEGIN CERTIFICATE' "$dest" && return 0
    fi
  fi

  # Fallback: fetch via SSH from the MicroShift filesystem
  if [ -n "$CRC_SSH_KEY" ]; then
    ssh -p 2222 "${CRC_SSH_OPTS[@]}" core@127.0.0.1 \
      'sudo cat /var/lib/microshift/certs/ingress-ca/ca.crt' >"$dest" 2>/dev/null
    [ -s "$dest" ] && grep -q 'BEGIN CERTIFICATE' "$dest" && return 0
  fi

  return 1
}

_import_ingress_ca_linux() {
  local path="$1"

  if [ -d /etc/pki/ca-trust/source/anchors ]; then
    if sudo cp "$path" "$_INGRESS_CA_RHEL_ANCHOR" \
      && sudo update-ca-trust; then
      echo "  ✓ Ingress CA trusted (system ca-trust)"
      return 0
    fi
  elif [ -d /usr/local/share/ca-certificates ]; then
    if sudo cp "$path" "$_INGRESS_CA_DEBIAN_ANCHOR" \
      && sudo update-ca-certificates; then
      echo "  ✓ Ingress CA trusted (system ca-certificates)"
      return 0
    fi
  fi

  echo "  Could not add CA to system trust store (sudo may be required)" >&2
  echo "  Manual import: sudo cp ${path} ${_INGRESS_CA_RHEL_ANCHOR} && sudo update-ca-trust" >&2
  return 1
}

_import_ingress_ca_nss() {
  local path="$1"
  local db imported=false

  if ! command -v certutil &>/dev/null; then
    if command -v dnf &>/dev/null; then
      echo "  Installing nss-tools for Chrome/Firefox browser trust..."
      sudo dnf install -y nss-tools &>/dev/null \
        && echo "  ✓ nss-tools installed" \
        || {
          echo "  Could not install nss-tools (sudo dnf install nss-tools)" >&2
          return 1
        }
    else
      echo "  certutil not found — install nss-tools manually for browser trust" >&2
      return 1
    fi
  fi

  local dbs=()
  while IFS= read -r db; do
    [ -n "$db" ] && dbs+=("$db")
  done < <(_ingress_ca_nss_db_paths)

  if [ "${#dbs[@]}" -eq 0 ]; then
    mkdir -p "${HOME}/.pki/nssdb"
    dbs=("sql:${HOME}/.pki/nssdb")
  fi

  for db in "${dbs[@]}"; do
    certutil -d "$db" -D -n "$_INGRESS_CA_NSS_NICKNAME" 2>/dev/null || true
    if certutil -d "$db" -A -t "C,," -n "$_INGRESS_CA_NSS_NICKNAME" -i "$path" 2>/dev/null; then
      imported=true
    fi
  done

  if [ "$imported" = true ]; then
    echo "  ✓ Ingress CA trusted (Chrome/Firefox NSS)"
    echo "  Fully quit Chrome and reopen the AAP URL if it still shows untrusted"
    return 0
  fi

  echo "  Could not import ingress CA to browser certificate store" >&2
  return 1
}

_import_ingress_ca_macos() {
  local path="$1"

  while sudo security delete-certificate -c "ingress-ca" /Library/Keychains/System.keychain 2>/dev/null; do :; done
  if sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$path"; then
    if security find-certificate -a -c "ingress-ca" /Library/Keychains/System.keychain &>/dev/null; then
      echo "  ✓ Ingress CA trusted (macOS keychain)"
      echo "  Fully quit Safari/Chrome and reopen the AAP URL if it still shows untrusted"
      return 0
    fi
  fi

  echo "  Could not add CA to macOS keychain (admin password required)" >&2
  echo "  Manual import: sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ${path}" >&2
  return 1
}

_purge_ingress_ca_trust() {
  local db

  if [[ "$(uname)" == "Darwin" ]]; then
    while sudo security delete-certificate -c "ingress-ca" /Library/Keychains/System.keychain 2>/dev/null; do :; done
    return 0
  fi

  if [ -f "$_INGRESS_CA_RHEL_ANCHOR" ]; then
    sudo rm -f "$_INGRESS_CA_RHEL_ANCHOR"
    sudo update-ca-trust 2>/dev/null || true
  fi
  if [ -f "$_INGRESS_CA_DEBIAN_ANCHOR" ]; then
    sudo rm -f "$_INGRESS_CA_DEBIAN_ANCHOR"
    sudo update-ca-certificates 2>/dev/null || true
  fi

  if command -v certutil &>/dev/null; then
    while IFS= read -r db; do
      [ -n "$db" ] || continue
      certutil -d "$db" -D -n "$_INGRESS_CA_NSS_NICKNAME" 2>/dev/null || true
    done < <(_ingress_ca_nss_db_paths)
  fi
}

import_ingress_ca_certificate() {
  local path="$1"
  local force="${2:-false}"

  [ -f "$path" ] || return 1
  grep -q 'BEGIN CERTIFICATE' "$path" || return 1

  if [ "$force" != "true" ] && _ingress_ca_fully_trusted "$path"; then
    echo "  ✓ Ingress CA already trusted"
    return 0
  fi

  if [ "$force" = "true" ]; then
    _purge_ingress_ca_trust
  fi

  local ok=true
  if [[ "$(uname)" == "Darwin" ]]; then
    _import_ingress_ca_macos "$path" || ok=false
  else
    _ingress_ca_in_trust_store "$path" || _import_ingress_ca_linux "$path" || ok=false
    _ingress_ca_in_nss_store "$path" || _import_ingress_ca_nss "$path" || ok=false
  fi
  [ "$ok" = true ]
}

ingress_ca_trust_status() {
  local ca_path="$1"
  local system_status="missing"
  local browser_status="n/a"

  if [ ! -f "$ca_path" ] || ! grep -q 'BEGIN CERTIFICATE' "$ca_path"; then
    printf "  %-18s %s\n" "Ingress CA file:" "not saved"
    printf "  %-18s %s\n" "Browser trust:" "unknown (run aap-demo deploy or create)"
    return 1
  fi

  printf "  %-18s %s\n" "Ingress CA file:" "$ca_path"

  if _ingress_ca_in_trust_store "$ca_path"; then
    system_status="trusted"
  else
    system_status="not trusted"
  fi

  if [[ "$(uname)" == "Darwin" ]]; then
    browser_status="$system_status (macOS keychain)"
  elif _ingress_ca_in_nss_store "$ca_path"; then
    browser_status="trusted (Chrome/Firefox NSS)"
  elif command -v certutil &>/dev/null; then
    browser_status="not trusted"
  else
    browser_status="unknown (install nss-tools for Chrome/Firefox)"
  fi

  printf "  %-18s %s\n" "System trust:" "$system_status"
  printf "  %-18s %s\n" "Browser trust:" "$browser_status"

  if [ "$system_status" = "not trusted" ] || [[ "$browser_status" == not\ trusted* ]]; then
    echo "  Run: aap-demo deploy   # re-import ingress CA"
    if [[ "$(uname)" != "Darwin" ]]; then
      echo "  Linux browsers (Chrome/Firefox) need NSS trust — ensure nss-tools is installed"
      echo "  Manual: certutil -d sql:\$HOME/.pki/nssdb -A -t \"C,,\" -n crc-ingress-ca -i $ca_path"
    fi
    echo "  Then fully quit and reopen your browser"
    return 1
  fi
  return 0
}

_ingress_ca_cluster_fingerprint() {
  local tmp fingerprint
  tmp=$(mktemp)
  if ! _fetch_ingress_ca_from_cluster "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  fingerprint=$(_ingress_ca_fingerprint "$tmp")
  rm -f "$tmp"
  [ -n "$fingerprint" ] || return 1
  echo "$fingerprint"
}

_ingress_ca_refresh_from_cluster() {
  local ca_path="$1"
  local tmp
  tmp=$(mktemp)
  if ! _fetch_ingress_ca_from_cluster "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$ca_path"
  chmod 644 "$ca_path"
  return 0
}

install_ingress_ca_trust() {
  if [ "${AAP_DEMO_TRUST_CA:-true}" = "false" ]; then
    return 0
  fi

  local ca_path cluster_fp saved_fp=""
  ca_path=$(get_ingress_ca_cert_path)
  mkdir -p "$(dirname "$ca_path")"

  cluster_fp=$(_ingress_ca_cluster_fingerprint 2>/dev/null || true)
  if [ -f "$ca_path" ]; then
    saved_fp=$(_ingress_ca_fingerprint "$ca_path")
  fi

  # Cluster recreate issues a new ingress CA — re-trust when fingerprints differ.
  if [ -n "$cluster_fp" ] && [ "$cluster_fp" != "$saved_fp" ]; then
    echo "Trusting ingress CA..."
    if ! _ingress_ca_refresh_from_cluster "$ca_path"; then
      echo "  Could not fetch ingress CA from cluster" >&2
      return 0
    fi
    import_ingress_ca_certificate "$ca_path" true || {
      echo "  ⚠ Ingress CA saved to $ca_path but automatic trust import failed" >&2
      echo "  CLI tools can use CURL_CA_BUNDLE=$ca_path; browsers may still warn until imported" >&2
    }
    _ingress_ca_export_env "$ca_path"
    return 0
  fi

  if [ -f "$ca_path" ] && _ingress_ca_fully_trusted "$ca_path"; then
    _ingress_ca_export_env "$ca_path"
    return 0
  fi

  echo "Trusting ingress CA..."

  local tmp
  tmp=$(mktemp)
  if _fetch_ingress_ca_from_cluster "$tmp"; then
    mv "$tmp" "$ca_path"
    chmod 644 "$ca_path"
  else
    rm -f "$tmp"
    if [ ! -f "$ca_path" ] || ! grep -q 'BEGIN CERTIFICATE' "$ca_path"; then
      echo "  Could not fetch ingress CA from cluster" >&2
      return 0
    fi
  fi

  import_ingress_ca_certificate "$ca_path" || {
    echo "  ⚠ Ingress CA saved to $ca_path but automatic trust import failed" >&2
    echo "  CLI tools can use CURL_CA_BUNDLE=$ca_path; browsers may still warn until imported" >&2
  }
  _ingress_ca_export_env "$ca_path"
  return 0
}
