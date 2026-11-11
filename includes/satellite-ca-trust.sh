#!/usr/bin/env bash
# =============================================================================
# satellite-ca-trust.sh — Trust the Satellite lab's Katello CA on the host
# =============================================================================
#
# The Satellite VM serves a self-signed certificate from its own internal CA
# (issuer = subject = satellite.demo.lab). Browsers and CLI tools reject it
# with ERR_CERT_AUTHORITY_INVALID until the CA is trusted. This mirrors the
# dual-store pattern of ingress-ca-trust.sh (ADR-015): the OS store covers
# curl/hammer/ansible, and the NSS stores cover Chrome/Chromium/Firefox.
#
# The CA is fetched from the Satellite's own unauthenticated /pub/ endpoint —
# the same place registered clients pull katello-ca-consumer from.
#
# Usage:
#   source "${SCRIPT_DIR}/includes/satellite-ca-trust.sh"
#   install_satellite_ca_trust            # fetch + import (idempotent)
#   purge_satellite_ca_trust              # remove from all stores
#
# Skip automatic import: AAP_DEMO_TRUST_CA=false
#
# =============================================================================

if [ -n "${_SATELLITE_CA_TRUST_LOADED:-}" ]; then return 0; fi
_SATELLITE_CA_TRUST_LOADED=1

_SATELLITE_CA_HOST="${SATELLITE_LAB_HOST:-satellite.demo.lab}"
_SATELLITE_CA_ANCHOR_NAME='satellite-demo-lab-ca.crt'
_SATELLITE_CA_NSS_NICKNAME='satellite-demo-lab-ca'
_SATELLITE_CA_RHEL_ANCHOR="/etc/pki/ca-trust/source/anchors/${_SATELLITE_CA_ANCHOR_NAME}"
_SATELLITE_CA_DEBIAN_ANCHOR="/usr/local/share/ca-certificates/${_SATELLITE_CA_ANCHOR_NAME}"

# Fetch the Katello CA over HTTPS without verifying (it is self-signed by
# definition). We then sanity-check that it is a CA certificate before import.
_fetch_satellite_ca() {
  local dest="$1"
  command -v curl >/dev/null 2>&1 || return 1
  curl -sk --connect-timeout 10 \
    "https://${_SATELLITE_CA_HOST}/pub/katello-server-ca.crt" -o "$dest" 2>/dev/null
  [ -s "$dest" ] && grep -q 'BEGIN CERTIFICATE' "$dest" || return 1
  # Must be a CA cert (basicConstraints CA:TRUE); refuse a leaf.
  openssl x509 -in "$dest" -noout -text 2>/dev/null | grep -q 'CA:TRUE' || return 1
  return 0
}

_satellite_ca_fingerprint() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null \
    | sed -E 's/sha256 [Ff]ingerprint=//' | tr -d ':' | tr '[:lower:]' '[:upper:]'
}

_satellite_ca_already_trusted() {
  local path="$1" fp installed
  [ -f "$path" ] || return 1
  fp=$(_satellite_ca_fingerprint "$path")
  [ -n "$fp" ] || return 1
  for anchor in "$_SATELLITE_CA_RHEL_ANCHOR" "$_SATELLITE_CA_DEBIAN_ANCHOR"; do
    if [ -f "$anchor" ]; then
      installed=$(_satellite_ca_fingerprint "$anchor")
      [ -n "$installed" ] && [ "$fp" = "$installed" ] && return 0
    fi
  done
  return 1
}

_import_satellite_ca_linux() {
  local path="$1"
  if [ -d /etc/pki/ca-trust/source/anchors ]; then
    if sudo cp "$path" "$_SATELLITE_CA_RHEL_ANCHOR" && sudo update-ca-trust; then
      echo "  ✓ Satellite CA trusted (system ca-trust)"
      return 0
    fi
  elif [ -d /usr/local/share/ca-certificates ]; then
    if sudo cp "$path" "$_SATELLITE_CA_DEBIAN_ANCHOR" && sudo update-ca-certificates; then
      echo "  ✓ Satellite CA trusted (system ca-certificates)"
      return 0
    fi
  fi
  echo "  Could not add Satellite CA to system trust store (sudo may be required)" >&2
  echo "  Manual import: sudo cp ${path} ${_SATELLITE_CA_RHEL_ANCHOR} && sudo update-ca-trust" >&2
  return 1
}

