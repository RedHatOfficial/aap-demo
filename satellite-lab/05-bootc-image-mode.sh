#!/usr/bin/env bash
# 05-bootc-image-mode.sh — Image Mode for RHEL (bootc) on Satellite 6.17+.
# Run sections A/D ON the Satellite VM; sections B/C on a build host with podman
# (can be the KVM host). Requires the bootc plugin enabled in 02-satellite-installer.sh.
set -euo pipefail

SAT=satellite.demo.lab
ORG="Default Organization"
ORG_LABEL=Demo_Org                 # org label (spaces -> underscores); check: hammer organization list
RHSM_USER="${RHSM_USER:-changeme}" # CDN creds to pull the upstream rhel-bootc base image
RHSM_PASS="${RHSM_PASS:-changeme}"

echo "== A. Satellite: sync the upstream bootc base image into Pulp =="
hammer product create --name bootc --organization "$ORG" 2>/dev/null || true

# Upstream base image (container repos always sync in full; no on_demand for docker)
hammer repository create --product bootc --name rhel10-bootc --content-type docker \
  --url https://registry.redhat.io \
  --docker-upstream-name rhel10/rhel-bootc \
  --upstream-username "$RHSM_USER" --upstream-password "$RHSM_PASS"
hammer repository synchronize --product bootc --name rhel10-bootc
# RHEL 9 equivalent: --docker-upstream-name rhel9/rhel-bootc

# Empty container repo that receives our customized pushes
hammer repository create --product bootc --name rhel10-bootc-demo --content-type docker 2>/dev/null || true

# Registry paths (Library): <sat>/<org_label>-<product>-<repo>
hammer repository info --product bootc --name rhel10-bootc-demo --fields "Published at"
echo "Pull/push path: $SAT/${ORG_LABEL,,}-bootc-rhel10-bootc-demo"

cat <<EOF

== B. Build host: customize + push the image ==

  podman login $SAT --username admin        # Satellite UI account
  podman build -f Containerfile.bootc -t $SAT/${ORG_LABEL,,}-bootc-rhel10-bootc-demo:v1 .
  podman push $SAT/${ORG_LABEL,,}-bootc-rhel10-bootc-demo:v1

== C. Build host: produce a QCOW2 with bootc-image-builder and boot it ==

  # Optional user/ssh config for the image (bib-config.json):
  #   {"blueprint":{"customizations":{"user":[{"name":"demo","password":"RedHat123!","groups":["wheel"]}]}}}
  mkdir -p output
  sudo podman run --rm -it --privileged \
    -v "\$PWD/output:/output" \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    --security-opt label=type:unconfined_t \
    registry.redhat.io/rhel10/bootc-image-builder:latest \
    build --type qcow2 \
    $SAT/${ORG_LABEL,,}-bootc-rhel10-bootc-demo:v1
  # older bootc-image-builder releases drop the 'build' subcommand:
  #   ... bootc-image-builder:latest --type qcow2 <image>

  sudo cp output/qcow2/disk.qcow2 /var/lib/libvirt/images/bootc-node10.qcow2
  sudo virt-install --name bootc-node10 --memory 4096 --vcpus 2 \
    --disk /var/lib/libvirt/images/bootc-node10.qcow2,bus=virtio \
    --network network=satlab,model=virtio \
    --import --os-variant rhel10.0 --noautoconsole
  # First boot: bootc-register.service registers the host to Satellite with
  # activation key ak-rhel10-prod (content view RHEL10 / PROD).

== C-alt. Bare metal / Anaconda: kickstart with the ostreecontainer command ==

  # In a kickstart served by Satellite (RHEL 9.4+; RHEL 10 also accepts 'bootc'):
  #   ostreecontainer --url=$SAT/${ORG_LABEL,,}-bootc-rhel10-bootc-demo:v1 \
  #                   --stateroot=default --no-signature-verification
  # (--no-signature-verification is a demo shortcut; use sigstore in production)

== D. Satellite: day-2 management of image-mode hosts (6.17+ bootc plugin) ==
EOF

# Fleet visibility: Hosts -> All Hosts shows "image mode" hosts and their booted image.
# Remote Execution job template "Bootc Action - Script Default" wraps bootc status/
# switch/upgrade/rollback. Examples:
echo
echo "  # Report bootc status across the fleet"
echo "  hammer job-invocation create --job-template 'Bootc Action - Script Default' \\"
echo "    --search-query 'os = RedHat' --inputs action=status"
echo
echo "  # Roll a node to a new image tag (staged; takes effect on reboot)"
echo "  hammer job-invocation create --job-template 'Bootc Action - Script Default' \\"
echo "    --search-query 'name = bootc-node10.demo.lab' \\"
echo "    --inputs action=switch,image=$SAT/${ORG_LABEL,,}-bootc-rhel10-bootc-demo:v2"
echo
echo "  # Rollback after a bad v2"
echo "  hammer job-invocation create --job-template 'Bootc Action - Script Default' \\"
echo "    --search-query 'name = bootc-node10.demo.lab' --inputs action=rollback"
