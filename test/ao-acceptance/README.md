# AO/AAP-Demo live acceptance

The AO/AAP-Demo acceptance runner validates an already selected live target.
It is opt-in and is intentionally separate from pull-request CI. Fast CI runs
the CLI safeguard, provisioning contracts, and all Python suites through the
discovery loader; those tests use controlled doubles and cannot contact or
provision a cluster. Run the live command from a dedicated,
access-controlled self-hosted runner or an operator workstation with access to
the disposable target.

## Prerequisites

Select the target explicitly and verify that it is the active Kubernetes
context. The runner fails closed before provisioning when these values differ.

```bash
target_context=$(kubectl config current-context)
kubectl config use-context "$target_context"
kubectl auth can-i get namespaces
```

The current identity must be able to read the target namespaces. For live API
checks, provide the three tokens through the process environment; do not add
them to the command line, source tree, or artifacts.

```bash
export AAP_ACCEPTANCE_AAP_TOKEN='...'
export AAP_ACCEPTANCE_AO_TOKEN='...'
export AAP_ACCEPTANCE_MCP_TOKEN='...'
# Optional: a PEM bundle trusted by all AAP, AO, and MCP routes.
export AAP_ACCEPTANCE_CA_FILE=/path/to/cluster-ca.pem
```

The target must provide AAP, Automation Orchestrator, the AAP MCP service, and
the Product Demos addon. The runner discovers managed AAP-Demo resources and
checks each managed execution environment referenced by those resources. A
representative job is launched only when its allowlisted read-only diagnostic
template exists; missing deterministic representatives are reported as
contract drift rather than silently skipped. Each representative job remains
available for a bounded probe so authenticated MCP `tools/list` and custom-CA
handling are exercised from the actual execution-environment pod. AO backend
and worker contexts are probed separately.

The default manifest is success-capable and contains four safe contracts: AO
wiring, an AO-backed AAP read-only workflow, a Product Demos read-only
workflow, and an authenticated read-only MCP tool call. Operational certificate,
disk, Product Demos installer, and ServiceNow scenarios are isolated in
`scenarios/unsafe-operations.json`; selecting that manifest is explicit opt-in
inspection and still reports them as blocked rather than authorizing mutation.

## Run modes

`--context` is required for every non-dry run. Use `--artifact-dir` to keep
results outside the repository. The existing-cluster command is:

```bash
./test/ao-acceptance/run.sh --mode validate --context "$target_context" \
  --artifact-dir /tmp/aap-demo-ao-acceptance
```

- `auto` is the default. It reuses a healthy target and provisions only missing
  prerequisites after context preflight and a check that the required live
  tokens and optional CA-file configuration are present.
- `provision` explicitly runs the required AAP-Demo deployment and addon setup
  before validation. It prepares only the deterministic Product Demos `linux`
  domain before AO, and stops immediately if preparation fails. Use it only
  for a disposable target.
- `validate` never invokes `aap-demo deploy` or `aap-demo enable`; it reports
  unavailable prerequisites and exits without provisioning.
- `--skip-provision` is an alias for `--mode validate`, useful in scripted
  existing-cluster runs.

Missing live tokens or an invalid optional `AAP_ACCEPTANCE_CA_FILE` are
prerequisite failures. When `auto` or `provision` would otherwise prepare a
target, the runner reports that failure before any `aap-demo deploy` or
`aap-demo enable` command.

For a controlled provisioning run, use an explicit context and a disposable
cluster:

```bash
./test/ao-acceptance/run.sh --mode provision --context "$target_context" \
  --artifact-dir /tmp/aap-demo-ao-acceptance
```

To inspect the isolated unsafe contracts without launching them:

```bash
./test/ao-acceptance/run.sh --mode validate --context "$target_context" \
  --scenario-file test/ao-acceptance/scenarios/unsafe-operations.json \
  --artifact-dir /tmp/aap-demo-ao-acceptance-unsafe
```

## Artifacts, cleanup, and triage

The default artifact directory is `artifacts/ao-acceptance`; each run writes
`results.json` and `summary.txt`. Failed runs also attempt to create a
timestamped `failure-*` bundle in that directory. Outputs are redacted and
bounded, but treat them as operational diagnostics and do not publish them
without review.

The runner preserves the cluster after success or failure. It never cleans up
automatically. After reviewing artifacts, clean a disposable target only with
an explicit AAP-Demo lifecycle command, such as `./aap-demo.sh disable ao`,
`./aap-demo.sh clean`, or the irreversible `./aap-demo.sh destroy` when that
is the intended scope.

When a run fails, start with `summary.txt` and the redacted failure bundle:

- `BLOCKED` or exit code `2` means context, credentials, or another required
  prerequisite is unavailable; correct the target selection and access first.
- `contract_drift` means expected managed resources, execution environments,
  or safe representative templates do not match the acceptance contract.
- `execution` or `timeout` means a launched safe check did not complete; use
  the bounded Kubernetes and API observations, then run `./aap-demo.sh
  diagnose` or `must-gather` as appropriate.

Never retry with `provision` merely to hide a `validate` failure. Confirm the
target and the reported prerequisite before making an explicit lifecycle
decision.
