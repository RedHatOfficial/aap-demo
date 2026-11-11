#!/usr/bin/env bash
# 02-satellite-installer.sh — run ON the Satellite VM as root, after first boot.
# Non-interactive Satellite 6 install: DNS/DHCP/TFTP on the satlab NIC,
# upstream DNS via the host's libvirt dnsmasq on the 'default' network.
#
# Adapted for CRC user-mode networking: there is no bridged 'crc' network, so
# the DNS forwarder is the host's 'default' dnsmasq (192.168.122.1), which
# resolves upstream. AAP/CRC routes (apps.127.0.0.1.nip.io) already resolve to
# 127.0.0.1 via public DNS; from the Satellite VM that loopback is the host's
# forwarded ports, reached via the default gateway.
set -euo pipefail

# ---- editable variables ---------------------------------------------------
FQDN=satellite.demo.lab
ORG="Default Organization"
LOC="Lab"
ADMIN_USER=admin
# The admin password comes from the host's encrypted credential Vault
# (aap_demo.satellite.admin_password), passed in by build-and-configure.sh via
# the SATELLITE_ADMIN_PASSWORD env var. The literal below is only a last-resort
# fallback for a standalone manual run — never a committed secret.
ADMIN_PASS="${SATELLITE_ADMIN_PASSWORD:-RedHat123!}"
LAB_IP=192.168.150.10
LAB_GW=192.168.150.1
DHCP_RANGE="192.168.150.100 192.168.150.200"
DNS_ZONE=demo.lab
DNS_REVERSE=150.168.192.in-addr.arpa
DNS_FORWARDER=192.168.122.1      # libvirt dnsmasq on the 'default' network (host):
                                 # resolves upstream; AAP/CRC is reached through the
                                 # host's forwarded ports via the default gateway
# ---------------------------------------------------------------------------

hostnamectl set-hostname "$FQDN"
grep -q "$FQDN" /etc/hosts || echo "$LAB_IP $FQDN satellite" >> /etc/hosts

# Detect the satlab-facing interface (the one holding LAB_IP)
LAB_IF=$(ip -o -4 addr show to 192.168.150.0/24 | awk '{print $2}' | head -n1)
[[ -n "$LAB_IF" ]] || { echo "ERROR: no interface with a 192.168.150.x address"; exit 1; }
echo "satlab interface: $LAB_IF"

dnf -y update
dnf -y install satellite

systemctl enable --now chronyd

# Demo firewall profile (tighten for anything beyond a lab)
firewall-cmd --permanent \
  --add-port=53/tcp --add-port=53/udp \
  --add-port=67/udp --add-port=69/udp \
  --add-port=80/tcp --add-port=443/tcp \
  --add-port=8000/tcp --add-port=8140/tcp \
  --add-port=9090/tcp
firewall-cmd --reload

# --tuning default fits 32 GB; use '--tuning development' only for tiny labs.
satellite-installer --scenario satellite \
  --tuning default \
  --foreman-initial-organization "$ORG" \
  --foreman-initial-location "$LOC" \
  --foreman-initial-admin-username "$ADMIN_USER" \
  --foreman-initial-admin-password "$ADMIN_PASS" \
  --foreman-proxy-dns true \
  --foreman-proxy-dns-managed true \
  --foreman-proxy-dns-interface "$LAB_IF" \
  --foreman-proxy-dns-zone "$DNS_ZONE" \
  --foreman-proxy-dns-reverse "$DNS_REVERSE" \
  --foreman-proxy-dns-forwarders "$DNS_FORWARDER" \
  --foreman-proxy-dhcp true \
  --foreman-proxy-dhcp-managed true \
  --foreman-proxy-dhcp-interface "$LAB_IF" \
  --foreman-proxy-dhcp-range "$DHCP_RANGE" \
  --foreman-proxy-dhcp-gateway "$LAB_GW" \
  --foreman-proxy-dhcp-nameservers "$LAB_IP" \
  --foreman-proxy-tftp true \
  --foreman-proxy-tftp-managed true \
  --foreman-proxy-tftp-servername "$LAB_IP" \
  --foreman-proxy-httpboot true \
  --enable-foreman-plugin-ansible \
  --enable-foreman-proxy-plugin-ansible \
  --enable-foreman-plugin-remote-execution \
  --enable-foreman-proxy-plugin-remote-execution-script \
  --enable-foreman-plugin-rh-cloud \
  --enable-foreman-plugin-discovery \
  --enable-foreman-proxy-plugin-discovery \
  --foreman-proxy-plugin-discovery-install-images true
# NOTE: --enable-foreman-plugin-bootc is not a valid installer option in
# Satellite 6.17.0 (the image-mode/bootc host support ships in core, not as a
# separately-enabled plugin). 05-bootc-image-mode.sh configures it post-install.

# hammer CLI auth for root
mkdir -p ~/.hammer/cli.modules.d
cat > ~/.hammer/foreman.yml <<EOF
:foreman:
  :username: $ADMIN_USER
  :password: '$ADMIN_PASS'
  :refresh_cache: true
EOF
chmod 600 ~/.hammer/foreman.yml

# Sanity checks
ping -c1 -W2 "$DNS_FORWARDER" && echo "Host (default gw) reachable" || echo "WARN: host gateway not reachable"
dig +short satellite.demo.lab @127.0.0.1 || echo "WARN: local named not answering yet"
# AAP route resolves to 127.0.0.1 via public DNS; from this VM that loopback is
# the host's forwarded AAP port, reached through the default gateway.
getent hosts aap-aap-operator.apps.127.0.0.1.nip.io >/dev/null \
  && echo "AAP route resolves (via nip.io -> host forwarded port)" \
  || echo "WARN: AAP route did not resolve"

cat <<EOF

Satellite is up:  https://$FQDN   ($ADMIN_USER / $ADMIN_PASS)
Next: scp your manifest to /root/manifest.zip, then run 03-content-hammer.sh
EOF
