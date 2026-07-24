---
name: aap-demo
description: >
  Manages AAP (Ansible Automation Platform) development environments on local
  MicroShift clusters. Handles cluster lifecycle (create, deploy, destroy),
  diagnostics, troubleshooting, and test execution. Activate when users want to
  deploy AAP, check cluster health, fix deployment issues, run tests, or manage
  their aap-demo environment.
allowed-tools:
  - Bash(aap-demo *)
  - Bash(kubectl *)
  - Bash(oc *)
argument-hint: "[command, question, or intent]"
---

# aap-demo Skill

You manage AAP development environments using the `aap-demo` CLI. Delegate to
CLI commands — do not reimplement their logic.

## SECURITY NOTICE — DEVELOPMENT ENVIRONMENT ONLY

**aap-demo is a LOCAL DEVELOPMENT tool and must NEVER be used in production.**

This environment includes characteristics specific to local development:

- **Self-signed certificates are trusted** in the MCP server addon using `NODE_EXTRA_CA_CERTS`
- **Router ClusterIP addresses** may become stale after cluster rebuild
- **All routes use localhost** (`127.0.0.1.nip.io`)

**DO NOT use aap-demo configurations or patterns in production environments.**

## Commands Reference

| Intent | Command |
|--------|---------|
| Create cluster | `aap-demo create` |
| Deploy AAP 2.7 | `aap-demo deploy` |
| Deploy operator only | `aap-demo deploy-operator` |
| Check status & creds | `aap-demo status` |
| Health check | `aap-demo diagnose` |
| AI-powered diagnostics | `aap-demo diagnose --ai` |
| Collect full diagnostics | `aap-demo must-gather` |
| Scale down (save resources) | `aap-demo idle true` |
| Scale back up | `aap-demo idle false` |
| Remove AAP (keep cluster) | `aap-demo clean` |
| Destroy entire cluster | `aap-demo destroy` |
| Stop/start cluster | `aap-demo stop` / `aap-demo start` |
| SSH into cluster node | `aap-demo ssh` |
| Run tests | `aap-demo test` |
| Enable addon | `aap-demo enable <name>` |
| Disable addon | `aap-demo disable <name>` |
| Destroy and rebuild from scratch | `aap-demo redeploy-all` |
| Show help | `aap-demo help` |

Available addons: olm, console, registry, mcp-server, devspaces, prometheus, portal

## Portal Addon

Helm-based Self-Service Portal on OpenShift (`aap-demo enable portal`):

- Auto-detects cluster CPU (`amd64` vs `arm64`) and selects x86 or ARM image profile
- Namespace: `redhat-rhaap-portal`
- Architecture: see `docs/adr/002-portal-helm-deployment.md`

**Access**: `aap-demo status portal` for route URL. Sign in with AAP OAuth (admin credentials).

**Prerequisites**: AAP deployed, Helm 3.10+, `registry.redhat.io` pull secret for OCI plugins.

## Workflow

Before any command, run `aap-demo status` to understand current state. The standard
lifecycle is: `create` -> `deploy` -> use -> `idle`/`clean` -> `destroy`.

- Deploy auto-creates the cluster if needed — no need to run create first
- After deploy completes, run `aap-demo status` to show routes and credentials
- **Destructive operations** (clean, destroy, redeploy-all): always confirm with the user first
- Use `QUIET=true` prefix to skip interactive prompts when running non-interactively

## Environment Awareness

Before suggesting commands, check the user's environment:

1. Read `~/.aap-demo/config` to determine INFRA type (crc, minc, lab)
2. Check `KUBECONFIG`:
   - CRC: `~/.crc/machines/crc/kubeconfig`
   - MINC: `~/.aap-demo/kubeconfig.microshift`
   - Lab: user's own kubeconfig
3. Run `aap-demo status` to see running deployments, namespaces, and pod counts

When the user has multiple AAP deployments (e.g., operator in `aap-operator` + aap-demo in
`aap27`), always clarify which deployment they mean before acting.

## Pull Secret Management

Pull secrets are required for image pulls and live in `~/.aap-demo/`:
- `pull-secret.txt` or `pull-secret.json` (from console.redhat.com)
- ATF tests: `atf-vault-password` (for vaulted test vars)  # pragma: allowlist secret

If image pulls fail with 403/unauthorized, check:  # pragma: allowlist secret
1. Correct pull secret exists in `~/.aap-demo/`  # pragma: allowlist secret
2. Pull secret is injected into the namespace: `kubectl get secret -n $NAMESPACE | grep pull`  # pragma: allowlist secret
3. ServiceAccount has imagePullSecrets: `kubectl get sa default -n $NAMESPACE -o yaml`

## Diagnostics Loop

When troubleshooting:

