# AAP MCP Server

## Overview

The Ansible Automation Platform (AAP) Model Context Protocol (MCP) server
exposes AAP capabilities to MCP-compatible AI clients through a structured
tool and resource interface. It is deployed as an `AnsibleMCPServer` custom
resource managed by the AAP operator.

This project configures the MCP server for a local OpenShift Local/MicroShift
development environment. The local certificate, DNS, and routing configuration
described here must not be copied to production.

## Quick Start

### Prerequisites

- A running `aap-demo` cluster
- AAP deployed successfully
- The AAP operator and `AnsibleMCPServer` CRD available
- A valid Red Hat registry pull secret

Check the environment before enabling the add-on:

```bash
aap-demo status
aap-demo diagnose
```

Enable the MCP server:

```bash
aap-demo enable mcp-server
```

Automation Orchestrator (AO) requires this add-on. Running
`aap-demo enable ao` installs it automatically when needed.

### What the Installer Configures

The supported installer:

1. Creates or updates the `AnsibleMCPServer` resource.
2. Derives the MCP and AAP route domains from the live AAP route.
3. Uses the in-cluster AAP service for token validation on MicroShift.
4. Mounts the local ingress CA and configures `NODE_EXTRA_CA_CERTS`.
5. Waits for the MCP deployment to become ready.
6. Generates an AAP OAuth token with write scope.
7. Configures Claude Code automatically when the `claude` CLI is available.
8. Wires the MCP integration into AO when AO is installed.
9. Disables outbound analytics delivery for the isolated local cluster.

Re-running the enable command is safe and refreshes the client OAuth token:

```bash
aap-demo enable mcp-server
```

## Discover Endpoints

Do not assume that route hostnames remain unchanged after rebuilding the
cluster. Discover them from the live environment:

```bash
aap-demo status
```

For scripts, use the secret-free JSON inventory:

```bash
aap-demo status --json |
  jq -r '.routes[] | select(.name | test("mcp")) | .url + "/mcp"'
```

The standard local routes normally resemble:

- MCP endpoint: `https://aap-mcp-aap-operator.apps.127.0.0.1.nip.io/mcp`
- AAP gateway: `https://aap-aap-operator.apps.127.0.0.1.nip.io`

The MCP endpoint uses Streamable HTTP. A basic browser request is not a
complete MCP protocol test and may return an authentication or method error
even when the server is healthy.

## Authentication

MCP clients authenticate with an AAP OAuth bearer token, not the AAP admin
password. The installer creates a token and supplies it to supported client
configuration.

Tokens expire. If a previously working client begins returning `401` or
`403`, refresh its token by running:

```bash
aap-demo enable mcp-server
```

The AAP admin password remains stored in the Kubernetes Secret referenced by
the AAP custom resource. Use `aap-demo status --show-secrets` when interactive credentials
are required. Do not put passwords or bearer tokens in documentation, source
control, or support bundles.

## Client Configuration

When Claude Code is installed, `aap-demo enable mcp-server` adds or updates the
`aap-demo` MCP server in user scope and verifies its connection.

Inspect the configured client:

```bash
claude mcp get aap-demo
```

The installer also configures the local ingress CA for Node.js clients through
`NODE_EXTRA_CA_CERTS`. Restart the terminal after the first installation if
the installer reports that it updated the shell profile.

Other MCP clients need:

- Transport: Streamable HTTP
- URL: the discovered MCP route with `/mcp`
- Header: `Authorization: Bearer <AAP OAuth token>`
- Trust for `$HOME/.aap-demo/crc-ingress-ca.crt`

Client-specific configuration formats vary. Prefer a client's secret store or
environment-variable support instead of writing the token directly into a
configuration file.

## Verify Deployment

Export the kubeconfig reported by `aap-demo status` before using `kubectl`.
For the standard local MicroShift environment:

```bash
export KUBECONFIG="$HOME/.aap-demo/kubeconfig.microshift"
kubectl config current-context
```

Verify the custom resource, deployment, service, route, and ready endpoint:

```bash
kubectl get ansiblemcpserver aap-mcp-server -n aap-operator
kubectl rollout status deployment/aap-mcp-server \
  -n aap-operator --timeout=120s
kubectl get service aap-mcp-server -n aap-operator -o wide
kubectl get route -n aap-operator \
  -l app.kubernetes.io/name=aap-mcp-server
kubectl get endpoints aap-mcp-server -n aap-operator
```

Verify the configured MCP client separately:

