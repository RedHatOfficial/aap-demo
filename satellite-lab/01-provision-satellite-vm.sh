#!/usr/bin/env bash
# 01-provision-satellite-vm.sh — run on the KVM host as root.
# Creates the Satellite VM: 4 vCPU / 32 GB / 150 GB qcow2, dual-homed on the
# libvirt 'default' network (NAT to host/upstream) and the isolated 'satlab'
# network (Satellite-owned DHCP/PXE), kickstarted unattended.
#
# Adapted for CRC user-mode networking: no bridged 'crc' libvirt network exists
# on this host, so NIC1 uses 'default' and the VM reaches AAP/CRC through the
# host's forwarded ports.
set -euo pipefail
cd "$(dirname "$0")"

# ---- editable variables ---------------------------------------------------
VM_NAME=satellite
VM_VCPUS=4
VM_RAM=32768                                   # MiB
VM_DISK=/var/lib/libvirt/images/${VM_NAME}.qcow2
VM_DISK_SIZE=40                                # GiB (minimal OS; Pulp content on host NFS)
# Install source. The ISO is downloaded automatically from the Red Hat CDN
# (using the host's RHSM entitlement cert) when missing — no portal login.
#   dvd (default): rhel-9.5-x86_64-dvd.iso  (~10 GB, fully offline install)
#   cdn:           rhel-9.5-x86_64-boot.iso (~1 GB) + packages from the CDN
RHEL_VERSION="${RHEL_VERSION:-9.5}"
RHEL_INSTALL_SOURCE="${RHEL_INSTALL_SOURCE:-dvd}"   # dvd | cdn
ISO_KIND=dvd; [ "$RHEL_INSTALL_SOURCE" = "cdn" ] && ISO_KIND=boot
RHEL_ISO="${RHEL_ISO:-/var/lib/libvirt/images/rhel-${RHEL_VERSION}-x86_64-${ISO_KIND}.iso}"
HOST_NET=default                               # libvirt network for NIC1 (NAT to host)
LAB_NET=satlab                                 # from 00-network-setup.sh
MAC_HOST="52:54:00:5a:7e:01"                   # must match satellite-vm.ks
MAC_LAB="52:54:00:5a:7e:02"

# Secrets rendered into the kickstart (prefer env vars over editing this file)
ROOTPW="${ROOTPW:-RedHat123!}"
RHSM_ORG="${RHSM_ORG:-}"                       # activation-key org id (preferred)
RHSM_AK="${RHSM_AK:-}"                         # activation key name
RHSM_USER="${RHSM_USER:-}"                     # fallback: username/password
RHSM_PASS="${RHSM_PASS:-}"
# ---------------------------------------------------------------------------

VIRSH="virsh -c qemu:///system"

case "$RHEL_INSTALL_SOURCE" in
  dvd | cdn) ;;
  *) echo "ERROR: RHEL_INSTALL_SOURCE must be 'dvd' or 'cdn' (got '$RHEL_INSTALL_SOURCE')"; exit 1 ;;
esac
# Fetch the ISO automatically from the CDN when it is missing.
if [ ! -f "$RHEL_ISO" ]; then
  echo "▸ RHEL ISO not present; downloading it automatically from the CDN..."
  ISO_KIND="$ISO_KIND" RHEL_VERSION="$RHEL_VERSION" RHEL_ISO="$RHEL_ISO" \
    bash "$(dirname "$0")/00a-fetch-rhel-iso.sh"
fi
[[ -f $RHEL_ISO ]] || { echo "ERROR: $RHEL_ISO still not found after download"; exit 1; }
$VIRSH net-info "$LAB_NET" >/dev/null 2>&1 || { echo "ERROR: run 00-network-setup.sh first"; exit 1; }
$VIRSH net-info "$HOST_NET" >/dev/null 2>&1 || { echo "ERROR: libvirt network '$HOST_NET' not found"; exit 1; }

# Resolve the install source line rendered into the kickstart.
#   dvd: no extra line — Anaconda installs from the DVD media.
#   cdn: register with RHSM during install and pull packages from the CDN.
INSTALL_SOURCE_LINE=""
# The rhsm kickstart command requires --organization + --activation-key (it
# has no username/password form). Use it only when an activation key is set;
# otherwise install from the ISO's own tree and register in %post (below).
if [ "$RHEL_INSTALL_SOURCE" = "cdn" ] && [ -n "$RHSM_AK" ] && [ -n "$RHSM_ORG" ]; then
  INSTALL_SOURCE_LINE="rhsm --organization=\"$RHSM_ORG\" --activation-key=\"$RHSM_AK\""
