---
name: aap-addon-development
description: >
  Guide addon creation for the aap-demo project with proper structure, dependencies,
  and CLI integration. Activates when users want to create new addons, understand
  addon architecture, or debug addon issues. Ensures addons follow project conventions
  and integrate correctly with the enable/disable system.
allowed-tools:
  - Bash(find *)
  - Bash(ls *)
  - Bash(grep *)
  - Bash(aap-demo *)
  - Read
argument-hint: "[addon name or operation]"
---

# aap-addon-development Skill

Guide addon creation for the aap-demo project with proper structure, dependencies, and integration with the aap-demo CLI.

## What is an Addon?

Addons are modular, optional components that extend aap-demo functionality beyond the core AAP deployment. They are:

- **Self-contained** in their own directory under `addons/`
- **Independently deployable** via `aap-demo enable <addon>`
- **Removable** via `aap-demo disable <addon>`
- **Persistent** across cluster restarts (state stored in `~/.aap-demo/config`)
- **Can depend** on other addons or AAP itself

## When to Create an Addon

Create an addon for:

- **Optional AAP integrations** (MCP server, portal, automation orchestrator)
- **Development tools** (console, registry, local cache)
- **Demo content** (product demos, APME playbooks)
- **External services** (Ollama, OPA, Prometheus)
- **Fleet management** (VM-based managed nodes)

**Don't create an addon for**:
- Core AAP functionality (belongs in main deployment)
- One-off scripts (use bash script in includes/ instead)
- Simple configuration (add to aap-demo.sh directly)

## Addon Architecture

Addons consist of:

```
addons/<addon-name>/
├── deploy.sh           # Required: deployment script
├── README.md           # Recommended: documentation
├── manifests/          # Optional: Kubernetes YAML
│   └── *.yaml
├── config/             # Optional: configuration templates
│   └── *.template
└── scripts/            # Optional: helper scripts
    └── *.sh
```

### Required: deploy.sh

Every addon must have an executable `deploy.sh` script that:

1. **Deploys the addon** (default action)
2. **Removes the addon** (`--delete` flag)
3. **Handles errors gracefully** (`set -e`)
4. **Validates prerequisites** (cluster connectivity, dependencies)
5. **Provides clear output** (success/failure indicators)

### Recommended: README.md

Addon-specific documentation should include:

- Purpose and use case
- Quick start commands
- Prerequisites and dependencies
- Configuration options
- Architecture overview
- Troubleshooting guide

### Optional: manifests/ and config/

