#!/usr/bin/env bash
# build-and-configure.sh — orchestrate the full Satellite lab build from the
# aap-demo host, non-interactively. Drives the satellite-lab stages in order:
#   network -> host NFS storage -> provision VM -> wait for install ->
#   satellite-installer -> content (hammer) -> provisioning -> integrations
#
# Invoked by `aap-demo create --full-demo --satellite` when the Satellite VM
# does not yet exist. Safe to re-run: each stage is skipped when already done.
#
# Required env / Vault:
#   - Red Hat offline token in the Vault (satellite-manifest addon uses it)
#   - RHSM_USERNAME/RHSM_PASSWORD (or RHSM_ORG/RHSM_AK) in the Vault for the VM
#   - RHEL 9.x DVD ISO at $RHEL_ISO (default /var/lib/libvirt/images/rhel-9.5-x86_64-dvd.iso)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../includes/credential-vault.sh
source "${REPO_ROOT}/includes/credential-vault.sh"
# shellcheck source=../includes/satellite-ca-trust.sh
source "${REPO_ROOT}/includes/satellite-ca-trust.sh"

SAT_IP="${SATELLITE_LAB_IP:-192.168.122.20}"
SAT_HOST="${SATELLITE_LAB_HOST:-satellite.demo.lab}"

# The kickstart injects the invoking user's SSH key for root, but this script
# runs under sudo (where $HOME is /root and root has no key). Point ssh/scp at
# the invoking user's key explicitly so the post-boot stages can connect.
_SAT_KEY=""
if [ -n "${SUDO_USER:-}" ]; then
  _sat_user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  for _k in "$_sat_user_home/.ssh/id_ed25519" "$_sat_user_home/.ssh/id_rsa"; do
    [ -f "$_k" ] && { _SAT_KEY="$_k"; break; }
  done
fi
for _k in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa"; do
  [ -z "$_SAT_KEY" ] && [ -f "$_k" ] && _SAT_KEY="$_k"
done
_SAT_KEY_OPTS=""
[ -n "$_SAT_KEY" ] && _SAT_KEY_OPTS="-i $_SAT_KEY -o IdentitiesOnly=yes"

SAT_SSH="ssh $_SAT_KEY_OPTS -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10 root@${SAT_IP}"
SAT_SCP="scp $_SAT_KEY_OPTS -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes"
# Let 01-provision-satellite-vm.sh resolve the ISO path from RHEL_INSTALL_SOURCE
# (boot vs dvd) unless the caller pinned an explicit path.
RHEL_ISO="${RHEL_ISO:-}"
MANIFEST="${MANIFEST:-${AAP_DEMO_DIR:-$HOME/.aap-demo}/satellite/manifest.zip}"
VIRSH="virsh -c qemu:///system"

_err() { printf 'ERROR: %s\n' "$*" >&2; }
_log() { printf '  %s\n' "$*"; }

# --- credential helpers -----------------------------------------------------
_vault_val() { aap_demo_vault_get "$1" 2>/dev/null || true; }

# --- stage checks -----------------------------------------------------------
_sat_vm_exists() { $VIRSH dominfo satellite >/dev/null 2>&1; }
_sat_ssh_ready() { $SAT_SSH 'true' 2>/dev/null; }
_sat_installed() { $SAT_SSH 'systemctl is-active foreman.service >/dev/null 2>&1' 2>/dev/null; }
_sat_content_done() { $SAT_SSH 'hammer content-view list 2>/dev/null | grep -q RHEL9' 2>/dev/null; }

# --- stages -----------------------------------------------------------------
_stage_network() {
  _log "▸ Stage: network setup"
  sudo bash "${SCRIPT_DIR}/00-network-setup.sh"
}

_stage_manifest() {
  if [ -s "$MANIFEST" ]; then
    _log "✓ Manifest already present: $MANIFEST"
    return 0
  fi
  _log "▸ Stage: build subscription manifest (satellite-manifest addon)"
  QUIET=true bash "${REPO_ROOT}/aap-demo.sh" enable satellite-manifest
  [ -s "$MANIFEST" ] || { _err "Manifest not produced at $MANIFEST"; return 1; }
}

