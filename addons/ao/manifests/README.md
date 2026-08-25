# Automation Orchestrator manifests

Checked-in Kubernetes templates applied by [`../deploy.sh`](../deploy.sh). Shapes match
[Automation Orchestrator documentation](https://docs.redhat.com/en/documentation/automation_orchestrator/)
(the GitOps guide used when these files were generated:
[Generate aapctl manifests for GitOps](https://docs.redhat.com/en/documentation/automation_orchestrator/2026.8/install-generate_aapctl_manifests_for_gitops)).
**`deploy.sh` applies them without calling `aapctl`.**

## Files

| File | Stage | Contents |
|------|-------|----------|
| [`operator-subscription.yaml`](operator-subscription.yaml) | 2 — OLM | `OperatorGroup` (AllNamespaces) + `Subscription` |
| [`postgres-cluster.yaml`](postgres-cluster.yaml) | 3 — data | CNPG `Cluster` + `Database` CRs (`orchestrator`, `temporal`, `temporal_visibility`) |
| [`automationorchestrator-cr.yaml`](automationorchestrator-cr.yaml) | 3 — instance | `AutomationOrchestrator` CR |

Placeholders (`__NAMESPACE__`, `__OPERATOR_CHANNEL__`, etc.) are substituted by `deploy.sh` before `kubectl apply`.

## Not checked in (by design)

Database **Secrets are not committed** (Red Hat GitOps guidance: credentials must not live in git).
**`deploy.sh` creates them at install time**—no `aapctl` call is required. Maintainers who regenerate
templates with `./scripts/generate-manifests.sh` / `aapctl --dry-run` must strip Secret manifests before
committing; dry-run output uses one-time passwords.

| Secret | Purpose |
|--------|---------|
| `orchestrator-postgres-secret` | CNPG bootstrap + backend DB connection (`kubernetes.io/basic-auth`) |
| `temporal-postgres-secret` | Temporal DB connection |
| `temporal-visibility-postgres-secret` | Temporal visibility DB connection |
| `automation-orchestrator-pull-secret` | Copied from `redhat-operators-pull-secret` (from `aap-operator` when present, else `~/.aap-demo/pull-secret.txt`) |

CNPG also creates `orchestrator-postgres-ca`, referenced by the instance CR as `caCertSecretRef`.

## Application order

Matches [Understand aapctl manifest application order](https://docs.redhat.com/en/documentation/automation_orchestrator/)
(doc version at generation time:
[application order](https://docs.redhat.com/en/documentation/automation_orchestrator/2026.8/install-understand_aapctl_manifest_application_order)):

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
