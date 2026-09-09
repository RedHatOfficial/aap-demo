# OPA (Open Policy Agent) Addon for AAP Demo

This addon enables **Policy as Code** functionality in Ansible Automation Platform (AAP) 2.5+ by deploying an Open Policy Agent (OPA) server and creating job templates for managing policy examples.

## Overview

Policy as Code allows AAP administrators to enforce policies on job executions using OPA and Rego policy language. Example use cases include:

- Enforcing maintenance windows for job execution
- Restricting credentials to specific organizations
- Validating extra variables (keys, values, user-based access)
- Whitelisting Git repositories and branches
- Enforcing job template naming standards
- Restricting inventory access by organization

## Prerequisites

- AAP 2.5+ deployed (`aap-demo deploy`)
- OpenShift/MicroShift cluster running
- `kubectl`, `curl`, `jq`, `base64` commands available

## Installation

Enable the OPA addon:

```bash
aap-demo enable opa
```

This will:
1. ✅ Enable `FEATURE_POLICY_AS_CODE_ENABLED` feature flag in AAP
2. ✅ Deploy OPA server to the cluster (same namespace as AAP)
3. ✅ Create Service and Route for OPA access
4. ✅ Create job templates for policy management
5. ✅ **Automatically configure OPA connection in AAP Settings**

## Configuration

**Good news!** The OPA server is automatically configured in AAP when you enable the addon. No manual configuration needed!

The addon automatically sets:
- **OPA server hostname**: `opa.aap-operator.svc.cluster.local`
- **OPA server port**: `8181`
- **SSL**: Disabled
- **Authentication**: None

### Verify Configuration (Optional)

If you want to verify the OPA configuration in AAP:

1. Login to AAP web interface
2. Navigate to **Settings → Policy**
3. You should see the OPA server already configured
4. Click **Test** to verify the connection

### Manual Configuration (If Needed)

If automatic configuration fails, you can manually configure via AAP UI:

| Setting | Value |
|---------|-------|
| **OPA server hostname** | `opa.aap-operator.svc.cluster.local` |
| **OPA server port** | `8181` |
| **Authentication** | None |

> **Note**: The internal service URL (`opa.aap-operator.svc.cluster.local`) is used for reliability.

## Loading Example Policies

The addon creates job templates for managing OPA policies from the upstream example repository:

### Via AAP Web Interface

1. Navigate to **Resources → Templates**
2. Find template: **OPA | Load Example Policies**
3. Click **Launch** to run the job

This job template downloads policy examples from:
https://github.com/ansible/example-opa-policy-for-aap

**Note:** Currently 10 of 12 example policies load successfully. The 2 failures (`maintenance_window.rego` and `mismatch_prefix_allowed_false.rego`) are due to missing `import rego.v1` or `import future.keywords` statements in the upstream repository. The upstream policies use newer Rego syntax (`if` keyword and `some x in y`) but don't include the required imports. The 10 working policies are fully functional for testing AAP Policy as Code!

### Job Templates Created

| Template Name | Purpose |
|---------------|---------|
| **OPA | Load Example Policies** | Download and load example policies from upstream |
| **OPA | Test Policies** | Run OPA policy test suite |
| **OPA | Clear Policies** | Remove all loaded policies (reset) |

## Example Policies

The upstream repository includes 9 example policies:

1. **Job Execution Prevention** - Block job execution at enforcement points
2. **Platform Admin Restrictions** - Limit platform administrator actions
3. **Maintenance Window Enforcement** - Only allow jobs during maintenance windows
4. **Credential Organization Validation** - Restrict credentials to specific orgs
5. **Resource Matching** - Require specific resource combinations
6. **Extra Vars Validation** - Validate extra variable keys and values
7. **Git Repository Whitelisting** - Only allow specific repos and branches
8. **Job Template Naming** - Enforce naming standards
9. **Inventory Organization Restrictions** - Limit inventory access by org

## Policy Structure

