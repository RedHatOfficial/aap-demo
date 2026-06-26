# portal-arm (deprecated alias)

The `portal-arm` addon is merged into [`addons/portal/`](../portal/). A single command
auto-detects cluster CPU architecture and selects the correct image set:

| Cluster CPU | RHDH hub image | Namespace |
|-------------|----------------|-----------|
| `amd64` | Red Hat chart default (`registry.redhat.io/rhdh/...`) | `redhat-rhaap-portal` |
| `arm64` | `quay.io/rhdh-community/rhdh:1.10` + RHEL9 PostgreSQL | `redhat-rhaap-portal` |

## Use

```bash
aap-demo enable portal
```

`aap-demo enable portal-arm` still works (runs the same deploy script).

Override detection if needed:

```bash
PORTAL_ARCH=arm aap-demo enable portal   # force ARM profile
PORTAL_ARCH=x86 aap-demo enable portal   # force x86 profile
```

## Legacy installs

Pre-merge `portal-arm` deployments used namespace `redhat-rhaap-portal-arm`.
`aap-demo disable portal` removes both the unified namespace and any legacy
`redhat-rhaap-portal-arm` release.

See [`addons/portal/README.md`](../portal/README.md) for full documentation.