_stage_provision() {
  if _sat_vm_exists; then
    _log "✓ Satellite VM already exists"
    return 0
  fi
  # The ISO is downloaded automatically from the CDN (using the host's RHSM
  # entitlement cert) when missing. Default to the DVD (full offline package
  # tree). A CDN/network install is not used: the boot ISO carries no packages
  # and the CDN does not publish a .treeinfo-bearing install tree, so Anaconda
  # cannot set up a network software source. The DVD is the reliable path.
  local install_source="${RHEL_INSTALL_SOURCE:-dvd}"
  _log "▸ Stage: provision Satellite VM (unattended kickstart, source=$install_source)"
  local rhsm_user rhsm_pass rhsm_org rhsm_ak ssh_pubkey
  rhsm_user=$(_vault_val RHSM_USERNAME)
  rhsm_pass=$(_vault_val RHSM_PASSWORD)
  rhsm_org=$(_vault_val RHSM_ORG_ID)
  rhsm_ak=$(_vault_val RHSM_ACTIVATION_KEY)
  # Pass the invoking user's SSH public key (sudo changes $HOME to /root).
  ssh_pubkey=""
  for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
    [ -f "$k" ] && { ssh_pubkey=$(cat "$k"); break; }
  done
  sudo \
    RHSM_USER="$rhsm_user" RHSM_PASS="$rhsm_pass" \
    RHSM_ORG="$rhsm_org" RHSM_AK="$rhsm_ak" \
    SATELLITE_SSH_PUBKEY="$ssh_pubkey" \
    RHEL_ISO="$RHEL_ISO" RHEL_INSTALL_SOURCE="$install_source" \
    bash "${SCRIPT_DIR}/01-provision-satellite-vm.sh"
}

_stage_wait_install() {
  _log "▸ Stage: wait for the kickstart install to finish (VM reboots when done)"
  # The installer reboots the VM; SSH becomes available once RHEL is up.
  # With virt-install --noautoconsole + the kickstart `reboot`, the VM can be
  # left shut off after the install completes — detect that and start it.
  local attempt
  for attempt in $(seq 1 120); do
    if _sat_ssh_ready; then
      _log "✓ Satellite VM is up and reachable over SSH"
      return 0
    fi
    # If the VM is shut off, the install finished and it needs starting.
    if [ "$($VIRSH domstate satellite 2>/dev/null)" = "shut off" ]; then
      _log "  VM is off after install; starting it..."
      $VIRSH start satellite >/dev/null 2>&1 || true
      $VIRSH autostart satellite >/dev/null 2>&1 || true
    fi
    sleep 15
  done
  _err "Timed out waiting for the Satellite VM to become SSH-ready"
  return 1
}

# Register the VM with RHSM over SSH (post-boot). The kickstart %post cannot
# register reliably: there is no TTY to debug auth failures, and a bad
# credential hangs the install silently. Doing it here surfaces errors and
# lets us retry. Order: existing registration -> existing cert access ->
# activation key -> username/password -> host entitlement certs (the same
# CDN cert-auth pattern 00a-fetch-rhel-iso.sh uses for the ISO download).
_stage_register() {
  if $SAT_SSH 'subscription-manager identity >/dev/null 2>&1'; then
    _log "✓ Satellite VM already registered with RHSM"
    _stage_repos
    return 0
  fi
  if $SAT_SSH 'dnf list satellite >/dev/null 2>&1'; then
    _log "✓ Satellite packages already accessible (entitlement certs present)"
    _stage_repos
    return 0
  fi
  _log "▸ Stage: register Satellite VM with RHSM"
  local rhsm_user rhsm_pass rhsm_org rhsm_ak
  rhsm_user=$(_vault_val RHSM_USERNAME)
  rhsm_pass=$(_vault_val RHSM_PASSWORD)
  rhsm_org=$(_vault_val RHSM_ORG_ID)
  rhsm_ak=$(_vault_val RHSM_ACTIVATION_KEY)

  if [ -n "$rhsm_ak" ] && [ -n "$rhsm_org" ]; then
    _log "  using activation key (org $rhsm_org)"
    if $SAT_SSH "subscription-manager register --org='$rhsm_org' --activationkey='$rhsm_ak'"; then
      _stage_repos
      return 0
    fi
    _log "  activation-key registration failed; trying next method"
  fi

  if [ -n "$rhsm_user" ] && [ -n "$rhsm_pass" ]; then
    _log "  using username $rhsm_user"
    # Pass the secret over stdin to keep it out of the process list.
    if printf '%s' "$rhsm_pass" | $SAT_SSH \
      "subscription-manager register --username='$rhsm_user' --password=\"$(cat)\" --auto-attach"; then
      _stage_repos
      return 0
    fi
    _log "  username/password registration failed; trying host entitlement certs"
  fi

  _stage_register_host_certs
}

