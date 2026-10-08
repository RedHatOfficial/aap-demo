#!/usr/bin/env bash
# =============================================================================
# ingress-ca-trust.sh — Trust the MicroShift ingress CA on the local machine
# =============================================================================
#
# Mirrors PowerShell Install-AapIngressCaTrust for bash/Linux/macOS.
# Saves the CA to ~/.aap-demo/crc-ingress-ca.crt. CURL_CA_BUNDLE / SSL_CERT_FILE
# replace the default trust store, so they are only exported when the CA is not
# already in the OS store (Fedora/RHEL ca-trust, Debian ca-certificates, macOS
# keychain). In that case a combined bundle (system CAs + ingress CA) is used.
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
  local leaf_path="${2:-}"
  local hostname="${3:-}"
  local fingerprint installed_fingerprint

  [ -f "$path" ] || return 1
  grep -q 'BEGIN CERTIFICATE' "$path" || return 1

  fingerprint=$(_ingress_ca_fingerprint "$path")
  [ -n "$fingerprint" ] || return 1

  if [[ "$(uname)" == "Darwin" ]]; then
    if [ -n "$leaf_path" ] && [ -n "$hostname" ]; then
      _ingress_ca_macos_server_certificate_trusted "$path" "$leaf_path" "$hostname"
      return $?
    fi
    installed_fingerprint=$(_ingress_ca_installed_fingerprint_macos)
  else
    installed_fingerprint=$(_ingress_ca_installed_fingerprint_linux)
    if [ -z "$installed_fingerprint" ] && _ingress_ca_trust_list_contains "$fingerprint"; then
      return 0
    fi
  fi

  [ -n "$installed_fingerprint" ] && [ "$fingerprint" = "$installed_fingerprint" ]
}

_ingress_ca_macos_verification_host() {
  local leaf="$1"
  local san

  san=$(openssl x509 -in "$leaf" -noout -text 2>/dev/null | awk '
    /X509v3 Subject Alternative Name/ {
      if (getline > 0 && match($0, /DNS:[^, ]+/)) {
        print substr($0, RSTART + 4, RLENGTH - 4)
        exit
      }
    }
  ')
  [ -n "$san" ] || return 1

  case "$san" in
    \*.*) printf 'aap-demo-cert-check.%s\n' "${san#*.}" ;;
    *) printf '%s\n' "$san" ;;
  esac
}

_ingress_ca_macos_server_certificate_trusted() {
  local ca_path="$1"
  local leaf_path="$2"
  local hostname="$3"

  [ -f "$ca_path" ] && [ -f "$leaf_path" ] && [ -n "$hostname" ] || return 1
  openssl verify -CAfile "$ca_path" "$leaf_path" >/dev/null 2>&1 || return 1
  security verify-cert -L -c "$leaf_path" -p ssl -s "$hostname" \
    -k /Library/Keychains/System.keychain >/dev/null 2>&1
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
  local leaf_path="${2:-}"
  local hostname="${3:-}"

  if [[ "$(uname)" == "Darwin" ]]; then
    _ingress_ca_macos_server_certificate_trusted "$path" "$leaf_path" "$hostname"
    return $?
  fi
  _ingress_ca_in_trust_store "$path" || return 1
  _ingress_ca_in_nss_store "$path" || return 1
}

_ingress_ca_system_bundle() {
  local p
  for p in \
    "${AAP_DEMO_SYSTEM_CA_BUNDLE:-}" \
    /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem \
    /etc/pki/tls/certs/ca-bundle.crt \
    /etc/pki/tls/cert.pem \
    /etc/ssl/certs/ca-certificates.crt \
    /etc/ssl/cert.pem; do
    [ -n "$p" ] && [ -f "$p" ] && [ -s "$p" ] || continue
    echo "$p"
    return 0
  done
  return 1
}

get_ingress_ca_cli_bundle_path() {
  local ca_dir="${AAP_DEMO_CONFIG_DIR:-${HOME}/.aap-demo}"
  echo "${ca_dir}/ca-bundle.crt"
}