OPA policies are written in **Rego** language and stored in the OPA server. Example policy structure:

```rego
package example_policy

import rego.v1

# Deny job execution outside maintenance window
deny contains msg if {
    input.request_type == "job"
    not maintenance_window_active
    msg := "Jobs can only run during maintenance windows (Mon-Fri 10:00-16:00 UTC)"
}

maintenance_window_active if {
    # Define maintenance window logic
    ...
}
```

## Manual Policy Loading

If the job templates don't work (upstream may not have playbooks yet), you can load policies manually:

### Using OPA REST API

```bash
# Get OPA route
OPA_ROUTE=$(kubectl get route opa -n aap-operator -o jsonpath='{.spec.host}')

# Upload a policy file
curl -X PUT \
  -H "Content-Type: text/plain" \
  --data-binary @policy.rego \
  "http://${OPA_ROUTE}/v1/policies/my-policy"

# List loaded policies
curl "http://${OPA_ROUTE}/v1/policies"

# Delete a policy
curl -X DELETE "http://${OPA_ROUTE}/v1/policies/my-policy"
```

### Using kubectl exec

```bash
# Get OPA pod name
OPA_POD=$(kubectl get pod -n aap-operator -l app=opa -o name | head -1)

# Upload policy via stdin
kubectl exec -n aap-operator $OPA_POD -- \
  opa load --bundle /policies
```

## Environment Variables

Customize OPA deployment with environment variables:

```bash
# Use specific OPA version (default: latest)
OPA_VERSION=0.70.0-static aap-demo enable opa

# Use different upstream OPA examples repository
OPA_REPO=https://github.com/myorg/custom-opa-policies aap-demo enable opa

# Use specific branch of upstream OPA examples
OPA_BRANCH=v1.0.0 aap-demo enable opa

# Use different aap-demo repository (for playbooks)
AAP_DEMO_REPO=https://github.com/myorg/aap-demo.git aap-demo enable opa

# Use specific branch of aap-demo (for testing feature branches)
AAP_DEMO_BRANCH=my-feature-branch aap-demo enable opa

# Deploy to different namespace
NAMESPACE=my-namespace aap-demo enable opa
```

**Note:** The playbooks are stored in the aap-demo repository at `addons/opa/playbooks/`. During development, the addon uses the `feat/opa-examples` branch. This will be changed to `main` when the feature is merged.

## Verification

Verify OPA is working correctly:

### Check OPA Pod Status

```bash
kubectl get pods -n aap-operator -l app=opa

# Expected output:
# NAME                   READY   STATUS    RESTARTS   AGE
# opa-xxxxxxxxxx-xxxxx   1/1     Running   0          2m
```

### Check Feature Flag

```bash
kubectl get aap aap -n aap-operator \
  -o jsonpath='{.spec.feature_flags.FEATURE_POLICY_AS_CODE_ENABLED}'

# Expected output: true
```

### Test OPA Health

```bash
OPA_ROUTE=$(kubectl get route opa -n aap-operator -o jsonpath='{.spec.host}')
curl -s "http://${OPA_ROUTE}/health" | jq '.'

# Expected output:
# {
#   "status": "ok"
# }
```

### Verify AAP API Recognizes Feature

```bash
AAP_ROUTE=$(kubectl get route aap -n aap-operator -o jsonpath='{.spec.host}')
curl -sk "https://${AAP_ROUTE}/api/controller/v2/feature_flags_state/" | \
  jq '.FEATURE_POLICY_AS_CODE_ENABLED'

# Expected output: true
```

## Troubleshooting

### OPA Pod Not Starting

**Check pod status and logs:**
```bash
kubectl get pods -n aap-operator -l app=opa
kubectl logs -n aap-operator -l app=opa
kubectl describe pod -n aap-operator -l app=opa
```

**Common issues:**
- Image pull failures: Check pull secrets and network connectivity
- Resource constraints: Check node capacity with `kubectl describe nodes`

