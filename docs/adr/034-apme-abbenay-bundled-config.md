# ADR-034: APME Abbenay Bundled Config on Redeploy

**Status**: Accepted

**Date**: 2026-10-29

**Authors**: aap-demo maintainers

## Context

The apme Helm chart (0.1.10) seeds Abbenay with `consumers.apme.capabilities.inline_policy: true`
only. Engine AI escalation requires `chat: true` on the Abbenay consumer ([apme#755](https://github.com/ansible/apme/issues/755)).

Abbenay persists runtime config on a PVC (`config.yaml` plus optional `secrets.json`). The chart
init container copies a ConfigMap seed only when the PVC file is missing. After deploy, operators
configure LLM providers through the portal (Modernization / AI providers), which writes additional
providers and secrets onto that PVC.

aap-demo must enable AI remediation out of the box without manual cluster surgery, while keeping
the apme-eap Ansible role small and reviewable.

## Decision

On every successful `apme_gateway_helm` run during `aap-demo enable apme-eap`:

1. Render a **single flat template**
   [`abbenay-config.yaml.j2`](../../addons/apme-eap/playbooks/roles/apme_gateway_helm/templates/abbenay-config.yaml.j2)
   (server, bundled `bootstrap-placeholder` provider, `inline_policy` + `chat` capabilities).
2. Apply the rendered content to the Abbenay **ConfigMap seed** when it differs from the current
   ConfigMap data.
3. **Overwrite** the live PVC `config.yaml` in the `apme-engine` Abbenay container when it differs
   from the rendered template (via `kubectl exec`, consistent with ADR-033 gateway seeding).
4. **Restart** `apme-engine` only when the PVC file actually changed.

**Tradeoff:** Each enable **resets** portal-configured Abbenay AI providers and file-store secrets
on the PVC to the bundled template. Operators must re-add LLM providers in the portal after
re-enable if they use AI escalation beyond the placeholder provider.

**User notice:** `addons/apme-eap/deploy.sh` prints a warning after successful enable; the addon
README and deployment report reference this ADR.

Keep the template aligned with
[`apme-values.yaml`](../../addons/apme-eap/playbooks/roles/apme_gateway_helm/files/apme-values.yaml)
Abbenay provider entries.

## Consequences

### Positive

- Predictable Abbenay config on every deploy; `chat: true` is always present for apme#755.
- One readable template instead of merge logic, sed patches, or multiple J2 fragments.
- Idempotent when config already matches (no engine restart).
- Fits apme-eap constraints (`kubectl exec`, no `k8s_exec` per ADR-033).

### Negative

- Re-running `aap-demo enable apme-eap` **wipes** portal AI provider settings on the Abbenay PVC.
- Does not fix upstream chart seed; aap-demo owns the workaround until apme chart exposes
  consumer capabilities in values.

### Neutral

- Portal GitHub catalog, galaxy seeding, and Helm releases are unaffected.
- First-time installs and redeploys use the same code path.

## Alternatives Considered

**Merge `chat: true` only on the live PVC**

- Preserves portal providers on redeploy.
- Rejected: more Ansible and template complexity; user accepted reset-on-redeploy for demo simplicity.

**Patch ConfigMap seed only**

- Does not update an existing PVC; clusters stay broken until manual exec or PVC wipe.

**Wait for upstream apme chart**

- Correct long-term; does not unblock aap-demo demos today.

## References

- [apme#755](https://github.com/ansible/apme/issues/755) — Abbenay consumer `chat` capability
- [ADR-019](019-apme-playbook-addon.md) — APME playbook addon
- [ADR-033](033-apme-local-oci-plugin-publishing.md) — `kubectl exec` in apme-eap playbooks
- Abbenay admin proxy: upstream apme ADR-070 (portal provider configuration)
