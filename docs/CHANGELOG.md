# Changelog

This changelog records the successful changes made after the original
`aap-demo 1.0.48` checkout at commit `39564b5` on 2026-10-16.

It is intentionally implementation-oriented so another engineer or AI can use it
as a patch specification. It describes the final working behavior, affected
surfaces, implementation sequence, and validation evidence. Failed intermediate
attempts are omitted unless they explain a requirement of the final fix.

## Unreleased - cumulative changes since `39564b5`

### 55. Hands-free `--sno` / `--microshift` flags and SNO deployment fixes

`aap-demo create` now accepts `--sno` and `--microshift` for non-interactive
tier selection, complementing the interactive prompt from entry 54. `--sno`
sets `CRC_PRESET=openshift` and `--microshift` sets `CRC_PRESET=microshift`;
both export the preset and set `AAP_DEMO_TIER_PROMPT=false` so the tier prompt
is skipped (the flags are the hands-free path for `create --full-demo
--satellite --sno`). When SNO is requested but the host does not meet the
minimums, `includes/crc-create.sh` now fails fast with the specific unmet
requirements and points at `--microshift`, rather than OOM-starving a full
control plane. Help text documents both flags.

**Lightspeed on SNO.** The `lightspeed` addon's postgres StatefulSet runs with
`capabilities: drop: ["ALL"]` and no `runAsUser`/`fsGroup`, so on SNO (random
UID via the `anyuid` SCC) it could not write the root-owned PVC — CrashLoopBackOff
with "mkdir: cannot create directory '/var/lib/pgsql/data/userdata': Permission
denied". The operator's `postgres_data_volume_init` init container is gated to
`not is_openshift`, so it does not help on SNO. `addons/lightspeed/deploy.sh`
now detects the permission crash and fixes the PVC ownership with a one-off
privileged pod (`chown -R 26:26`), then restarts postgres. Verified live on
SNO: `aap-lightspeed-api` + `aap-lightspeed-postgres-15` Running, route
`https://aap-lightspeed-aap-operator.apps-crc.testing` returns 200, and the
Lightspeed API reaches the in-cluster Ollama `qwen2.5:3b` endpoint.

**Validation:** `bash -n` + `shellcheck` clean on `aap-demo.sh`,
`includes/crc-create.sh`, `includes/help.sh`, `addons/lightspeed/deploy.sh`;
`test-cli-parsing.sh` passes; flag parsing verified to set `CRC_PRESET` and
skip the prompt. Live: `create --full-demo --satellite --sno` completed
end-to-end (exit 0) on OpenShift 4.22.14 SNO — AAP UI 200, OpenShift web
console 200, Ollama serving, 3 fleet nodes registered, Satellite UI trusted,
all full-demo addons enabled. (The `machine-config` cluster operator reports
Degraded on single-node CRC, which is expected and cosmetic.)

### 54. Hardware-aware SNO/MicroShift tier prompt in create

`aap-demo create` now prompts the user to choose a deployment tier based on
what the host hardware supports, instead of silently defaulting to MicroShift.
A new `_prompt_tier_choice` in `includes/crc-create.sh` runs after host
resource detection (CPUs/RAM/disk) and before the preset is locked in.

When the host meets the SNO minimums (≥8 vCPUs, ≥16 GB RAM [32 GB
recommended], ≥100 GB disk — the same thresholds as
`scripts/aap-demo-tier-select.sh`), it prints "This hardware will support
SNO" with both tiers listed and asks "Use Single Node OpenShift? [y/n]
(default: y)". When the host falls short, it prints "The hardware will support
MicroShift" with the unmet SNO requirements and asks "Continue with
MicroShift? [y/n] (default: y)"; answering `n` aborts so the user can free
resources or pin `CRC_PRESET`.

The prompt is skipped (preserving prior behavior) when `CRC_PRESET` is already
set, when `QUIET=true`, when `AAP_DEMO_TIER_PROMPT=false`, or on a
non-interactive TTY — so scripts and `--full-demo` non-interactive runs are
unaffected. The chosen tier is exported as `CRC_PRESET` and persisted to
`~/.aap-demo/config` via the existing `_save_config_key`. Host resource
detection (`_detect_host_resources` + disk) moved above the preset block so
the prompt has the numbers it needs.

**Validation:** `bash -n` and `shellcheck` clean; detection logic verified for
both SNO-capable and under-resourced hosts; prompt gating verified to skip on
pinned preset / quiet / non-interactive; `test-cli-parsing.sh` and
`test-portability.sh` pass; full shell suite 105/106 (the one failure is the
pre-existing `test-core-commands.sh` `status_executes`, unrelated).

### 53. Satellite CA trust, fleet→Satellite registration, and AAP Lightspeed on Ollama

Three lab integrations completed and automated.

**Satellite CA trust on the host.** The Satellite VM serves a self-signed cert
from its own Katello CA (`CN=satellite.demo.lab`), so browsers and CLI tools
rejected it with `ERR_CERT_AUTHORITY_INVALID`. New
`includes/satellite-ca-trust.sh` fetches the CA from the Satellite's
unauthenticated `/pub/katello-server-ca.crt` (validating it is a `CA:TRUE`
cert, not a leaf) and imports it into the dual stores per ADR-015: the OS
store (`update-ca-trust` / `update-ca-certificates`) for curl/hammer/ansible,
and the NSS stores (`~/.pki/nssdb`, `~/.local/share/pki/nssdb`, Firefox
profiles) for Chrome/Chromium/Firefox. Import is idempotent (SHA-256
fingerprint match against the installed anchor) and skipped when
`AAP_DEMO_TRUST_CA=false`. A `_stage_ca_trust` stage in
`build-and-configure.sh` runs it as the invoking user (not root) so browser
trust lands in the right NSS DB. New `test/test-satellite-ca-trust.sh` (6
cases: fingerprint format, CA accept / non-CA reject, already-trusted match /
mismatch, skip flag).

**Fleet nodes register to the Satellite.** New `aap-demo fleet
satellite-register` (`includes/fleet-satellite.sh` +
`satellite-lab/07-fleet-activation-key.sh`) registers every running fleet node
to the Satellite instead of directly to Red Hat, so content is served from the
local Pulp and hosts appear in the Satellite inventory. The Satellite-side
script creates a `fleet-rhel9` activation key bound to the content view that
actually has repositories (RHEL9, falling back to RHEL10) in the org that owns
it — the lab publishes RHEL content views in **Demo Org**, while the manifest
lives in **Default Organization**. Per node, registration (1) installs
`katello-ca-consumer` to trust the Satellite CA, (2) registers with
`subscription-manager --activationkey`, and (3) registers Insights / connects
`rhc`. Two node-specific fixes were required: fleet nodes are cloned from one
image and share a DMI UUID, which Satellite rejects as a duplicate (HTTP 422),
so each node writes a unique `dmi.system.uuid` rhsm fact before registering;
and a stale Insights `.registered` file from a pre-Satellite direct attempt
makes `--register` refuse with "Machine-id found", so it is cleared first.
Credentials and the AK name cross SSH via stdin, never argv. New
`test/test-fleet-satellite.sh` (7 cases).

**Ansible Lightspeed in AAP, backed by Ollama.** New `lightspeed` addon
(`addons/lightspeed/deploy.sh`) deploys the Lightspeed intelligent assistant
into the existing `aap-operator` namespace, wired to the local Ollama LLM
(`qwen2.5:3b`) instead of a cloud model. It creates a model-configuration
Secret pointing at the in-cluster Ollama OpenAI-compatible endpoint
(`http://ollama.aap-demo-ollama.svc.cluster.local:11434/v1`, `model_type:
wca-onprem`, which requires a `username` key even though Ollama ignores it),
then an `AnsibleLightspeed` CR (`lightspeed.ansible.com/v1alpha1`) that the
ansible-lightspeed operator reconciles into the Lightspeed API + postgres. The
addon depends on `ollama` in `config/addons-dashboard.json` and is registered
in `AVAILABLE_ADDONS` and the `enable` argument parser. Verified live:
`aap-lightspeed-api` and `aap-lightspeed-postgres-15` pods Running, route
`https://aap-lightspeed-aap-operator.apps.127.0.0.1.nip.io` returns 200.

**Known manual step — Insights cloud confirmation.** Fleet nodes upload
Insights data to the Satellite's `rh_cloud` connector, but the Satellite only
forwards it to Red Hat after the org has a Hybrid Cloud branch ID
(`foreman-rake rh_cloud:hybridcloud_register`). That task requires a
**cert-based Hybrid Cloud API token** from console.redhat.com → Integrations →
Satellite (the Vault's offline OAuth token returns 401 "Certificate required"),
so it cannot be fully automated; until it is run, `insights-client --status`
reports "Insights API could not be reached" on the nodes even though they are
correctly registered to the Satellite.

**Validation:** `test-satellite-ca-trust.sh` 6/6, `test-fleet-satellite.sh`
7/7; `bash -n` and `shellcheck` clean on all touched scripts. Live: 3/3 fleet
nodes registered and visible in `hammer host list`; Lightspeed API + route
serving; Satellite UI trusted (302) with no browser warning. The pre-existing
`test-core-commands.sh` `status_executes`/`status_format` failure (exit 255)
reproduces with these changes stashed and is unrelated.

Current comparison point:

- Baseline: `39564b5`
- Latest committed state inspected: `7cbc0c2`
- Additional working-tree implementation and documentation changes are included
  below. Entries 35-37 record the Fleet updates completed on 2026-10-23.
- The earlier cumulative file/line counts predate these Fleet changes and are
  omitted rather than presented as current totals.

### 52. Satellite lab: post-boot RHSM registration, entitlement fallback, and demo-content wiring

The Satellite lab now builds end-to-end on a host whose RHSM account has a
Satellite infrastructure subscription, and the Satellite demo content installs
against it without manual credential edits.

Registration moved out of the kickstart `%post` (a bad credential hung the
install silently with no TTY) into a post-boot SSH stage
(`_stage_register` in `build-and-configure.sh`). It tries, in order: an
existing registration, existing entitlement certs, `RHSM_ORG_ID` +
`RHSM_ACTIVATION_KEY`, `RHSM_USERNAME` + `RHSM_PASSWORD`, and finally the
**host's entitlement cert** copied to the VM (the same CDN cert-auth pattern
`00a-fetch-rhel-iso.sh` uses for the ISO). `_stage_repos` enables and verifies
each required repo individually and confirms the `satellite` package is visible
with `dnf list` (not `list available`, which false-fails once the package is
installed). The orchestrator authorizes the Satellite's foreman SSH key in the
invoking user's `authorized_keys` (the host's sshd refuses root login via the
`99-csb-remote-access.conf` policy), and the Libvirt compute resource connects
as that user (`qemu+ssh://<user>@host/system`), never root.

