#!/usr/bin/env bash
# 00b-host-nfs-storage.sh — run on the KVM host as root.
# Exports a host directory over NFS to the Satellite VM for /var/lib/pulp, so
# the Satellite VM's OS disk stays small while Pulp content (the bulk of a
# Satellite's storage) lives on the host's larger filesystem.
#
# Sets up:
#   - the NFS export (/var/lib/satlab/pulp -> 192.168.122.20, the Satellite VM)
#   - the nfs-server systemd unit
#   - firewalld rules (when firewalld is active)
#   - SELinux booleans (virt_use_nfs, nfs_export_all_rw) when SELinux is Enforcing
#
# Idempotent: safe to re-run.
set -euo pipefail

# ---- editable variables ---------------------------------------------------
EXPORT_DIR="${SATLAB_NFS_DIR:-/var/lib/satlab/pulp}"
SAT_IP="${SATELLITE_LAB_IP:-192.168.122.20}"   # Satellite VM NIC1 (default net)
EXPORT_OPTS="rw,sync,no_subtree_check,no_root_squash"
# ---------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)"; exit 1; }
command -v exportfs >/dev/null 2>&1 || { echo "ERROR: nfs-utils not installed"; exit 1; }

echo "== 1. Export directory =="
mkdir -p "$EXPORT_DIR"
# Pulp runs as the 'pulp' user in the VM; with no_root_squash the VM's root can
# chown as needed. Keep the export writable and world-accessible on the lab net.
chmod 0777 "$EXPORT_DIR"
echo "  export dir: $EXPORT_DIR"

echo "== 2. /etc/exports entry =="
EXPORT_LINE="$EXPORT_DIR $SAT_IP($EXPORT_OPTS)"
if grep -qF "$EXPORT_DIR " /etc/exports 2>/dev/null; then
  # Replace any existing export of this dir with the current options.
  sed -i "\\|^$EXPORT_DIR |c\\$EXPORT_LINE" /etc/exports
else
  echo "$EXPORT_LINE" >> /etc/exports
fi
echo "  $EXPORT_LINE"

echo "== 3. firewalld (only when active) =="
if systemctl is-active --quiet firewalld; then
  for svc in nfs mountd rpc-bind; do
    firewall-cmd --permanent --add-service="$svc" 2>/dev/null || true
  done
  firewall-cmd --reload || true
  echo "  firewalld: nfs/mountd/rpc-bind permitted"
else
  echo "  firewalld inactive; skipping (no host firewall rules needed)"
fi

echo "== 4. SELinux booleans =="
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" = "Enforcing" ]; then
  setsebool -P virt_use_nfs on
  setsebool -P nfs_export_all_rw on
  echo "  SELinux Enforcing: virt_use_nfs=on nfs_export_all_rw=on"
else
  echo "  SELinux $(getenforce 2>/dev/null || echo 'not present'); booleans not required"
fi

echo "== 5. Start + enable nfs-server =="
systemctl enable --now nfs-server
exportfs -ra
# rpc.mountd can race the export table (/var/lib/nfs/etab) on first start;
# restart it once if it failed so showmount/mount requests succeed.
if ! systemctl is-active --quiet nfs-mountd; then
  systemctl restart nfs-mountd 2>/dev/null || true
fi
exportfs -v | grep "$EXPORT_DIR" || { echo "ERROR: export not active"; exit 1; }
# Confirm the export answers a showmount from the host (what the VM checks).
showmount -e 127.0.0.1 2>/dev/null | grep -q "$EXPORT_DIR" \
  || echo "  NOTE: showmount not answering yet; NFSv4 mount still works without mountd"

echo ""
echo "Done. The Satellite VM ($SAT_IP) can now mount:"
echo "  mount -t nfs $(hostname -I | awk '{print $1}'):$EXPORT_DIR /var/lib/pulp"
echo "(from the VM, the host is reachable at the default-net gateway 192.168.122.1)"
