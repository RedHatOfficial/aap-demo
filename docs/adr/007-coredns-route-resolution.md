# ADR-007: CoreDNS Route Resolution for nip.io

**Status**: Accepted

**Date**: 2026-06-15

**Authors**: aap-demo maintainers

## Context

OpenShift Routes expose services at hostnames like `aap-aap-operator.apps.127.0.0.1.nip.io`. On developer laptops:

- **Browsers** resolve `*.nip.io` via public DNS to `127.0.0.1` — routes work without `/etc/hosts`
- **Pods inside the cluster** also resolve `*.nip.io` via upstream DNS to `127.0.0.1` — wrong
  inside the pod network

Symptoms without a fix:

- OAuth token exchange fails (portal, MCP)
- Pod-to-AAP API calls timeout
- Catalog sync and webhook callbacks break

MicroShift lacks `ingresses.config.openshift.io`; route domains use `apps.<baseDomain>`
(e.g., `apps.crc.testing` or custom `127.0.0.1.nip.io`).

## Decision

Patch the cluster CoreDNS ConfigMap (`dns-default` in `openshift-dns`) to **rewrite nip.io
route hostnames to the ingress router Service** using the CoreDNS `rewrite` plugin.

### Implementation

`includes/crc-create.sh` → `configure_coredns()`:

1. Wait for `router-internal-default` Service in `openshift-ingress`
2. Detect route domain from MicroShift config (`apps.crc.testing` or custom)
3. Patch CoreDNS Corefile with:

```text
rewrite stop {
    name regex (.*)\.apps\.<domain> router-internal-default.openshift-ingress.svc.cluster.local
    answer auto
}
```

1. Re-apply on `aap-demo start` — router ClusterIP can change after CRC restarts

### Why not static manifests?

`config/manifests/coredns-config.yaml` is documentation only. The router ClusterIP is
**dynamic** and unknown until the cluster runs; a runtime patch is required.

### MicroShift OAuth companion fixes

Some addons (portal, ADR-002) additionally use:

- `hostAliases` mapping route hostname → AAP Service ClusterIP
- `AAP_HOST_URL` as `http://` for in-cluster token exchange
- `checkSSL: false` in Backstage auth providers

CoreDNS fixes general in-cluster DNS; OAuth-specific workarounds address TLS and nip.io edge cases.

## Consequences

### Positive

- Pods resolve route hostnames to the ingress router — standard OpenShift ingress path
- No `/etc/hosts` editing on developer machines
- `aap-demo start` re-applies config after stale router IP issues
- `diagnose` can detect DNS misconfiguration

### Negative

- CoreDNS patch is fragile across OpenShift version upgrades (Corefile schema changes)
- Must re-run after CRC stop/start if router IP changes
- Custom route domains require matching regex in rewrite rule

### Neutral

- External (browser) traffic still uses nip.io → 127.0.0.1 — unchanged
- Ingress CA trust is separate (see ADR-010 / `ingress-ca-trust.sh`)

## Alternatives Considered

### /etc/hosts in every pod

Rejected: not maintainable; breaks on route changes.

### Use in-cluster Service DNS only

Rejected: OAuth redirects and external URLs require route hostnames reachable from browsers.

### Disable nip.io; use crc.testing only

Rejected: nip.io is widely documented in aap-demo; CRC testing domain varies by preset.

## References

- [includes/crc-create.sh](../../includes/crc-create.sh) — `configure_coredns()`
- [config/manifests/coredns-config.yaml](../../config/manifests/coredns-config.yaml) — documentation placeholder
- [ADR-002](002-portal-helm-deployment.md) — MicroShift OAuth host alias
- Skill troubleshooting: DNS resolution failures → `aap-demo start`
