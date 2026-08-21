# Automation Orchestrator manifests

Checked-in Kubernetes templates applied by [`../deploy.sh`](../deploy.sh). They follow the
resource shapes from
[`aapctl install ao --dry-run`](https://docs.redhat.com/en/documentation/automation_orchestrator/2026.8/install-generate_aapctl_manifests_for_gitops)
but **do not require `aapctl` at install time**.

## Files

| File | Stage | Contents |
|------|-------|----------|
| [`operator-subscription.yaml`](operator-subscription.yaml) | 2 — OLM | `OperatorGroup` (AllNamespaces) + `Subscription` |
| [`postgres-cluster.yaml`](postgres-cluster.yaml) | 3 — data | CNPG `Cluster` + `Database` CRs (`orchestrator`, `temporal`, `temporal_visibility`) |
| [`automationorchestrator-cr.yaml`](automationorchestrator-cr.yaml) | 3 — instance | `AutomationOrchestrator` CR |

Placeholders (`__NAMESPACE__`, `__OPERATOR_CHANNEL__`, etc.) are substituted by `deploy.sh` before `kubectl apply`.

## Not checked in (by design)

Per Red Hat GitOps guidance, **database Secrets are not committed** — passwords change on every
`aapctl --dry-run` invocation. `deploy.sh` creates these at install time:

| Secret | Purpose |
|--------|---------|
| `orchestrator-postgres-secret` | CNPG bootstrap + backend DB connection (`kubernetes.io/basic-auth`) |
| `temporal-postgres-secret` | Temporal DB connection |
| `temporal-visibility-postgres-secret` | Temporal visibility DB connection |
| `automation-orchestrator-pull-secret` | Copied from `redhat-operators-pull-secret` in `aap-operator` |

CNPG also creates `orchestrator-postgres-ca`, referenced by the instance CR as `caCertSecretRef`.

## Application order

Matches [Understand aapctl manifest application order](https://docs.redhat.com/en/documentation/automation_orchestrator/2026.8/install-understand_aapctl_manifest_application_order):

1. Namespace + SCC grants (script)
2. AO-local `CatalogSource` copy (MicroShift only — script)
3. CloudNativePG operator from upstream manifest (script)
4. Postgres secrets + [`postgres-cluster.yaml`](postgres-cluster.yaml)
5. [`operator-subscription.yaml`](operator-subscription.yaml) — wait for CSV, approve InstallPlan
6. Pull secret link + [`automationorchestrator-cr.yaml`](automationorchestrator-cr.yaml)

## Regenerating templates

Maintainers with `aapctl` installed:

```bash
./addons/ao/scripts/generate-manifests.sh
```

Review the dry-run output, then update the YAML files above (strip Secrets before committing).