# Enable only the repos Satellite 6.17 on RHEL 9 needs. Enable and verify each
# repo individually: a combined --disable='*' --enable=... can silently drop a
# repo when the entitlement cert's content list has not refreshed yet.
_stage_repos() {
  local repo
  $SAT_SSH "subscription-manager repos --disable='*'" || return 1
  for repo in \
    rhel-9-for-x86_64-baseos-rpms \
    rhel-9-for-x86_64-appstream-rpms \
    satellite-6.17-for-rhel-9-x86_64-rpms \
    satellite-maintenance-6.17-for-rhel-9-x86_64-rpms; do
    $SAT_SSH "subscription-manager repos --enable='$repo'" || {
      _err "Failed to enable repository: $repo"
      return 1
    }
  done
  # Refresh metadata and confirm the satellite package is actually visible.
  # 'dnf list' (not 'list available') so an already-installed package passes.
  $SAT_SSH 'dnf clean all >/dev/null 2>&1; dnf list satellite >/dev/null 2>&1' || {
    _err "Satellite packages are not reachable after enabling repositories"
    return 1
  }
  _log "✓ Satellite VM content access ready"
}

# Fallback: copy the host's RHSM entitlement cert to the VM so it can pull
# packages from the CDN without its own registration. This mirrors how
# 00a-fetch-rhel-iso.sh downloads the RHEL ISO with the host cert.
_stage_register_host_certs() {
  _log "▸ Stage: grant the Satellite VM CDN access via the host entitlement"
  local ent_cert="" ent_key="" f
  for f in /etc/pki/entitlement/*.pem; do
    [ -e "$f" ] || continue
    case "$f" in
      *-key.pem) [ -z "$ent_key" ] && ent_key="$f" ;;
      *) [ -z "$ent_cert" ] && ent_cert="$f" ;;
    esac
  done
  if [ -z "$ent_cert" ] || [ -z "$ent_key" ]; then
    _err "No working RHSM credentials and no host entitlement cert found."
    _err "  Set RHSM credentials: aap-demo fleet auth configure"
    _err "  Or register this host: subscription-manager register ..."
    return 1
  fi

  $SAT_SSH 'mkdir -p /etc/pki/entitlement && chmod 755 /etc/pki/entitlement' || return 1
  $SAT_SCP "$ent_cert" "$ent_key" "root@${SAT_IP}:/etc/pki/entitlement/" || return 1
  $SAT_SSH 'chmod 644 /etc/pki/entitlement/*.pem' || return 1

  # subscription-manager reads entitlement certs directly from
  # /etc/pki/entitlement even without a consumer identity, so repo enablement
  # and dnf metadata fetches authenticate with the host cert.
  _stage_repos || return 1

  # Prove the Satellite repo metadata is reachable before the installer runs.
  $SAT_SSH 'dnf clean all >/dev/null 2>&1; dnf list satellite >/dev/null 2>&1' || {
    _err "Satellite packages are not reachable via the host entitlement cert"
    return 1
  }
  _log "✓ Satellite packages accessible via host entitlement cert"
}

_stage_installer() {
  if _sat_installed; then
    _log "✓ Satellite already installed"
    return 0
  fi
  _log "▸ Stage: run satellite-installer on the VM"
  # Pull the admin password from the encrypted Vault (generated on first use)
  # and pass it to the installer over the SSH environment, never on the command
  # line or in the repo.
  local admin_pass
  admin_pass=$(aap_demo_satellite_admin_password) || {
    _err "Could not read/generate the Satellite admin password from the Vault"
    return 1
  }
  $SAT_SCP "${SCRIPT_DIR}/02-satellite-installer.sh" "root@${SAT_IP}:/root/" || return 1
  # Send the password over stdin; the installer reads it if SATELLITE_ADMIN_PASSWORD
  # is unset. This keeps it out of the remote process list.
  printf '%s\n' "$admin_pass" | $SAT_SSH \
    'SATELLITE_ADMIN_PASSWORD="${SATELLITE_ADMIN_PASSWORD:-$(cat)}" bash /root/02-satellite-installer.sh' || {
    unset admin_pass
    return 1
  }
  unset admin_pass
}

_stage_content() {
  if _sat_content_done; then
    _log "✓ Satellite content already configured"
    return 0
  fi
  _log "▸ Stage: content architecture (manifest + RHEL 9/10 repos, on_demand)"
  $SAT_SCP "$MANIFEST" "root@${SAT_IP}:/root/manifest.zip" || return 1
  $SAT_SCP "${SCRIPT_DIR}/03-content-hammer.sh" "root@${SAT_IP}:/root/" || return 1
  $SAT_SSH 'bash /root/03-content-hammer.sh /root/manifest.zip' || return 1
}

_stage_provisioning() {
  _log "▸ Stage: provisioning (kickstart host groups)"
  $SAT_SCP "${SCRIPT_DIR}/04-provisioning-kickstart.sh" "root@${SAT_IP}:/root/" || return 1
  $SAT_SSH 'bash /root/04-provisioning-kickstart.sh' || return 1
}

_stage_integrations() {
  _log "▸ Stage: integrations (libvirt compute resource, rhc/Insights)"

  # The Satellite's foreman user drives the hypervisor over qemu+ssh. The
  # host's sshd policy (99-csb-remote-access.conf) sets PermitRootLogin no, so
  # the compute resource connects as the invoking user (who is in the libvirt
  # group), never root. Generate the foreman key on the VM, then authorize it
  # in that user's authorized_keys here (this orchestrator runs on the host).
  local hv_user="${SATELLITE_HYPERVISOR_USER:-${SUDO_USER:-$USER}}"
  $SAT_SSH 'sudo -u foreman mkdir -p /usr/share/foreman/.ssh && \
    [ -f /usr/share/foreman/.ssh/id_ed25519 ] || \
    sudo -u foreman ssh-keygen -t ed25519 -N "" -f /usr/share/foreman/.ssh/id_ed25519' || return 1
  local foreman_pubkey
  foreman_pubkey=$($SAT_SSH 'cat /usr/share/foreman/.ssh/id_ed25519.pub' 2>/dev/null) || {
    _err "Could not read the foreman public key from the Satellite VM"
    return 1
  }
  if [ -n "$foreman_pubkey" ]; then
    local hv_home auth_keys
    hv_home=$(getent passwd "$hv_user" | cut -d: -f6)
    auth_keys="$hv_home/.ssh/authorized_keys"
    mkdir -p "$hv_home/.ssh" && chmod 700 "$hv_home/.ssh"
    touch "$auth_keys" && chmod 600 "$auth_keys"
    chown -R "$hv_user:$(id -gn "$hv_user")" "$hv_home/.ssh"
    grep -qF "$foreman_pubkey" "$auth_keys" 2>/dev/null || {
      echo "$foreman_pubkey" >>"$auth_keys"
      _log "  Authorized the Satellite foreman key on the hypervisor ($hv_user)"
    }
  fi

  $SAT_SCP "${SCRIPT_DIR}/06-integrations.sh" "root@${SAT_IP}:/root/" || return 1
  # Pass the hypervisor user so the compute resource URL is qemu+ssh://user@host.
  $SAT_SSH "HYPERVISOR_USER='$hv_user' bash /root/06-integrations.sh" || return 1
}

# Trust the Satellite's Katello CA on the host so the UI and CLI tools stop
# warning about the self-signed cert. Runs as the invoking user (not root) so
# the NSS import lands in that user's browser stores; the system ca-trust
# import uses sudo. Idempotent and skipped when the CA is already trusted.
_stage_ca_trust() {
  _log "▸ Stage: trust Satellite CA on host (browser + CLI)"
  # The orchestrator may run under sudo; import into the invoking user's
  # stores so browser trust lands in the right NSS DB.
  if [ -n "${SUDO_USER:-}" ]; then
    sudo -u "$SUDO_USER" AAP_DEMO_TRUST_CA="${AAP_DEMO_TRUST_CA:-true}" \
      bash -c "source '${REPO_ROOT}/includes/satellite-ca-trust.sh'; install_satellite_ca_trust" || return 1
  else
    install_satellite_ca_trust || return 1
  fi
}

main() {
  echo ""
  echo "Satellite Build and Configure - building the Satellite lab..."
  _stage_network
  _stage_manifest
  _stage_provision
  _stage_wait_install
  _stage_register
  _stage_installer
  _stage_content
  _stage_provisioning
  _stage_integrations
  _stage_ca_trust
  echo ""
  echo "✓ Satellite Build and Configure complete"
  echo "  Satellite UI: https://${SAT_HOST} (admin / see 'aap-demo status --show-secrets')"
  echo "  Next: aap-demo enable product-demo-satellite (Satellite Demo content)"
}

main "$@"
