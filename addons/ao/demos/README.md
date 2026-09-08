# Automation Orchestrator demos

These workflow exports are downloaded at enable time from
[ansible-tmm/aap-orchestrator-demos](https://github.com/ansible-tmm/aap-orchestrator-demos),
commit `abcc1a1482a` (resolves to the immutable upstream commit).

`aap-demo enable ao` downloads and synchronizes every JSON file from the upstream
`demos/` directory after the AO,
AAP, and MCP integrations are ready. Synchronization is idempotent and updates an
existing workflow by name. At import time, AAP job-template nodes receive the
auto-wired AAP credential and `aap-demo AAP` integration, old `config` exports are
upgraded to `parameters`, and
agent nodes with empty tool selections use all tools from the auto-wired MCP
integration.

The upstream demos that call ServiceNow, Lightspeed, or an LLM still require those
external integrations and credentials to be configured in AO. Environment-specific
LLM credential IDs are omitted unless `AO_AGENT_CREDENTIAL_ID` is set; this avoids
importing stale IDs from another AO instance. The AAP and MCP configuration used by
the demos is created automatically from the local `aap-demo` deployment; no token is
stored in this directory.

The normal synchronization path is the `Sync AO Workflows from TMM` job template in
the `AAP Demo Control Plane` project. It runs
[`playbooks/sync-ao-demos.yml`](../playbooks/sync-ao-demos.yml) from AAP and uses the
same pinned upstream source as the addon bootstrap fallback.
