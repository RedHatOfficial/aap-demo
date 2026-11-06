#!/usr/bin/env bash
# Best-effort APD credential wiring after a product-demos install.
# The installer has already succeeded. Exit 0 unless the library itself is missing.
# Usage: product_demos_wire.sh /path/to/product-demos-base/lib.sh

lib="${1:-}"
if [ -z "$lib" ] || [ ! -f "$lib" ]; then
  echo "product demos wiring skipped: installer library not found" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$lib"
apd_ensure_aap_credential || echo "⚠ AAP credential wiring skipped"
apd_ensure_openshift_credential || echo "⚠ OpenShift credential wiring skipped"
apd_configure_galaxy_credentials || echo "⚠ Galaxy credential wiring skipped"
exit 0
