# ADR-017: Automation Orchestrator Early Access Addon (ao-eap)

**Status**: Proposed

**Date**: 2026-07-15

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

Script exits with setup instructions if either file is missing, following the same pattern
as `setup-pah`.

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

1. Check credentials — exit with instructions if missing
2. Install `aapctl` — skip if already in PATH
3. Create `automation-orchestrator` namespace; grant `anyuid` + `privileged` SCCs
4. Apply `quay-aap-viewer` Secret and `cs-automation-orchestrator` CatalogSource to
   `openshift-marketplace`; wait for catalog pod Running
5. First-pass `aapctl install` with `--no-wait --set automation-orchestrator-cr.enabled=false`
6. Wait for CSV; patch `registry.redhat.io/ansible-automation-platform` to
   `quay.io/aap/ansible-automation-platform`
7. Copy pull secret to namespace, link to operator service account, `rollout restart`;
   wait for Running pod
8. Second-pass `aapctl install` (full, with wait)
9. Patch `AutomationOrchestrator` CR with `imagePullSecrets`; `rollout restart`
10. Wait for all pods Running; retrieve admin password; print route URL

### Delete flow

`deploy.sh --delete`:

1. `aapctl uninstall automation-orchestrator --force`
2. `oc delete catalogsource cs-automation-orchestrator -n openshift-marketplace`
3. `oc delete secret quay-aap-viewer -n openshift-marketplace`
4. `oc delete namespace automation-orchestrator` (if exists)

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
- 10-step process means the script is long and has multiple wait loops
- EA limitations: no air-gap support, no HA, in-place upgrades not guaranteed

### Neutral

- AO runs in its own `automation-orchestrator` namespace, isolated from `aap-operator`
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