_ingress_ca_export_standalone() {
  local ca_path="$1"

  echo "  ⚠ Exporting standalone ingress CA as CURL_CA_BUNDLE (public HTTPS may fail)" >&2
  echo "  Import the ingress CA to your OS trust store or set AAP_DEMO_SYSTEM_CA_BUNDLE" >&2
  export CURL_CA_BUNDLE="$ca_path"
  export SSL_CERT_FILE="$ca_path"
  export REQUESTS_CA_BUNDLE="$ca_path"
}

_ingress_ca_export_env() {
  local ca_path="$1"
  local leaf_path="${2:-}"
  local hostname="${3:-}"
  local combined sys_bundle

  [ -f "$ca_path" ] || return 0

  # CURL_CA_BUNDLE / SSL_CERT_FILE replace OpenSSL's default store. After
  # update-ca-trust on Fedora/RHEL the ingress CA is already in that store, so
  # exporting the standalone PEM breaks public HTTPS (e.g. GitHub operator-sdk).
  if _ingress_ca_in_trust_store "$ca_path" "$leaf_path" "$hostname"; then
    unset CURL_CA_BUNDLE SSL_CERT_FILE REQUESTS_CA_BUNDLE
    return 0
  fi

  combined=$(get_ingress_ca_cli_bundle_path)
  mkdir -p "$(dirname "$combined")"

  if sys_bundle=$(_ingress_ca_system_bundle); then
    if cat "$sys_bundle" "$ca_path" >"$combined" 2>/dev/null; then
      chmod 644 "$combined"
      export CURL_CA_BUNDLE="$combined"
      export SSL_CERT_FILE="$combined"
      export REQUESTS_CA_BUNDLE="$combined"
      return 0
    fi
    echo "  ⚠ Could not write combined CA bundle to $combined" >&2
  else
    echo "  ⚠ No system CA bundle found on this host" >&2
  fi

  _ingress_ca_export_standalone "$ca_path"
}

