# ADR-028: Bind AO Agentic Tasks to the Selected LLM Provider Model

**Status**: Accepted

**Date**: 2026-09-24

**Authors**: Chad Ferman

## Context

aap-demo configures an LLM provider for Automation Orchestrator (AO) and synchronizes
agentic demo workflows. AO task-agent nodes select an LLM through provider-specific
resources, not through a free-form model name. A node must carry the provider
`integration_id`, the authentication `credential_id`, and the discovered model resource
`llm_model_id`.

Previously, synchronization supplied the credential and model resource but omitted the
provider integration. The Workflow Builder could therefore display the configured model
in the setup prompt while leaving the Model selector empty on an agentic task.

## Decision

Every synchronized AO agentic node receives the complete provider binding:

```json
{
  "integration_id": "<LLM provider integration UUID>",
  "credential_id": "<AO credential UUID>",
  "llm_model_id": "<AO LLM model UUID>"
}
```

The implementation applies this consistently across all synchronization paths:

- direct demo import in `addons/ao/scripts/import-demos.py`;
- the AAP control-plane synchronization playbook;
- rebinding of existing `aap-demo` workflows during `aap-demo wire`;
- both external and Ollama providers.

The model resource UUID is resolved from the selected provider integration by matching
the configured model identifier. For external providers, the default identifier remains
`gpt-5.6-luna`. Stale or legacy free-form `model` fields are removed so AO does not retain
an environment-specific selection that conflicts with the local provider.

## Consequences

### Positive

- The Workflow Builder opens with the provider and model selected on every demo agentic task.
- Newly imported and already-existing workflows use the same binding behavior.
- Provider credentials remain referenced by UUID; secret values are never placed in workflow definitions.
- Re-running `aap-demo wire` repairs incomplete bindings idempotently.

### Negative

- Synchronization must resolve three related AO resources instead of only a model name.
- If the provider integration, credential, or model cannot be resolved, workflow rebinding is
  skipped with a warning rather than writing a partial binding.
- Provider changes require re-running workflow synchronization or `aap-demo wire`.

## Alternatives considered

**Set only `llm_model_id`**: Rejected because the Workflow Builder needs the provider
integration context to present the selected model consistently.

**Keep the free-form `model` field**: Rejected because AO task-agent configuration uses
`llm_model_id`, and upstream model names may refer to a different environment or provider.

**Bind only during initial import**: Rejected because existing workflows remain incomplete
after provider configuration changes or upgrades.

## References

- [`includes/addon-wire.sh`](../../includes/addon-wire.sh)
- [`addons/ao/scripts/import-demos.py`](../../addons/ao/scripts/import-demos.py)
- [`addons/ao/playbooks/tasks/sync_workflow.yml`](../../addons/ao/playbooks/tasks/sync_workflow.yml)
- [AO node type catalog: Task Agent configuration](https://docs.redhat.com/en/documentation/automation_orchestrator/2026.8/reference-ref_node_type_catalog_settings_and_common_output_fields)
- ADR-017: Automation Orchestrator addon
- ADR-023: Addon auto-wiring