The Satellite VM uses `satellite.demo.lab`; the cluster's CoreDNS now maps that
FQDN to the VM's real IP (a `hosts` block in `configure_coredns`, applied only
when the Satellite VM is running) so AAP controller pods resolve it — the
`apps.127.0.0.1.nip.io` wildcard cannot be used because it resolves to the
pod's own loopback. The lab org is now `Default Organization` (was `Demo Org`)
to match the upstream product-demos Satellite content, and the manifest is
imported there.

`product-demo-satellite` now wires the APD **Satellite Credential** and
**Satellite Inventory** to the real server (`SATELLITE_URL` /
`SATELLITE_USERNAME` / `SATELLITE_PASSWORD`, defaulting to the lab's
`https://satellite.demo.lab` admin) before/after the install, and re-runs
`SETUP | Satellite` against the wired server. The SETUP bootstrap creates
RHEL 7/8 content views from upstream host_vars, which do not apply to this
RHEL 9/10 lab, so its failure is a warning, not an addon failure — the
`SATELLITE | *` / `LINUX | * with Satellite` templates are installed and work
against the lab's RHEL 9/10 content.

Hammer option fixes for Satellite 6.17: `--httpboot-id` (numeric capsule ID,
not a hostname), `--root-password` (not `--root-pass`), `--display-type VNC`
(uppercase), `--unlimited-hosts` (a bare flag, no value), and dropped the
nonexistent `--enable-foreman-plugin-bootc` (image-mode support ships in core).
Subnet, hostgroup, activation-key, and compute-resource creation are now
idempotent so re-runs converge instead of failing on "already taken".

`create --full-demo` now defaults the CRC VM to 32 GB (`CRC_MEMORY=32768`)
unless the caller pinned memory — AAP + AO + Ollama + Fleet + product demos
OOM-starved the AO UI pod at the 16 GB default. The fleet step resolves the
`rhel9` managed image and passes `FLEET_IMAGE` + `FLEET_NODE_COUNT=3` to
`enable fleet` (which creates the nodes itself in current upstream), and skips
re-enabling when the nodes already exist so re-runs do not create duplicates.

**Validation:** new `test/test-satellite-register.sh` (6 cases: registration
short-circuits, activation-key preference, username/password and host-cert
fallback order, missing-cert guidance); `test-full-demo.sh`,
`test-cli-parsing.sh`, `test-dashboard.py` pass; full shell suite 104/104 and
Python suite 1058/1058 pass; `bash -n` and `shellcheck --severity=warning`
clean on all touched scripts. Live: `create --full-demo --satellite` completes
end-to-end — AAP Successful (27/27 pods), AO 8/8, three Fleet nodes registered,
Satellite serving HTTPS at https://satellite.demo.lab, and the Satellite demo
templates installed.

### 51. Fully automatic Satellite lab: ISO download, reliable install, dashboard visibility

The satellite-lab is now fully automatic end-to-end. `00a-fetch-rhel-iso.sh`
downloads the RHEL 9.x DVD ISO from the Red Hat CDN using the host's RHSM
entitlement certificate — no portal login or manual download. The kickstart
writes persistent NetworkManager keyfiles in `%post` so the static IPs survive
the post-install reboot (the `network --device=<MAC>` lines only configure the
install environment), injects the invoking user's SSH public key for root
(passed through sudo via `SATELLITE_SSH_PUBKEY`, since sudo changes `$HOME` to
/root), and hashes the root password (`rootpw --iscrypted`, SHA-512) instead of
rendering it plaintext. The Satellite VM gets a VNC graphical console
(`--graphics vnc --video vga`, dual `console=tty0 console=ttyS0`) so
virt-manager shows a live console, and `build-and-configure.sh` starts the VM
when the install leaves it shut off. The dashboard now surfaces the Satellite
lab in Routes (pending during the build, admitted once it serves HTTPS) and as
an external `satellite-lab` entry in Namespaces. Fleet nodes get VNC displays
(5911+, offset to avoid colliding with the Satellite VM).

Note: a CDN/network install source is not used — the boot ISO carries no
packages and the CDN does not publish a `.treeinfo`-bearing install tree, so
Anaconda cannot set up a network software source. The DVD ISO (full BaseOS +
AppStream tree) is the reliable automated path.

**Validation:** kickstart validated with pykickstart; the DVD downloads via the
entitlement cert (11 GB, valid bootable tree); the VM installs, registers with
RHSM, mounts the host NFS `/var/lib/pulp`, and is reachable over key-based SSH;
test-cli-parsing, test-full-demo, test-system-info-document, and
test-dashboard.py pass; `bash -n` and `shellcheck --severity=warning` clean.

### 50. Add per-node fleet power control (CLI + dashboard)

Fleet nodes can now be power-controlled individually. The new
`fleet_node_power <index> <start|stop|restart>` in `addons/fleet/fleet.sh`
drives a single node; `aap-demo fleet node <index> <start|stop|restart>`
exposes it in the CLI (the arg parser now keeps `start`/`stop`/`restart` as
fleet args when the fleet command is selected, instead of treating them as
top-level commands). The dashboard fleet node cards gained start/stop/restart
buttons backed by a new `POST /api/fleet/<index>/power` endpoint (with the same
origin + session-token validation as the other mutating endpoints). Stop now
also clears the node PID and marks the meta `STATUS=stopped`, and
`fleet_stop_all` keeps node metas in sync, so the dashboard reflects the real
power state.

**Validation:** `test/test-fleet-cli.sh` extended with power-control cases
(index/action validation, missing node, stop marks stopped, restart runs
stop+start); stop/start/restart verified live against the fleet nodes both via
the CLI and the dashboard API; test-fleet-access, test-fleet-auth,
test-cli-parsing, and test-dashboard.py pass; `bash -n` and
`shellcheck --severity=warning` clean.

### 49. Add a self-healing CRC vsock forward watchdog

The recurring "VM running but MicroShift/SSH unreachable" fault — the CRC
daemon's vsock forward (port 2222) dropping under load or after a daemon
restart — is now self-healing. `scripts/aap-demo-crc-watchdog.sh` detects the
dropped forward (VM running + SSH refused) and recovers with the least
disruptive action that works: restart `crc-daemon.service` first, then a full
`crc stop`/`start` only as a last resort. A systemd user timer runs the check
every minute, installed automatically by `aap-demo service install` and removed
by `aap-demo service disable`. Concurrent runs are serialized with a lock;
state is written to `~/.aap-demo/crc-watchdog.state`; retry counts and sleep
are tunable via `AAP_DEMO_WATCHDOG_*`. Documented in `docs/state-service.md`.

**Validation:** `test/test-crc-watchdog.sh` covers healthy (no-op), dropped
forward (daemon-restart recovery), and VM-stopped (no-op) scenarios with stubbed
crc/ssh/systemctl; the timer verified live (installed, enabled, ran on schedule,
reported healthy). test-state-service, test-dashboard-autostart, and
test-maintenance pass; `bash -n` and `shellcheck --severity=warning` clean.

### 48. Extract status/diagnose, help, and fleet handlers from aap-demo.sh

Continued the `includes/` modularization: moved `cmd_status`, `cmd_diagnose`,
and `_show_fleet_status` into `includes/cmd-status.sh`; `show_help` into
`includes/help.sh`; and `cmd_fleet` into `includes/cmd-fleet.sh` (all
double-source-guarded, following the cmd-dashboard.sh/maintenance.sh pattern).
`aap-demo.sh` drops from 4,121 to 3,125 lines and is closer to
parse-and-dispatch only. `test/test-fleet-access.sh` now sources
`_show_fleet_status` from its new home. Note: `addons/ao-eap` is a tracked
symlink to `addons/ao` (the CLI also normalizes the `ao-eap` alias), so there
is no duplicated AO addon to remove.

**Validation:** `bash -n` and `shellcheck --severity=warning` clean on all
touched files; test-cli-parsing, test-full-demo, test-fleet-access,
test-fleet-auth, test-maintenance, test-state-service,
test-system-info-document, and test-dashboard.py all pass; `aap-demo help`,
`status`, `status --json`, `diagnose`, and `fleet list` verified live against
the running cluster. (test-core-commands, test-live-idempotency, test-ollama,
test-storage-capacity, and test-ao-live-smoke fail identically before and after
this change — they are cluster/live-dependent and unrelated.)

### 47. Add `--satellite` full-demo flag and NFS-backed Satellite storage

`aap-demo create --full-demo --satellite` builds and configures the Satellite
lab when the Satellite VM does not yet exist, then installs the Satellite Demo
content. The new `satellite-lab/build-and-configure.sh` orchestrates the lab
non-interactively from the host (network → manifest via the satellite-manifest
addon → VM provision → installer → content → provisioning → integrations),
idempotently skipping completed stages. The Satellite VM now uses a minimal
40 GB OS disk with `/var/lib/pulp` mounted from the host over NFS; the new
`satellite-lab/00b-host-nfs-storage.sh` configures the export, firewalld rules
(when active), and the SELinux `virt_use_nfs`/`nfs_export_all_rw` booleans (when
Enforcing), and the kickstart mounts the export with `_netdev` in `%post`. The
full-demo Satellite logic uses overridable helpers
(`_full_demo_satellite_vm_exists` / `_full_demo_satellite_build`) so tests can
drive both the build and skip paths.

**Validation:** `test/test-full-demo.sh` extended with `--satellite` ordering
and skip cases; `test-cli-parsing.sh`, `test-maintenance.sh`, `bash -n`, and
`shellcheck --severity=warning` all pass; the host NFS export verified live
(`exportfs`/`showmount` answer, nfs-server + rpc.mountd active).

