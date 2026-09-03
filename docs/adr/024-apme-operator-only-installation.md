# ADR-024: APME Operator-Only Installation

**Status:** Accepted

**Date:** 2026-09-03

**Authors:** Chad Ferman

**Related:** [ADR-008](008-addon-system.md), [ADR-019](019-apme-playbook-addon.md),
[ADR-022](022-apme-prebuilt-portal-hub.md), [ADR-023](023-apme-openshift-template.md)

## Context

APME had accumulated several installation paths: Helm charts, an AAP-native playbook, an
OpenShift Template, and the upstream APME operator. Multiple paths made it difficult to know
which resources were authoritative and allowed stale portal or gateway installations to remain
in the cluster.

The supported installation must work on OpenShift Local/MicroShift and on Linux, use the upstream
APME project as the source of truth, and keep the portal integration separate from the APME
installation lifecycle.

## Decision

Install APME only through the published resources from
[`ansible/apme-operator`](https://github.com/ansible/apme-operator):

1. Apply the operator release manifest:

   `https://github.com/ansible/apme-operator/releases/latest/download/install.yaml`

2. Wait for the `apmes.apme.ansible.com` CRD and
   `apme-operator-controller-manager` deployment to become ready.

3. Create the `apme` namespace and apply the upstream sample CR from:

   `https://raw.githubusercontent.com/ansible/apme-operator/main/config/samples/apme_v1alpha1_apme.yaml`

4. Set the sample Route host to `apme.<cluster-domain>`, then wait for the APME CR to report
   `Ready=True`.

The `apme-eap` addon is therefore limited to operator installation and CR application for APME.
It does not install APME with Helm, an OpenShift Template, or a custom gateway manifest.

### Integration with the portal

The portal is an independent deployment. When it is colocated in the `apme` namespace, its APME
client uses the operator-managed gateway service:

`http://apme-gateway:8080`

The portal deployment also registers the repository scaffolder template from the repository in
the Backstage catalog. The template is mounted through the `apme-scaffolder-templates` ConfigMap
and configured as a file catalog location with an allow rule for the `Template` kind.

Colocating the portal and APME is the default because the APME NetworkPolicy permits gateway
traffic from workloads in the same namespace. A cross-namespace deployment requires an explicit
network-policy change and a namespace-qualified service address.

### Requirements

The operator-only path requires:

- An accessible OpenShift/Kubernetes cluster and kubeconfig
- `kubectl` and `curl`
- Network access to GitHub from the deployment environment
- A cluster route domain; `apps.crc.testing` is the fallback for CRC
- The APME CRD/operator permissions needed to create the `apme` namespace and CR

The portal integration additionally requires the portal prerequisites, AAP access, and
`mikefarah/yq` for catalog configuration.

### Validation and cleanup

Validation checks include:

- Operator deployment is available
- APME CR condition is `Ready=True`
- APME gateway and managed PostgreSQL pods are ready
- Portal deployment is ready
- Portal catalog contains the repository template
- The portal Route responds over HTTPS

Before testing a fresh installation, remove old APME/operator/portal resources and stale portal
namespaces. In particular, status output must be based on the live Route, not an obsolete Route
such as `redhat-rhaap-portal-redhat-rhaap-portal.<domain>`.

## Consequences

### Positive

- One APME installation mechanism and one upstream source of truth
- No Helm repository, chart values, custom gateway manifests, or AAP job is required for APME
- Operator reconciliation manages the APME deployment lifecycle
- The portal can be upgraded or removed independently
- The same flow is straightforward to reproduce on Linux

### Negative

- The operator release URL tracks the upstream latest release unless explicitly pinned later
- The upstream sample is fetched at deployment time, so GitHub availability is required
- Route host customization is required because the upstream sample leaves the host unset
- Portal and APME must share a namespace by default because of the APME NetworkPolicy
- Existing stale installations can produce misleading status output or route conflicts

### Neutral

- The portal still uses the pre-built portal hub image and APME dynamic plugins
- AAP remains the authentication and automation backend for the portal
- Existing Helm/template/playbook assets remain historical or optional reference paths; they are
  not part of the default APME installation

## Alternatives Considered

### Helm-based APME installation

Rejected as the default because it introduces chart lifecycle and values management separate from
the upstream operator.

### OpenShift Template containing portal and APME

Rejected for APME installation because it duplicates operator reconciliation and couples the portal
and APME lifecycles.

### AAP-native deployment job

Rejected for the operator-only path because APME installation does not require an AAP job. The
portal may still use AAP for its own credentials and automation integration.

### Custom manifests maintained in this repository

Rejected as the source of truth because they can drift from the upstream operator API and managed
resource expectations.

## References

- [APME operator repository](https://github.com/ansible/apme-operator)
- `addons/apme-eap/lib.sh`
- `addons/apme-eap/deploy.sh`
- `addons/portal/deploy.sh`
- `addons/portal/deploy.yaml`
- [ADR-019: APME Playbook Addon](019-apme-playbook-addon.md)
- [ADR-022: APME Pre-Built Portal Hub Deployment](022-apme-prebuilt-portal-hub.md)
- [ADR-023: APME OpenShift Template Deployment](023-apme-openshift-template.md)
