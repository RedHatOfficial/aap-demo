# ADR-016: Console.redhat.com and Private Automation Hub Authentication

**Status**: Accepted

**Date**: 2026-07-08

**Authors**: aap-demo maintainers

## Context

aap-demo deploys Ansible Automation Platform 2.7 to OpenShift Local for development
and testing. Users frequently need certified and private Ansible collections that are
**not** published to the public `galaxy.ansible.com`:

- **Certified collections** (e.g. `ansible.controller`, `redhat.rhel_system_roles`) are
  available from `console.redhat.com` with a valid Red Hat subscription
- **Private collections** (internal, pre-release, or organization-specific) are
  published to Private Automation Hub (PAH) instances

Currently, aap-demo has **no authentication mechanism** for either source. Users must:

1. Manually configure `ansible.cfg` with galaxy server entries
2. Generate and copy offline tokens from console.redhat.com
3. Manually install collections via `ansible-galaxy collection install` after deployment
4. Re-authenticate on every cluster recreate

This creates significant friction:

- **Manual overhead**: 5-10 minutes of repetitive authentication and collection installs
- **Inconsistent environments**: developers use different collection versions depending
  on when they last installed
- **Testing gaps**: CI/CD pipelines skip certified collections due to auth complexity
- **Credential exposure**: tokens pasted into shell commands and config files
- **Version drift**: manual installs may pull newer patch versions than production uses

Requirements:

- Auto-detect console.redhat.com **offline token** from `~/.aap-demo/galaxy-token`
- Support PAH authentication via `~/.aap-demo/pah-config.yml`
- Prioritize collection sources: PAH → console.redhat.com → galaxy.ansible.com
- Auto-generate `ansible.cfg` with multiple galaxy servers
- Install collections from `requirements.yml` during `deploy`
- Clear error messages when tokens are missing or expired
- Show authenticated sources and available collections in `aap-demo status`
- Optional skip via `SKIP_COLLECTIONS=true` for environments without auth

## Decision

Implement a **multi-source authentication and collection management system** that:

1. **Detects credentials** from local config files (`~/.aap-demo/galaxy-token`,
   `~/.aap-demo/pah-config.yml`)
2. **Configures AAP's integrated Private Automation Hub** with console.redhat.com
   and external PAH remotes
3. **Syncs certified collections** into local PAH from console.redhat.com
4. **Auto-generates ansible.cfg** with prioritized galaxy servers for local use
5. **Validates authentication** before attempting collection downloads
6. **Reports source status** in `aap-demo status`

**Key insight**: AAP 2.7 includes an integrated Private Automation Hub instance.
Rather than configuring Controller to pull from external sources, we configure
PAH to **sync** from console.redhat.com, then Controller uses the local PAH.

### Credential detection and storage

#### console.redhat.com offline token

File: `~/.aap-demo/galaxy-token` (Windows: `%USERPROFILE%\.aap-demo\galaxy-token`)

Format: Single line containing the offline token from
https://console.redhat.com/ansible/automation-hub/token

```
eyJhbGciOiJIUzI1NiIsInR5cCIgOiAiSldUIiwia2lkIiA6ICI...
```

Generation:

- User logs into console.redhat.com
- Navigates to Connect to Hub → Get token
- Copies offline token to `~/.aap-demo/galaxy-token`

Token is refreshed automatically via OAuth2 device flow when expired.

#### Private Automation Hub (PAH) config

File: `~/.aap-demo/pah-config.yml`

Format:

```yaml
url: https://pah.example.com/api/galaxy/
token: your-pah-api-token-here
verify_ssl: true  # optional, defaults to true
```

Generation:

- User generates API token from PAH UI (Collections → API Token)
- Creates `pah-config.yml` with URL and token

### ansible.cfg generation

`includes/collection-install.sh` (bash) and
`powershell/native/Private/Helpers.ps1` (PowerShell) generate `ansible.cfg`:

```ini
[galaxy]
server_list = pah, console_redhat, galaxy

[galaxy_server.pah]
url=https://pah.example.com/api/galaxy/
token=<token-from-pah-config>

[galaxy_server.console_redhat]
url=https://console.redhat.com/api/automation-hub/
token=<token-from-galaxy-token>

[galaxy_server.galaxy]
url=https://galaxy.ansible.com/
```

