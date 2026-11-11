#!/usr/bin/env bash
# 04-provisioning-kickstart.sh — run ON the Satellite VM as root, after 03.
# Traditional PXE/kickstart provisioning for RHEL 9 + RHEL 10 fleet nodes.
set -euo pipefail

SAT=satellite.demo.lab
ORG="Default Organization"
LOC="Lab"
ROOTPW='RedHat123!'

echo "== Domain + subnet (backed by the integrated smart proxy) =="
hammer domain create --name demo.lab --dns "$SAT" \
  --locations "$LOC" --organizations "$ORG" 2>/dev/null || true

# --httpboot-id needs the capsule's numeric ID, not its hostname.
CAPSULE_ID=$(hammer --no-headers capsule list --search "name = $SAT" 2>/dev/null | awk '{print $1}' | head -1)
CAPSULE_ID="${CAPSULE_ID:-1}"

# Idempotent: skip creation when the subnet already exists.
if hammer subnet info --name satlab >/dev/null 2>&1; then
  echo "  subnet satlab already exists"
else
  hammer subnet create --name satlab \
    --network 192.168.150.0 --mask 255.255.255.0 \
    --gateway 192.168.150.1 --dns-primary 192.168.150.10 \
    --from 192.168.150.100 --to 192.168.150.200 \
    --boot-mode DHCP --ipam DHCP \
    --domains demo.lab \
    --dhcp "$SAT" --tftp "$SAT" --dns "$SAT" --httpboot-id "$CAPSULE_ID" \
    --locations "$LOC" --organizations "$ORG"
fi
hammer subnet info --name satlab

echo "== Operating systems (auto-created by the kickstart tree sync) =="
hammer os list   # expect: RedHat 9.5 and RedHat 10.0

echo "== Host groups (kickstart via synced content + activation key) =="
# The default 'Kickstart default' provisioning template already contains the
# 'redhat_register' snippet, which consumes the host parameter kt_activation_keys.
mk_hostgroup() { # <name> <os title> <kickstart repo> <cv> <lce> <activation key>
  # Idempotent: update the activation-key parameter when the hostgroup exists.
  if hammer hostgroup info --name "$1" >/dev/null 2>&1; then
    echo "  hostgroup $1 already exists"
  else
    hammer hostgroup create --name "$1" \
      --domain demo.lab --subnet satlab \
      --architecture x86_64 \
      --operatingsystem "$2" \
      --pxe-loader "PXELinux BIOS" \
      --partition-table "Kickstart default" \
      --lifecycle-environment "$5" --content-view "$4" \
      --content-source "$SAT" \
      --kickstart-repository "$3" \
      --root-password "$ROOTPW" \
      --locations "$LOC" --organizations "$ORG" --query-organization "$ORG"
  fi
  hammer hostgroup set-parameter --hostgroup "$1" \
    --name kt_activation_keys --value "$6"
}
mk_hostgroup hg-rhel9-prod  "RedHat 9.5"  "Red Hat Enterprise Linux 9 for x86_64 - BaseOS Kickstart 9.5"   RHEL9  PROD ak-rhel9-prod
mk_hostgroup hg-rhel10-prod "RedHat 10.0" "Red Hat Enterprise Linux 10 for x86_64 - BaseOS Kickstart 10.0" RHEL10 PROD ak-rhel10-prod

cat <<'EOF'

== Provision a fleet VM (requires the KVM-Host compute resource from 06-integrations.sh) ==

  hammer host create --name node01.demo.lab --hostgroup hg-rhel9-prod \
    --compute-resource "KVM-Host" \
    --compute-attributes "cpus=2,memory=4294967296" \
    --interface "managed=true,primary=true,provision=true,compute_type=network,compute_network=satlab,compute_model=virtio" \
    --volume "pool_name=default,capacity=30G,format_type=qcow2" \
    --build true

Satellite will: allocate a DHCP lease + DNS record, drop PXELinux/grub2 + kickstart
onto TFTP/HTTP, create the VM on the KVM host, network-boot it, and the
redhat_register snippet registers it with the host group's activation key.

Notes:
- UEFI fleet nodes: use --pxe-loader "Grub2 UEFI" (or "Grub2 UEFI SecureBoot").
- Bare metal: same host group; just create the host with --mac and no compute
  resource, and PXE-boot the machine on the satlab segment.
- Customize the kickstart %post by cloning the 'Kickstart default' template
  (hammer template clone) or dropping a 'custom_post' snippet — the default
  template includes it automatically if it exists.
- Discovery workflow (optional, installed by 02): PXE-boot unknown hardware on
  satlab, then `hammer discovery list` / `hammer discovery provision`.
EOF
