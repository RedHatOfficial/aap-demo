# ADR-019b: APME AAP-Native Execution

**Status:** Accepted  
**Date:** 2026-07-21  
**Author:** Chad Ferman  
**Supersedes:** ADR-019 Architecture Decision 2 (venv approach)

## Context

ADR-019 established the `apme-eap` addon using official APME playbooks via a bash wrapper with an isolated Python virtual environment. While functional, this approach had drawbacks:

1. **Redundant execution environment**: Created a separate venv when AAP already has execution environments
2. **Missed demo opportunity**: Didn't showcase AAP running automation workloads
3. **Slower first run**: Venv setup takes 1-2 minutes
4. **System dependencies**: Required local Ansible installation
5. **No UI visibility**: Playbook runs were opaque to users

**Key insight:** Since `aap-demo` deploys AAP, we can use AAP's REST API to execute the playbooks *within AAP itself*, eliminating the venv entirely.

## Decision

Replace venv-based `ansible-playbook` execution with **AAP REST API orchestration**. The addon now:

1. Uses AAP's REST API to create/update resources (Project, Inventory, Job Template)
2. Copies playbooks to AAP controller pod (`/var/lib/awx/projects/`)
3. Launches playbook execution as an AAP job
4. Streams job output to console and provides AAP Web UI link

### Implementation

### Final Architecture: Ansible Playbooks with `ansible.builtin.uri`

After initial attempts with bash+curl API wrappers, the implementation evolved to use **Ansible playbooks** for cleaner, more maintainable code.

**New Ansible Playbooks:**

1. **`playbooks/create_aap_token.yml`** - Auto-creates OAuth2 API tokens
   - Uses basic auth with `aap-admin-password` secret
   - POSTs to `/api/gateway/v1/tokens/` endpoint
   - Stores token in `aap-api-token` Kubernetes secret
   - Idempotent - skips if token already exists

2. **`playbooks/setup_aap_resources.yml`** - Creates AAP resources via REST API
   - Queries Default organization
   - Creates Project (manual type, timestamp-based unique path)
   - Copies playbooks to controller pod (tar-free method using `kubectl exec` + `cat`)
   - Creates Inventory (localhost with `ansible_connection: local`)
   - Creates Job Template ("Deploy APME")

3. **`playbooks/launch_apme_deployment.yml`** - Executes APME deployment
   - Launches job with extra vars from generated vars file
   - Waits for completion with polling
   - Streams job output from API
   - Reports success/failure

**Modified:** `addons/apme-eap/deploy.sh`

- `setup_minimal_venv()` - Creates venv with `ansible-core` (not full Ansible suite)
- `ensure_aap_token()` - Auto-creates token via playbook if not exists
- `deploy()` - Orchestrates playbooks instead of bash functions
- Removed dependency on `lib/aap-api.sh` (bash+curl approach)

**Key Implementation Details:**

```yaml
# Token creation (basic auth works!)
- name: Create API token via gateway
  ansible.builtin.uri:
    url: "{{ aap_host }}/api/gateway/v1/tokens/"
    method: POST
    url_username: "{{ aap_username }}"
    url_password: "{{ aap_password }}"
    force_basic_auth: true
    body_format: json
    body:
      description: "aap-demo APME addon API access"
      scope: "write"
```

**Tar-free file copy** (AAP controller pods lack `tar`):
```bash
cd {{ playbook_dir_local }}
find . -type f | while read file; do
  dir=$(dirname "$file")
  kubectl exec -n aap-operator {{ controller_pod }} -- \
    mkdir -p "/var/lib/awx/projects/{{ project_local_path }}/$dir"
  kubectl exec -n aap-operator {{ controller_pod }} -i -- \
    sh -c "cat > /var/lib/awx/projects/{{ project_local_path }}/$file" < "$file"
done
```

**Unique project paths** (avoid conflicts with leftover files):
```yaml
project_local_path: "aap-demo-apme-{{ ansible_date_time.epoch }}"
```

**Job execution flow:**
```
deploy.sh
  ↓
1. Auto-discover AAP config from cluster
  ↓
2. ensure_aap_token()
   - Check for existing token secret
   - If missing: run create_aap_token.yml
  ↓
3. Run setup_aap_resources.yml
   - Query/create Organization
   - Copy playbooks to controller pod
   - Create Project (manual, unique timestamp path)
   - Create Inventory
   - Create Job Template
  ↓
4. Run launch_apme_deployment.yml
   - Launch job with extra_vars
   - Wait for completion (polling)
   - Stream output
  ↓
5. Display AAP Web UI link for job details
```