**Priority order**: PAH → console.redhat.com → galaxy.ansible.com

- `ansible-galaxy collection install` tries servers in `server_list` order
- First successful download wins
- Private collections only exist in PAH → PAH must be first
- Certified collections exist in console.redhat.com → second priority
- Public collections fallback to galaxy.ansible.com

Missing credentials result in omitted server entries (e.g., no PAH config → only
console_redhat and galaxy in `server_list`).

### Collection installation flow

During `aap-demo deploy`:

1. **Detect credentials** from `~/.aap-demo/`
2. **Configure AAP PAH remotes** via Pulp API:
   - Update `rh-certified` remote with offline token from `galaxy-token`
   - Trigger background sync of certified collections
   - Create `external-pah` remote if `pah-config.yml` exists
3. **Generate ansible.cfg** in `~/.aap-demo/ansible.cfg` for local dev use
4. **Install collections locally** (optional) from `config/requirements.yml`:

   ```yaml
   collections:
     - name: ansible.controller
       version: ">=4.5.0"
     - name: containers.podman
   ```

#### PAH Remote Configuration

Uses Pulp API (`/api/galaxy/pulp/api/v3/`) to configure collection sources:

```bash
# Update rh-certified remote token
PATCH /remotes/ansible/collection/{uuid}/
{
  "token": "<offline-token-from-galaxy-token>"
}

# Sync repository
POST /repositories/ansible/ansible/{uuid}/sync/
{
  "mirror": false
}
```

Collections sync into PAH's `rh-certified` repository. Controller jobs then
pull from local PAH (`https://aap.../api/galaxy/content/rh-certified/`), not
external console.redhat.com.

Local `ansible.cfg` generation remains for CLI/dev use outside Controller.

### Error handling and user feedback

**Missing token**:

```
[WARN] console.redhat.com token not found at ~/.aap-demo/galaxy-token
       Collections from console.redhat.com will not be available.
       Generate token: https://console.redhat.com/ansible/automation-hub/token
```

**Expired token**:

```
[ERROR] console.redhat.com token expired. Attempting refresh...
[INFO] Token refreshed successfully.
```

**PAH unreachable**:

```
[WARN] Private Automation Hub at https://pah.example.com unreachable.
       Skipping PAH collections. Check VPN connection or pah-config.yml URL.
```

**Collection not found**:

```
[ERROR] Collection 'internal.custom_collection' not found in:
        - PAH (https://pah.example.com)
        - console.redhat.com
        - galaxy.ansible.com
        Ensure collection is published to PAH or check requirements.yml spelling.
```

### Status reporting

`aap-demo status` output includes:

```
Collection Sources:
  Private Automation Hub: ✓ Connected (https://pah.example.com)
  console.redhat.com: ✓ Authenticated
  galaxy.ansible.com: ✓ Available

Installed Collections:
  ansible.controller 4.5.1 (from console.redhat.com)
  containers.podman 1.11.0 (from galaxy.ansible.com)
  internal.custom_collection 2.3.0 (from PAH)
```

When `SKIP_COLLECTIONS=true` is set:

```
Collection Sources: Skipped (SKIP_COLLECTIONS=true)
```

### Opt-out behavior

Set `SKIP_COLLECTIONS=true` to bypass all collection authentication and installation:

```bash
export SKIP_COLLECTIONS=true
aap-demo deploy
```

Use cases:

- Air-gapped environments
- CI/CD pipelines with pre-cached collections
- Debugging cluster deployment without collection overhead

### Implementation files

| File | Responsibility |
|------|----------------|
| `includes/collection-install.sh` | Bash implementation (Linux/macOS) |
| `powershell/native/Private/Helpers.ps1` | PowerShell implementation (Windows) |
| `config/requirements.yml` | Default collection manifest |
| `~/.aap-demo/galaxy-token` | console.redhat.com offline token |
| `~/.aap-demo/pah-config.yml` | PAH URL and API token |
| `~/.aap-demo/ansible.cfg` | Generated multi-source galaxy config |

## Consequences

### Positive

