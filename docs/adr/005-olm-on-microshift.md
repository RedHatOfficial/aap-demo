# ADR-005: OLM Installation on MicroShift

**Status**: Accepted

**Date**: 2026-07-02

**Authors**: aap-demo maintainers

## Context

AAP 2.7 ships as an **OLM-managed operator** installed via CatalogSource + Subscription + CSV.
Full OpenShift includes OLM by default; **MicroShift does not**.

Without OLM, aap-demo cannot:

- Install `ansible-automation-platform-operator` from `registry.redhat.io`
- Reconcile ClusterServiceVersions and operator pods
- Use the standard Red Hat operator index

MicroShift also lacks `openshift-marketplace` — CatalogSources must live in the AAP namespace.

## Decision

Install OLM during cluster creation using **`operator-sdk olm install`**, wrapped by `addons/olm/deploy.sh`.

### Installation flow

```text
aap-demo create
      │
      ├─▶ crc start (MicroShift VM)
      ├─▶ addons/olm/deploy.sh
      │         ├─ ensure operator-sdk (auto-download v1.38.0 if missing)
      │         ├─ operator-sdk olm install
      │         └─ delete operatorhubio-catalog (MicroShift incompatible)
      └─▶ continue NFS, CoreDNS, metrics-server setup
```

### operator-sdk bootstrap

If `operator-sdk` is absent, `deploy.sh` downloads the matching OS/arch binary to `~/.local/bin/`
(or `/usr/local/bin/` with sudo). This removes a manual prerequisite for most users.

### operatorhubio-catalog removal

The default `operatorhubio-catalog` CatalogSource causes pod scheduling issues on MicroShift. It
is deleted immediately after OLM install:

```bash
kubectl delete catsrc operatorhubio-catalog -n olm
```

### Idempotency

If `subscriptions.operators.coreos.com` CRD already exists, the script exits early with "OLM is already installed."

### Timeout tolerance

`operator-sdk olm install` may report timeout while CRDs are actually present. The script checks
for CRD existence and treats that as success.

### CatalogSource placement

AAP's CatalogSource (`config/olm/catalogsource.yaml`) is created in the **target namespace**
(`aap-operator` by default), not `openshift-marketplace`:

```yaml
metadata:
  name: redhat-operators
  namespace: aap-operator
spec:
  image: registry.redhat.io/redhat/redhat-operator-index:v4.20
```

Version is overridable via `AAP_OCP_VERSION` to match the cluster's OpenShift version mapping.

## Consequences

### Positive

- AAP operator installs the same way on MicroShift as on production OpenShift
- OLM install is automated and idempotent
- operator-sdk auto-install lowers onboarding friction

### Negative

- Adds ~1 minute to cluster create time
- OLM pods consume cluster resources (~4 pods in `olm` namespace)
- operator-sdk version pinned in deploy script — must be updated deliberately
- Full CRC OpenShift preset includes OLM but aap-demo still documents the addon for consistency

### Neutral

- OLM uninstall on `destroy` relies on namespace deletion or `operator-sdk olm uninstall`
- Bundle unpack jobs require `privileged` SCC (see ADR-012)

## Alternatives Considered

### Manual operator install without OLM

Rejected: unsupported by Red Hat; bypasses CSV lifecycle and upgrade paths.

### Embedded OLM manifests in repo

Rejected: `operator-sdk olm install` is the maintained upstream path and handles version compatibility.

### Keep operatorhubio-catalog

Rejected: causes known pod failures on MicroShift; no AAP dependency on community catalog.

## References

- [addons/olm/deploy.sh](../../addons/olm/deploy.sh)
- [config/olm/catalogsource.yaml](../../config/olm/catalogsource.yaml)
- [config/olm/subscription.yaml](../../config/olm/subscription.yaml)
- [ADR-009](009-aap-operator-olm-deployment.md)