fi

# Hash the root password for the kickstart (never render it plaintext).
# Pattern adapted from the MRHIS installer (openssl SHA-512, python fallback).
_ks_password_hash() {
  local plain="$1"
  if command -v openssl >/dev/null 2>&1; then
    printf '%s' "$plain" | openssl passwd -6 -stdin 2>/dev/null && return 0
  fi
  python3 -c 'import crypt,sys; print(crypt.crypt(sys.argv[1], crypt.mksalt(crypt.METHOD_SHA512)))' "$plain"
}
ROOTPW_HASH=$(_ks_password_hash "$ROOTPW")

# The host's SSH public key is injected for root so the orchestrator can SSH in.
# The orchestrator passes the invoking user's key via SATELLITE_SSH_PUBKEY
# (sudo changes $HOME to /root, so the user's ~/.ssh is not reachable here).
HOST_SSH_PUBKEY="${SATELLITE_SSH_PUBKEY:-}"
if [ -z "$HOST_SSH_PUBKEY" ]; then
  for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub" /root/.ssh/id_ed25519.pub; do
    [ -f "$k" ] && { HOST_SSH_PUBKEY=$(cat "$k"); break; }
  done
fi

# Render kickstart with secrets (escape & for sed)
esc() { printf '%s' "${1//&/\\&}"; }
RENDERED_KS=$(mktemp /tmp/satellite-vm.XXXXXX.ks)
sed -e "s|__ROOTPW_HASH__|$(esc "$ROOTPW_HASH")|g" \
    -e "s|__RHSM_ORG__|$(esc "$RHSM_ORG")|g" \
    -e "s|__RHSM_AK__|$(esc "$RHSM_AK")|g" \
    -e "s|__RHSM_USER__|$(esc "$RHSM_USER")|g" \
    -e "s|__RHSM_PASS__|$(esc "$RHSM_PASS")|g" \
    -e "s|__INSTALL_SOURCE__|$(esc "$INSTALL_SOURCE_LINE")|g" \
    -e "s|__HOST_SSH_PUBKEY__|$(esc "$HOST_SSH_PUBKEY")|g" \
    satellite-vm.ks > "$RENDERED_KS"
chmod 600 "$RENDERED_KS"

# Set up the host NFS export for /var/lib/pulp before the VM boots, so the
# kickstart %post can mount it. Skip with SATLAB_SKIP_NFS=1 (Pulp stays local).
if [ "${SATLAB_SKIP_NFS:-0}" != "1" ]; then
  echo "▸ Setting up host NFS storage for /var/lib/pulp..."
  bash "$(dirname "$0")/00b-host-nfs-storage.sh"
fi

[[ -f $VM_DISK ]] || qemu-img create -f qcow2 "$VM_DISK" "${VM_DISK_SIZE}G"

$VIRSH destroy "$VM_NAME" 2>/dev/null || true

virt-install \
  --connect qemu:///system \
  --name "$VM_NAME" \
  --vcpus "$VM_VCPUS" --cpu host-passthrough \
  --memory "$VM_RAM" \
  --disk path="$VM_DISK",format=qcow2,bus=virtio,cache=writeback,discard=unmap \
  --network network="$HOST_NET",model=virtio,mac="$MAC_HOST" \
  --network network="$LAB_NET",model=virtio,mac="$MAC_LAB" \
  --location "$RHEL_ISO",kernel=images/pxeboot/vmlinuz,initrd=images/pxeboot/initrd.img \
  --initrd-inject "$RENDERED_KS" \
  --extra-args "inst.ks=file:/$(basename "$RENDERED_KS") console=tty0 console=ttyS0,115200n8" \
  --os-variant rhel9.0 \
  --graphics vnc,listen=127.0.0.1 --video vga --console pty,target_type=serial \
  --noautoconsole
rm -f "$RENDERED_KS"
cat <<EOF

VM '$VM_NAME' is installing unattended.
Watch progress:   $VIRSH console $VM_NAME
When done:        ssh root@192.168.122.20   (NIC1, default net) or 192.168.150.10 (NIC2, satlab)
Next step:        copy your manifest to the VM, then run 02-satellite-installer.sh on it.
EOF