- **Automation**: Zero-touch collection installation after initial credential setup
- **Consistency**: All developers use the same collection versions from `requirements.yml`
- **Reproducibility**: Cluster recreate restores authenticated sources automatically
- **Testing**: CI/CD can authenticate to console.redhat.com and PAH via file-based creds
- **Security**: Tokens stored in user home directory, not committed to git
- **Transparency**: `status` command shows exactly which sources are authenticated
- **Source priority**: Private collections shadow certified collections (PAH first)
- **Graceful degradation**: Missing PAH or console.redhat.com falls back to
  galaxy.ansible.com for public collections

### Negative

- **Credential management burden**: Users must manually generate and store tokens
  - console.redhat.com token generation requires Red Hat SSO login
  - PAH token requires PAH admin or self-service token creation
  - Token expiry requires manual refresh (OAuth2 refresh mitigates for console.redhat.com)
- **Token security**: Plaintext tokens in `~/.aap-demo/` rely on filesystem permissions
  - Mitigation: Files created with `0600` permissions (user read/write only)
  - Risk: Local malware or shared machines may expose tokens
- **Version drift in requirements.yml**: `>=4.5.0` may install different patch versions
  on different days
  - Mitigation: Pin exact versions (`==4.5.1`) when reproducibility is critical
- **Network dependency**: Collection install fails if PAH or console.redhat.com are
  unreachable at deploy time
  - Mitigation: Retry logic + fallback to cached collections in `~/.ansible/collections`
- **Windows credential store gap**: Tokens not integrated with Windows Credential Manager
  - Future work: Optional keyring integration via PowerShell `CredentialManager` module

### Neutral

- Collection install is orthogonal to AAP deployment (AAP itself runs without collections)
- `ansible-galaxy` CLI is already a dependency (ships with Ansible)
- Token rotation frequency depends on console.redhat.com and PAH policies (not
  controlled by aap-demo)
- Galaxy server priority order (PAH → console → galaxy) is the same priority used
  in production AAP deployments

## Alternatives Considered

### Manual ansible.cfg only (no auto-generation)

Rejected: High user friction; every developer must hand-edit `ansible.cfg` and
remember to update tokens after expiry. Does not solve version drift or consistency.

### AAP UI-based collection configuration only

Rejected: AAP UI requires post-deployment manual clicks; defeats automation goal.
Also does not help CLI users (`ansible-navigator`, `ansible-playbook`) outside AAP.

### Different priority order (console.redhat.com first, PAH second)

Rejected: Breaks common use case where private collections **shadow** certified
collections (e.g., `ansible.controller` with internal patches must override
console.redhat.com version). PAH must be first.

### Reverse priority order (galaxy.ansible.com first)

Rejected: Would always download public versions even when certified or private
versions exist. Defeats the purpose of PAH and console.redhat.com.

### Store tokens in environment variables instead of files

Rejected: Environment variables are less persistent (shell session scoped) and
harder to manage across `create`, `deploy`, `status` commands. Files allow
one-time setup.

### Keyring integration for credential storage

Considered but deferred: Would improve security on Windows (Credential Manager),
macOS (Keychain), and Linux (Secret Service API). However:

- Adds complexity (platform-specific keyring libraries)
- Not all environments have keyring available (headless CI/CD)
- File-based tokens are simpler for initial implementation

Future enhancement: Optional keyring backend when `~/.aap-demo/use-keyring` exists.

### Embed tokens in aap-demo config file

Rejected: Config file may be committed to version control or shared in screenshots.
Separate credential files reduce accidental exposure.

### Collection caching to avoid re-download on recreate

Already implemented: `ansible-galaxy` caches to `~/.ansible/collections`. Cluster
recreate does not trigger re-download unless collection versions change in
`requirements.yml`.

## References

- Issue #36: [Add console.redhat.com and PAH authentication](https://github.com/chadalen/aap-demo/issues/36)
- [console.redhat.com Automation Hub](https://console.redhat.com/ansible/automation-hub/)
- [Private Automation Hub documentation](https://access.redhat.com/documentation/en-us/red_hat_ansible_automation_platform/2.7/html/managing_red_hat_certified_and_ansible_galaxy_collections_in_automation_hub/)
- [ansible-galaxy collection install](https://docs.ansible.com/ansible/latest/cli/ansible-galaxy.html#ansible-galaxy-collection-install)
- [ansible.cfg galaxy_server configuration](https://docs.ansible.com/ansible/latest/reference_appendices/config.html#galaxy-server-list)
