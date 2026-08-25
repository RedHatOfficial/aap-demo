<!-- markdownlint-disable MD013 MD024 -->
# ADR-023: APME OpenShift Template Deployment

**Status:** Proposed

**Date:** 2026-08-24

**Authors:** Chad Ferman

**Related:** [ADR-019](019-apme-playbook-addon.md), [ADR-019b](019b-apme-aap-native-execution.md), [ADR-022](022-apme-prebuilt-portal-hub.md)

**Implementation branch:** `feat/apme-openshift-template`

## Context

The `apme-eap` addon deploys the Ansible automation portal with APME on OpenShift Local
(MicroShift/CRC). Through ADR-019, ADR-019b, and ADR-022, the deploy path evolved to:

1. A bash wrapper that discovers cluster and AAP credentials
2. An AAP job (custom EE) running `deploy_apme_portal.yml`
3. Two Helm releases: Red Hat Developer Hub portal chart + APME gateway chart
4. Large rendered Helm values (`portal-apme-values.yaml.template`) with pre-built hub patches

This works but carries ongoing cost:

| Issue | Detail |
| ----- | ------ |
| **Dual Helm installs** | Portal and APME gateway are separate chart lifecycles, versions, and failure surfaces |
| **Values sprawl** | `portal-apme-values.yaml.template` is thousands of lines; most fields are unused for aap-demo |
| **Chart vs manifest drift** | APME gateway Helm chart and raw Kubernetes manifests used elsewhere (EAP template) diverge |
| **EE dependency on Helm** | Custom `apme-ee` image installs Helm CLI though `kubernetes.core.helm` is the real requirement |
| **Template parity** | A single-file OpenShift Template (`deploy.yaml` + param file) already deploys portal + PostgreSQL + APME engine for EAP demos |

A consolidated **OpenShift Template** approach (`oc process -f deploy.yaml --param-file=params.env`)
matches how the portal-hub-EAP image is validated upstream and reduces moving parts for aap-demo
operators.

**Constraints preserved:**

- **AAP-native orchestration** (ADR-019b): deploy still launches an AAP job; host does not run
  `oc`/`helm` for the main install
- **Pre-built portal hub** (ADR-022): `quay.io/cferman/portal-hub-eap:latest` with
  `install-dynamic-plugins` init — not runtime OCI injection
- **MicroShift OAuth** (ADR-022, README): in-pod AAP reachability via `hostAliases` and
  `http://` in-cluster AAP URL where required
- **Addon contract** (ADR-008): `deploy.sh` / `--delete` entry point unchanged

## Decision

Replace Helm-based portal and APME gateway installation with a **single OpenShift Template**
processed and applied from the AAP execution environment using the **`redhat.openshift`**
collection.

### Deploy flow

```text
aap-demo enable apme-eap
  → deploy.sh (discover cluster, setup-pah, generate params, launch AAP job)
  → AAP EE: deploy_apme_portal.yml
      → aap_apme_prerequisites (AAP OAuth app + API token only)
      → apme_template_deploy (process deploy.yaml, apply objects)
      → MicroShift hostAliases patch (portal Deployment)
      → optional Route TLS patch
      → optional apme_scm_secrets (GitHub App)
      → apme_pah_integration (galaxy-server seed)
```

### Template assets

| Asset | Role |
| ----- | ---- |
| `addons/apme-eap/deploy.yaml` | `template.openshift.io/v1` — namespace, secrets, ConfigMaps, PostgreSQL, portal Deployment, APME engine (multi-container), Routes, PVCs |
| `addons/apme-eap/params.example.env` | Documented parameter template |
| `~/.aap-demo/apme-eap-params.env` | Generated per deploy; pins DB/session/Abenay secrets across redeploys |

Portal Route host is fixed in the template:

`redhat-rhaap-portal-apme.<CLUSTER_ROUTER_BASE>`

OAuth redirect URI must match that host exactly.

### AAP job playbook

- **`redhat.openshift.openshift_process`** (or equivalent) on `deploy.yaml` with parameters
  derived from Ansible vars
- **`kubernetes.core.k8s`** to apply processed objects
- **No Helm** in the main deploy path

### Execution environment