_satellite_ca_nss_db_paths() {
  if [ -d "${HOME}/.pki/nssdb" ]; then
    echo "sql:${HOME}/.pki/nssdb"
  fi
  if [ -d "${HOME}/.local/share/pki/nssdb" ]; then
    echo "sql:${HOME}/.local/share/pki/nssdb"
  fi
  if [ -d "${HOME}/.mozilla/firefox" ]; then
    while IFS= read -r -d '' profile_dir; do
      [ -f "${profile_dir}/cert9.db" ] && echo "sql:${profile_dir}"
    done < <(find "${HOME}/.mozilla/firefox" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  fi
}

_import_satellite_ca_nss() {
  local path="$1" db imported=false

  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) return 1 ;;
  esac

  if ! command -v certutil >/dev/null 2>&1; then
    if command -v dnf >/dev/null 2>&1; then
      echo "  Installing nss-tools for Chrome/Firefox browser trust..."
      sudo dnf install -y nss-tools >/dev/null 2>&1 || {
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
  done < <(_satellite_ca_nss_db_paths)

  if [ "${#dbs[@]}" -eq 0 ]; then
    mkdir -p "${HOME}/.pki/nssdb"
    dbs=("sql:${HOME}/.pki/nssdb")
  fi

  for db in "${dbs[@]}"; do
    certutil -d "$db" -D -n "$_SATELLITE_CA_NSS_NICKNAME" 2>/dev/null || true
    if certutil -d "$db" -A -t "C,," -n "$_SATELLITE_CA_NSS_NICKNAME" -i "$path" 2>/dev/null; then
      imported=true
    fi
  done

  if [ "$imported" = true ]; then
    echo "  ✓ Satellite CA trusted (Chrome/Firefox NSS)"
    echo "  Fully quit the browser and reopen https://${_SATELLITE_CA_HOST} if it still shows untrusted"
    return 0
  fi
  echo "  Could not import Satellite CA to browser certificate store" >&2
  return 1
}

_import_satellite_ca_macos() {
  local path="$1"
  while sudo security delete-certificate -c "$_SATELLITE_CA_HOST" /Library/Keychains/System.keychain 2>/dev/null; do :; done
  if sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$path"; then
    echo "  ✓ Satellite CA trusted (macOS keychain)"
    echo "  Fully quit Safari/Chrome and reopen https://${_SATELLITE_CA_HOST} if it still shows untrusted"
    return 0
  fi
  echo "  Could not add Satellite CA to macOS keychain (admin password required)" >&2
  return 1
}

install_satellite_ca_trust() {
  if [ "${AAP_DEMO_TRUST_CA:-true}" != "true" ]; then
    echo "  Skipping Satellite CA trust (AAP_DEMO_TRUST_CA=false)"
    return 0
  fi

  local tmp
  tmp=$(mktemp 2>/dev/null || echo "/tmp/satellite-ca.$$.crt")
  if ! _fetch_satellite_ca "$tmp"; then
    echo "  Satellite CA not reachable at https://${_SATELLITE_CA_HOST}/pub/ — skipping trust" >&2
    rm -f "$tmp"
    return 1
  fi

  if _satellite_ca_already_trusted "$tmp"; then
    echo "  ✓ Satellite CA already trusted"
    rm -f "$tmp"
    return 0
  fi

  local rc=0
  if [[ "$(uname)" == "Darwin" ]]; then
    _import_satellite_ca_macos "$tmp" || rc=1
  else
    _import_satellite_ca_linux "$tmp" || rc=1
    _import_satellite_ca_nss "$tmp" || true
  fi
  rm -f "$tmp"
  return $rc
}

purge_satellite_ca_trust() {
  local db
  if [[ "$(uname)" == "Darwin" ]]; then
    while sudo security delete-certificate -c "$_SATELLITE_CA_HOST" /Library/Keychains/System.keychain 2>/dev/null; do :; done
    return 0
  fi
  if [ -f "$_SATELLITE_CA_RHEL_ANCHOR" ]; then
    sudo rm -f "$_SATELLITE_CA_RHEL_ANCHOR"
    sudo update-ca-trust 2>/dev/null || true
  fi
  if [ -f "$_SATELLITE_CA_DEBIAN_ANCHOR" ]; then
    sudo rm -f "$_SATELLITE_CA_DEBIAN_ANCHOR"
    sudo update-ca-certificates 2>/dev/null || true
  fi
  if command -v certutil >/dev/null 2>&1; then
    while IFS= read -r db; do
      [ -n "$db" ] || continue
      certutil -d "$db" -D -n "$_SATELLITE_CA_NSS_NICKNAME" 2>/dev/null || true
    done < <(_satellite_ca_nss_db_paths)
  fi
}