```bash
claude mcp get aap-demo
```

MCP resources and tools are discovered only after an authenticated MCP client
session is established. An empty or failed client discovery result should be
investigated with both the Kubernetes and client checks above.

## Configuration

The checked-in development manifest is
[`addons/mcp-server/mcp-server.yaml`](../addons/mcp-server/mcp-server.yaml).
The installer renders environment-specific route and AAP values before
applying it.

| Field | Development default | Description |
|---|---|---|
| `spec.public_base_url` | Derived from the live environment | AAP URL used by the MCP server |
| `spec.allow_write_operations` | `true` | Enables tools that modify AAP |
| `spec.api.replicas` | `1` | MCP API replica count |
| `spec.ingress_type` | `Route` | OpenShift exposure method |
| `spec.service_type` | `ClusterIP` | Internal service type |
| `spec.no_log` | `true` | Reduces sensitive request logging |
| `spec.extra_settings` | Blank `ANALYTICS_KEY` override | Disables unavailable outbound analytics in the local cluster |

Write operations are enabled for this local development environment. Review
the manifest and use least-privilege OAuth scopes before adapting the
deployment for another environment.

## Manual Installation

The supported path is `aap-demo enable mcp-server`. Applying the custom
resource directly is useful only for manifest development:

```bash
kubectl apply -f addons/mcp-server/mcp-server.yaml
```

Direct application does **not** perform dynamic route rendering, MicroShift
service rewrites, ingress CA injection, OAuth token creation, client
configuration, readiness checks, or AO wiring.

## Troubleshooting

Start with:

```bash
aap-demo diagnose
aap-demo status --json |
  jq '{cluster, routes: [.routes[] | select(.name | test("mcp"))]}'
```

### `localhost:8080` connection refused

`kubectl` is not using a kubeconfig with a configured cluster. This error
occurs before Kubernetes queries the MCP resources; it does not indicate an
MCP server failure.

```bash
export KUBECONFIG="$HOME/.aap-demo/kubeconfig.microshift"
kubectl config current-context
kubectl get ansiblemcpserver -n aap-operator
```

Use the kubeconfig path reported by `aap-demo status` if it differs from the
standard path.

### TLS or certificate errors

Check that the ingress CA exists and restart the terminal after the installer
updates the shell profile:

```bash
test -s "$HOME/.aap-demo/crc-ingress-ca.crt"
echo "$NODE_EXTRA_CA_CERTS"
```

Re-run the installer to restore the MCP pod CA mount and client configuration:

```bash
aap-demo enable mcp-server
```

Do not disable TLS verification as the permanent fix.

### `401 Unauthorized` or `403 Forbidden`

The OAuth token may be missing, expired, or lack the required scope:

```bash
aap-demo enable mcp-server
claude mcp get aap-demo
```

### Route resolves but the client cannot connect

Confirm that the route has a service endpoint and that the pod is ready:

```bash
kubectl get route,service,endpoints -n aap-operator |
  grep -E 'NAME|mcp'
kubectl get pods -n aap-operator \
  -l app.kubernetes.io/name=aap-mcp-server
```

After a cluster rebuild, stale DNS or route wiring can be repaired with:

```bash
aap-demo wire
```

### Pod or custom resource is unhealthy

```bash
kubectl describe ansiblemcpserver aap-mcp-server -n aap-operator
kubectl describe deployment aap-mcp-server -n aap-operator
kubectl logs -n aap-operator \
  -l app.kubernetes.io/name=aap-mcp-server --tail=200
kubectl get events -n aap-operator \
  --sort-by=.metadata.creationTimestamp | tail -30
```

Common causes include a missing pull secret, an unavailable AAP route, an
incorrect CA mount, or insufficient cluster resources.

The development manifest disables outbound analytics because the local cluster
does not resolve `api.segment.io`. Without the override, the server remains
functional but periodically logs non-fatal analytics delivery errors.

## Collect Support Information

Generate a redacted report before sharing environment details:

```bash
aap-demo system-info --redact --output /tmp/aap-support.md
```

For deeper diagnostics:

```bash
aap-demo must-gather
```

Review diagnostic output before sharing it. Do not include OAuth tokens,
passwords, pull secrets, or unredacted system-information reports.

## Removal

```bash
aap-demo disable mcp-server
```

AO depends on the MCP server. Disabling it while AO remains enabled breaks that
integration. Re-enable AO or the MCP add-on to restore the dependency and
rewire integrations:

```bash
aap-demo enable ao
```