### 46. Add the satellite-manifest addon and adapt satellite-lab for CRC user-mode networking

The new `satellite-manifest` addon (`aap-demo enable satellite-manifest`, also
available as "Build satellite" on the dashboard Add-ons page) creates and
downloads a Red Hat Satellite subscription manifest programmatically via the
RHSM management API, removing the manual portal download from the
satellite-lab content stage. It reuses the credential Vault's Red Hat offline
token (the same `rhsm-api` exchange the fleet addon uses) to find-or-create the
allocation, trigger the export job, poll to completion, and download a signed
`manifest.zip` to `~/.aap-demo/satellite/manifest.zip`. The RHSM allocations
API requires the account to hold the "View/Renew Subscription Information"
permission; the addon detects the 401/403 case and prints guidance to grant the
role (console.redhat.com → Settings → User Access) instead of failing
cryptically. `_rhsm_api` returns the HTTP status on the first stdout line so
callers capture it through the command-substitution subshell.

The `satellite-lab/` scripts assumed a bridged libvirt `crc` network, which
does not exist on hosts running CRC with the MicroShift preset (QEMU user-mode
networking + vsock). The lab is adapted to attach the Satellite VM's first NIC
to the libvirt `default` network (NAT to host/upstream) and reach AAP/CRC
through the host's forwarded ports; the isolated `satlab` network still hosts
Satellite-owned DHCP/PXE for fleet provisioning. `00-network-setup.sh`,
`01-provision-satellite-vm.sh`, `satellite-vm.ks`, `02-satellite-installer.sh`,
`06-integrations.sh`, and the README architecture/teardown were updated.

**Validation:** manifest flow verified live (allocation found/created, export
job completed, signed Candlepin `manifest.zip` downloaded); `satlab` network
defined/started/autostarted alongside `default`; kickstart rendering verified
against the Vault's RHSM credentials; `test-dashboard.py`,
`test-cli-parsing.sh`, `bash -n`, and `shellcheck --severity=warning` all pass.

### 45. Keep the CRC VM reachable during boot recovery

Boot recovery failed on an already-running VM because two steps dropped the CRC
daemon's vsock SSH forward (port 2222), leaving the VM unreachable and failing
the disk-usage check: `state_boot` restarted `crc-daemon.service`
unconditionally, and `_start_crc_cluster` always ran `crc start` (which restarts
the daemon on a running VM). Now `state_boot` only restarts the daemon when the
VM is not running, `_start_crc_cluster` reuses a running, SSH-reachable VM
instead of restarting it, and the storage disk check retries the SSH probe to
ride out the brief forward lag after a genuine `crc start`.

**Validation:** `test/test-state-service.sh` (updated for the conditional
daemon restart), `test/test-crc-storage.sh`, `test/test-crc-create-stability.sh`,
`bash -n`, and `shellcheck --severity=warning` all pass; boot recovery service
installs and validates successfully on a running VM.

### 44. Preserve the credential Vault across uninstall/rebuild cycles

`aap-demo maintenance uninstall` no longer removes the `aap_demo` section from
the encrypted credential Vault (`~/.ansible/conf/env.yml`). The Vault and its
password file (`~/.ansible/conf/.vaultpass.txt`) are shared with other products
and projects, so uninstall now preserves them intact and a later
`create --full-demo` reuses the stored pull secret and tokens without
re-prompting. A new opt-in flag, `aap-demo maintenance uninstall --reconfigure`,
strips only the aap-demo entries (`aap_demo` and `ah_offline_token` keys) so
the next `create` starts fresh; the Vault files themselves are never deleted,
even when no aap-demo data remains. `aap_demo_vault_remove_managed` in
`includes/credential-vault.sh` no longer deletes an emptied Vault file, the
uninstall preview reports exactly which Vault content each mode keeps or
removes, and `--reconfigure` is rejected outside `maintenance uninstall`.

**Validation:** `test/test-credential-vault-migration.sh` and
`test/test-maintenance.sh` updated and passing — default uninstall leaves the
Vault untouched, `--reconfigure` strips only the aap-demo keys, the shared
password file is never modified, and `--reconfigure` is rejected outside
`maintenance uninstall`. `bash -n`, `shellcheck --severity=warning`, and
`test/test-cli-parsing.sh` all clean.

### 43. Modularize preset detection and dashboard/console handlers

`includes/preset.sh` is now the single source of truth for CRC preset
resolution (`aap_demo_detect_crc_preset`: env var → `~/.aap-demo/config` →
`crc config get preset` → `microshift` default) and for preset-derived domain
knowledge: `aap_demo_route_domain` (`apps-crc.testing` on OpenShift,
`apps.127.0.0.1.nip.io` on MicroShift) and
`aap_demo_microshift_kubeconfig_vm_path`. The duplicate detector in
`aap-demo.sh` was removed and `_detect_crc_preset` in `includes/infra-crc.sh`
delegates to the canonical helper. `aap-demo.sh`, `includes/crc-create.sh`,
`includes/addon-wire.sh`, and `includes/infra-crc.sh` consume the helpers
instead of hardcoding domains and VM paths.

`cmd_dashboard`, `cmd_console`, `_aap_demo_auto_console`, and
`_aap_demo_auto_dashboard` moved from `aap-demo.sh` into the new
`includes/cmd-dashboard.sh` module (double-source guarded), leaving the entry
point closer to parse-and-dispatch only.

**Validation:** `bash -n` and `shellcheck --severity=warning` clean on all
touched files; test-cli-parsing, test-full-demo, test-state-service,
test-dashboard-autostart, test-ovn-readiness, test-tier-select,
test-crc-create-stability, test-crc-storage, test-crc-pull-secret,
test-crc-daemon, test-crc-version-check, and test-dashboard.py all pass;
`aap-demo console --no-open` and `aap-demo dashboard --no-open` verified live
against the running OpenShift-preset cluster.

### 42. Add hardware-aware SNO/MicroShift tier selection

Added `scripts/aap-demo-tier-select.sh`, which inspects host vCPUs, RAM, and
root disk space and deploys Single Node OpenShift (`CRC_PRESET=openshift`,
>= 8 vCPUs / 16 GB RAM / 100 GB disk) or MicroShift (>= 2 vCPUs / 2 GB RAM /
10 GB disk). When both tiers are supported it shows an interactive menu with
specs, footprint, and UI availability; otherwise it falls back to MicroShift
with a warning or exits 1 listing the missing prerequisites. Supports
`--tier sno|microshift`, `--yes`, and `--dry-run`, color-coded output, and
distinct exit codes (0 success, 1 insufficient resources, 2 invalid input,
3 deploy failure).

**Validation:** `test/test-tier-select.sh` covers menu choices, invalid-input
retry, forced tiers, exact-minimum boundaries, fallback warning,
insufficient-resource error text, and dry-run; shellcheck clean; real dry-run
on a 16 vCPU / 125 GB host selects SNO.

### 41. Support the OpenShift preset with web console

`CRC_PRESET=openshift` is now an opt-in single-node OpenShift tier.
`includes/crc-create.sh` selects and persists the preset, uses the
CRC-generated kubeconfig and `apps-crc.testing` domain on OpenShift, and skips
MicroShift-only steps (nip.io baseDomain rewrite, CoreDNS patch,
metrics-server, inotify sysctls). New `aap-demo console [--no-open]` command
prints/opens the OpenShift web console and is auto-opened after
create/start/restart/full-demo on the OpenShift preset
(`AAP_DEMO_CONSOLE_AUTOOPEN=false` disables). `_wait_for_ovn_ready` handles
OpenShift's `ovnkube-control-plane` topology (no `ovnkube-master` daemonset).
ADR-020 is updated to partially accepted (opt-in only).

**Validation:** live OpenShift-preset cluster created and AAP operator CSV
reached Succeeded; `test/test-ovn-readiness.sh` covers both OVN topologies;
`aap-demo console --no-open` prints the console URL and masked credentials.

### 40. Restore latest CRC state on boot and auto-open the dashboard

The Linux boot service now resumes the latest CRC disks, settings, credentials
and demo configuration in place at boot instead of restoring an older
checkpoint: `state_boot` restarts the CRC daemon, starts the cluster and the
dashboard HTTP server before login, and warns about (then clears) a stale
shutdown-pending marker. The browser opens at graphical login via
`~/.config/autostart/aap-demo-dashboard.desktop`, installed on the first
create/start/restart. `create --full-demo` installs boot recovery and fails if
recovery installation or dashboard startup fails. Windows gains a native
dashboard command, `status --json`, and dashboard auto-open after login-time
state restore; pre-login recovery remains Linux-only.

**Validation:** test-state-service, test-dashboard-autostart, test-full-demo,
test-windows-platform (292 checks), test-windows-dashboard, and
test-dashboard.py pass.

### 39. Gate CI on clean Python dependencies and core smoke tests

Added a gating `python-cli-smoke` job to the existing lint workflow. It sets
up the tested Python 3.11 runtime, installs the root Python manifest and declared
Ansible collections into the job environment, checks dependency consistency,
imports, and Ansible CLI startup, then runs isolated Vault, Fleet, RHC, CLI,
secret-handling, and dashboard tests. Each failure stops the job. The new job
does not use live credentials, enroll systems, or require a cluster.

**Validation:** Executed the job's dependency installation, collection
installation, checks, and exact test command sequence in a disposable Python
3.11 virtual environment. Both RHC tests and all 24 dashboard tests passed.
Workflow YAML parsing and `git diff --check` passed.

The existing `ansible-lint` job remains advisory pending a separate cleanup of
its current baseline.

### 38. Declare core Python dependencies for manual setup

Added a root `requirements.txt` declaring `ansible-core>=2.16,<3`,
`PyYAML>=6.0.1,<7`, and `kubernetes>=28.0.0`. These provide the Ansible CLI/Vault
tools, YAML credential handling, and the Kubernetes client without installing the
full optional Ansible distribution. Collections remain in `requirements.yml`.

