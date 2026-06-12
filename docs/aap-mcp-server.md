# AAP MCP Server

## Overview

The Ansible Automation Platform MCP (Model Context Protocol) Server provides programmatic access to AAP functionality
through a standardized MCP interface. This enables AI assistants and other tools to interact with AAP using structured
tools and resources.

The MCP server is a CR managed by the AAP operator. The `AnsibleMCPServer` CRD is included in AAP operator 2.6+.

## Deployment

```bash
aap-demo enable mcp-server
```

Or manually:

```bash
kubectl apply -f addons/mcp-server/mcp-server.yaml
```

### Verify Deployment

```bash
kubectl get ansiblemcpserver -n aap-operator
kubectl get pods -n aap-operator -l app.kubernetes.io/name=aap-mcp-server
kubectl get svc,route -n aap-operator -l app.kubernetes.io/name=aap-mcp-server
```

## Access

- **MCP Endpoint:** https://aap-mcp-aap-operator.apps.127.0.0.1.nip.io/mcp
- **AAP Instance:** https://aap-aap-operator.apps.127.0.0.1.nip.io
- **Username:** admin
- **Password:** stored in secret `aap-admin-password`

## Features

The MCP server provides 100 tools organized into categories:

- **Job Management:** 21 tools
- **Inventory Management:** 17 tools
- **User Management:** 32 tools
- **Security & Compliance:** 12 tools
- **Platform Configuration:** 18 tools

Write operations (POST, DELETE, PATCH) are enabled by default.

## Configuration

| Field | Default | Description |
|-------|---------|-------------|
| `spec.public_base_url` | `https://aap-aap-operator.apps.127.0.0.1.nip.io` | AAP instance URL |
| `spec.allow_write_operations` | `true` | Enable write tools |
| `spec.api.replicas` | `1` | Number of replicas |
| `spec.ingress_type` | `Route` | Ingress method |

## Troubleshooting

```bash
# Check logs
kubectl logs -n aap-operator -l app.kubernetes.io/name=aap-mcp-server

# Check status
kubectl get ansiblemcpserver aap-mcp-server -n aap-operator -o yaml

# Check route
kubectl get route -n aap-operator -l app.kubernetes.io/name=aap-mcp-server
```

## Removal

```bash
aap-demo disable mcp-server
```
