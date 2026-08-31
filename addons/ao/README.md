# Automation Orchestrator Addon (`ao`)

Deploys **Automation Orchestrator (GA)** on aap-demo MicroShift clusters.

- **Command:** `aap-demo enable ao` (legacy alias: `ao-eap`)
- **Namespace:** `automation-orchestrator`
- **Requires:** `aap-demo deploy` (AAP + OLM + `redhat-operators` in `aap-operator`)
- **Requires:** `mcp-server` addon (`aap-demo enable ao` installs it automatically)
- **Does not require:** `aapctl`, Quay credentials, GitHub CLI, or a private operator index

Manifests follow the
[aapctl GitOps shape](https://docs.redhat.com/en/documentation/automation_orchestrator/2026.8/install-generate_aapctl_manifests_for_gitops)
and are checked in under [`manifests/`](manifests/). `deploy.sh` applies them with `kubectl`.

## Quick start

```bash
aap-demo deploy          # once: AAP + OLM + catalog
aap-demo enable ao       # mcp-server + Automation Orchestrator + wiring
aap-demo status          # route URL + admin password when ready
```

Force a clean reinstall (resets Postgres if secret names or passwords drifted):

```bash
FORCE=1 aap-demo enable ao
```

Remove:

```bash
aap-demo disable ao
```

This removes the `automation-orchestrator` namespace and AO OLM resources. The CloudNativePG
operator in `cnpg-system` is **not** removed (it may be shared).

### Auto-wiring (AAP + MCP)

After the instance is ready, `aap-demo enable ao` automatically configures cluster-local
integrations (no separate wiring step):

- **Integration URL allow-list** — patches AO deployments with
  `APP_INTEGRATION_URL_ALLOWED_HOSTS` and `APP_OIDC_ALLOW_PRIVATE_NETWORKS` (same intent as
  upstream APD `infrastructure/ao/network-access.yml`) so co-located AAP/MCP base URLs that
  resolve to private addresses on MicroShift pass AO SSRF validation
- **AAP integration** (`aap-demo AAP`) → AAP route URL (fallback: in-cluster service) with a
  write-scoped gateway token stored as an AO credential
- **MCP integration** (`aap-demo MCP Server`) — **required**; `mcp-server` is enabled automatically
  and wired to AO (route or in-cluster `/mcp` URL with tools enabled)

Wiring also runs automatically when AAP deploy finishes (`aap-demo deploy` / `watch`).
Use `aap-demo wire` only to re-run wiring after manual cluster changes.

**Workflow builder note:** Configuration → Integrations may show **Available** while the workflow
UI still reports “AAP credential not configured” until you select **aap-demo AAP** and
**aap-demo AAP Token** on an AAP job-template node. AO proxy APIs require both `integration_id`
and `credential_id`; that message is expected before both are chosen on the node.

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| `aap-demo deploy` | Installs OLM and `redhat-operators` CatalogSource in `aap-operator` |
| `mcp-server` addon | Installed automatically by `aap-demo enable ao`; required for AO MCP integration wiring |
| Pull secret | `registry.redhat.io` access (`~/.aap-demo/pull-secret.txt`) |
| Operator in index | `automation-orchestrator-operator` in `redhat-operator-index` v4.18+; automatic fallback index if missing |
| StorageClass | Auto-detected: `nfs-local-rwx` or `topolvm-provisioner` |

**`aapctl` is optional.** Install it only to refresh checked-in templates via
[`scripts/generate-manifests.sh`](scripts/generate-manifests.sh). On disable, `deploy.sh` calls
`aapctl uninstall` if the binary happens to be on your PATH.

## How it works

```
aap-demo deploy                    aap-demo enable ao
     │                                    │
     ▼                                    ▼
 redhat-operators                  automation-orchestrator ns
 in aap-operator          ──►      + local CatalogSource copy
 (AAP subscription)                + CNPG (upstream manifest)
                                   + Postgres secrets + Cluster
                                   + OLM Subscription (AO operator)
                                   + AutomationOrchestrator CR
```

### MicroShift OLM constraints

Stock `aapctl` assumes full OpenShift (`openshift-marketplace`, `certified-operators`). On MicroShift:

| Topic | Full OpenShift / aapctl default | aap-demo |
|-------|----------------------------------|----------|
| AO catalog | `sourceNamespace: openshift-marketplace` | Local `redhat-operators` CatalogSource in `automation-orchestrator` |
| AO subscription | Same namespace as catalog | `automation-orchestrator` (not `aap-operator`) |
| OperatorGroup | Varies | Empty spec (`AllNamespaces`) — **cannot** share `aap-operator` with AAP's OperatorGroup |
| CNPG operator | `certified-operators` subscription | Upstream `cnpg-*.yaml` into `cnpg-system` |
| Database secrets | Random each `aapctl --dry-run` | Created once at install; password reused on re-run |

See [`manifests/README.md`](manifests/README.md) for file-level detail and apply order.

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `AO_STORAGE_CLASS` | auto-detected | StorageClass for CNPG PostgreSQL PVC |
| `CNPG_VERSION` | `1.25.1` | CloudNativePG operator version (dev-only) |
| `AAP_DEMO_NAMESPACE` | `aap-operator` | Used to derive cluster ingress domain for the AO route |
| `FORCE` | unset | Set to `1` or use `--force` to reinstall |
| `AO_REFRESH_CATALOG` | unset | Set to `1` to restart the AO catalog pod before install |
| `AO_INDEX_IMAGE` | auto | Pin operator index image explicitly |
| `AO_FALLBACK_INDEX_IMAGE` | `...v4.22-automation-orchestrator-operator-early-access-1787151066` | Used when default AAP catalog lacks AO |
| `AO_OPERATOR_CHANNEL` | `stable` | OLM subscription channel (`early-access` also available in the index) |
| `AO_PULL_SECRET_NAME` | `automation-orchestrator-pull-secret` | Registry pull secret in AO namespace |
| `AO_CATALOG_TIMEOUT` | `600` | Seconds to wait for AO CatalogSource READY (index pull can be slow) |
| `AO_DISABLE_INDEX_FALLBACK` | unset | Set to `1` to disable automatic fallback index |
| `AAP_OCP_VERSION` | auto-detected | OCP version for default index tag |

### Operator channel

Default channel is **`stable`**. Override if you need the early-access build:

```bash
AO_OPERATOR_CHANNEL=early-access aap-demo enable ao
```

### Catalog fallback

If AO is missing from the default `redhat-operator-index:vX.Y`, the script copies a fallback early-access
index into the AO namespace automatically. Pin explicitly:

```bash
AO_INDEX_IMAGE=registry.redhat.io/redhat/redhat-operator-index:v4.22-automation-orchestrator-operator-early-access-1787151066 \
  FORCE=1 aap-demo enable ao
```

Refresh the AO catalog pod:

```bash
AO_REFRESH_CATALOG=1 aap-demo enable ao
# or
./deploy.sh --refresh-catalog
```

## Access

After the instance reconciles:

```bash
kubectl get routes -n automation-orchestrator
kubectl get secret -n automation-orchestrator automation-orchestrator-initial-admin-password \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Username: **admin**

## Troubleshooting

### Catalog not READY / `TRANSIENT_FAILURE`

MicroShift requires a **copy** of `redhat-operators` in `automation-orchestrator`. While the
catalog pod pulls the operator index (multi-GB), OLM reports `TRANSIENT_FAILURE` and the pod
may stay `Pending` — this is normal and can take **10+ minutes** on slow networks.

**Prerequisite:** the AAP catalog in `aap-operator` must be `READY` first:

```bash
kubectl get catalogsource redhat-operators -n aap-operator \
  -o jsonpath='{.status.connectionState.lastObservedState}{"\n"}'
aap-demo deploy   # if not READY
```

Check the **AO-local** catalog:

```bash
kubectl get catalogsource redhat-operators -n automation-orchestrator
kubectl get pods -n automation-orchestrator -l olm.catalogSource=redhat-operators
kubectl describe pod -n automation-orchestrator -l olm.catalogSource=redhat-operators
kubectl get events -n automation-orchestrator --sort-by=.lastTimestamp | tail -15
```

Retry with a longer wait:

```bash
AO_CATALOG_TIMEOUT=900 AO_REFRESH_CATALOG=1 aap-demo enable ao
```

### SignatureValidationFailed (MicroShift 4.22+)

MicroShift 4.22+ rejects unsigned `registry.redhat.io` images. **`aap-demo enable ao` does not
SSH to the CRC VM** — run **`aap-demo deploy` first** on the same machine; deploy relaxes
signature policy and waits for the AAP catalog to become `READY`.

**Do not interrupt** a catalog pull that shows `Pulling catalog image...` — the index is
multi-GB and can take several minutes. Only retry after fixing policy or increasing timeout.

```bash
aap-demo deploy
AO_CATALOG_TIMEOUT=900 AO_REFRESH_CATALOG=1 aap-demo enable ao
```

If the catalog pod was restarted mid-pull, force a clean retry:

```bash
AO_REFRESH_CATALOG=1 FORCE=1 aap-demo enable ao
```

### `constraints not satisfiable` / operator not in catalog

Check packagemanifest in the **AO namespace**:

```bash
kubectl get packagemanifest automation-orchestrator-operator -n automation-orchestrator
kubectl get catalogsource redhat-operators -n automation-orchestrator \
  -o jsonpath='{.spec.image}{"\n"}'
```

Retry with fallback or force:

```bash
aap-demo disable ao
FORCE=1 aap-demo enable ao
```

### `MultipleOperatorGroupsFound` in `aap-operator`

Do **not** install the AO subscription in `aap-operator` (AAP already has an OperatorGroup there).
The addon installs OLM resources in `automation-orchestrator` only. Clean up stray resources:

```bash
kubectl delete subscription,operatorgroup automation-orchestrator-operator -n aap-operator --ignore-not-found
FORCE=1 aap-demo enable ao
```

### Backend migration / `InvalidPasswordError`

Usually a **password drift** between CNPG bootstrap and connection secrets (e.g. after upgrading from
older `orchestrator-pg-credentials` names). Force reinstall recreates Postgres with matching secrets:

```bash
FORCE=1 aap-demo enable ao
```

### Backend migration / `database "orchestrator" does not exist`

The operator on **`stable`** can install successfully while Postgres databases are still missing. This
happens when an older CloudNativePG install (without the `Database` CRD) was already on the cluster;
`deploy.sh` now upgrades CNPG and verifies `orchestrator`, `temporal`, and `temporal_visibility` exist
before continuing. Re-run:

```bash
FORCE=1 aap-demo enable ao
```

Verify databases:

```bash
kubectl exec -n automation-orchestrator orchestrator-postgres-1 -- psql -U postgres -c '\l'
kubectl get database -n automation-orchestrator
```

Check migration job logs:

```bash
kubectl logs -n automation-orchestrator -l job-name --tail=50
kubectl get automationorchestrator -n automation-orchestrator -o yaml
```

### Maintainer: refresh manifests from aapctl

Requires `aapctl` (Technology Preview):

```bash
./addons/ao/scripts/generate-manifests.sh
```

See [Generate aapctl manifests for GitOps](https://docs.redhat.com/en/documentation/automation_orchestrator/2026.8/install-generate_aapctl_manifests_for_gitops).

## Related documentation

- ADR: [`docs/adr/017-ao-addon.md`](../../docs/adr/017-ao-addon.md)
- ADR: [`docs/adr/023-addon-auto-wiring.md`](../../docs/adr/023-addon-auto-wiring.md)
- Manifest index: [`manifests/README.md`](manifests/README.md)
- [Install the operator from the OpenShift CLI](https://docs.redhat.com/en/documentation/automation_orchestrator/2026.8/install-install_the_operator_from_the_openshift_cli)
- [Generate aapctl manifests for GitOps](https://docs.redhat.com/en/documentation/automation_orchestrator/2026.8/install-generate_aapctl_manifests_for_gitops)
- [Manifest application order](https://docs.redhat.com/en/documentation/automation_orchestrator/2026.8/install-understand_aapctl_manifest_application_order)
