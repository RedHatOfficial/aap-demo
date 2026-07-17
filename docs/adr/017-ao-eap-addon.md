# ADR-017: Automation Orchestrator Early Access Addon (ao-eap)

**Status**: Accepted

**Date**: 2026-07-15 (updated 2026-07-16)

**Authors**: Chad Ferman

## Context

Automation Orchestrator (AO) is a new Red Hat workflow orchestration platform in Early Access.
It runs as an operator-managed application on OpenShift and integrates with an existing AAP
installation to launch job templates and use AAP as an OIDC identity provider.

The install process requires:

- A private Quay.io registry (access granted by Red Hat point of contact)
- The `aapctl` CLI binary (distributed via GitHub releases)
- A multi-step install: CatalogSource setup, two-pass `aapctl install`, CSV image patching,
  and secret linking

aap-demo needs a repeatable, scriptable way to deploy AO EAP on MicroShift for development
and demo purposes.

## Decision

Add `ao-eap` to the aap-demo addon system as `addons/ao-eap/deploy.sh`. The addon automates
all 10 installation steps from the AO EAP deployment guide into a single idempotent script
invoked via `aap-demo enable ao-eap`.

### Credential storage

- `~/.aap-demo/quay-username` — Quay.io username
- `~/.aap-demo/quay-token` — Quay.io encrypted password/token (chmod 600)

On first run, the script prompts interactively for credentials and saves them to the above
files. On subsequent runs, credentials are read from disk.

### aapctl binary

Checked via `which aapctl`. If missing, the script detects the platform (`uname -s` /
`uname -m`), downloads the matching binary from the latest GitHub release at
`https://github.com/automation-nexus/aapctl/releases`, and installs it to
`/usr/local/bin/aapctl` via `sudo install`. On macOS, the Gatekeeper quarantine attribute
is stripped automatically with `xattr -d com.apple.quarantine`.

Platform matrix: `aapctl-darwin-arm64`, `aapctl-darwin-amd64`, `aapctl-linux-amd64`,
`aapctl-linux-arm64`.

### Install flow

Namespace: `automation-orchestrator`
Storage class: `topolvm-provisioner` (RWO)
Kubeconfig: `~/.crc/machines/crc/kubeconfig`

1. Check credentials — prompt interactively if not saved
2. Install `aapctl` — skip if already in PATH
3. Create `automation-orchestrator` and `openshift-marketplace` namespaces; grant
   `anyuid` + `privileged` SCCs to both (marketplace namespace needs them for OLM
   bundle unpack jobs that run as non-root UIDs outside the namespace range)
4. Patch OLM catalog-operator — `operator-sdk olm install` sets `--namespace=olm`,
   limiting CatalogSource discovery to the `olm` namespace. The script patches the
   catalog-operator deployment to watch `openshift-marketplace` instead (idempotent —
   skipped if already patched)
5. Apply `quay-aap-viewer` Secret and `cs-automation-orchestrator` CatalogSource to
   `openshift-marketplace`; wait for catalog pod Running
6. Install CloudNativePG operator directly from the upstream release manifest
   (`cnpg-1.25.1.yaml`); grant SCCs to `cnpg-system`; wait for controller-manager
   Running. Skipped if CNPG CRDs already exist
7. Create PostgreSQL cluster — apply secrets (`orchestrator-postgres-secret`,
   `temporal-postgres-secret`, `temporal-visibility-postgres-secret`), CNPG `Cluster`
   CR, wait for ready, then apply `Database` CRs. Reuses existing password on re-runs
   to avoid bootstrap/secret mismatch
8. Create AO operator OLM resources — pre-create `OperatorGroup` and `Subscription`
   pointing to `cs-automation-orchestrator` catalog with `installPlanApproval: Automatic`.
   Clears stale OLM state (subscription, installplans, CSVs) first
