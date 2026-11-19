# OPA v2-Python Addon Design

**Status:** Proposed

**Date:** 2026-11-18

## Goal

Port the OPA addon to the native Python v2 addon interface while preserving the
current `aap-demo enable opa` experience and leaving the existing shell addon as
the compatibility fallback during the migration.

## Scope and compatibility

The native addon must continue to provide:

- an OPA 1.20.2 deployment in the configured AAP namespace;
- an OPA Service and Route, with the same in-cluster URL used by AAP;
- automatic AAP Policy as Code settings configuration;
- the `Policy as Code` organization, `OPA Localhost` inventory, project,
  least-privilege AAP credential, and four existing job templates;
- the existing checked-in policy playbooks and their upstream repository/ref
  configuration;
- idempotent enable and safe disable behavior;
- the existing environment-variable configuration surface unless a value is
  explicitly moved into native addon options;
- `addons.enabled` state in the Python config file.

The shell implementation in `addons/opa/deploy.sh` remains packaged and
available as the legacy path until the native port is complete. The port does
not change the bash command's behavior or the OPA policy examples in this
design.

## Architecture

### Native registry entry

Add `OpaAddon` to `src/aap_demo/addons/opa.py` and register it from
`src/aap_demo/addons/__init__.py` as a public native addon. It exposes the
standard `enable` and `disable` behavior expected by the existing `Addon`
protocol, requires a cluster, and uses the shared addon state helpers.

The addon owns only resources it can identify by stable names and labels. It
must refuse to delete or reuse an OPA resource that has conflicting ownership
metadata, following the ownership guard used by the native Keycloak addon.

### Kubernetes resources

Render the OPA Deployment, Service, and Route as Python data and apply them
with the existing kube helpers. The desired Deployment keeps the configured
`OPA_VERSION`, the existing OPA labels, port 8181, and the current readiness
wait. The manifest source ref remains configurable, but native rendering must
not depend on downloading and text-substituting an arbitrary remote YAML file;
the native path uses an explicit, reviewable resource definition and treats the
configured image version as data.

The Service and Route are owned by the addon. Disable removes those resources
and the Deployment, but does not delete the shared AAP namespace.

### AAP bootstrap and playbook execution

The host process does not grow a second HTTP client for AAP. Instead, add a
small OPA bootstrap playbook beside the existing OPA playbooks. Run it through
`aap_demo.addons.common.playbook_job`, using the cluster's trusted execution
environment and the shared gateway/password discovery seams.

The bootstrap playbook uses `ansible.builtin.uri` against the AAP gateway to
create or update the organization, project, inventory/localhost host,
credential, job templates, and the Policy as Code settings. It waits for the
project sync before creating templates and builds the policy-demo survey from
the configured upstream policy ref. Credentials are passed as secret-backed
extra vars and never printed in console output.

The existing load, test, clear, and demo policy playbooks continue to be
available to the resulting AAP job templates. Their repository/ref and OPA
service variables are supplied by the bootstrap playbook. The native addon
does not execute those user-facing policy jobs during enable.

### Configuration and state

Read native options from `addons.options.opa`, with environment variables kept
as a compatibility input for the first port: `OPA_VERSION`, `OPA_REPO`,
`OPA_MANIFEST_REF`, `AAP_DEMO_REPO`, and `AAP_DEMO_BRANCH`. Persist only
non-secret user choices. Record `opa` in `addons.enabled` after the full
enable sequence succeeds; leave state unchanged when any required stage fails.

Disable clears the AAP OPA settings, deletes the OPA-owned AAP resources
created by the bootstrap playbook, deletes the OPA Kubernetes resources, and
then removes `opa` from `addons.enabled`. Cleanup is best-effort per resource,
but conflicting ownership or an inability to authenticate to AAP is reported
instead of silently deleting unrelated resources.

## Error handling

- Missing cluster/AAP readiness is handled by the CLI preflight and addon
  metadata, not duplicated inside the addon.
- Missing trusted execution environment, gateway route, or admin password is a
  clear `AddonError` with a retry hint.
- A failed bootstrap Job includes its pod log in the error hint and still
  deletes temporary Job, ConfigMap, Secret, service account, and RBAC objects
  through the shared runner cleanup.
- A failed OPA rollout reports the deployment status/log command and does not
  mark the addon enabled.
- Disable verifies ownership before deleting AAP or Kubernetes resources.
- No password, API token, or secret-backed extra var is included in structured
  output, exception text, or normal progress messages.

## Testing

Unit tests must cover:

1. native registry metadata and public addon listing;
2. deterministic OPA Kubernetes manifest content, image/version options, and
   ownership labels;
3. bootstrap Job inputs, including gateway URL, admin password handling,
   repository/ref values, and secret redaction;
4. idempotent enable and state recording only after success;
5. disable ownership refusal and complete owned-resource cleanup;
6. failed rollout/bootstrap cleanup and useful error hints;
7. compatibility of the existing OPA shell installer/package fallback;
8. documentation and packaging of the new bootstrap playbook and existing OPA
   playbooks.

The implementation uses the repository's normal unit checks from
`CONTRIBUTING.md`; a real cluster test should enable OPA, verify the OPA health
endpoint and AAP Policy settings, launch each created template, then disable
OPA and verify that only OPA-owned resources were removed.

## Non-goals

- Rewriting or correcting upstream Rego policy examples.
- Changing AAP Policy as Code semantics or adding new policy features.
- Removing the bash addon in the same change.
- Adding a general AAP REST client to the application.
- Moving shared addon framework code beyond what the existing ADR-040 native
  layer already provides.
