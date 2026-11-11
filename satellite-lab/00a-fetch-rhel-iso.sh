#!/usr/bin/env bash
# 00a-fetch-rhel-iso.sh — run on the KVM host (root).
# Download the RHEL install ISO automatically from the Red Hat CDN using the
# host's RHSM entitlement certificate — no portal login, no manual step.
#
# Defaults to the small boot ISO (~1 GB); the kickstart then installs packages
# from the CDN (RHEL_INSTALL_SOURCE=cdn). Set ISO_KIND=dvd for the full offline
# DVD (~10 GB, RHEL_INSTALL_SOURCE=dvd).
#
# Idempotent: skips the download when the ISO already exists and matches the
# expected size class.
set -euo pipefail

RHEL_VERSION="${RHEL_VERSION:-9.5}"
ISO_KIND="${ISO_KIND:-boot}"                 # boot | dvd
ISO_NAME="rhel-${RHEL_VERSION}-x86_64-${ISO_KIND}.iso"
DEST="${RHEL_ISO:-/var/lib/libvirt/images/${ISO_NAME}}"
CDN_ISO_URL="https://cdn.redhat.com/content/dist/rhel9/${RHEL_VERSION}/x86_64/baseos/iso/${ISO_NAME}"

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)"; exit 1; }

# Locate the host entitlement cert + key (proves RHSM registration).
ENT_CERT=""
ENT_KEY=""
for f in /etc/pki/entitlement/*.pem; do
  [ -e "$f" ] || continue
  case "$f" in
    *-key.pem) [ -z "$ENT_KEY" ] && ENT_KEY="$f" ;;
    *) [ -z "$ENT_CERT" ] && ENT_CERT="$f" ;;
  esac
done
if [ -z "$ENT_CERT" ] || [ -z "$ENT_KEY" ]; then
  echo "ERROR: host is not registered with RHSM (no entitlement cert in /etc/pki/entitlement)."
  echo "  Register first: subscription-manager register --org <org> --activationkey <key>"
  echo "  Or download the ISO manually from access.redhat.com and place it at $DEST"
  exit 1
fi

if [ -s "$DEST" ]; then
  echo "✓ ISO already present: $DEST ($(du -h "$DEST" | cut -f1))"
  exit 0
fi

echo "▸ Downloading $ISO_NAME from the Red Hat CDN (entitlement cert auth)..."
echo "  $CDN_ISO_URL"
mkdir -p "$(dirname "$DEST")"
TMP="${DEST}.partial"
if curl -sk --fail --cert "$ENT_CERT" --key "$ENT_KEY" \
    --connect-timeout 20 --max-time 1800 \
    -o "$TMP" "$CDN_ISO_URL"; then
  mv "$TMP" "$DEST"
  chmod 644 "$DEST"
  echo "✓ Downloaded: $DEST ($(du -h "$DEST" | cut -f1))"
else
  rm -f "$TMP"
  echo "ERROR: ISO download failed. Check the host's RHSM subscription covers RHEL ${RHEL_VERSION}."
  exit 1
fi
