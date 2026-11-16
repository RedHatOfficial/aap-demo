# Automation Orchestrator manifests

Checked-in Kubernetes templates applied by [`../deploy.sh`](../deploy.sh). The operator is installed
with an OLM Subscription, the supported CLI method in the
[Automation Orchestrator documentation](https://docs.redhat.com/en/documentation/automation_orchestrator/).
The instance CR follows the CRD (`kubectl explain automationorchestrator.spec`).

## Files

| File | Stage | Contents |
|------|-------|----------|
| [`operator-subscription.yaml`](operator-subscription.yaml) | 2 — OLM | `OperatorGroup` (AllNamespaces) + `Subscription` |
| [`operator-rbac.yaml`](operator-rbac.yaml) | 2 — OLM compatibility | Explicit cluster permissions for the operator service account on MicroShift |
| [`postgres.yaml`](postgres.yaml) | 3 — data | One `StatefulSet` of `rhel9/postgresql-15`, its `Service`, and TLS from service-ca (ADR-043) |
| [`automationorchestrator-cr.yaml`](automationorchestrator-cr.yaml) | 3 — instance | `AutomationOrchestrator` CR |

Placeholders (`__NAMESPACE__`, `__OPERATOR_CHANNEL__`, etc.) are substituted by `deploy.sh` before `kubectl apply`.

## Not checked in (by design)

Database **Secrets are not committed**. `deploy.sh` creates them at install time and reuses the
PostgreSQL password on a re-run.

| Secret | Purpose |
|--------|---------|
| `orchestrator-postgres-secret` | PostgreSQL user and backend DB connection (`kubernetes.io/basic-auth`) |
| `temporal-postgres-secret` | Temporal DB connection |
| `temporal-visibility-postgres-secret` | Temporal visibility DB connection |
| `orchestrator-postgres-ca` | The service-ca CA, for the CR's `caCertSecretRef` and `sslMode: verify-ca` |
| `orchestrator-postgres-tls` | PostgreSQL's serving certificate, issued by service-ca |
| `automation-orchestrator-initial-admin-password` | Explicitly referenced bootstrap password, restored across re-enable |
| `automation-orchestrator-pull-secret` | Copied from `redhat-operators-pull-secret` in `aap-operator` |

## PostgreSQL image

`deploy.sh` reuses the `rhel9/postgresql-15` image AAP's own PostgreSQL StatefulSet runs, which is
already on the node. When it can't be read, it uses `registry.redhat.io/rhel9/postgresql-15`.
`AO_POSTGRES_IMAGE` overrides both.

## Application order

1. Namespace + SCC grants (script)
2. AO-local `CatalogSource` copy (MicroShift only — script)
3. Postgres secrets + [`postgres.yaml`](postgres.yaml), then the `orchestrator-postgres-ca` Secret
4. [`operator-subscription.yaml`](operator-subscription.yaml) — wait for CSV, approve InstallPlan
5. Pull secret link + [`automationorchestrator-cr.yaml`](automationorchestrator-cr.yaml)
