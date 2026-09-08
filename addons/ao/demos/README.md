# Automation Orchestrator demos

These workflow exports are vendored from
[ansible-tmm/aap-orchestrator-demos](https://github.com/ansible-tmm/aap-orchestrator-demos),
commit `a1cc1a1482a42a94488a3f9c36aeb31eea9e36a1`.

`aap-demo enable ao` synchronizes every JSON file in this directory after the AO,
AAP, and MCP integrations are ready. Synchronization is idempotent and updates an
existing workflow by name. At import time, AAP job-template nodes receive the
auto-wired AAP credential, old `config` exports are upgraded to `parameters`, and
agent nodes with empty tool selections use all tools from the auto-wired MCP
integration.

The upstream demos that call ServiceNow, Lightspeed, or an LLM still require those
external integrations and credentials to be configured in AO. The AAP and MCP
configuration used by the demos is created automatically from the local `aap-demo`
deployment; no token is stored in this directory.