### AAP Cannot Connect to OPA

**Verify OPA service:**
```bash
kubectl get svc opa -n aap-operator
```

**Test connectivity from within cluster:**
```bash
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
  curl http://opa.aap-operator.svc.cluster.local:8181/health
```

**Check AAP Settings:**
- Ensure hostname is `opa.aap-operator.svc.cluster.local` (not external route)
- Port should be `8181`
- Use internal service URL for reliability

### Job Templates Fail

The upstream repository may not include playbooks yet. If job templates fail:

1. **Check upstream repository:**
   ```bash
   # View repository structure
   curl -s https://api.github.com/repos/ansible/example-opa-policy-for-aap/contents/playbooks | jq '.[].name'
   ```

2. **Create custom playbooks** or load policies manually (see Manual Policy Loading section)

3. **Check project sync status** in AAP:
   - Navigate to Resources → Projects
   - Find "OPA Example Policies"
   - Check sync status and error messages

### Feature Flag Not Working

**Verify AAP version supports Policy as Code:**
```bash
kubectl get csv -n aap-operator -o jsonpath='{.items[0].spec.version}'
```

Policy as Code requires AAP 2.5 or later.

**Restart AAP pods after enabling flag:**
```bash
kubectl delete pod -n aap-operator -l app.kubernetes.io/component=gateway
```

## Uninstallation

Disable the OPA addon and remove all resources:

```bash
aap-demo disable opa
```

This will:
1. Delete OPA deployment, service, and route
2. Remove job templates and project
3. Disable `FEATURE_POLICY_AS_CODE_ENABLED` feature flag in AAP
4. Remove addon from saved configuration

## Resources

- **Upstream Repository**: https://github.com/ansible/example-opa-policy-for-aap
- **OPA Documentation**: https://www.openpolicyagent.org/docs/latest/
- **Rego Language Guide**: https://www.openpolicyagent.org/docs/latest/policy-language/
- **AAP Policy as Code Docs**: Check AAP documentation for Policy configuration

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ AAP Namespace (aap-operator)                                │
│                                                             │
│  ┌──────────────┐                  ┌────────────────┐      │
│  │              │   Policy Check   │                │      │
│  │  AAP Gateway │─────────────────▶│  OPA Server    │      │
│  │              │   (HTTP/8181)    │  (Deployment)  │      │
│  └──────────────┘                  └────────────────┘      │
│         │                                   │               │
│         │                                   │               │
│         │ Job Launch                        │ Policy Data   │
│         ▼                                   ▼               │
│  ┌──────────────┐                  ┌────────────────┐      │
│  │              │                  │                │      │
│  │ AAP          │                  │ Policies       │      │
│  │ Controller   │                  │ (.rego files)  │      │
│  │              │                  │                │      │
│  └──────────────┘                  └────────────────┘      │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Job Templates (Created by OPA Addon)                 │  │
│  │ • OPA | Load Example Policies                        │  │
│  │ • OPA | Test Policies                                │  │
│  │ • OPA | Clear Policies                               │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## How It Works

1. **Auto-Configuration**: The addon automatically configures AAP to connect to OPA via the Settings API
2. **Policy Evaluation**: When a job is launched in AAP, the gateway sends a policy evaluation request to OPA
3. **OPA Decision**: OPA evaluates the request against loaded policies (written in Rego)
4. **Allow/Deny**: OPA returns allow/deny decision with optional violation messages
5. **Enforcement**: AAP gateway enforces the decision (blocks job if denied)

## License

This addon deploys resources from the upstream repository which is released under **The Unlicense** (public domain). You are free to use, modify, and distribute the policies and examples.

## Support

For issues with:
- **aap-demo OPA addon**: Open issue in aap-demo repository
- **OPA policy examples**: Open issue in https://github.com/ansible/example-opa-policy-for-aap
- **OPA server**: Consult OPA documentation
- **AAP Policy as Code feature**: Contact Red Hat support
