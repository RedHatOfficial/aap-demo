#!/usr/bin/env bash

# Return the URL that APME pods should use for AAP API and OAuth calls.
# CRC/MicroShift exposes AAP on the in-cluster HTTP service port; browsers
# continue to use the external HTTPS route.
apme_aap_portal_host_url() {
  local aap_host="$1"
  local cluster_domain
  local aap_hostname="${aap_host#http://}"
  cluster_domain=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  aap_hostname="${aap_hostname#https://}"
  aap_hostname="${aap_hostname%/}"

  case "$cluster_domain" in
    crc.testing | *.crc.testing | nip.io | *.nip.io)
      printf 'http://%s\n' "$aap_hostname"
      ;;
    *)
      printf '%s\n' "${aap_host%/}"
      ;;
  esac
}
