#!/usr/bin/env bash
# 06-integrations.sh — run ON the Satellite VM as root.
# 1) Local libvirt compute resource (provision fleet VMs onto this KVM host)
# 2) Red Hat connector (rhc) / Insights rollout across the fleet
set -euo pipefail

HYPERVISOR=192.168.122.1     # KVM host, reachable via the 'default' network NIC
# The hypervisor's sshd refuses root login (PermitRootLogin no via the
# csb-remote-access policy), so the compute resource connects as a dedicated
# user in the host's libvirt group. Passed by build-and-configure.sh.
HYPERVISOR_USER="${HYPERVISOR_USER:-}"
ORG="Default Organization"
LOC="Lab"

echo "== 1. Libvirt compute resource =="
# The Libvirt provider uses qemu+ssh as the 'foreman' user -> the hypervisor
# user (libvirt group member; the host's sshd refuses root login).
sudo -u foreman mkdir -p /usr/share/foreman/.ssh
[[ -f /usr/share/foreman/.ssh/id_ed25519 ]] || \
  sudo -u foreman ssh-keygen -t ed25519 -N '' -f /usr/share/foreman/.ssh/id_ed25519
# The foreman public key is authorized on the hypervisor by the orchestrator
# (build-and-configure.sh runs on the host) before this script runs. Here we
# only accept the host key and verify the connection non-interactively.
# The hypervisor user must be in the host's libvirt group (root login is
# refused by the host's sshd policy).
HV_CONN_USER="${HYPERVISOR_USER:-root}"
sudo -u foreman ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 "${HV_CONN_USER}@$HYPERVISOR" true

# Idempotent: the compute resource persists across re-runs.
if hammer compute-resource info --name "KVM-Host" >/dev/null 2>&1; then
  echo "  compute resource KVM-Host already exists"
else
  hammer compute-resource create --name "KVM-Host" --provider Libvirt \
    --url "qemu+ssh://${HV_CONN_USER}@$HYPERVISOR/system" \
    --display-type VNC --set-console-password true \
    --locations "$LOC" --organizations "$ORG"
fi

# Verify Satellite can see the satlab network + storage pools on the hypervisor.
# These queries are not implemented for the Libvirt provider in some Satellite
# versions (ERF42-7329); they are informational only, so never fail the build.
hammer compute-resource networks --name "KVM-Host" || \
  echo "  (networks query not supported for Libvirt here — continuing)"
hammer compute-resource storage-pools --name "KVM-Host" || \
  echo "  (storage-pools query not supported for Libvirt here — continuing)"

echo
echo "== 2. Red Hat connector (rhc) / Insights =="
# Cloud plugin is enabled by default on current Satellite; harmless to re-assert:
satellite-installer --scenario satellite --enable-foreman-plugin-rh-cloud

# Stage the clients on every managed node via Remote Execution. There are no
# managed nodes on a fresh build (they are provisioned later), and the
# os_family search field is not recognized until hosts exist — so this is
# best-effort and never fails the build.
hammer job-invocation create --job-template "Run Command - Script Default" \
  --search-query "os_family = Redhat" \
  --inputs command="dnf install -y rhc insights-client" || \
  echo "  (rhc/Insights staging skipped — no managed nodes yet)"

cat <<'EOF'
Choose ONE connectivity pattern per node:

Option A — direct egress to the Hybrid Cloud Console (simplest demo path)
  # Create an activation key first: console.redhat.com -> Insights ->
  # Remote Host Configuration -> Activation keys (note your ORG ID from
  # console.redhat.com -> Settings -> Remote Host Configuration).
  hammer job-invocation create --job-template "Run Command - Script Default" \
    --search-query "os_family = Redhat" \
    --inputs command="rhc connect --organization RH_ORG_ID --activation-key INSIGHTS_AK && rhc status"
  # One command delivers: Insights registration + remediations (rhc worker) +
  # optional subscription attach. 'rhc disconnect' reverses it.

Option B — no node egress: Insights proxied through Satellite
  # katello-host-tools (installed at registration) already points insights-client
  # at the Satellite; hosts report via Satellite without internet access:
  #     insights-client --register        # automatic during host registration
  #     insights-client --status
  # Remediations need the Red Hat connector ON THE SATELLITE:
  #   console.redhat.com -> Insights -> Remediations -> Connections ->
  #   "Red Hat Satellite" -> run the generated Ansible playbook against the
  #   Satellite (it enables the rhc/cloud-connector worker locally).
  # Then: Insights -> Remediations -> select Satellite-managed hosts -> the fix
  # is pushed through Satellite Remote Execution (SSH).
EOF