9. Wait for CSV; patch `registry.redhat.io/ansible-automation-platform` →
   `quay.io/aap/ansible-automation-platform`
10. Copy pull secret to namespace, link to operator service account, `rollout restart`;
    wait for Running pod
11. `aapctl install` with `--set cloudnative-pg-operator.enabled=false` — skips
    existing OperatorGroup/Subscription, creates the `AutomationOrchestrator` CR
12. Patch `AutomationOrchestrator` CR with `imagePullSecrets`; `rollout restart`
13. Wait for all pods Running; retrieve admin password; print route URL

### MicroShift compatibility workarounds

`aapctl` assumes a full OpenShift environment. The following workarounds are needed on
MicroShift:

| Problem | Cause | Workaround |
|---------|-------|------------|
| CNPG subscription fails | `aapctl` hardcodes `source: certified-operators` which doesn't exist on MicroShift; the AO operator index doesn't bundle CNPG | Install CNPG directly from upstream release manifest; disable in `aapctl` |
| AO subscription fails | `aapctl` hardcodes `source: redhat-operators`; `--set catalogSource` is silently ignored | Pre-create Subscription pointing to `cs-automation-orchestrator` |
| OLM can't find CatalogSource | `operator-sdk olm install` sets catalog-operator `--namespace=olm`; CatalogSource is in `openshift-marketplace` | Patch catalog-operator deployment args |
| Bundle unpack jobs fail | Unpack pods specify UID 1001 (from image), blocked by `restricted-v2` SCC | Grant `anyuid`/`privileged` SCCs to `openshift-marketplace` |
| Migration auth failures on re-run | Password regenerated on each run; CNPG cluster retains bootstrap password | Preserve existing password from secret if it already exists |

### Delete flow

`deploy.sh --delete`:

1. `aapctl uninstall automation-orchestrator --force`
2. Delete `cs-automation-orchestrator` CatalogSource and `quay-aap-viewer` Secret from
   `openshift-marketplace`
3. Delete `automation-orchestrator` and `cloudnative-pg` namespaces
4. Delete CloudNativePG operator (`kubectl delete -f` the upstream manifest)

### aap-demo.sh changes

- Add `ao-eap` to `AVAILABLE_ADDONS`
- Help text: `enable ao-eap    Install Automation Orchestrator Early Access`
- `show_status`: display AO route URL when `ao-eap` is enabled

## Consequences

### Positive

- Full AO EAP deployment is a single command: `aap-demo enable ao-eap`
- Consistent with existing addon conventions (deploy.sh, --delete, credential files)
- `aapctl` auto-installed; users need only provide Quay credentials
- Idempotent — safe to re-run

### Negative

- Requires Quay access granted externally (Red Hat point of contact) — not self-service
- Multiple MicroShift workarounds make the script complex; may break if `aapctl` changes
  its hardcoded catalog names or install flow
- EA limitations: no air-gap support, no HA, in-place upgrades not guaranteed
- Patches the OLM catalog-operator deployment, which could interfere with other OLM
  consumers if any expect the `olm` namespace for CatalogSources

### Neutral

- AO runs in its own `automation-orchestrator` namespace, isolated from `aap-operator`
- CloudNativePG installed directly (not via OLM), isolated in `cnpg-system` namespace
- OLM is a prerequisite already satisfied by `aap-demo deploy`

## Alternatives Considered

**Separate setup + deploy scripts**: Cleaner credential onboarding UX, but breaks the
single-script addon convention and `aap-demo enable` only calls `deploy.sh`. Rejected.

**Thin wrapper / manual aapctl**: Addon only creates the CatalogSource; user runs `aapctl`
manually. Easier to maintain but defeats the purpose of an addon. Rejected.

## References

- Automation Orchestrator EA Deployment Guide (Google Doc — ask your Red Hat POC for access)
- [aapctl releases](https://github.com/automation-nexus/aapctl/releases)
- ADR-008: Addon system
