#!/usr/bin/env bash

# Preserve a generated scalar verbatim, including YAML quoting. These settings
# are single-line scalars; Ansible validates the image reference before use.
apme_saved_yaml_value() {
  local vars_file="$1" key="$2" fallback="$3" value=""
  if [ -f "$vars_file" ]; then
    value=$(sed -n "s/^${key}:[[:space:]]*//p" "$vars_file" | tail -1)
  fi
  printf '%s\n' "${value:-$fallback}"
}

apme_preloaded_image_selected() {
  if [ -n "${APME_PRELOADED_IMAGE_REF:-}" ]; then
    return 0
  fi
  local value
  value=$(apme_saved_yaml_value "$1" apme_preloaded_image_ref '""')
  value=$(printf '%s' "$value" | sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//')
  case "$value" in
    '""' | "''" | null | '~') return 1 ;;
    *) return 0 ;;
  esac
}

# Return the URL that APME pods should use for AAP API and OAuth calls.
# CRC exposes AAP on the in-cluster HTTP service port. MicroShift's nip.io
# routes continue to use the external HTTPS router route.
apme_aap_portal_host_url() {
  local aap_host="$1"
  local cluster_domain
  local aap_hostname="${aap_host#http://}"
  cluster_domain=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  aap_hostname="${aap_hostname#https://}"
  aap_hostname="${aap_hostname%/}"

  case "$cluster_domain" in
    crc.testing | *.crc.testing)
      printf 'http://%s\n' "$aap_hostname"
      ;;
    *)
      printf '%s\n' "${aap_host%/}"
      ;;
  esac
}
