# ADR-023: Addon Auto-Wiring (`aap-demo wire`)

**Status**: Accepted

**Date**: 2026-08-26

**Authors**: Chad Ferman

## Context

aap-demo installs optional capabilities as independent addons (ADR-008): product demos (APD),
Automation Orchestrator (AO), MCP server, portal, and others. Enabling them separately still
left manual follow-up in Ansible Automation Platform Controller and Automation Orchestrator:

- APD demo job templates expect **OpenShift Credential**, **AAP Credential**, and optional Galaxy
  credentials with hosts that work from execution environment pods on MicroShift.
- AO integration registration fails SSRF validation when `base_url` resolves to private or
  reserved addresses unless the backend allow-list is configured first.
- AO workflow nodes and proxy APIs need a registered **Ansible Automation Platform** integration
  plus a Syntara credential; MCP integration is required for AO agent workflows.

Upstream APD addresses AO network access in
[`infrastructure/ao/network-access.yml`](https://github.com/ansible/product-demos/blob/main/infrastructure/ao/network-access.yml)
under the Infrastructure category, which aap-demo does not install by default. Operators had to
run that job ad hoc or configure integrations manually in the AO UI.

Additionally, AO proxy endpoints (`/api/v1/proxies/aap/*`) return `AAP_NOT_CONFIGURED` when called
without **both** `integration_id` and `credential_id` query parameters, even when Configuration →
Integrations shows an integration as **Available**. The workflow builder must select the
integration and health-check credential on each AAP node.

## Decision

Add cross-addon auto-wiring as a shared module and CLI command.

### Module and command

| Piece | Location | Behavior |
|-------|----------|----------|
| Wiring module | [`includes/addon-wire.sh`](../../includes/addon-wire.sh) | `aap_demo_wire()` — idempotent API calls |
| CLI command | `aap-demo wire` | Runs wiring on demand |
| Post-enable hook | `cmd_enable` in [`aap-demo.sh`](../../aap-demo.sh) | Best-effort `aap_demo_wire` after each successful enable |

### Wiring order

```text
aap-demo wire
  ├─ APD: AAP Credential (in-cluster URL for EE pods)
  ├─ APD: OpenShift Credential (SA token + API host)
  ├─ APD: Galaxy credentials (if ~/.aap-demo/galaxy-token exists)
  ├─ AO:  APP_INTEGRATION_URL_ALLOWED_HOSTS + APP_OIDC_ALLOW_PRIVATE_NETWORKS (backend patch)
  ├─ AO:  Integration "aap-demo AAP" (route URL + gateway OAuth token)
  └─ AO:  Integration "aap-demo MCP Server" (route /mcp URL + bearer token; tools enabled)
```

### AO SSRF allow-list

Before creating integrations, `wire_ao_network_access()` patches AO backend deployments with:

- `APP_INTEGRATION_URL_ALLOWED_HOSTS` — JSON array of AAP route hostname, AO route hostname,
  `aap.<namespace>.svc.cluster.local`, and MCP route hostname when deployed
- `APP_OIDC_ALLOW_PRIVATE_NETWORKS=true`

This mirrors upstream APD `network-access.yml` intent so co-located AAP/MCP URLs pass AO SSRF
validation on MicroShift.

### AO ↔ AAP and MCP integrations

- Mint write-scoped gateway OAuth tokens via AAP gateway API.
- Create or update global AO credentials and integrations named **`aap-demo AAP`** and
  **`aap-demo MCP Server`**.
- Validate integrations via AO `/integrations/{id}/validate`.
- Enable all discovered MCP tools on the MCP integration.

Integration `base_url` uses the **AAP route URL** (HTTPS nip.io on MicroShift), not only the
in-cluster service URL, because the allow-list and workflow proxy layer expect reachable route
hostnames.

### AO dependency on MCP

`aap-demo enable ao` calls `_ensure_addon_dependency mcp-server` so MCP is installed before AO
wiring. If AO is deployed and MCP integration wiring fails, `aap_demo_wire` returns non-zero.

### APD credential helpers

[`addons/product-demos-base/lib.sh`](../../addons/product-demos-base/lib.sh) exposes
`apd_ensure_openshift_credential`, `apd_ensure_aap_credential`, and Galaxy helpers invoked from
addon-wire. OpenShift and AAP callback credentials use in-cluster URLs where EE pods cannot reach
external routes.

## Consequences

### Positive

- Single command (`aap-demo wire`) or automatic run after `enable` completes cross-addon setup.
- Idempotent PATCH/create; safe to re-run.
- Removes need for ad hoc APD Infrastructure AO network job on MicroShift demos.
- Validated on MicroShift: integrations reach **Available**; proxy APIs work with dual query IDs.

### Negative

- AO backend env patch triggers deployment rollout restart.
- Hostname allow-list is MicroShift-oriented (nip.io routes + in-cluster svc).
- MCP is a hard dependency for AO in aap-demo (extra addon install time and resources).
- AO env patch uses `kubectl patch` on deployments (not operator CR fields).

### Neutral

- Does not register upstream APD Infrastructure category job templates.
- AWS, Satellite, SSH/WinRM, and Insights credentials still require manual AAP UI configuration.
- Experimental in-cluster AO wiring playbook is out of scope for the default path.

## Alternatives considered

**Run upstream APD `Infrastructure | AO Network Configuration | Install` job**: Uses official
content but requires Infrastructure category registration and a manual or custom job launch.
Rejected as the default path; logic inlined into `wire_ao_network_access()`.

**In-cluster `.svc` URLs only for AO integrations**: Fails AO SSRF checks without allow-list and
does not match workflow proxy expectations for route hostnames. Rejected.

**Ansible playbook executed inside AO backend pod**: Implemented experimentally as
`addons/ao/playbooks/wire_ao_aap_incluster.yml` but rejected for the default path — shell module
from the laptop is sufficient once SSRF allow-list is applied.

**Manual Configuration → Integrations wizard only**: Matches Red Hat docs but adds friction for
every demo install. Rejected as sole path; API wiring automates the same outcome.

## References

- [`includes/addon-wire.sh`](../../includes/addon-wire.sh)
- [`addons/ao/README.md`](../../addons/ao/README.md)
- [Configure an Ansible Automation Platform integration (AO 2026.8)](https://docs.redhat.com/en/documentation/automation_orchestrator/2026.8/configure-configure_an_ansible_automation_platform_integration)
- [APD infrastructure/ao/network-access.yml](https://github.com/ansible/product-demos/blob/main/infrastructure/ao/network-access.yml)
- ADR-008: Addon system
- ADR-011: MCP server addon
- ADR-017: Automation Orchestrator addon
- ADR-018: Product demos addon
