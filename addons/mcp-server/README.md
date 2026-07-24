# AAP MCP Server Addon

Deploys the AAP MCP (Model Context Protocol) server, enabling AI assistants to interact with your AAP deployment
via structured APIs.

## SECURITY NOTICE — DEVELOPMENT ENVIRONMENT ONLY

**This addon is intended for LOCAL DEVELOPMENT ONLY and should NEVER be used in production environments.**

The MCP server deployment includes the following characteristics for dev convenience:

- **Self-signed certificates are trusted** using `NODE_EXTRA_CA_CERTS` pointing to the ingress CA
- **Router ClusterIP addresses** may change on cluster rebuild, causing stale DNS entries

These configurations **bypass critical security protections** and are acceptable ONLY because:

- The cluster runs locally on your development machine
- Routes use `127.0.0.1.nip.io` (localhost)
- The environment is isolated and ephemeral
- This is explicitly a testing/development tool

**DO NOT:**

- Use this configuration in production environments
- Deploy this to shared clusters
- Expose the MCP server outside of localhost
- Copy these patterns for production deployments

## Usage

```bash
# Deploy MCP server
aap-demo enable mcp-server

# Check status
kubectl get ansiblemcpserver -n aap-operator

# View logs
kubectl logs -n aap-operator -l app.kubernetes.io/name=aap-mcp-server
```

The addon automatically:

1. Deploys the AnsibleMCPServer CR
2. Configures ingress CA trust for token validation
3. Generates an OAuth token for Claude Code
4. Configures the MCP server in your Claude Code settings (if `claude` CLI is available)

## Configuration

The MCP server connects to your AAP deployment using:

- **Endpoint**: `https://aap-mcp-aap-operator.apps.127.0.0.1.nip.io/mcp`
- **Authentication**: Bearer token (OAuth from AAP Gateway)
- **TLS**: Trusts self-signed ingress CA via `NODE_EXTRA_CA_CERTS`

See [ADR 011: MCP Server Addon](../../docs/adr/011-mcp-server-addon.md) for design details.

## Removal

```bash
aap-demo disable mcp-server
```

This removes the AnsibleMCPServer CR and related resources. To remove from Claude Code:

```bash
claude mcp remove aap-demo --scope user
```