_fetch_ingress_ca_from_cluster() {
  local dest="$1"
  local leaf_dest="${2:-}"

  # Primary: extract the CA from the router-certs-default secret chain (works without SSH)
  if command -v kubectl &>/dev/null; then
    local chain
    chain=$(kubectl get secret router-certs-default -n openshift-ingress \
      -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null)
    if [ -n "$chain" ]; then
      if [ -n "$leaf_dest" ]; then
        echo "$chain" | awk '
          /BEGIN CERTIFICATE/ { p=1; n++ }
          p { print }
          /END CERTIFICATE/ { if (p) exit }
        ' >"$leaf_dest"
      fi
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

  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*)
      # Git Bash's certutil is the Windows utility, not NSS certutil. Browser
      # trust is imported by the PowerShell wrapper into the Windows store.
      return 1
      ;;
  esac

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
  local leaf_path="${2:-}"
  local hostname="${3:-}"

  while sudo security delete-certificate -c "ingress-ca" /Library/Keychains/System.keychain 2>/dev/null; do :; done
  if sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$path"; then
    if security find-certificate -a -c "ingress-ca" /Library/Keychains/System.keychain &>/dev/null \
      && { [ -z "$leaf_path" ] || [ -z "$hostname" ] \
        || _ingress_ca_macos_server_certificate_trusted "$path" "$leaf_path" "$hostname"; }; then
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
  local leaf_path="${3:-}"
  local hostname="${4:-}"

  [ -f "$path" ] || return 1
  grep -q 'BEGIN CERTIFICATE' "$path" || return 1

  if [ "$force" != "true" ] && _ingress_ca_fully_trusted "$path" "$leaf_path" "$hostname"; then
    echo "  ✓ Ingress CA already trusted"
    return 0
  fi

  # On macOS, certificate removal and replacement must share the native
  # administrator-authorization prompt used by _import_ingress_ca_macos.
  if [ "$force" = "true" ] && [[ "$(uname)" != "Darwin" ]]; then
    _purge_ingress_ca_trust
  fi

  local ok=true
  if [[ "$(uname)" == "Darwin" ]]; then
    _import_ingress_ca_macos "$path" "$leaf_path" "$hostname" || ok=false
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
  local live_ca_path="" leaf_path="" hostname=""

  if [ ! -f "$ca_path" ] || ! grep -q 'BEGIN CERTIFICATE' "$ca_path"; then
    printf "  %-18s %s\n" "Ingress CA file:" "not saved"
    printf "  %-18s %s\n" "Browser trust:" "unknown (run aap-demo trust-ca)"
    return 1
  fi

  printf "  %-18s %s\n" "Ingress CA file:" "$ca_path"

  if [[ "$(uname)" == "Darwin" ]]; then
    live_ca_path=$(mktemp)
    leaf_path=$(mktemp)
    if _fetch_ingress_ca_from_cluster "$live_ca_path" "$leaf_path"; then
      hostname=$(_ingress_ca_macos_verification_host "$leaf_path" 2>/dev/null || true)
      if [ -n "$hostname" ] && _ingress_ca_macos_server_certificate_trusted "$ca_path" "$leaf_path" "$hostname"; then
        system_status="trusted"
      else
        system_status="not trusted"
      fi
    else
      system_status="unknown"
    fi
    rm -f "$live_ca_path" "$leaf_path"
  elif _ingress_ca_in_trust_store "$ca_path"; then
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

  if [ "$system_status" != "trusted" ] || [[ "$browser_status" == not\ trusted* ]]; then
    echo "  Run: aap-demo trust-ca   # re-import ingress CA"
    if [[ "$(uname)" != "Darwin" ]]; then
      echo "  Linux browsers (Chrome/Firefox) need NSS trust — ensure nss-tools is installed"
      echo "  Manual: certutil -d sql:\$HOME/.pki/nssdb -A -t \"C,,\" -n crc-ingress-ca -i $ca_path"
    fi
    echo "  Then fully quit and reopen your browser"
    return 1
  fi
  return 0
}

fix_ingress_ca_trust() {
  if [ "${AAP_DEMO_TRUST_CA:-true}" = "false" ]; then
    echo "Ingress CA trust is disabled (AAP_DEMO_TRUST_CA=false); enable trust to fix SSL." >&2
    return 1
  fi

  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*)
      # The PowerShell entrypoint imports the CA into the Windows trust store
      # after the Git Bash command succeeds.
      echo "Windows ingress CA trust will be updated by the PowerShell wrapper."
      return 0
      ;;
  esac

  echo "Checking and fixing ingress certificate trust..."
  install_ingress_ca_trust
  ingress_ca_trust_status "$(get_ingress_ca_cert_path)"
}

_ingress_ca_cluster_fingerprint() {
  local leaf_path="${1:-}"
  local tmp fingerprint
  tmp=$(mktemp)
  if ! _fetch_ingress_ca_from_cluster "$tmp" "$leaf_path"; then
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
  local leaf_path="${2:-}"
  local tmp
  tmp=$(mktemp)
  if ! _fetch_ingress_ca_from_cluster "$tmp" "$leaf_path"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$ca_path"
  chmod 644 "$ca_path"
  return 0
}