- Use **Product Demos EE** (`quay.io/ansible-product-demos/apd-ee-26:latest`) — shared with product-demos addons
- Reuse existing AAP EE registration named `Product Demos EE` when present
- Includes `kubernetes.core`, `redhat.openshift`, `community.general`, and `oc` for `oc process --local`
- Optional custom EE build in `addons/apme-eap/execution-environment/` for forks only

### GitHub integration

| Mode | Default? | Mechanism |
| ---- | -------- | --------- |
| PAT + OAuth | Yes | Template `secrets-github-portal` + `GITHUB_*` template params |
| GitHub App (push/PR) | No | Opt-in: `apme_scm_secrets` creates `secrets-scm`; playbook patches portal Deployment env vars; documented in README Advanced section |

### Optional Route TLS

- Default: Route **edge** termination with cluster ingress certificate (ADR-015 laptop trust on MicroShift)
- Optional: user supplies PEM files under `~/.aap-demo/apme-eap-tls/`; playbook patches Route `spec.tls` (edge or reencrypt)
- Custom Route certs are independent of ingress CA trust on the laptop

### Galaxy seeding

APME gateway runs as container `gateway` inside Deployment `apme-engine` (not a separate Helm
gateway pod). Post-deploy seeding targets that pod/container for
`/api/v1/settings/galaxy-servers`.

### Deprecated (not removed)

Helm roles remain in the tree for reference but are **not** invoked by the main deploy playbook:

- `portal_helm_install`, `apme_gateway_helm`, `apme_helm_values`, `openshift_apme_setup`

`apme_scm_secrets` remains for optional GitHub App mode.

## Consequences

### Positive

- **Single artifact** for portal + APME — easier to diff, review, and align with EAP template work
- **Smaller EE** — no Helm CLI; fewer collections tied to chart repos
- **Faster mental model** — param file + template vs dual-chart values rendering
- **Keeps AAP demo value** — job still runs in AAP with visible job output (ADR-019b intent)
- **Debuggable manually** — `oc process -f deploy.yaml --param-file=... | oc apply -f -`

### Negative

- **Template conditionals are weak** — optional TLS and GitHub App wiring use post-apply patches, not inline template branches
- **Less chart upgrade automation** — APME image versions are pinned in `deploy.yaml`; bumps require template edit or regenerate script
- **Route host fixed** — not `redhat-rhaap-portal-<namespace>.<domain>`; namespace must stay `apme` for URL expectations unless template changes
- **Init container parity** — template init may lack scrollWidth patch from Helm values path; may need follow-up if catalog UI regresses (ADR-022)

### Neutral

- Host `deploy.sh` still discovers environment and orchestrates AAP REST API
- Pre-built portal hub image and init contract unchanged (ADR-022)
- `setup-pah` and Automation Hub catalog sync behavior unchanged
- GitHub App remains available for advanced users who configure it explicitly

## Alternatives considered

### Keep Helm dual-chart deploy (status quo on 019b path)

- **Pros:** Chart version pins, established values patches (hostAliases, scrollWidth)
- **Cons:** Large maintenance surface; EE needs Helm; diverges from EAP single-template workflow
- **Rejected** for aap-demo default path

### Host-side `oc process` only (no AAP job)

- **Pros:** Simplest shell flow
- **Cons:** Loses AAP-native demo and job UI visibility (ADR-019b goal)
- **Rejected**

### Pure `kubernetes.core` manifests (no Template)

- **Pros:** No `redhat.openshift` dependency
- **Cons:** Loses param substitution and documented `params.example.env` operator UX
- **Rejected** — Template matches upstream EAP deliverable

## References

- `addons/apme-eap/deploy.yaml` — OpenShift Template (portal-hub-EAP + APME)
- `addons/apme-eap/params.example.env` — parameter documentation
- [ADR-019: APME Playbook Addon](019-apme-playbook-addon.md)
- [ADR-019b: APME AAP-Native Execution](019b-apme-aap-native-execution.md)
- [ADR-022: APME Pre-Built Portal Hub](022-apme-prebuilt-portal-hub.md)
- [ADR-015: Ingress CA Trust](015-ingress-ca-user-store-trust.md)