README and full documentation describe Python 3.11 virtual-environment setup,
separate collection installation, dependency checks, and shell activation.
`.venv/` is ignored by Git. APME's addon-managed environment, dashboard npm
dependencies, and system prerequisites remain separate and unchanged. The
manifest declares compatibility ranges, not an exact dependency lock.
Validation exposed stable `ansible-core` 2.21.5 failing CLI startup under the
host's Python 3.15, so the setup explicitly uses the Python 3.11 CI baseline
rather than claiming pip resolution guarantees interpreter compatibility.

**Validation:** A disposable Python 3.11 environment resolved and installed the
manifest successfully (`ansible-core` 2.19.14). `pip check`, PyYAML/Kubernetes
imports, all three Ansible CLI startup checks, and the existing Vault migration
test passed. The temporary environments were removed; system packages and the
shared credential store were not changed.

### 37. Add explicit Red Hat connection for Fleet systems

**Type:** Feature / explicit opt-in system enrollment

`aap-demo fleet rhc-connect` enrolls running Fleet VMs with retained Vault CDN
credentials, using SSH stdin and interactive PTYs instead of password arguments.
It connects RHSM, Insights reporting, and Remote Host Configuration, reuses
complete enrollment, and explicitly verifies all three components. RHC's
zero-exit/partial-Insights case is handled with `insights-client --register`;
failures remain failures until final connection status verifies.

Enrollment is manual only, not triggered by normal lifecycle operations.
CRC is explicitly deferred because its OSTree appliance lacks RHC/Insights
packages; no host/cluster package layering is attempted. Documentation explains
reporting/remote-management consent and the distinction between account-linked
system inventory and individual demo-user tracking.

Credentials remain in the shared encrypted Vault. They are supplied to RHC's
interactive prompts over encrypted SSH stdin, not command-line arguments,
plaintext credential files, or printed authentication output. Enrollment has
bounded timeouts, reaps its PTY child process, skips stopped nodes, and returns
failure when any running node cannot be verified. If RHSM and remote management
are already connected, only incomplete Insights enrollment is retried.

**Validation:** All three existing Fleet VMs were enrolled and verified as
connected to RHSM, Insights, and Remote Host Configuration. Insights reports
were uploaded, and three distinct RHSM system identities were confirmed without
printing identifiers or credentials. A subsequent command run recognized all
three as already connected. Seven Python tests and a focused shell test cover
interactive credential delivery, secret non-disclosure, timeout cleanup,
partial registration, idempotency, stopped-node exclusion, and failure
propagation. CLI parsing, completion, secret-handling, syntax, and ShellCheck
checks passed. CRC remains unregistered and unchanged, as explicitly deferred.

**Files:** `scripts/fleet-rhc-connect.py`, `includes/fleet-rhc.sh`, `aap-demo.sh`,
`scripts/aap-demo-completion.bash`, `test/test-fleet-rhc.py`,
`test/test-fleet-rhc.sh`, `test/test-cli-parsing.sh`,
`test/test-bash-completion.sh`, `README.md`, `docs/FULL-README.md`.

### 36. Exchange Fleet public keys and reconcile full-stack hosts

Each Fleet admin now has a unique, retained Ed25519 key; only public keys are
exchanged. Managed SSH aliases select the correct gateway/forwarded port and pin
host keys collected over the bootstrap connection. Managed hosts blocks contain
IP, FQDN, and shortname entries for Fleet, development host, cluster machines,
and application routes. Localhost, IPv6, and unmanaged entries are preserved;
ambiguous names, malformed markers, and failed discovery fail explicitly.
Lifecycle and registration reconcile additions/removals without VM restarts.

Admin sudo now uses `admin     ALL=(ALL)       ALL`, validated by `visudo`, and
admin is removed from `wheel`. The shared AAP credential and inventory use the
existing `ansible` bootstrap account, preserving unattended automation without
copying per-node admin passwords into inventory variables. Only Fleet VMs are
configuration targets; cluster/host configuration is not changed.

Fleet FQDNs use `fleet.aap-demo.test` by default. Because the VMs retain isolated
QEMU networks, their hosts entries share the development host's gateway address;
SSH aliases select each forwarded port. This does not provide unique guest
addresses or direct connectivity for arbitrary protocols. Cluster machine
entries retain discovered internal addresses, and Kubernetes services/pods
continue using cluster DNS. Host-address or route changes require a subsequent
reconciliation; no background hosts watcher is installed.

Existing private keys are preserved, and missing public-key files are recovered
from their matching private keys. Managed hosts and authorized-key blocks
preserve unrelated entries while removing stale managed records. Fleet
add/start reconciles access for all running nodes before exchanging public keys.
Unchanged sshd configuration no longer triggers unnecessary daemon reloads.

**Validation:** All nine SSH paths across the three running nodes succeeded with
distinct admin key fingerprints and strict host verification. Passwordless admin
sudo was rejected, hosts names resolved, application ingress returned HTTP 200,
and AAP ping succeeded using the updated bootstrap credential. Focused tests
cover managed-block preservation, stale-node removal, discovery failure, and
SSH key collection without consuming inventory-loop input.
Both shortname and FQDN SSH paths passed, real admin passwords authorized sudo
on all three nodes, and repeated live reconciliation preserved hosts files,
public keys, and authorized-key contents. Mocked lifecycle tests cover add,
start, and removal without deleting or rebuilding live VMs.

### 35. Reconcile Fleet inventory and expose secure node access

Fleet now provisions and reconciles an `admin` account with a unique Vault-backed
password and the managed SSH key, including existing nodes without a rebuild.
Interactive `status --show-secrets` displays each node's host SSH endpoint,
guest IP, username, and password. Default JSON/dashboard inventory omits passwords.

AAP registration updates existing Fleet hosts and machine credentials instead
of skipping them, and fails when its verification ping fails. Product Demos
installation and addon wiring reconcile existing Fleet nodes into AAP.

The dashboard Routes panel includes per-node SSH links to a localhost browser
terminal using pinned local xterm assets and a server-side SSH PTY. Same-origin
and session checks protect terminal creation/input/output; private keys and login
passwords are not sent to the browser. Sessions are bounded and expired/closed
on disconnect, inactivity, or dashboard restart.

**Validation:** All three existing nodes accepted admin password SSH and AAP
ad-hoc ping succeeded. Interactive status was checked without printing passwords.
Browser SSH executed `whoami` and `hostname` as admin. Isolated Fleet, dashboard,
inventory, CLI, and shell lint checks cover reconciliation and redaction.

### 34. Add validated Automation Hub token setup and four-day cron

**Type:** Feature / reliability

The shared password defaults to `~/.ansible/conf/.vaultpass.txt`. Existing
password contents are preserved across setup, token updates, and uninstall;
an empty existing password file is rejected rather than overwritten. New
password files are created exclusively to avoid overwriting another product's
concurrent creation. Missing passwords for existing encrypted Vaults remain
an explicit recovery error.

`aap-demo credentials keepalive setup` now validates an existing Hub token before
prompting, stores replacements as `ah_offline_token` in the shared encrypted
Vault, and installs an idempotent `0 0 */4 * *` user cron job. Older
`aap_demo.galaxy.offline_token` credentials remain readable. Unrelated Vault
secrets and cron jobs are preserved.

SSO validation requires HTTP 200 and a nonempty JSON `access_token`. Rejected
tokens are securely re-prompted; network, server, malformed-response, and Vault
decryption failures stop without substituting credentials. Cron reads the token
dynamically and sends it over stdin, keeping it out of process arguments,
crontabs, and logs. The existing daily scheduler remains available.

**Validation:** Isolated token-authentication, keepalive/cron, Vault migration,
credential cleanup, secret-handling, and shell-completion tests cover the new
flow. Real user credentials and crontabs are not used by these tests.

### 33. Recover a missing OpenShift pull secret automatically

**Type:** Failure fix / feature

**Problem:** Complete uninstall correctly removed the managed pull secret, but a
later `aap-demo create` stopped before CRC startup even when the encrypted Vault
still contained a valid Red Hat Customer Portal offline token.

