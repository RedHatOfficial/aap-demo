#!/usr/bin/env bash
# AAP deployment version selection.

aap_demo_configure_aap_version() {
  local requested_version="${1:-2.7}"

  case "$requested_version" in
    2.6 | 2.7)
      AAP_VERSION="$requested_version"
      AAP_CHANNEL="stable-${requested_version}"
      export AAP_VERSION AAP_CHANNEL
      ;;
    *)
      echo "ERROR: Unsupported AAP_VERSION: '$requested_version' (supported: 2.6, 2.7)" >&2
      return 1
      ;;
  esac
}

aap_demo_csv_matches_aap_version() {
  local csv_name="${1:-}"
  local escaped_version
  escaped_version="${AAP_VERSION//./\\.}"
  [[ "$csv_name" =~ ^aap-operator\.v${escaped_version}([.-]|$) ]]
}
