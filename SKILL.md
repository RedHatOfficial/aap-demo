---
name: aap-demo
description: AAP Demo deployment knowledge - ADRs, API patterns, credentials, and troubleshooting
---

# AAP Demo Deployment Knowledge

## Architecture Decision Records (ADRs)

ADRs are located in `docs/adr/` and document key architectural decisions made during the project. Each ADR follows the standard format:

- `000-template.md` - Template for new ADRs
- `001-` through `019+` - Numbered decision records

When making architectural changes or understanding design rationale, always check existing ADRs first:

```bash
ls docs/adr/
```

To create a new ADR, copy `docs/adr/000-template.md` and follow the numbering convention.

## API Access Patterns

### Always use the Gateway API, not direct controller access

**CORRECT:**
```bash
# Use the AAP gateway API endpoint
curl -k -u admin:password https://{{ aap_host }}/api/v2/ping/
```

**INCORRECT:**
```bash
# Do NOT access controller API directly
curl -k https://{{ controller_host }}/api/v2/ping/  # ❌ WRONG
```

**Why:** The AAP gateway (introduced in AAP 2.5+) provides:
- Single entry point for all AAP services (controller, hub, EDA)
- Unified authentication and authorization
- Service discovery and routing
- Consistent API versioning

The controller API endpoint is an internal implementation detail and may change or be deprecated.

## Credentials

### Always use aap-admin-password secret

**CORRECT:**
```bash
# Get AAP admin password from the correct secret
kubectl get secret aap-admin-password -n aap-operator -o jsonpath='{.data.password}' | base64 -d

# Or use aap-demo status (recommended)
aap-demo status | grep "AAP Admin"
```

**INCORRECT:**
```bash
# Do NOT use controller-specific credentials
kubectl get secret aap-controller-admin-password  # ❌ WRONG
kubectl get secret controller-admin-password      # ❌ WRONG
```

**Why:** 
- `aap-admin-password` is the gateway admin credential (AAP 2.5+)
- AAP gateway uses its own RBAC system that may differ from controller's
- Controller credentials are service-internal and not guaranteed to work via gateway
- Using AAP admin credentials ensures consistent behavior across all services (controller, hub, EDA)

### Credential retrieval

**Method 1: Using aap-demo (recommended)**
```bash
# Get all credentials (AAP admin, hub admin, etc.)
aap-demo status

# AAP admin username is always: admin
# Password is displayed in status output
```

**Method 2: Direct kubectl access**
```bash
# Get AAP admin password from Kubernetes secret
AAP_PASSWORD=$(kubectl get secret aap-admin-password -n aap-operator -o jsonpath='{.data.password}' | base64 -d)
echo $AAP_PASSWORD

# Use in API calls
curl -k -u admin:${AAP_PASSWORD} https://{{ aap_host }}/api/v2/ping/
```

**Method 3: One-liner for scripts**
```bash
# Get password inline
kubectl get secret aap-admin-password -n aap-operator -o jsonpath='{.data.password}' | base64 -d && echo
```

### Login to AAP web UI

```bash
# 1. Get the AAP gateway URL
AAP_URL=$(aap-demo status | grep "AAP Gateway" | awk '{print $3}')

# 2. Get the admin password
AAP_PASSWORD=$(kubectl get secret aap-admin-password -n aap-operator -o jsonpath='{.data.password}' | base64 -d)

# 3. Navigate to $AAP_URL in browser and login with:
#    Username: admin
#    Password: $AAP_PASSWORD
```

## Deprecated Tools

### NEVER use awx-cli

**❌ DO NOT USE:**
```bash
awx-cli login  # WRONG - deprecated tool
awx ping       # WRONG - deprecated tool
```

**✅ USE INSTEAD:**
```bash
# Direct API calls via curl
curl -k -u admin:password https://{{ aap_host }}/api/v2/ping/

# Or ansible.controller collection modules
ansible-playbook -i inventory playbook.yml
```

**Why:**
- `awx-cli` is deprecated and no longer maintained
- `awx-cli` was designed for AWX (upstream), not AAP (downstream product)
- `awx-cli` does not support AAP gateway authentication
- `awx-cli` bypasses the gateway and tries to connect directly to controller
- Modern AAP integrations use the `ansible.controller` collection or direct API calls

**Alternatives:**
1. **For automation**: Use `ansible.controller` collection modules
2. **For testing**: Use `curl` with gateway API endpoints
3. **For CLI workflows**: Use `aap-demo` commands or write shell scripts around the API

## Common Integration Patterns

### Playbook execution via API

```bash
# 1. Get AAP credentials
AAP_PASS=$(aap-demo status | grep "AAP Admin Password" | awk '{print $4}')
AAP_HOST=$(aap-demo status | grep "AAP Gateway" | awk '{print $3}')

# 2. Use gateway API
curl -k -u admin:${AAP_PASS} \
  -H "Content-Type: application/json" \
  -X POST \
  https://${AAP_HOST}/api/v2/job_templates/1/launch/
```

### Ansible collection authentication

See `docs/collection-authentication.md` for detailed guidance on:
- Using `ansible.controller` collection with gateway API
- Token-based authentication
- Certificate verification options

## Troubleshooting

### Quick diagnostics

```bash
# Run automated health checks
aap-demo diagnose

# AI-powered root cause analysis (requires claude CLI)
aap-demo diagnose --ai

# Full diagnostic bundle for complex issues
aap-demo must-gather
```

### Common issues

1. **API authentication failures**
   - Verify you're using AAP admin credentials, not controller credentials
   - Ensure you're hitting `{{ aap_host }}/api` not `{{ controller_host }}/api`

2. **Route resolution**
   - Routes use nip.io DNS (e.g., `aap-gateway.192.168.64.2.nip.io`)
   - Check routes: `aap-demo status`

3. **Pod failures**
   - SCC permissions: `oc adm policy add-scc-to-group anyuid system:serviceaccounts:aap-operator`
   - See CLAUDE.md for detailed troubleshooting

## Key Technical Details

- **Infrastructure**: OpenShift Local (MicroShift) via CRC
- **Storage**: LVMS (RWO), in-cluster NFS (RWX)
- **Namespace**: `aap-operator` (default)
- **Gateway**: Primary API entry point (AAP 2.5+)
- **DNS**: nip.io for route resolution

## References

- Architecture decisions: `docs/adr/`
- Full documentation: `docs/FULL-README.md`
- Collection auth: `docs/collection-authentication.md`
- Contributing: `docs/CONTRIBUTING.md`
- Project CLAUDE.md: `.claude/CLAUDE.md` (if present in working directory)