**Synopsis:** Added secure pull-secret recovery using Red Hat's official APIs.
The offline token is exchanged with the `rhsm-api` OAuth client, the resulting
short-lived bearer token is used to generate the OpenShift pull secret, and the
validated Docker authentication document is written directly to encrypted
Vault storage. The workflow corresponds to Red Hat Solution
[4844461](https://access.redhat.com/solutions/4844461).

**Implementation / patch steps:**

1. Add `aap_demo_pull_secret_fetch_redhat` to the credential Vault abstraction.
2. Keep the offline token, bearer token, and pull secret out of process
   arguments through stdin and the shared secure curl wrapper.
3. Require a non-empty JSON `auths` object before accepting the API response.
4. Save the result as `aap_demo.redhat.pull_secret` in the encrypted Vault.
5. Make CRC creation attempt recovery before reporting that the pull secret is
   unavailable.
6. Add `test/test-pull-secret-recovery.sh` for success and invalid-response
   behavior.

**Validation:** The live Red Hat API flow returned HTTP 200 with a Docker
authentication document; no secret value was printed. Mocked recovery tests,
credential tests, and CRC pull-secret tests passed.

### 32. Harden path portability and repeat-run convergence

**Type:** Bug fix / reliability

**Problem:** `AAP_DEMO_DIR` and `AAP_DEMO_CONFIG` were supported by some core
paths, but CRC settings, Fleet, AO, portal, cache, token, and generated-state
paths could still bypass them and write to `~/.aap-demo`. Namespace creation
also ignored every error, not only the harmless already-existing case, and the
operator pull secret was deleted before being recreated.

**Synopsis:** Standardized managed state and config overrides across Bash core
and addon processes. Converted namespace and operator pull-secret creation to
repeatable `kubectl create --dry-run=client -o yaml | kubectl apply -f -`
convergence so reruns do not create a secret gap and real API failures surface.

**Implementation / patch steps:**

1. Export `AAP_DEMO_DIR`, `AAP_DEMO_KUBECONFIG`, `AAP_DEMO_CONFIG`, and
   `AAP_DEMO_CONFIG_FILE` to child addon processes.
2. Route CRC preferences, Fleet disks/images, AO state, portal/cache state,
   Automation Hub files, CA material, and generated addon files through the
   configured state directory.
3. Route all persistent setting reads/writes through the configured config path.
4. Replace ignored namespace-create failures with dry-run/apply convergence.
5. Apply the operator pull secret atomically instead of delete-then-create.
6. Reject unknown portal host/cluster architectures instead of silently using
   the x86 image profile.
7. Route Fleet AAP Basic authentication through the shared secure curl wrapper
   and propagate HTTP failures.
8. Add `test/test-portability-contract.sh` and document the supported
   repeat-run, path, platform, architecture, namespace, and CI behavior.

**Validation:** Bash syntax and affected CRC, Fleet, portal, AO, authentication,
and reliability tests passed. The portability contract test verifies inherited
custom paths and rejects namespace creation that hides API failures.

### 1. Add safe runtime maintenance

**Type:** Feature

**Problem:** Long-running CRC environments accumulated exited CRI-O containers,
unused images, package metadata, and old journal data. Users had no supported way
to preview or reclaim that space.

**Synopsis:** Added read-only maintenance reporting and an explicit apply mode.
The operation avoids running containers, active images, namespaces, PVCs, AAP
resources, and the optional local image cache.

**Implementation / patch steps:**

1. Add `includes/maintenance.sh` with `cmd_maintenance`, `disk_snapshot`, and
   `print_report`.
2. Make `aap-demo maintenance` preview reclaimable data without mutation.
3. Make `aap-demo maintenance --apply` remove exited CRI-O containers, prune
   unused images, clear DNF metadata, vacuum journals older than seven days, and
   run filesystem trim.
4. Route maintenance through the shared mutation lock in
   `includes/operation-lock.sh`.
5. Add Bash, Zsh, and PowerShell command/help surfaces.
6. Add `test/test-maintenance.sh` for preview, apply, safety, and failure paths.

**Primary files:** `includes/maintenance.sh`, `aap-demo.sh`,
`powershell/native/Private/Commands.ps1`, `scripts/aap-demo-completion.bash`,
`scripts/aap-demo-completion.zsh`, `test/test-maintenance.sh`.

**Validation:** Mocked maintenance tests passed. A live cleanup completed without
removing running workloads and reported the actual reclaimed space.

### 2. Add complete environment uninstall

**Type:** Feature

**Problem:** Removing the launcher did not remove CRC, Fleet disks, caches,
generated state, shell integration, or host recovery services.

**Synopsis:** Added a complete, fail-closed uninstall under the maintenance
command while preserving the source checkout, shared tools, and unrelated data
in the encrypted credential Vault.

**Implementation / patch steps:**

1. Add `aap-demo maintenance uninstall` as a non-destructive preview.
2. Add `aap-demo maintenance uninstall --apply` for actual removal.
3. Require the literal confirmation `UNINSTALL` interactively, or
   `AAP_DEMO_UNINSTALL_CONFIRM=UNINSTALL` for unattended execution.
4. Stop the dashboard and remove CRC/MicroShift, Fleet VMs and images, CRC
   caches, generated state, persistent image storage, temporary swap, local CA
   trust, MCP registration, shell blocks, symlinks, completions, generated
   reports, and temporary logs.
5. Validate every resolved deletion path before removing it.
6. Stop if CRC deletion fails rather than deleting the remaining host state and
   creating a partially successful result.
7. Remove Linux/macOS recovery services, configuration, and retained backups.
8. Remove the `aap_demo` Vault namespace while preserving unrelated keys; remove
   the Vault and password file when no unrelated content remains.
9. Delete `~/.aap-demo` rather than recreating an empty state directory.
10. Preserve the repository, shared tools/packages, unrelated Vault data, and
    libvirt membership.
11. Remove only installer-owned shell blocks.

**Primary files:** `includes/maintenance.sh`, `install.sh`, `aap-demo.sh`,
`powershell/native/Private/Commands.ps1`, `test/test-maintenance.sh`.

**Validation:** Mocked end-to-end uninstall tests passed, including recovery
service/backups and Vault namespace removal. The workflow preserves the source
checkout and unrelated encrypted credentials.

### 3. Preserve 100 GiB for container images

**Type:** Failure fix

**Problem:** A 100 GiB CRC disk with 70 GiB assigned to persistent volumes left
only about 29 GiB for the root filesystem and container images, causing image
pull and pod-eviction failures.

**Synopsis:** Changed capacity planning so fresh environments preserve at least
100 GiB for root and container-image storage.

**Implementation / patch steps:**

1. Raise the fresh default CRC disk to 180 GiB while retaining the 70 GiB LVMS
   persistent-volume allocation.
2. Replace interactive disk choices with 180, 220, 270, and 320 GiB.
3. Clamp undersized saved values during fresh creation.
4. Add addon-aware recommendations so larger addon selections receive a larger
   planning warning.
5. Raise the optional persistent CRI-O image-store default and minimum to
   100 GiB.
6. Apply the same capacity rules to Bash and PowerShell.
7. Update the storage model, status text, dashboard guidance, ADRs, and tests.

**Primary files:** `config/storage-capacity.json`,
`includes/storage-capacity.sh`, `includes/crc-create.sh`,
`includes/persistent-crio-store.sh`,
`powershell/native/Private/Create.ps1`, `test/test-storage-capacity.sh`,
`test/test-persistent-crio-store.sh`.

**Validation:** Storage-capacity and persistent-store tests passed. A real fresh
creation used the new disk plan and completed MicroShift setup.

### 4. Grow an existing CRC disk at the 90 percent threshold

**Type:** Feature

**Problem:** Capacity recommendations protected new VMs but did not recover an
existing CRC filesystem that later became full.

**Synopsis:** Added supported, retryable disk growth during `aap-demo start`.
When `/var` reaches 90 percent utilization, the tool adds 20 percent capacity
after verifying host space and stopping CRC gracefully.

**Implementation / patch steps:**

1. Add `includes/crc-storage.sh`.
2. Read `/var` capacity from inside CRC and validate all numeric fields.
3. Trigger only at an exact usage threshold of at least 90 percent, unless a
   previous resize is pending.
4. Derive the current disk allocation from CRC machine metadata.
5. Round a 20 percent increase up to whole GiB and verify sufficient host space.
6. Persist both `CRC_DISK` and a private pending-resize marker before restart.
7. Stop CRC without force, update `crc config set disk-size`, restart, and verify
   both disk metadata and guest filesystem growth.
8. Keep the pending marker when interrupted or incomplete so the next start can
   retry safely.
9. Implement equivalent checks in PowerShell.

**Primary files:** `includes/crc-storage.sh`, `aap-demo.sh`,
`powershell/native/Private/Start.ps1`, `test/test-crc-storage.sh`.

**Validation:** Tests cover the exact 90 percent threshold, 20 percent rounded
growth, host-capacity rejection, saved settings, interruption, and retry.

### 5. Add one-command full-demo provisioning

**Type:** Feature

**Problem:** Building the complete demonstration required many manually ordered
commands and made interruption or rerun behavior difficult to reason about.

**Synopsis:** Added `aap-demo create --full-demo` as a fail-fast, idempotent
orchestrator.

**Implementation / patch steps:**

1. Add `cmd_full_demo` to `aap-demo.sh`.
2. Preflight Fleet/Customer Portal credentials before expensive mutations and
   launch the existing secure `fleet auth` configuration when they are missing
   or invalid in an interactive run.
3. Reuse a running cluster or create CRC/MicroShift with addon-aware sizing.
4. Deploy AAP without the old implicit AO shortcut.
5. Configure Private Automation Hub and enable offline-token keepalive.
6. Enable Ollama and Automation Orchestrator with Ollama as the provider.
7. Enable Fleet, create only the number of RHEL 9 nodes needed to reach three,
   start preserved nodes, and register them in AAP.
8. Enable Product Demos after licensing is available.
9. Run final strict addon wiring, regenerate system information, release the
   mutation lock, and then launch the dashboard.
10. Support `--no-open`.
11. Make PowerShell reject this Fleet-dependent mode with a clear platform
    message rather than partially executing it.
12. Keep `QUIET=true` runs noninteractive and fail with a setup command instead
    of attempting to read credentials.

**Primary files:** `aap-demo.sh`, `test/test-full-demo.sh`,
`scripts/aap-demo-completion.bash`, `scripts/aap-demo-completion.zsh`,
`powershell/aap-demo.ps1`.

**Validation:** Ordering and rerun tests passed. Live execution successfully
created AAP, three Fleet nodes, addon wiring, and the dashboard.

### 6. License AAP before Product Demos

**Type:** Failure fix

**Problem:** Product Demos attempted to launch jobs before AAP had an attached
subscription and failed with “AAP does not have a registered subscription.”

**Synopsis:** Reordered full-demo so Fleet registration performs automatic
subscription attachment before Product Demos are enabled.

**Implementation / patch steps:**

1. Keep setup-pah, token keepalive, Ollama, and AO before Fleet.
2. Run `fleet start` and `fleet register` before `enable product-demos`.
3. Treat Fleet registration and licensing failure as fatal.
4. Keep the final strict `wire` after Product Demos so all integrations converge.
5. Encode the exact order in `test/test-full-demo.sh`.

**Primary files:** `aap-demo.sh`, `test/test-full-demo.sh`,
`addons/product-demos-base/README.md`.

**Validation:** Full-demo ordering tests passed. Product Demos could proceed
after the live subscription was attached.

### 7. Automatically select and attach an entitled subscription

**Type:** Error-handling fix

**Problem:** Fleet registration stopped when the Red Hat account returned
multiple matching AAP subscriptions.

**Synopsis:** Made subscription selection deterministic and user-correctable:
reuse a saved valid ID, otherwise choose the first entitled subscription.

**Implementation / patch steps:**

1. Request subscriptions from AAP's credential-scoped
   `/config/subscriptions/` endpoint using the Customer Portal credentials.
2. Validate that the response is non-empty JSON and surface returned API errors.
3. Prefer `aap_demo.redhat.aap_subscription_id` when it still appears in the
   response.
4. Otherwise select the first entry containing a `subscription_id`.
5. Save the selected ID in the encrypted Vault.
6. POST only that ID to `/config/attach/`.
7. Verify attachment success and return a nonzero result on API failure.
8. Store the non-secret display name separately for status/dashboard use.

**Primary files:** `addons/fleet/fleet-aap.sh`,
`includes/credential-vault.sh`, `test/test-fleet-subscription.sh`,
`docs/adr/026-fleet-addon.md`.

**Validation:** Tests passed for first-entitlement selection, saved-ID reuse,
missing APIs, and persistence. Live AAP attached “Red Hat Developer Subscription
for Individuals.”

### 8. Display the attached AAP subscription

**Type:** Feature

**Problem:** Automatic licensing succeeded but users could not see which
subscription was selected.

**Synopsis:** Added the selected non-secret subscription name to shared system
inventory, generated system information, and the dashboard OS/platform line.

**Implementation / patch steps:**

1. Persist the display name to
   `~/.aap-demo/fleet/aap_subscription_name` using an atomic private temporary
   file.
2. Add `host.aap_subscription` to `includes/system-inventory.sh`.
3. Render it in `dashboard/static/app.js`.
4. Include it in generated system documentation.
5. Keep the subscription ID encrypted and never expose it as the display value.

**Primary files:** `addons/fleet/fleet-aap.sh`,
`includes/system-inventory.sh`, `includes/system-info-document.sh`,
`dashboard/static/app.js`, `test/test-dashboard.py`.

**Validation:** Fleet subscription and dashboard tests passed; live inventory
showed the attached subscription name.

### 9. Repair modern CRC daemon lifecycle handling

**Type:** Failure fix

**Problem:** CRC 2.64 failed with connection resets/refusals because the code
checked the obsolete `~/.crc/crc-http.sock`, while modern CRC uses
`~/.crc/sockets/crc-http.sock` and systemd user socket activation. An unmanaged
daemon could also hold the vsock.

**Synopsis:** Replaced unmanaged daemon startup with systemd-aware recovery and
API readiness checks.

**Implementation / patch steps:**

1. Add `_crc_daemon_api_ready`, `_crc_stop_unmanaged_daemons`, and
   `_crc_daemon_ensure` to `includes/crc-create.sh`.
2. Recognize the current CRC socket directory.
3. Detect systemd user units `crc-daemon.service`, `crc-http.socket`, and
   `crc-vsock.socket`.
4. Find stale unmanaged daemon PIDs precisely and terminate only those exact
   processes.
5. Reset failed units, restart socket activation, and wait for the daemon API.
6. Fail with concrete diagnostics if the API never becomes ready.
7. Do not launch a competing manual `crc daemon` when managed units exist.

**Primary files:** `includes/crc-create.sh`, `test/test-crc-daemon.sh`.

**Validation:** CRC daemon tests passed. The live orphan process was removed,
all user units became active, and real cluster creation proceeded.

### 10. Hand CRC a secure real pull-secret file

**Type:** Failure fix

**Problem:** CRC 2.64 does not interpret `--pull-secret-file -` as stdin and
failed noninteractively with “cannot ask for secret, crc not launched by a
terminal.”

**Synopsis:** Added a runtime-only, mode-0600 pull-secret file for CRC start.

**Implementation / patch steps:**

1. Read the pull secret from the encrypted credential Vault.
2. Create a uniquely named file under the user's runtime directory with
   restrictive permissions.
3. Pass the actual path to `crc start --pull-secret-file`.
4. Register cleanup for normal exit and HUP, INT, and TERM.
5. Never retain the temporary file under `~/.aap-demo`.
6. Preserve the existing retry and diagnostic behavior without printing the
   secret.

**Primary files:** `includes/crc-create.sh`,
`includes/credential-vault.sh`, `test/test-crc-pull-secret.sh`.

**Validation:** Pull-secret security tests passed. A real noninteractive create
completed and no temporary pull-secret file remained.

### 11. Consolidate retained credentials in one encrypted Vault

**Type:** Security fix

**Problem:** Credential state was split across legacy Vault names and plaintext
files, making backup, lookup, and secret hygiene inconsistent.

**Synopsis:** Standardized retained credentials under `aap_demo` in encrypted
`~/.ansible/conf/env.yml`, protected by
`~/.ansible/conf/.vaultpass.txt`.

**Implementation / patch steps:**

1. Update `includes/credential-vault.sh` to use the standard paths.
2. Create the directory as mode 0700 and both files as mode 0600.
3. Generate a strong Vault password when no password file exists.
4. Preserve unrelated YAML already stored in `env.yml`.
5. Migrate legacy `env-aap-demo.yml`, MicroShift-named Vaults, and supported
   plaintext credential files atomically.
6. Store values under namespaced keys including:
   - `aap_demo.redhat.offline_token`
   - `aap_demo.redhat.cdn_username`
   - `aap_demo.redhat.cdn_password`
   - `aap_demo.redhat.account_number`
   - `aap_demo.redhat.aap_subscription_id`
   - `aap_demo.galaxy.offline_token`
   - `aap_demo.redhat.pull_secret`
   - `aap_demo.ao.initial_admin_password`
7. Remove managed plaintext pull-secret and AO password files after successful
   import.
8. Extend `.gitignore` for local Vault/password/export paths.

**Primary files:** `includes/credential-vault.sh`,
`addons/ao/lib/admin-password.sh`, `.gitignore`,
`test/test-credential-vault-migration.sh`.

**Validation:** Migration tests passed. Live Vault entries decrypted correctly,
permissions were verified, and no managed plaintext credential remnants remained
under `~/.aap-demo`.

### 12. Hide credentials from normal status and generated output

**Type:** Security fix

**Problem:** Bash and PowerShell status/watch/deploy paths printed AAP and addon
passwords to ordinary terminal output, logs, and redirected output.

**Synopsis:** Made normal status secret-free and added an explicit,
interactive-only credential display.

**Implementation / patch steps:**

1. Remove password values from normal `status`, watch, deploy completion, AO,
   Portal, and PowerShell output.
2. Display a consistent “Credentials: hidden” message with the reveal command.
3. Add `aap-demo status --show-secrets`.
4. Require both stdin and stdout to be terminals for secret display.
5. Reject redirected or piped secret output.
6. Keep generated system information redacted by default.
7. Direct automation to Kubernetes Secrets rather than parsing human status
   output.
8. Update help, completion, skills, quickstarts, addon docs, and ADR language.

**Primary files:** `aap-demo.sh`, `scripts/watch-aap.sh`,
`powershell/native/Private/Status.ps1`,
`powershell/native/Private/Watch.ps1`, documentation and skill files,
`test/test-secret-handling.sh`.

**Validation:** Secret-handling tests passed. Normal status no longer displays
passwords, while interactive `--show-secrets` retrieves the expected credentials.

### 13. Keep secrets and payloads out of child-process arguments

**Type:** Security fix

**Problem:** AO, OPA, Portal, Product Demos, and Fleet paths passed Basic auth,
authorization headers, passwords, tokens, or JSON bodies in process arguments
visible through process inspection.

**Synopsis:** Added a secure curl wrapper and inherited-file-descriptor patterns.

**Implementation / patch steps:**

1. Add `includes/secure-curl.sh`.
2. Intercept sensitive curl options and move their values into protected
   configuration or file-descriptor input.
3. Pass AO tokens/passwords to Python through inherited descriptors rather than
   command arguments.
4. Pipe JSON request bodies through stdin or descriptors.
5. Update AO, OPA, Portal, Product Demos, Fleet, and MCP/setup paths to use the
   shared secure behavior.
6. Preserve response and exit-code semantics so errors remain visible.
7. Add process-argument inspection tests for auth values and payloads.

**Primary files:** `includes/secure-curl.sh`, `addons/ao/deploy.sh`,
`addons/ao/scripts/import-demos.py`,
`addons/ao/scripts/provision-aap-demos.py`, `addons/fleet/fleet-aap.sh`,
`addons/portal/deploy.sh`, `addons/product-demos-base/lib.sh`,
`test/test-secret-handling.sh`.

**Validation:** Security tests confirmed credentials and request bodies were
absent from child argv.

### 14. Correct secure curl stdin body forwarding

**Type:** Bug fix

**Problem:** The first secure wrapper treated `--data-binary @-` as the literal
body `@-`, so AAP received an invalid subscription request.

**Synopsis:** Made the wrapper consume stdin and forward the actual body securely.

**Implementation / patch steps:**

1. Detect `--data`, `--data-raw`, or `--data-binary` values that equal `@-`.
2. Read the original caller's stdin before launching the child curl.
3. Place the captured body in protected descriptor/config input.
4. Preserve binary/body bytes and curl's original response code.
5. Extend tests to inspect both argv secrecy and the body received by a mock
   endpoint.

**Primary files:** `includes/secure-curl.sh`,
`test/test-secret-handling.sh`, `addons/fleet/fleet-aap.sh`.

**Validation:** The focused stdin-body test passed. Live subscription attachment
then succeeded.

### 15. Keep Customer Portal and Automation Hub tokens separate

**Type:** Bug fix

**Problem:** Two different Red Hat offline tokens were treated as potentially
interchangeable. A Customer Portal token could be accepted for a Private
Automation Hub flow and fail later with HTTP 400.

**Synopsis:** Enforced separate sources, OAuth validation, storage keys, and
purposes for the two token types.

**Implementation / patch steps:**

1. Use the Customer Portal token from
   `https://access.redhat.com/management/api` with OAuth client `rhsm-api`.
2. Use the Automation Hub token from
   `https://console.redhat.com/ansible/automation-hub/token` with OAuth client
   `cloud-services`.
3. Store them as `aap_demo.redhat.offline_token` and
   `aap_demo.galaxy.offline_token`, respectively.
4. Validate an Automation Hub token before configuring PAH remotes.
5. Delete a rejected Hub token from the Vault so the next run prompts for the
   correct value.
6. Never copy or reuse one token as the other.
7. Update help and authentication documentation with both URLs and purposes.

**Primary files:** `includes/galaxy-auth.sh`,
`addons/setup-pah/deploy.sh`, `includes/credential-vault.sh`,
`docs/collection-authentication.md`, `test/test-galaxy-auth.sh`.

**Validation:** Token-separation and rejection tests passed. The rejected live
Hub token was removed while the valid Customer Portal token remained usable.

### 16. Make Vault deletion fail safely

**Type:** Error-handling fix

**Problem:** Deleting an invalid stored token could silently fail because
`aap_demo_vault_delete` did not initialize validated Vault/Python tools and did
not check the YAML update result.

**Synopsis:** Made Vault deletion use the same validated toolchain and atomic
error handling as Vault reads and writes.

**Implementation / patch steps:**

1. Call `_aap_demo_vault_require_tools` before decrypt/update operations.
2. Check the Python/YAML transformation exit status.
3. Write through a protected temporary file.
4. Replace the encrypted Vault only after transformation and re-encryption both
   succeed.
5. Return nonzero and preserve the original Vault on any failure.

**Primary files:** `includes/credential-vault.sh`,
`test/test-credential-vault-migration.sh`, `test/test-galaxy-auth.sh`.

**Validation:** Vault deletion and invalid-Hub-token cleanup tests passed.

### 17. Preserve Vault ownership during root state restore

**Type:** Failure fix

**Problem:** The root-owned backup service restored
`~/.ansible/conf` as `root:root` mode 0700. The user could no longer read the
Vault and full-demo reported credentials as unconfigured.

**Synopsis:** Preserved the installing user's ownership and required private modes
during backup and restore.

**Implementation / patch steps:**

1. Record the managed user and home ownership in the state-service configuration.
2. Avoid applying root staging-directory ownership to the restored user
   directory.
3. Restore the Vault directory and files with the intended user's UID/GID.
4. Reassert directory mode 0700 and file mode 0600.
5. Update the installed root helper as part of service installation.
6. Add regression assertions for ownership and permissions.

**Primary files:** `scripts/aap-demo-state.sh`,
`powershell/native/Private/StateService.ps1`,
`test/test-state-service.sh`.

**Validation:** Ownership regression tests passed. The live directory was
repaired and Vault/Fleet authentication worked again.

### 18. Survive broken executables in an active virtual environment

**Type:** Failure fix

**Problem:** An activated project `.venv` shadowed working host tools with a
Python interpreter lacking PyYAML and a broken `ansible-vault` executable.

**Synopsis:** Credential handling now validates tool candidates instead of
blindly trusting the first PATH match.

**Implementation / patch steps:**

1. Enumerate candidate Python interpreters.
2. Select the first interpreter that can import the required YAML module.
3. Enumerate candidate `ansible-vault` executables.
4. Probe each candidate before use and skip broken shadow executables.
5. Cache only a verified pair for the current process.
6. Return an explicit dependency error if no working tools exist.
7. Add test fixtures that prepend intentionally broken executables to PATH.

**Primary files:** `includes/credential-vault.sh`,
`test/test-credential-vault-migration.sh`.

**Validation:** Broken-shadow tests passed. `aap-demo fleet auth status` worked
inside the active `.venv`.

### 19. Add offline-token keepalive

**Type:** Feature

**Problem:** Red Hat offline tokens can expire after extended non-use, causing
future demo setup to fail unexpectedly.

**Synopsis:** Added an opt-in daily validation scheduler for Linux and macOS.

**Implementation / patch steps:**

1. Add `scripts/aap-demo-token-keepalive.sh`.
2. Add CLI actions:
   - `aap-demo credentials keepalive enable`
   - `aap-demo credentials keepalive status`
   - `aap-demo credentials keepalive run`
   - `aap-demo credentials keepalive disable`
3. Install a persistent systemd user timer on Linux.
4. Install a LaunchAgent on macOS.
5. Read tokens from the encrypted Vault on every run.
6. Exchange and immediately discard short-lived access tokens.
7. Log only provider, timestamp, return code, and safe status.
8. Notify for rejected credentials while treating transient network failures as
   retryable.
9. Remove scheduler artifacts during complete uninstall while preserving the
   Vault.

**Primary files:** `scripts/aap-demo-token-keepalive.sh`, `aap-demo.sh`,
`includes/maintenance.sh`, `test/test-token-keepalive.sh`.

**Validation:** Keepalive tests passed. Live execution reported the Customer
Portal token as valid and safely skipped an unconfigured Hub token.

### 20. Fix nested command parsing

**Type:** Bug fix

**Problem:** Nested words such as `credentials keepalive status`, `enable`, and
`disable` could be interpreted as top-level commands during global argument
parsing.

**Synopsis:** Scoped parsing so nested command arguments remain attached to their
parent command.

**Implementation / patch steps:**

1. Determine the top-level command before interpreting nested action words.
2. Preserve `status`, `enable`, `disable`, and Fleet/auth actions in
   `EXTRA_ARGS`.
3. Validate flags only for the command that owns them.
4. Add parser regression cases for keepalive and Fleet nested commands.

**Primary files:** `aap-demo.sh`, `test/test-cli-parsing.sh`,
`test/test-core-commands.sh`.

**Validation:** CLI parser tests passed for top-level and nested command forms.

### 21. Add contextual shell completion

**Type:** Feature

**Problem:** The existing Bash completion did not understand most commands,
addons, nested actions, or option values.

**Synopsis:** Replaced static completion with context-aware Bash completion and
updated Zsh coverage.

**Implementation / patch steps:**

1. Complete top-level commands and aliases.
2. Complete addon names for enable/disable.
3. Complete Fleet, credential keepalive, maintenance, and service subcommands.
4. Complete command-specific options including contexts, branches, paths, and
   images.
5. Keep completion side-effect free and tolerant of partially typed input.
6. Install it under
   `~/.local/share/bash-completion/completions/aap-demo`.
7. Add focused completion assertions.

**Primary files:** `scripts/aap-demo-completion.bash`,
`scripts/aap-demo-completion.zsh`, `test/test-bash-completion.sh`.

**Validation:** Bash completion tests passed for commands, addons, nested
actions, and option values.

### 22. Make installation configure PATH and completion idempotently

**Type:** Bug fix

**Problem:** Installation created `~/.local/bin/aap-demo`, but the current or
future shell might not have `~/.local/bin` on PATH. Completion also did not load
reliably after reinstall.

**Synopsis:** Added installer-owned Bash configuration blocks and matching
uninstall cleanup. No virtual-environment changes are needed.

**Implementation / patch steps:**

1. Export `~/.local/bin` for the installer process.
2. Add a guarded, marked PATH block to `~/.bashrc`.
3. Add a guarded, marked Bash-completion loader.
4. Avoid duplicate blocks on repeated installation.
5. Explain that the already-running parent shell must run `source ~/.bashrc` or
   start a new shell.
6. Remove only the marked blocks during installer or full uninstall.
7. Verify downloaded `oc`/`kubectl` archives with published checksums.
8. Add install/reinstall/uninstall tests.

**Primary files:** `install.sh`, `includes/maintenance.sh`,
`test/test-install.sh`.

**Validation:** Installer tests and an uninstall-to-reinstall workflow passed.
`aap-demo` became available after sourcing `.bashrc`.

### 23. Add cold backup and boot recovery on Linux

**Type:** Feature

**Problem:** A complete local demo could be lost or become difficult to recover
across shutdown, disk corruption, or CRC state drift.

**Synopsis:** Added an optional systemd-backed cold state service with verified,
transactional backups and restore-before-start behavior.

**Implementation / patch steps:**

1. Add `aap-demo service install|uninstall|status|backup|backups|retention`.
2. Add `includes/state-service.sh` for CLI dispatch.
3. Add root runner `scripts/aap-demo-state.sh`.
4. Stop Fleet and CRC cleanly before disk capture.
5. Copy CRC metadata/disks, Fleet overlays, `~/.aap-demo`, libvirt XML/UEFI
   state, and the encrypted credential Vault.
6. Flatten QCOW2 backing chains so a backup does not depend on mutable base
   images.
7. Stage, checksum, verify, and publish a backup atomically as `latest`.
8. Keep the previous completed backup when a new backup fails.
9. Restore and verify before starting CRC, AAP, addons, Fleet, and wiring.
10. Use the shared operation lock to prevent lifecycle races.
11. Support configurable retention.
12. Provide an explicit Linux-only forced CRC power-off fallback that is
    disabled by default and recorded as crash-consistent.

**Primary files:** `includes/state-service.sh`,
`scripts/aap-demo-state.sh`, `docs/state-service.md`,
`test/test-state-service.sh`.

**Validation:** Tests cover cold backup, checksums, flattened disks, retention,
failed-backup preservation, restore, locks, unit ordering, and force-stop policy.

### 24. Add explicit macOS checkpoint and login recovery

**Type:** Feature

**Problem:** Linux systemd shutdown semantics do not exist on macOS, and abrupt
host shutdown cannot guarantee a final cold backup.

**Synopsis:** Added an explicit checkpoint-before-reboot model and LaunchAgent
login recovery for macOS.

**Implementation / patch steps:**

1. Add `scripts/aap-demo-macos-state.sh`.
2. Reuse the state-service CLI contract where platform semantics permit.
3. Require an explicit checkpoint rather than claiming guaranteed shutdown
   backup.
4. Handle CRC/vfkit/raw disk state and restore at login.
5. Validate host architecture and supported file layouts.
6. Add macOS installation, state, start, and storage tests to CI.
7. Document limitations clearly in `MAC_Quickstart.md` and
   `docs/state-service.md`.

**Primary files:** `scripts/aap-demo-macos-state.sh`, `install.sh`,
`MAC_Quickstart.md`, `.github/workflows/test.yaml`,
`test/test-macos-state.sh`.

**Validation:** Hermetic macOS tests run on `macos-latest`. Live CRC recovery on
macOS remains explicitly documented as requiring real-host qualification.

### 25. Add native Windows lifecycle and recovery

**Type:** Feature

**Problem:** The PowerShell CLI lacked equivalent operation locking, start
readiness, checkpoint/restore, and scheduled recovery behavior.

**Synopsis:** Added native PowerShell lifecycle support with Hyper-V-aware state
management and both Windows PowerShell 5.1 and PowerShell 7 validation.

**Implementation / patch steps:**

1. Add `powershell/native/Private/OperationLock.ps1`.
2. Add `powershell/native/Private/Start.ps1` for cluster, storage, AAP, addon,
   and route readiness.
3. Add `powershell/native/Private/StateService.ps1` for backup, restore,
   retention, journal, and scheduled-task management.
4. Wire the modules through `AapDemo.psm1` and `powershell/aap-demo.ps1`.
5. Use explicit checkpoint/login recovery rather than claiming guaranteed
   shutdown capture.
6. Add WSL routing guidance so WSL uses the Windows-hosted CRC instead of
   creating a conflicting second installation.
7. Add parser and isolated behavior tests for Windows PowerShell and PowerShell
   7.

**Primary files:** `powershell/native/Private/OperationLock.ps1`,
`powershell/native/Private/Start.ps1`,
`powershell/native/Private/StateService.ps1`,
`test/test-windows-platform.ps1`, `Windows_Quickstart.md`,
`WSL_Quickstart.md`.

**Validation:** Windows syntax parsing and isolated tests run on
`windows-latest` under both PowerShell implementations.

### 26. Make start and restart restore the complete demo

**Type:** Feature

**Problem:** Starting CRC alone did not prove that Kubernetes, AAP, routes,
addons, Fleet nodes, and integrations were usable after sleep, reboot, or
restore.

**Synopsis:** Added bounded, fail-fast resume logic for the entire configured
environment.

**Implementation / patch steps:**

1. Add `includes/demo-start.sh`.
2. Wait for Kubernetes `/readyz`.
3. Verify installed infrastructure namespaces and workload generations.
4. Resume AAP instances with `spec.idle_aap=true`.
5. Require AAP terminal conditions and gateway API readiness.
6. Wait for enabled addon namespaces, including AO/CNPG, Portal, APME, and
   Ollama.
7. Start preserved Fleet VMs.
8. Re-run strict addon wiring.
9. Recheck workloads after wiring-triggered rollouts.
10. On timeout, print relevant resources, scheduling messages, recent events,
    and a concrete diagnose/retry action.

**Primary files:** `includes/demo-start.sh`, `aap-demo.sh`,
`includes/kubernetes-readiness.sh`, `test/test-start.sh`.

**Validation:** Start tests cover idle AAP, missing enabled addons, readiness
timeouts, wiring failures, Fleet startup, and successful convergence.

### 27. Improve dashboard lifecycle and environment visibility

**Type:** Feature

**Problem:** The dashboard did not expose enough capacity/recovery context and
could not restart itself safely after repository updates.

**Synopsis:** Added storage planning, subscription context, safer operation
coordination, and dashboard restart support.

**Implementation / patch steps:**

1. Add actual and recommended VM disk values to shared inventory.
2. Render disk utilization with warning and critical states.
3. Explain the 90-percent automatic growth policy without presenting planning
   recommendations as resize triggers.
4. Render the attached AAP subscription display name.
5. Add `/api/restart` guarded by the active-operation lock/state.
6. Reject restart while an addon operation is running.
7. Restart the dashboard process and have the UI wait for a new health
   generation.
8. Keep API errors explicit and redact command output before returning it.

**Primary files:** `dashboard/server.py`, `dashboard/static/app.js`,
`dashboard/static/app.css`, `dashboard/static/index.html`,
`includes/system-inventory.sh`, `test/test-dashboard.py`.

**Validation:** Dashboard unit tests passed, including health, authorization,
operation conflict, addon action, restart, static content, and subscription
rendering. The live dashboard returned HTTP 200.

### 28. Add cross-platform quickstarts and portability CI

**Type:** Feature

**Problem:** Installation guidance mixed Linux, macOS, Windows, and WSL
assumptions, while CI primarily exercised Linux.

**Synopsis:** Split platform setup into dedicated guides and added macOS/Windows
portability jobs.

**Implementation / patch steps:**

1. Add `Linux_Quickstart.md`, `MAC_Quickstart.md`,
   `Windows_Quickstart.md`, and `WSL_Quickstart.md`.
2. Add a platform capability table to the main README.
3. Make `scripts/local-prereq.sh` reject macOS and WSL for the native-Linux
   bootstrap path.
4. Add `.gitattributes` rules enforcing LF for shell and PowerShell sources.
5. Add macOS CI for installer, storage, start, checkpoint, and ShellCheck.
6. Add Windows CI for syntax plus isolated tests under PowerShell 5.1 and 7.
7. Install cold-state test dependencies in Ubuntu CI.

**Primary files:** platform quickstarts, `.gitattributes`,
`.github/workflows/test.yaml`, `scripts/local-prereq.sh`.

**Validation:** The cross-platform jobs and isolated test suites passed in their
respective CI environments.

### 29. Remove obsolete local SELinux build artifacts

**Type:** Cleanup

**Problem:** Generated `my-snapupdatens.pp` and source
`my-snapupdatens.te` artifacts were tracked even though they were not part of
the supported installation or current recovery design.

**Synopsis:** Removed the obsolete generated policy artifacts from the project.

**Implementation / patch steps:**

1. Delete `my-snapupdatens.pp`.
2. Delete `my-snapupdatens.te`.
3. Keep supported host configuration in explicit installer/state-service paths.

**Primary files:** removed `my-snapupdatens.pp` and `my-snapupdatens.te`.

**Validation:** Shell, lifecycle, and state-service test suites continued to pass
without the files.

### 30. Align help, skills, and documentation with secure behavior

**Type:** Documentation fix

**Problem:** Documentation still said ordinary status showed passwords, pull
secrets lived permanently in plaintext, tokens could be reused, and users had
to select AAP subscriptions manually.

**Synopsis:** Updated CLI help and applicable Markdown to match the implemented
security and automation behavior.

**Implementation / patch steps:**

1. Document `status --show-secrets` and its interactive-only restriction.
2. Document the encrypted Vault and separate token sources/purposes.
3. Document installer-managed PATH and Bash completion.
4. Document full-demo ordering and automatic subscription selection.
5. Document encrypted pull-secret and AO-password retention.
6. Replace examples that scraped passwords from normal status with Kubernetes
   Secret access for automation.
7. Update Fleet, AO, Product Demos, authentication, PowerShell, assistant skill,
   ADR, and quickstart documentation.
8. Preserve historical repository references where they still match the actual
   code default.

**Primary files:** `aap-demo.sh`, `README.md`, `docs/FULL-README.md`,
`Linux_Quickstart.md`, `docs/collection-authentication.md`,
`addons/product-demos-base/README.md`, `addons/ao/README.md`,
`powershell/README.md`, `SKILL.md`, `.claude/CLAUDE.md`,
`.claude/skills/aap-demo/SKILL.md`, related ADRs.

**Validation:** CLI parsing/help tests, Bash completion tests, Markdown lint, and
`git diff --check` passed.

### 31. Add an evidence-based project roadmap

**Type:** Documentation feature

**Problem:** The project had many advanced capabilities but no ordered evolution
plan or measurable criteria for deciding what to improve next.

**Synopsis:** Added a roadmap that prioritizes modularization, addon/state
contracts, resumable orchestration, live release qualification, user experience,
platform parity, and release hardening.

**Implementation / patch steps:**

1. Add `ROADMAP.md` with current strengths and scaling risks.
2. Define Now, Next, and Later milestones.
3. Give every milestone measurable exit criteria.
4. Add an architecture decision gate that recommends modularization before any
   language rewrite.
5. Add release metrics, contribution guidance, and explicit non-goals.
6. Link the roadmap from `README.md`.

**Primary files:** `ROADMAP.md`, `README.md`.

**Validation:** Markdown lint and `git diff --check` passed.

## Consolidated validation evidence

The changes above were validated through a combination of focused automated
tests and live local-environment checks.

### Automated validation

- Core CLI commands: 24 passing checks during the implementation cycle.
- CLI parsing and rendered help.
- Bash contextual completion.
- Maintenance preview/apply and full-uninstall mocks.
- Full-demo ordering, fail-fast behavior, and rerun behavior.
- CRC daemon lifecycle and socket recovery.
- CRC temporary pull-secret security.
- CRC storage planning and automatic-growth policy.
- Persistent CRI-O image storage.
- Credential Vault migration, update, deletion, permissions, and broken-tool
  fallback.
- Secure curl argv and stdin-body handling.
- Customer Portal/Automation Hub token separation.
- Offline-token keepalive scheduling and logs.
- Fleet authentication, image handling, subscription selection, and AAP
  registration.
- Product Demos API handling.
- AO password, provider, SCC, catalog, import, and wiring behavior.
- Start/resume convergence and failure diagnostics.
- Linux state backup/restore, checksums, retention, locks, and failures.
- macOS checkpoint behavior.
- Windows PowerShell 5.1 and PowerShell 7 isolated lifecycle/state tests.
- Dashboard suite: 20 passing tests in the final documentation cycle.
- Bash syntax, targeted ShellCheck, Python tests, Node syntax, Markdown lint, and
  `git diff --check`.

### Live validation

- Repaired stale CRC/libvirt state and recreated MicroShift.
- Repaired an orphan CRC daemon and verified systemd user socket units.
- Completed real noninteractive CRC creation using the encrypted pull secret.
- Verified Kubernetes node readiness, storage classes, DNS, and NFS.
- Observed AAP progressing through image pulls and database migrations to
  successful readiness.
- Attached the live AAP subscription
  “Red Hat Developer Subscription for Individuals.”
- Created and started three RHEL 9 Fleet VMs.
- Registered Fleet inventory, credential, and hosts in AAP.
- Ran a successful Fleet ad-hoc ping.
- Verified the dashboard was reachable and displayed the subscription.
- Verified the Customer Portal token keepalive exchange without logging secrets.
- Verified normal status hides passwords and interactive secret display works.

## Reimplementation order for a future patch

If these changes must be replayed onto another baseline, apply them in this
dependency order:

1. Credential Vault and secure HTTP primitives.
2. Secret-safe status/output changes.
3. CRC daemon and pull-secret startup fixes.
4. Storage capacity model and existing-VM growth.
5. Maintenance and complete uninstall.
6. Start/resume readiness helpers.
7. State-service backup/restore and operation locks.
8. Fleet subscription attachment and display-name inventory.
9. Token validation and keepalive.
10. Full-demo orchestration and Product Demos ordering.
11. Installer PATH/completion and contextual completion.
12. Dashboard enhancements.
13. PowerShell/macOS parity.
14. CI, tests, quickstarts, ADRs, help, roadmap, and this changelog.

After each stage, run the smallest related tests before continuing. Run the full
non-live suite, linting, and a disposable live qualification flow before treating
the replayed patch as complete.
