#!/usr/bin/env bash
# Entitled RHEL QCOW2 image download and cache management.

if [ -n "${_FLEET_IMAGES_LOADED:-}" ]; then return 0; fi
_FLEET_IMAGES_LOADED=1

FLEET_IMAGE_CACHE_DIR="${FLEET_IMAGE_CACHE_DIR:-${AAP_DEMO_DIR:-$HOME/.aap-demo}/fleet/images}"
FLEET_RHEL9_FILENAME="${FLEET_RHEL9_FILENAME:-rhel-9.8-x86_64-kvm.qcow2}"
FLEET_RHEL9_SHA256="${FLEET_RHEL9_SHA256:-b99091f1b4489111004d449398d9cc6aa024cb48b02c72fa99e6ca1fc48a7e4e}"
FLEET_RHEL10_FILENAME="${FLEET_RHEL10_FILENAME:-rhel-10.2-x86_64-kvm.qcow2}"
FLEET_RHEL10_SHA256="${FLEET_RHEL10_SHA256:-caaacd0b11bbc4206f8c7fec8594b82b4366b3f88ff974dbbf373832ae676f4f}"
FLEET_REDHAT_API_BASE="${FLEET_REDHAT_API_BASE:-https://api.access.redhat.com/management/v1}"

fleet_image_metadata() {
  case "$1" in
    rhel9)
      FLEET_MANAGED_IMAGE_FILENAME="$FLEET_RHEL9_FILENAME"
      FLEET_MANAGED_IMAGE_SHA256="$FLEET_RHEL9_SHA256"
      ;;
    rhel10)
      FLEET_MANAGED_IMAGE_FILENAME="$FLEET_RHEL10_FILENAME"
      FLEET_MANAGED_IMAGE_SHA256="$FLEET_RHEL10_SHA256"
      ;;
    *)
      _err "Unsupported managed Fleet image: $1"
      echo "  Supported images: rhel9, rhel10"
      return 1
      ;;
  esac
}

_fleet_redhat_resolve_download_url() {
  local checksum="$1"
  local access_token="$2"
  local response
  response=$(printf 'header = "Authorization: Bearer %s"\n' "$access_token" |
    curl --config - --silent --show-error --proto '=https' --max-redirs 0 \
      --write-out '\n%{http_code}\n%{redirect_url}' \
      "${FLEET_REDHAT_API_BASE}/images/${checksum}/download") || {
    _err "Unable to resolve the image through the Red Hat RHSM API"
    return 1
  }

  local redirect_url="${response##*$'\n'}"
  response="${response%$'\n'*}"
  local http_code="${response##*$'\n'}"
  local response_body="${response%$'\n'*}"
  if [ "$http_code" != "200" ] && [ "$http_code" != "307" ]; then
    _err "Red Hat RHSM image API returned HTTP $http_code"
    return 1
  fi

  local download_url
  download_url=$(python3 -c '
import json
import sys
try:
    print(json.load(sys.stdin).get("body", {}).get("href", ""))
except (json.JSONDecodeError, AttributeError):
    pass
' <<<"$response_body") || return 1
  [ -n "$download_url" ] || download_url="$redirect_url"

  case "$download_url" in
    "https://access.cdn.redhat.com/"*"/${FLEET_MANAGED_IMAGE_FILENAME}?"*) ;;
    *)
      _err "Red Hat RHSM API returned an unexpected download URL"
      return 1
      ;;
  esac
  FLEET_MANAGED_IMAGE_DOWNLOAD_URL="$download_url"
}

_fleet_image_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    _err "sha256sum or shasum is required to verify managed Fleet images"
    return 1
  fi
}

_fleet_verify_managed_image() {
  local image_path="$1"
  local expected_sha256="$2"
  [ -f "$image_path" ] || return 1

  local actual_sha256
  actual_sha256=$(_fleet_image_sha256 "$image_path" 2>/dev/null) || return 1
  [ "$actual_sha256" = "$expected_sha256" ] || return 1

  local format
  format=$(qemu-img info --output=json "$image_path" 2>/dev/null |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("format", ""))' 2>/dev/null) || return 1
  [ "$format" = "qcow2" ]
}

fleet_download_managed_image() {
  local image_name="$1"
  fleet_image_metadata "$image_name" || return 1

  for command_name in curl qemu-img python3; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      _err "$command_name is required to download managed Fleet images"
      return 1
    fi
  done

  mkdir -p "$FLEET_IMAGE_CACHE_DIR"
  chmod 700 "$FLEET_IMAGE_CACHE_DIR"
  local image_path="${FLEET_IMAGE_CACHE_DIR}/${FLEET_MANAGED_IMAGE_FILENAME}"
  local partial_path="${image_path}.part"

  if _fleet_verify_managed_image "$image_path" "$FLEET_MANAGED_IMAGE_SHA256"; then
    echo "✓ Using cached image: $image_path"
    FLEET_RESOLVED_IMAGE="$image_path"
    return 0
  fi
  if [ -e "$image_path" ]; then
    echo "Cached image failed validation; downloading a fresh copy."
    rm -f "$image_path"
  fi

  fleet_redhat_store_project_metadata || return 1
  local access_token
  access_token=$(fleet_redhat_access_token true) || {
    _err "Red Hat Customer Portal authentication is required"
    return 1
  }

  _fleet_redhat_resolve_download_url \
    "$FLEET_MANAGED_IMAGE_SHA256" "$access_token" || {
    unset access_token
    return 1
  }
  unset access_token

  echo "Downloading ${FLEET_MANAGED_IMAGE_FILENAME}..."
  echo "  Destination: $image_path"
  local http_code
  http_code=$(curl --show-error --proto '=https' \
    --continue-at - --output "$partial_path" --write-out '%{http_code}' \
    --progress-bar "$FLEET_MANAGED_IMAGE_DOWNLOAD_URL") || http_code=""
  unset FLEET_MANAGED_IMAGE_DOWNLOAD_URL
  if [ "$http_code" != "200" ] && [ "$http_code" != "206" ]; then
    rm -f "$partial_path"
    _err "Red Hat image download failed"
    echo "  HTTP status: ${http_code:-connection failure}"
    echo "  Confirm that the Red Hat account has RHEL download entitlement."
    return 1
  fi

  echo "Verifying SHA256 and QCOW2 format..."
  if ! _fleet_verify_managed_image "$partial_path" "$FLEET_MANAGED_IMAGE_SHA256"; then
    rm -f "$partial_path"
    _err "Downloaded image failed checksum or QCOW2 validation"
    return 1
  fi

  mv "$partial_path" "$image_path"
  chmod 600 "$image_path"
  echo "✓ Image downloaded and verified"
  FLEET_RESOLVED_IMAGE="$image_path"
}

fleet_resolve_image() {
  local image_spec="$1"
  case "$image_spec" in
    rhel9 | rhel10)
      fleet_download_managed_image "$image_spec"
      ;;
    *)
      FLEET_RESOLVED_IMAGE="$image_spec"
      ;;
  esac
}