install_ingress_ca_trust() {
  if [ "${AAP_DEMO_TRUST_CA:-true}" = "false" ]; then
    echo "  Ingress CA trust skipped (AAP_DEMO_TRUST_CA=false)"
    return 0
  fi

  local ca_path cluster_fp saved_fp="" leaf_path="" hostname=""
  ca_path=$(get_ingress_ca_cert_path)
  mkdir -p "$(dirname "$ca_path")"

  if [[ "$(uname)" == "Darwin" ]]; then
    leaf_path=$(mktemp)
  fi
  cluster_fp=$(_ingress_ca_cluster_fingerprint "$leaf_path" 2>/dev/null || true)
  if [ -n "$leaf_path" ] && [ -s "$leaf_path" ]; then
    hostname=$(_ingress_ca_macos_verification_host "$leaf_path" 2>/dev/null || true)
  fi
  if [ -f "$ca_path" ]; then
    saved_fp=$(_ingress_ca_fingerprint "$ca_path")
  fi

  # Cluster recreate issues a new ingress CA — re-trust when fingerprints differ.
  if [ -n "$cluster_fp" ] && [ "$cluster_fp" != "$saved_fp" ]; then
    echo "Trusting ingress CA..."
    if ! _ingress_ca_refresh_from_cluster "$ca_path" "$leaf_path"; then
      echo "  Could not fetch ingress CA from cluster" >&2
      [ -z "$leaf_path" ] || rm -f "$leaf_path"
      return 0
    fi
    if [ -n "$leaf_path" ] && [ -s "$leaf_path" ]; then
      hostname=$(_ingress_ca_macos_verification_host "$leaf_path" 2>/dev/null || true)
    fi
    local import_ok=true
    case "$(uname -s)" in
      MINGW* | MSYS* | CYGWIN*)
        _ingress_ca_export_env "$ca_path"
        return 0
        ;;
    esac
    import_ingress_ca_certificate "$ca_path" true "$leaf_path" "$hostname" || import_ok=false
    _ingress_ca_export_env "$ca_path" "$leaf_path" "$hostname"
    if [ "$import_ok" = false ]; then
      echo "  ⚠ Ingress CA saved to $ca_path but automatic trust import failed" >&2
      if [ -n "${CURL_CA_BUNDLE:-}" ]; then
        echo "  CLI tools can use CURL_CA_BUNDLE=$CURL_CA_BUNDLE; browsers may still warn until imported" >&2
      fi
    fi
    [ -z "$leaf_path" ] || rm -f "$leaf_path"
    return 0
  fi

  if [ -f "$ca_path" ] && _ingress_ca_fully_trusted "$ca_path" "$leaf_path" "$hostname"; then
    echo "  ✓ Ingress CA already trusted"
    _ingress_ca_export_env "$ca_path" "$leaf_path" "$hostname"
    [ -z "$leaf_path" ] || rm -f "$leaf_path"
    return 0
  fi

  echo "Trusting ingress CA..."

  local tmp
  tmp=$(mktemp)
  if _fetch_ingress_ca_from_cluster "$tmp" "$leaf_path"; then
    mv "$tmp" "$ca_path"
    chmod 644 "$ca_path"
    if [ -n "$leaf_path" ] && [ -s "$leaf_path" ]; then
      hostname=$(_ingress_ca_macos_verification_host "$leaf_path" 2>/dev/null || true)
    fi
  else
    rm -f "$tmp"
    if [ ! -f "$ca_path" ] || ! grep -q 'BEGIN CERTIFICATE' "$ca_path"; then
      echo "  Could not fetch ingress CA from cluster" >&2
      [ -z "$leaf_path" ] || rm -f "$leaf_path"
      return 0
    fi
  fi

  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*)
      _ingress_ca_export_env "$ca_path"
      return 0
      ;;
  esac

  local import_ok=true
  import_ingress_ca_certificate "$ca_path" false "$leaf_path" "$hostname" || import_ok=false
  _ingress_ca_export_env "$ca_path" "$leaf_path" "$hostname"
  if [ "$import_ok" = false ]; then
    echo "  ⚠ Ingress CA saved to $ca_path but automatic trust import failed" >&2
    if [ -n "${CURL_CA_BUNDLE:-}" ]; then
      echo "  CLI tools can use CURL_CA_BUNDLE=$CURL_CA_BUNDLE; browsers may still warn until imported" >&2
    fi
  fi
  [ -z "$leaf_path" ] || rm -f "$leaf_path"
  return 0
}
