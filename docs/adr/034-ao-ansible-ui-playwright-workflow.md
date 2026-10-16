# ADR-034: AO Workflow for Test-by-Test Ansible UI Playwright Analysis

**Status**: Proposed

**Date**: 2026-10-16

**Authors**: aap-demo maintainers

## Context

The Ansible UI repository contains Playwright tests that describe realistic AAP
resource setup, UI interactions, API assertions, cleanup, and known capability
gaps. We want Automation Orchestrator (AO) to turn those tests into an
agent-assisted validation workflow.

A first live prototype proved the concept, but also exposed operational limits:

- sending an entire Playwright source file to one agent exceeded AO's 10,000
  character prompt limit;
- ranged HTTP requests were applied to compressed responses until the workflow
  explicitly requested `Accept-Encoding: identity`;
- exposing all 144 MCP tools exceeded the provider's maximum of 128 tools;
- the configured reasoning model rejected tool calls through AO's Chat
  Completions path;
- a shared audit step could not safely resolve output from whichever execution
  branch had been selected.

The workflow also needs a safe operating model. Read-only analysis should be the
default, mutation execution must be explicit and scoped to unique test resources,
and every result must identify the source ref, test path, selected test, execution
mode, and unsupported operations.

## Decision

We will maintain a version-controlled AO workflow definition in the aap-demo
repository and synchronize it idempotently with the existing AO demo import and
control-plane paths.

The workflow will process one Playwright test case per execution. Its trigger
contract will include:

```json
{
  "ref": "devel",
  "test_path": "playwright/tests/integration/.../workflow-job-templates.spec.ts",
  "test_title": "can edit a workflow job template from the details view",
  "target_name": "ao-playwright-validation-<unique-suffix>",
  "execute_mutations": false
}
```

The workflow graph will use bounded stages:

1. fetch the source file in identity-encoded byte ranges;
2. analyze each chunk independently without MCP tools;
3. converge the chunk reports into a bounded test catalog;
4. select and synthesize exactly one requested test case, including the nearest
   applicable setup and teardown hooks;
5. stop with a structured selection error when `test_title` is missing or does
   not uniquely match a discovered test;
6. switch between read-only discovery and explicitly requested mutations;
7. audit through a branch-specific read-only agent and converge the audit result.

Agentic nodes that use MCP will use `tool_selection_strategy: SELECTED` with a
small, checked-in allowlist of relevant AAP list/retrieve tools and supported
mutation tools. The analysis/synthesis nodes may use the configured reasoning
model. MCP executor and audit nodes will use a provider model that supports
non-reasoning tool calls through the AO Chat Completions integration. Credentials,
integration IDs, model IDs, and API keys remain environment-provided and are never
committed.

The importer and AAP synchronization playbook will treat the checked-in workflow
as a local aap-demo workflow in addition to the pinned upstream demo exports.
Normalization will preserve the existing provider binding, integration connection,
project selection, and idempotent update behavior while applying the workflow's
selected MCP tools and branch-specific model choices.

## Consequences

### Positive

- Each execution has a bounded prompt and a clear test-case boundary.
- A failed test selection does not spend tokens or mutate AAP resources.
- The safe read-only path is the default and is independently auditable.
- Tool exposure stays below the provider limit and is reviewable in Git.
- The workflow can be recreated after AO reinstall instead of living only in a
  development cluster.
- The same source definition can be imported during local enablement and through
  the AAP control-plane synchronization path.

### Negative

- A single Playwright file requires an additional discovery step before a test can
  run.
- The checked-in MCP allowlist must be updated when the MCP server renames tools
  or when new test capabilities are added.
- Read-only and mutation executor/audit nodes intentionally use different model
  bindings from the analysis nodes.
- Live validation still requires AO, AAP, MCP, and access to the public GitHub
  source; unit tests cannot prove provider or cluster behavior.

### Neutral

- Playwright remains the source of intent; AO does not replace the browser tests.
- AAP remains the system of record for AAP resources and execution governance.
- Existing upstream AO demos continue to be imported and normalized unchanged.

## Alternatives considered

**Send the entire Playwright file to one agent**: Rejected because it exceeds AO's
prompt limit for realistic files and makes failures difficult to isolate.

**Create one static AO workflow for every Playwright test**: Rejected because it
duplicates graph logic and makes upstream test changes expensive to absorb. A
single reusable workflow with a test selector preserves test-level isolation
without multiplying workflow definitions.

**Expose every MCP tool to every agent**: Rejected because the current integration
exposes more tools than the provider allows and increases accidental mutation risk.

**Use the reasoning model for MCP execution**: Rejected for the current AO
Chat Completions integration because the provider rejects function tools when
`reasoning_effort` is present.

**Run mutations by default**: Rejected because analysis of a Playwright test must
not create, update, launch, or delete AAP resources without an explicit caller
choice and scoped cleanup policy.

## References

- [Ansible UI Playwright tests](https://github.com/ansible/ansible-ui)
- [`addons/ao/scripts/import-demos.py`](../../addons/ao/scripts/import-demos.py)
- [`addons/ao/playbooks/tasks/sync_workflow.yml`](../../addons/ao/playbooks/tasks/sync_workflow.yml)
- [`addons/ao/demos/README.md`](../ao/demos/README.md)
- [ADR-017: Automation Orchestrator Addon](017-ao-addon.md)
- [ADR-023: Addon Auto-Wiring](023-addon-auto-wiring.md)
- [ADR-028: AO Agentic Task Model Binding](028-ao-agentic-model-binding.md)
