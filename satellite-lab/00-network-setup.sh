#!/usr/bin/env bash
# 00-network-setup.sh — run on the KVM host as root.
# Creates the 'satlab' libvirt network (NAT, no DHCP) used by Satellite + fleet,
# and enables L3 forwarding between satlab and the host's other libvirt networks.
#
# Adapted for CRC user-mode networking: this host runs CRC with the MicroShift
# preset, which uses QEMU user-mode networking + vsock instead of a bridged
# libvirt 'crc' network. There is no 'crc' libvirt network here. The Satellite
# VM's first NIC therefore attaches to the libvirt 'default' network (NAT to
# the host and upstream), and reaches AAP/CRC through the host's forwarded
# ports. The 'satlab' network stays isolated for Satellite-owned DHCP/PXE.
set -euo pipefail
cd "$(dirname "$0")"

VIRSH="virsh -c qemu:///system"

# Sanity: the libvirt 'default' network must exist (Satellite's NIC1 lives here)
$VIRSH net-info default >/dev/null 2>&1 || { echo "ERROR: libvirt network 'default' not found."; exit 1; }

# Define + start satlab
if ! $VIRSH net-info satlab >/dev/null 2>&1; then
  $VIRSH net-define ./satlab-network.xml
fi
$VIRSH net-start satlab 2>/dev/null || true
$VIRSH net-autostart satlab

# L3 reachability between segments (satlab fleet -> host/upstream via forwarding)
sysctl -w net.ipv4.ip_forward=1
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-satlab-forward.conf

# If the host runs firewalld with the libvirt zone, permit satlab <-> default forwarding
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --zone=libvirt --add-rich-rule='rule family=ipv4 source address=192.168.150.0/24 destination address=192.168.122.0/24 accept' || true
  firewall-cmd --permanent --zone=libvirt --add-rich-rule='rule family=ipv4 source address=192.168.122.0/24 destination address=192.168.150.0/24 accept' || true
  firewall-cmd --reload || true
fi

echo "== networks =="
$VIRSH net-list --all
echo "Done. satlab = 192.168.150.0/24 (host .1, Satellite will be .10, DHCP pool .100-.200)"
echo "Satellite NIC1 will be on 'default' (192.168.122.0/24, host at .1)."
