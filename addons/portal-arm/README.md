# Portal ARM Addon — Ansible Automation Portal on ARM64

Helm-based portal deployment for **ARM64 clusters**, using upstream community RHDH
images instead of the x86-only Red Hat builds.

## Overview

Same deployment flow as `addons/portal/`, with these differences:

| | `portal` (x86) | `portal-arm` |
|---|----------------|--------------|
| Target cluster | x86_64 | **arm64** |
| RHDH hub image | `registry.redhat.io/rhdh/rhdh-hub-rhel9:1.9` | `quay.io/rhdh-community/rhdh:1.10` |
| PostgreSQL | RHEL image (x86) | `bitnami/postgresql:16.6.0` (multi-arch) |
| Namespace | `redhat-rhaap-portal` | `redhat-rhaap-portal-arm` |
| OAuth app | `ansible-automation-portal` | `ansible-automation-portal-arm` |
| Config dir | `~/.aap-demo/portal` | `~/.aap-demo/portal-arm` |

Both addons use the same `redhat-rhaap-portal` Helm chart (2.2.1) and AAP OCI plugins
(`imageTagInfo: "2.2"`).

## Quick Start

```bash
# Verify cluster is ARM64
kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}'
# Expected: arm64

aap-demo enable portal-arm
```

## Image Research (2026-06)

### RHDH hub — ARM supported

`quay.io/rhdh-community/rhdh:1.10` publishes a multi-arch manifest list with both
`linux/amd64` and `linux/arm64`. This is the current stable community build used by
[RHDH Local](https://github.com/redhat-developer/rhdh-local).

Override via environment variables if needed:

```bash
DEFAULT_RHDH_TAG=next aap-demo enable portal-arm   # nightly community build
```

### AAP OCI plugins — metadata is amd64, content may still work

`registry.redhat.io/ansible-automation-platform/automation-portal:2.2` reports
`Architecture: amd64` in its OCI manifest. The artifacts are JavaScript plugin bundles
(not native binaries), so they may install and run on ARM once pulled — but this is
**not officially documented** for ARM clusters.

The plugin init container uses the same RHDH hub image (now arm64), and `skopeo` pulls
OCI artifacts by digest without enforcing platform match on the layer content.

If plugin install fails on ARM, check init container logs:

```bash
kubectl logs deploy/redhat-rhaap-portal-arm -c install-dynamic-plugins \
  -n redhat-rhaap-portal-arm
```

### Chart constraint

The OpenShift Helm chart is certified for `x86_64` only
(`charts.openshift.io/archs: x86_64`). This addon overrides container images for ARM
but is **experimental** — not Red Hat supported.

## Prerequisites

Same as `addons/portal/`:

- AAP 2.6+ deployed (`aap-demo deploy`)
- Helm 3.10+, `jq`, `oc`/`kubectl`
- `registry.redhat.io` credentials (required for AAP OCI plugins, not for RHDH hub)

## Disable

```bash
aap-demo disable portal-arm
```

Removes the `redhat-rhaap-portal-arm` namespace, Helm release, OAuth app, and
`~/.aap-demo/portal-arm`.

## Helm Values

Generated at `~/.aap-demo/portal-arm/values.yaml`:

```yaml
redhat-developer-hub:
  global:
    clusterRouterBase: <auto-detected>
    pluginMode: oci
    imageTagInfo: "2.2"
  upstream:
    backstage:
      image:
        registry: quay.io
        repository: rhdh-community/rhdh
        tag: "1.10"
      appConfig:
        catalog:
          providers:
            rhaap:
              orgs: "<aap-org>"
    postgresql:
      image:
        registry: docker.io
        repository: bitnami/postgresql
        tag: "16.6.0"
      postgresqlDataDir: /bitnami/postgresql/data
```

## See Also

- `addons/portal/` — production x86 Helm deployment
- `addons/portal-vm/` — QEMU appliance for macOS local testing