## Consequences

### Positive

- **No venv needed**: Eliminates 40+ MB venv and 1-2 minute setup time
- **AAP-native**: Showcases AAP running real automation (great demo story)
- **Web UI visibility**: Users can watch playbook execution in AAP UI
- **Simpler prerequisites**: Just `kubectl`, `jq`, and `python3` (no Ansible)
- **Better integration**: Uses AAP's execution environments and collection management
- **Reusable pattern**: Establishes API-driven addon pattern for other AAP-based workflows

### Negative

- **API complexity**: More complex than direct `ansible-playbook` call
- **kubectl cp dependency**: Requires copying files to controller pod (not ideal for large repos)
- **Debugging**: Harder to debug API calls vs local playbook runs
- **API changes**: Vulnerable to AAP API version changes

### Neutral

- **Namespace fix**: Also fixed MicroShift compatibility by replacing `Project`/`ProjectRequest` with `Namespace` (separate change in same commit)
- **Same playbooks**: No changes to official APME playbooks themselves

## Alternatives Considered

### 1. Keep venv approach (ADR-019)

**Rejected:** Misses opportunity to showcase AAP's capabilities and creates redundant execution environment.

### 2. Use AWX CLI

**Rejected:** Adds another dependency (`awx` CLI) and doesn't provide more value than direct API calls.

### 3. Git-based Project

Instead of `kubectl cp`, use a git URL pointing to the repo.

**Rejected:**
- Requires git server or public GitHub (aap-demo is often airgapped)
- Adds complexity (SSH keys, credentials)
- `kubectl cp` is simpler for local development

### 4. MCP Server for AAP

Use the (hypothetical) AAP MCP server instead of direct API calls.

**Future consideration:** If AAP MCP server becomes available, this would be cleaner than direct API calls.

## Consequences

### Positive

- **Zero manual setup** - Token auto-created via basic auth (no Web UI steps!)
- **Clean code** - Ansible `uri` module > bash+curl for API calls
- **AAP-native** - Showcases AAP running real automation (great demo story)
- **Web UI visibility** - Users can watch playbook execution in AAP UI
- **Minimal venv** - ~50 MB with ansible-core (vs 150+ MB with full Ansible suite)
- **Better error handling** - Ansible's built-in retry/status checking
- **Infrastructure as code** - Playbooks are self-documenting
- **Idempotent** - Can run multiple times safely
- **Reusable pattern** - Establishes API-driven addon pattern for other AAP-based workflows

### Negative

- **Learning curve** - More complex than pure bash addon
- **File copy overhead** - Tar-free method slower than `kubectl cp` (but more compatible)
- **Debugging** - Must check AAP UI for job logs, not just local stdout
- **API changes** - Vulnerable to AAP API version changes
- **Timestamp paths** - Creates new project path each run (old paths left behind)

### Neutral

- **Namespace fix** - Also fixed MicroShift compatibility by replacing `Project`/`ProjectRequest` with `Namespace` (unrelated to API approach)
- **Same playbooks** - No changes to official APME playbooks themselves
- **Small venv** - Still needs venv for ansible-core, but much smaller than original approach

## Migration Notes

**From venv-based (ADR-019) to AAP-native (ADR-019b):**

1. No user action required - deployment command is the same
2. Venv now contains `ansible-core` instead of just PyYAML
3. `~/.aap-demo/apme-eap-venv/` is still created but much smaller (~50 MB vs 150+ MB)
4. Token creation is automatic (no manual Web UI steps)

## Test Plan

See [TEST_PLAN.md](../../addons/apme-eap/TEST_PLAN.md) for comprehensive test cases covering:
- Clean installation and idempotent re-runs
- Token auto-creation and AAP resource creation
- MicroShift compatibility and tar-free file copy
- Error handling and security validation
- Performance benchmarks

## References

- [ADR-019](019-apme-eap-addon.md): Original APME playbook addon design
- [AAP REST API Documentation](https://docs.ansible.com/automation-controller/latest/html/controllerapi/)
- [ADR-004](004-portal-helm-addon.md): Portal Helm addon (similar pattern)
- [addons/apme-eap/README.md](../../addons/apme-eap/README.md): Updated addon documentation
- [addons/apme-eap/TEST_PLAN.md](../../addons/apme-eap/TEST_PLAN.md): Comprehensive test plan