1. Run `aap-demo diagnose` — parse output for `✗` (fail) and `⚠` (warn) markers
2. Apply the matching fix from the table below
3. Re-run `aap-demo diagnose` to verify
4. If issues persist after 2 attempts, run `aap-demo must-gather` for deeper analysis
5. Check operator logs: `kubectl logs -l app.kubernetes.io/managed-by=aap-gateway-operator -n $NAMESPACE --tail=100`

## Known Fixes

| Diagnose Output | Fix |
|-----------------|-----|
| SCC validation failure | `oc adm policy add-scc-to-group anyuid system:serviceaccounts:$NAMESPACE && oc adm policy add-scc-to-group privileged system:serviceaccounts:$NAMESPACE` |
| PVC pending (hub-file-storage) | Check `kubectl get sc nfs-local-rwx`. Missing: re-run `aap-demo create`. Present but pending: check NFS server `kubectl get pods -n nfs-storage` |
| CatalogSource TRANSIENT_FAILURE | DNS race condition. Check catalog pod: `kubectl get pods -n $NAMESPACE -l olm.catalogSource`. If pod is running but catalog stuck, restart catalog-operator: `kubectl rollout restart deployment/catalog-operator -n openshift-operator-lifecycle-manager`. Verify pull secret exists. |
| Gateway CrashLoopBackOff (EACCES) | Usually self-resolves after reconciliation. If persistent: `kubectl delete pod -l app.kubernetes.io/name=gateway -n $NAMESPACE` |
| DNS resolution failures | `aap-demo start` (re-applies CoreDNS config) or `kubectl rollout restart daemonset/dns-default -n openshift-dns`. Root cause: CoreDNS template plugin returns router ClusterIP directly for *.nip.io — if router IP changes after restart, CoreDNS config is stale. |
| Disk space / pod eviction | `aap-demo ssh` then `sudo crictl rmi --prune` |
| Pods stuck Pending (resources) | `kubectl describe node | grep -A 5 Allocated` — consider `aap-demo idle true` on other deployments |
| Stale pod mounts after crash | Restart kube-proxy and CoreDNS: `kubectl rollout restart daemonset/kube-proxy -n kube-proxy && kubectl rollout restart daemonset/dns-default -n openshift-dns`. Symptom: "transport endpoint is not connected" or "executable file not found" |
| ImagePullBackOff | Pull secret missing or incorrect. Needs `pull-secret.txt` for registry.redhat.io. Check `~/.aap-demo/` for correct file. |
| OLM not installed | `aap-demo enable olm` — MicroShift does not include OLM by default, it's installed during `aap-demo create` but may be missing on older setups |

## Test Orchestration

- Default: `aap-demo test` runs interop tests against auto-detected AAP deployment
- Specific markers: `aap-demo test aap-operator interop,smoke`
- Multiple deployments: specify namespace with `NAMESPACE=<ns> aap-demo test`
- After tests, summarize pass/fail counts from the output
- If tests fail, check AAP health first (`aap-demo diagnose`) before investigating test issues

## Post-Deploy Verification

After any deployment, verify health with this sequence:

1. `aap-demo status` — check all pods are running, routes are accessible
2. `aap-demo diagnose` — automated health checks
3. If diagnose shows issues, apply fixes from the Known Fixes table
4. For latest deployments, check AAP CR status: `kubectl get aap -n $NAMESPACE -o jsonpath='{.items[0].status.conditions}'`

The AAP CR goes through phases: Pending → Running → Successful. A deployment typically
takes 5-10 minutes. If stuck in Running for >15 minutes, check operator logs and diagnose.

## AAP Interaction Tooling

**NEVER use awxkit for AAP operations.** awxkit causes:
- Inconsistent tooling across environments
- Python dependency conflicts
- Complex authentication setup
- Windows compatibility issues

### Priority Order for AAP Interactions

Use the following tools in this order of preference:

#### 1. MCP Server (Preferred)

Check if `aap-mcp` MCP server is configured:

```bash
# Check MCP server availability
aap-demo status | grep -i mcp
```

If configured, use MCP tools for AAP operations:
- `aap-controller-*` tools for Controller operations
- `aap-eda-*` tools for Event-Driven Ansible
- `aap-hub-*` tools for Automation Hub

MCP provides typed, validated API interactions without authentication complexity.

#### 2. kubectl/oc for Operator Resources

For operator-deployed AAP, use kubectl/oc to manage AAP resources directly:

**Check AAP deployment status:**
```bash
kubectl get aap -n aap-operator -o yaml
kubectl get aap -n aap-operator -o jsonpath='{.items[0].status.conditions}'
```

**Get AAP credentials:**
```bash
# Admin password
kubectl get secret aap-admin-password -n aap-operator -o jsonpath='{.data.password}' | base64 -d

# Database credentials
kubectl get secret aap-postgres-configuration -n aap-operator -o yaml
```

**Get AAP routes:**
```bash
kubectl get routes -n aap-operator
kubectl get route gateway -n aap-operator -o jsonpath='{.spec.host}'
```

