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
  security find-certificate -a -p -c "ingress-ca" /Library/Keychains/System.keychain 2>/dev/null \
    | awk '/BEGIN CERTIFICATE/{p=1} p{print} /END CERTIFICATE/{exit}' \
    | openssl x509 -noout -fingerprint -sha256 2>/dev/null \
    | sed -E 's/sha256 [Ff]ingerprint=//' | tr -d ':' | tr '[:lower:]' '[:upper:]'
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

_ingress_ca_export_env() {
  local ca_path="$1"
  export CURL_CA_BUNDLE="$ca_path"
  export SSL_CERT_FILE="$ca_path"
}

_fetch_ingress_ca_from_cluster() {
  local dest="$1"
  local crc_ssh_key="${HOME}/.crc/machines/crc/id_ed25519"
  local crc_ssh_opts

  [ -f "$crc_ssh_key" ] || return 1

  crc_ssh_opts="-i ${crc_ssh_key} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
  ssh -p 2222 $crc_ssh_opts core@127.0.0.1 \
    'sudo cat /var/lib/microshift/certs/ingress-ca/ca.crt' >"$dest" 2>/dev/null

  [ -s "$dest" ] && grep -q 'BEGIN CERTIFICATE' "$dest"
}

_import_ingress_ca_linux() {
  local path="$1"

  if [ -d /etc/pki/ca-trust/source/anchors ]; then
    if sudo cp "$path" "$_INGRESS_CA_RHEL_ANCHOR" 2>/dev/null \
      && sudo update-ca-trust 2>/dev/null; then
      echo "  ✓ Ingress CA trusted (system ca-trust)"
      return 0
    fi
  elif [ -d /usr/local/share/ca-certificates ]; then
    if sudo cp "$path" "$_INGRESS_CA_DEBIAN_ANCHOR" 2>/dev/null \
      && sudo update-ca-certificates 2>/dev/null; then
      echo "  ✓ Ingress CA trusted (system ca-certificates)"
      return 0
    fi
  fi

  echo "  Could not add CA to system trust store (sudo may be required)" >&2
  echo "  Manual import: sudo cp ${path} ${_INGRESS_CA_RHEL_ANCHOR} && sudo update-ca-trust" >&2
  return 1
}

_import_ingress_ca_macos() {
  local path="$1"

  while sudo security delete-certificate -c "ingress-ca" /Library/Keychains/System.keychain 2>/dev/null; do :; done
  if sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$path" 2>/dev/null; then
    echo "  ✓ Ingress CA trusted (macOS keychain)"
    return 0
  fi

  echo "  Could not add CA to macOS keychain (may need admin password)" >&2
  return 1
}

import_ingress_ca_certificate() {
  local path="$1"

  [ -f "$path" ] || return 1
  grep -q 'BEGIN CERTIFICATE' "$path" || return 1

  if _ingress_ca_in_trust_store "$path"; then
    echo "  ✓ Ingress CA already trusted"
    return 0
  fi

  if [[ "$(uname)" == "Darwin" ]]; then
    _import_ingress_ca_macos "$path"
  else
    _import_ingress_ca_linux "$path"
  fi
}

install_ingress_ca_trust() {
  if [ "${AAP_DEMO_TRUST_CA:-true}" = "false" ]; then
    return 0
  fi

  local ca_path
  ca_path=$(get_ingress_ca_cert_path)
  mkdir -p "$(dirname "$ca_path")"

  if [ -f "$ca_path" ] && _ingress_ca_in_trust_store "$ca_path"; then
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

  import_ingress_ca_certificate "$ca_path" || true
  _ingress_ca_export_env "$ca_path"
  return 0
}