- **manifests/** — Kubernetes resources (CRs, ConfigMaps, Secrets, etc.)
- **config/** — Template files requiring variable substitution

## Workflow

### 1. Validate Addon Name

**Naming rules**:
- Lowercase only
- Use hyphens (not underscores)
- Descriptive but concise
- No conflicts with existing addons

**Check for conflicts**:
```bash
ls -1 addons/
```

**Current addons**:
- fleet
- mcp-server
- portal
- portal-operator
- setup-pah
- ao (automation orchestrator)
- apme-eap
- local-cache
- product-demos
- product-demo-satellite
- opa
- ollama

**Good names**:
- `grafana` (simple service)
- `gitlab-runner` (external integration)
- `demo-security` (demo content category)

**Bad names**:
- `Grafana` (wrong case)
- `gitlab_runner` (underscores)
- `addon-grafana` (redundant prefix)
- `new-addon` (not descriptive)

### 2. Determine Dependencies

**Does addon require AAP?**

If yes, add comment header to deploy.sh:
```bash
# ADDON_REQUIRES_AAP=true
```

**Does addon depend on other addons?**

Example: AO addon requires mcp-server. In deploy.sh:
```bash
# Check if mcp-server is enabled
if ! aap-demo status | grep -q "mcp-server"; then
  echo "Enabling prerequisite: mcp-server"
  aap-demo enable mcp-server
fi
```

**Does addon require external tools?**

Examples:
- `helm` (portal addon)
- `ansible-galaxy` (product-demos)
- `jq` (various addons)

Check for tools in deploy.sh:
```bash
if ! command -v helm &>/dev/null; then
  echo "ERROR: helm is required but not installed"
  exit 1
fi
```

**Does addon require specific infrastructure?**

Examples:
- OLM installed (`aap-demo enable olm`)
- Specific StorageClass
- NetworkPolicy support
- LoadBalancer support

### 3. Create Addon Directory Structure

```bash
# Create addon directory
mkdir -p addons/<addon-name>

# Create subdirectories if needed
mkdir -p addons/<addon-name>/manifests
mkdir -p addons/<addon-name>/config
mkdir -p addons/<addon-name>/scripts
```

### 4. Create deploy.sh

Use this template as starting point:

```bash
#!/usr/bin/env bash
# Deploy <Addon Name>
# ADDON_REQUIRES_AAP=true  # Uncomment if AAP required
#
# <Brief description of what this addon does>
#
# Prerequisites:
#   - <List prerequisites>
#   - <External tool requirements>
#
# Usage:
#   ./deploy.sh          # Deploy addon
#   ./deploy.sh --delete # Remove addon

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-aap-operator}"

ACTION="${1:-deploy}"

# Delete logic
if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  echo "Removing <Addon Name>..."
  
  # Remove Kubernetes resources
  kubectl delete -f "${SCRIPT_DIR}/manifests/" -n "$NAMESPACE" 2>/dev/null || true
  
  # Remove namespace (if addon creates its own)
  # kubectl delete namespace <addon-namespace> 2>/dev/null || true
  
  # Clean up local files
  # rm -rf ~/.aap-demo/<addon-name>
  
  echo "✓ <Addon Name> removed"
  exit 0
fi

# Cluster connectivity check
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "ERROR: kubectl not connected to cluster"
  exit 1
fi

# Check prerequisites (example: AAP operator)
if ! kubectl get csv -n "$NAMESPACE" 2>/dev/null | grep -q "aap-operator"; then
  echo "WARNING: AAP operator not found in namespace '$NAMESPACE'"
  echo "  Deploy AAP first: aap-demo deploy"
  exit 1
fi

# Deployment logic
echo "Deploying <Addon Name>..."

# Apply manifests
kubectl apply -f "${SCRIPT_DIR}/manifests/" -n "$NAMESPACE"

# Wait for resources
kubectl wait --for=condition=ready pod -l app=<addon-label> -n "$NAMESPACE" --timeout=300s || {
  echo "ERROR: <Addon Name> pods not ready after 5 minutes"
  kubectl get pods -l app=<addon-label> -n "$NAMESPACE"
  exit 1
}

echo "✓ <Addon Name> deployed successfully!"
echo ""
echo "Access the addon:"
echo "  kubectl get routes -n $NAMESPACE | grep <addon>"
echo "  or"
echo "  aap-demo status <addon-name>"
```

**Make executable**:
```bash
chmod +x addons/<addon-name>/deploy.sh
```

### 5. Create Kubernetes Manifests

If addon deploys Kubernetes resources, create manifests:

**Simple example** (ConfigMap):
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-addon-config
  namespace: aap-operator
data:
  setting: "value"
```

**CR example** (Custom Resource):
```yaml
apiVersion: example.com/v1
kind: MyAddon
metadata:
  name: my-addon
  namespace: aap-operator
spec:
  replicas: 1
  image: registry.example.com/my-addon:latest
```

**Deployment example**:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-addon
  namespace: aap-operator
spec:
  replicas: 1
  selector:
    matchLabels:
      app: my-addon
  template:
    metadata:
      labels:
        app: my-addon
    spec:
      containers:
      - name: my-addon
        image: registry.example.com/my-addon:latest
        ports:
        - containerPort: 8080
```

### 6. Register in AVAILABLE_ADDONS

Edit `aap-demo.sh` line 3002 and add addon name:

**Current**:
```bash
AVAILABLE_ADDONS="fleet mcp-server portal portal-operator setup-pah ao apme-eap local-cache product-demos product-demo-satellite opa ollama"
```

**Updated** (add in alphabetical order):
```bash
AVAILABLE_ADDONS="fleet local-cache mcp-server my-addon opa ollama portal portal-operator product-demos product-demo-satellite setup-pah ao apme-eap"
```

### 7. Create README.md

Use this template:

```markdown
# <Addon Name> Addon

Brief description of addon purpose and what it provides.

- **Command**: `aap-demo enable <addon-name>`
- **Namespace**: `<namespace>` (or `aap-operator` if same as AAP)
- **Requires**: <List dependencies>

## Quick Start

\`\`\`bash
# Prerequisites
aap-demo deploy              # Deploy AAP (if required)

# Deploy addon
aap-demo enable <addon-name>

# Verify deployment
aap-demo status <addon-name>

# Access addon
kubectl get routes -n <namespace>
\`\`\`

## Prerequisites

- AAP deployed (if ADDON_REQUIRES_AAP=true)
- <Other addon dependencies>
- <External tool requirements>

## Configuration

### Environment Variables

- `NAMESPACE` — Target namespace (default: aap-operator)
- `<ADDON_VAR>` — Description (default: value)

### Custom Configuration

How to customize the addon deployment.

## Architecture

How the addon works:

- Components deployed
- Integration points with AAP
- External dependencies
- Data flow

## Troubleshooting

### Issue: <Common Problem>

**Symptom**: Description of what users see

**Cause**: Why it happens

**Fix**: How to resolve it

### Issue: <Another Problem>

...

## References

- [Related ADR](../../docs/adr/NNN-addon-name.md) (if exists)
- [GitHub Issue #NNN](https://github.com/RedHatOfficial/aap-demo/issues/NNN) (if exists)
- [External Documentation](https://example.com) (if applicable)
```

### 8. Test Addon Integration

**Enable addon**:
```bash
aap-demo enable <addon-name>
```

**Verify**:
```bash
# Check config storage
cat ~/.aap-demo/config | grep ADDONS

# Check deployment
kubectl get pods -n <namespace>
kubectl get routes -n <namespace>

# Check status
aap-demo status <addon-name>
```

**Disable addon**:
```bash
aap-demo disable <addon-name>
```

**Verify cleanup**:
```bash
# Check resources removed
kubectl get pods -n <namespace>

# Check config updated
cat ~/.aap-demo/config | grep ADDONS

# Check local files cleaned up
ls ~/.aap-demo/<addon-name>/  # Should not exist or be empty
```

### 9. Consider Creating an ADR

If addon involves significant architectural decisions, create an ADR:

```bash
# Use the aap-adr skill
/aap-adr "<Addon Name> addon architecture"
```

Include in ADR:
- Why this addon is needed
- Integration approach
- Dependencies and prerequisites
- Trade-offs and consequences

Examples: ADR-011 (MCP Server), ADR-017 (AO), ADR-024 (Ollama)

## Best Practices

### Script Safety

1. **Use `set -e`** — Exit on first error
2. **Check prerequisites** — Cluster connectivity, dependencies
3. **Validate input** — Check environment variables, arguments
4. **Handle errors gracefully** — Clear error messages
5. **Test both paths** — Deploy and delete modes

### Output Clarity

Use consistent markers:
- ✓ for success
- ✗ for errors
- ⚠ for warnings
- Plain echo for info

```bash
echo "Deploying addon..."
echo "✓ Addon deployed successfully"
echo "⚠ Warning: Resource already exists, updating"
echo "✗ ERROR: Failed to deploy"
```

### Resource Management

1. **Namespace handling** — Respect `NAMESPACE` env var
2. **Resource cleanup** — Delete mode removes all resources
3. **Idempotency** — Safe to run multiple times
4. **Wait for ready** — Use `kubectl wait` for async resources

### Dependencies

1. **Document prerequisites** — In deploy.sh header and README
2. **Check dependencies** — Before deploying
3. **Auto-enable dependencies** — If appropriate (see AO addon)
4. **Version constraints** — Document required versions

### Configuration

1. **Environment variables** — Use for common customization
2. **Default values** — Provide sensible defaults
3. **Template files** — Use envsubst for variable substitution
4. **Local storage** — Use `~/.aap-demo/<addon-name>/` for addon-specific files

## Common Patterns

### Pattern: Simple Manifest Deployment

For addons that just apply static YAML:

```bash
#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-aap-operator}"
ACTION="${1:-deploy}"

if [ "$ACTION" = "--delete" ]; then
  kubectl delete -f "${SCRIPT_DIR}/manifests/" -n "$NAMESPACE" 2>/dev/null || true
  echo "✓ Addon removed"
  exit 0
fi

kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: kubectl not connected"; exit 1; }
kubectl apply -f "${SCRIPT_DIR}/manifests/" -n "$NAMESPACE"
echo "✓ Addon deployed"
```

### Pattern: Custom Resource Deployment

For addons deploying CRs:

```bash
#!/usr/bin/env bash
# ADDON_REQUIRES_AAP=true
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-aap-operator}"
ACTION="${1:-deploy}"

if [ "$ACTION" = "--delete" ]; then
  kubectl delete -f "${SCRIPT_DIR}/manifests/cr.yaml" -n "$NAMESPACE" 2>/dev/null || true
  echo "✓ Addon removed"
  exit 0
fi

kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: kubectl not connected"; exit 1; }

# Check AAP operator
if ! kubectl get csv -n "$NAMESPACE" | grep -q "aap-operator"; then
  echo "ERROR: AAP operator required"
  exit 1
fi

# Deploy CR
kubectl apply -f "${SCRIPT_DIR}/manifests/cr.yaml" -n "$NAMESPACE"

# Wait for ready
kubectl wait --for=condition=ready pod -l app=my-addon -n "$NAMESPACE" --timeout=300s

echo "✓ Addon deployed"
```

### Pattern: Helm-Based Deployment

For addons using Helm charts:

```bash
#!/usr/bin/env bash
set -e

ADDON_NAME="my-addon"
NAMESPACE="${NAMESPACE:-my-addon-namespace}"
ACTION="${1:-deploy}"

if [ "$ACTION" = "--delete" ]; then
  helm uninstall "$ADDON_NAME" -n "$NAMESPACE" 2>/dev/null || true
  kubectl delete namespace "$NAMESPACE" 2>/dev/null || true
  echo "✓ Addon removed"
  exit 0
fi

# Check helm
if ! command -v helm &>/dev/null; then
  echo "ERROR: helm is required"
  exit 1
fi

# Create namespace
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Install chart
helm upgrade --install "$ADDON_NAME" ./path/to/chart \
  --namespace "$NAMESPACE" \
  --set key=value \
  --wait

echo "✓ Addon deployed"
```

### Pattern: Addon with Dependencies

For addons requiring other addons:

```bash
#!/usr/bin/env bash
set -e

# This addon requires mcp-server
if ! aap-demo status | grep -q "mcp-server"; then
  echo "Enabling prerequisite: mcp-server"
  aap-demo enable mcp-server || {
    echo "ERROR: Failed to enable mcp-server"
    exit 1
  }
fi

# Rest of deployment...
```

### Pattern: Interactive Configuration

For addons requiring user input:

```bash
#!/usr/bin/env bash
set -e

# Prompt for configuration (if not already set)
if [ -z "$MY_ADDON_TOKEN" ]; then
  read -p "Enter API token: " MY_ADDON_TOKEN
  export MY_ADDON_TOKEN
fi

# Use configuration in deployment...
```

## Examples to Study

### Simple Addon: registry

**Location**: `addons/registry/`

**What to learn**:
- Minimal structure (deploy.sh + one manifest)
- Simple deployment pattern
- Clean delete logic

### Medium Addon: mcp-server

**Location**: `addons/mcp-server/`

**What to learn**:
- AAP dependency checking
- Post-deployment patching (CA trust)
- ConfigMap injection
- README with clear usage

### Complex Addon: ao (Automation Orchestrator)

**Location**: `addons/ao/`

**What to learn**:
- Multi-dependency management (requires mcp-server)
- Interactive prompts (password generation)
- Multiple manifest directories
- Complex CR with many fields
- Namespace isolation (ao runs in automation-orchestrator, not aap-operator)
- Wiring integration with AAP
- Comprehensive README

### Tool Addon: fleet

**Location**: `addons/fleet/`

**What to learn**:
- External tool management (QEMU VMs)
- Background processes
- Custom status reporting
- Multiple subcommands

## Integration with Other Skills

- **aap-adr skill**: Create ADR for significant addon architecture
- **aap-issue-creation skill**: Create tracking issue for addon implementation
- Use `/aap-adr "<addon> addon architecture"` before starting complex addons
- Use `/aap-issue-creation "Feature: Add <addon> addon"` to track work

## Validation Checklist

Before considering addon complete:

- [ ] Addon name follows conventions (lowercase, hyphens)
- [ ] `deploy.sh` exists and is executable
- [ ] Deploy mode works (`aap-demo enable <addon>`)
- [ ] Delete mode works (`aap-demo disable <addon>`)
- [ ] Registered in `AVAILABLE_ADDONS` (aap-demo.sh:3002)
- [ ] `README.md` exists with Quick Start, Prerequisites, Troubleshooting
- [ ] Dependencies documented (AAP, other addons, external tools)
- [ ] Prerequisites checked in deploy.sh
- [ ] Error handling in place (`set -e`, clear error messages)
- [ ] Idempotent (safe to run multiple times)
- [ ] Resources cleaned up in delete mode
- [ ] Addon persists in `~/.aap-demo/config` after enable
- [ ] Addon removed from config after disable
- [ ] ADR created (if significant architecture)
- [ ] Issue created for tracking (if appropriate)

## Troubleshooting Addon Development

### Addon not found by aap-demo enable

**Cause**: Not registered in AVAILABLE_ADDONS

**Fix**: Add addon name to line 3002 of aap-demo.sh

### deploy.sh permission denied

**Cause**: Script not executable

**Fix**: `chmod +x addons/<addon-name>/deploy.sh`

### Addon deploys but doesn't persist

**Cause**: Not added to config by enable command

**Fix**: Verify addon directory exists and deploy.sh is present

### Delete mode doesn't clean up all resources

**Cause**: Incomplete cleanup logic

**Fix**: Review kubectl delete commands in delete mode, test thoroughly

### Dependencies not checked

**Cause**: Missing prerequisite validation

**Fix**: Add checks for AAP operator, other addons, external tools