**Manage AAP components via CR:**
```bash
# Scale down AAP (idle mode)
kubectl patch aap aap -n aap-operator --type=merge -p '{"spec":{"idle_aap":true}}'

# Scale back up
kubectl patch aap aap -n aap-operator --type=merge -p '{"spec":{"idle_aap":false}}'
```

#### 3. Direct REST API via curl

For AAP gateway endpoints when kubectl is insufficient:

**Get authentication token:**
```bash
# Extract admin password
ADMIN_PASSWORD=$(kubectl get secret aap-admin-password -n aap-operator -o jsonpath='{.data.password}' | base64 -d)

# Get gateway route
GATEWAY_HOST=$(kubectl get route gateway -n aap-operator -o jsonpath='{.spec.host}')

# Authenticate and get token
TOKEN=$(curl -sk -X POST "https://${GATEWAY_HOST}/api/gateway/v1/tokens/" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"admin\",\"password\":\"${ADMIN_PASSWORD}\"}" | jq -r '.token')
```

**Common API operations:**

```bash
# List organizations
curl -sk -H "Authorization: Bearer ${TOKEN}" \
  "https://${GATEWAY_HOST}/api/controller/v2/organizations/"

# List job templates
curl -sk -H "Authorization: Bearer ${TOKEN}" \
  "https://${GATEWAY_HOST}/api/controller/v2/job_templates/"

# Launch job template
curl -sk -X POST -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  "https://${GATEWAY_HOST}/api/controller/v2/job_templates/${TEMPLATE_ID}/launch/" \
  -d '{"extra_vars": "{}"}'

# Check job status
curl -sk -H "Authorization: Bearer ${TOKEN}" \
  "https://${GATEWAY_HOST}/api/controller/v2/jobs/${JOB_ID}/"
```

**EDA API examples:**

```bash
# List activations
curl -sk -H "Authorization: Bearer ${TOKEN}" \
  "https://${GATEWAY_HOST}/api/eda/v1/activations/"

# List rulebook activations
curl -sk -H "Authorization: Bearer ${TOKEN}" \
  "https://${GATEWAY_HOST}/api/eda/v1/rulebook-activations/"
```

**Hub API examples:**

```bash
# List collections
curl -sk -H "Authorization: Bearer ${TOKEN}" \
  "https://${GATEWAY_HOST}/api/galaxy/_ui/v1/collection-versions/"

# List execution environments
curl -sk -H "Authorization: Bearer ${TOKEN}" \
  "https://${GATEWAY_HOST}/api/galaxy/pulp/api/v3/distributions/container/container/"
```

#### 4. Ansible Modules (Last Resort)

Use Ansible modules only when kubectl/curl are insufficient for complex workflows:

```yaml
# ansible.controller modules
- name: Create organization
  ansible.controller.organization:
    controller_host: "{{ gateway_host }}"
    controller_username: admin
    controller_password: "{{ admin_password }}"
    name: "Demo Org"
    state: present
    validate_certs: false

# ansible.eda modules
- name: Create EDA project
  ansible.eda.project:
    controller_host: "{{ gateway_host }}"
    controller_username: admin
    controller_password: "{{ admin_password }}"
    name: "Demo Project"
    url: "https://github.com/example/repo.git"
    state: present
    validate_certs: false
```

**When to use Ansible modules:**
- Complex multi-step AAP configuration workflows
- Idempotent configuration management
- Integration with existing Ansible playbooks
- When MCP/kubectl/curl would require excessive scripting

### Authentication Best Practices

**For MCP:** Authentication is handled by the MCP server configuration — no manual auth required.

**For curl:** Always extract credentials from Kubernetes secrets, never hardcode. Use environment variables for tokens.

**For Ansible modules:** Use `controller_host`, `controller_username`, `controller_password` parameters. Set `validate_certs: false` for local development environments.

## Key Details

- Default namespace: `aap-operator` (override with `NAMESPACE=<ns>`)
- CRC kubeconfig: `~/.crc/machines/crc/kubeconfig`
- Config file: `~/.aap-demo/config` (stores infra type, addons, preferences)
- Backends: CRC (macOS, recommended) uses a VM; MINC (Linux) uses a Podman container
- SCCs are granted at namespace group level, not per ServiceAccount
- NFS provisioner uses `__NFS_SERVER_IP__` placeholder resolved at deploy time
- MicroShift lacks `ingresses.config.openshift.io` API — route hosts use nip.io
- OLM is not built into MicroShift — installed via `operator-sdk olm install` during create
- Latest CatalogSource must be in `aap-operator` namespace (no `openshift-marketplace` on MicroShift)
- Bundle unpack jobs need `privileged` SCC (not just `anyuid`) due to seccomp annotations
- `inotify` sysctl limits (`max_user_instances=2099999999`) are critical for operator performance
