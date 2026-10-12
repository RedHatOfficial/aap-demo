# ADR-032: OAuth2 SSO for AAP/AO Authentication

**Status**: Accepted

**Date**: 2026-10-09

**Authors**: Brian Grimmett, Claude Code

## Context

Users working with both Ansible Automation Platform (AAP) and Automation Orchestrator (AO) in the aap-demo environment must authenticate separately to each system. This creates friction in development workflows, demos, and integration testing where seamless navigation between AAP Controller UI and AO UI is expected.

### Problem Statement

When a user logs into AAP Controller and then navigates to AO, they encounter a second login prompt. This breaks the flow of demos, requires managing multiple sessions, and creates unnecessary cognitive load during development. For environments where both systems are meant to work together seamlessly, this separate authentication is a barrier to productivity.

### Existing Authentication Landscape

- **AAP**: Uses Gateway authentication with local admin account (`admin` with auto-generated password)
- **AO**: Separate local admin account (`admin` with separate auto-generated password stored in `automation-orchestrator-initial-admin-password` secret)
- **Portal addon**: Already demonstrates OAuth2/OIDC integration with AAP as the identity provider
- **Current AAP ↔ AO integration**: API-level only, using pre-generated OAuth2 bearer tokens for AO to call AAP APIs, not for user authentication

### Constraints

- **MicroShift development environment**: Self-signed certificates, nip.io routes, limited DNS resolution
- **Automation requirement**: Must work with `aap-demo enable ao` without manual configuration
- **AAP Gateway limitations**: OAuth2 `client_secret` is only returned at application creation time, never on subsequent reads
- **Network isolation**: AO pods need `hostAliases` to resolve route hostnames to ingress ClusterIP
- **Idempotency**: Wire functions must be safe to run multiple times

### Forces at Play

- AAP Gateway provides OAuth2/OIDC capabilities (authorization-code flow, RS256 signing)
- AO supports OIDC identity providers via API with pre-built AAP template
- Portal addon established a pattern for OAuth2 app creation and credential persistence
- Existing wire infrastructure already handles AAP ↔ AO integration and network configuration
- Users expect single sign-on in modern web applications

## Decision

Implement OAuth2-based single sign-on (SSO) using OpenID Connect (OIDC) with AAP Gateway as the identity provider and AO as the relying party. This configuration will be automated via the existing `includes/addon-wire.sh` infrastructure, invoked automatically when `aap-demo enable ao` completes.

### OAuth2 Application in AAP

Create an OAuth2 application in AAP Gateway with the following characteristics:

- **Name**: "Automation Orchestrator (aap-demo)"
- **Authorization Grant Type**: `authorization-code` (standard OAuth2 flow for web applications)
- **Client Type**: `confidential` (client can securely store a secret)
- **Redirect URI**: `https://{AO_ROUTE}/api/v1/auth/oidc/callback`
- **Organization**: Default AAP organization (first available)
- **Client Credentials**: Persisted locally to `~/.aap-demo/ao/oauth_credentials.json` with mode 600

### OIDC Identity Provider in AO

Configure AAP as an OIDC identity provider in AO via the AO API (`POST /api/v1/identity-providers/`) with:

- **Template**: `ansible_automation_platform` (pre-configured scopes, claims, group extraction)
- **Issuer URL**: `https://{AAP_ROUTE}/o/` (note the `/o/` suffix required by AAP Gateway)
- **OIDC Discovery**: Enabled (uses `/.well-known/openid-configuration` endpoint)
- **Scopes**: `read write openid roles` (pre-configured by template)
- **TLS Verification**: Disabled (required for self-signed MicroShift certificates)
- **Single Logout**: Enabled via `enable_rp_initiated_logout` (logs out of both systems)
- **Role Mapping**: Enabled via `map_aap_system_roles_to_groups` (AAP admins → AO admins)
- **Allow All Authenticated**: Enabled (all AAP users can access AO)

### Pre-configured Claims and Mappings

The `ansible_automation_platform` template in AO pre-configures:

| Claim Purpose | Claim Name | Description |
|---------------|------------|-------------|
| Subject | `sub` | Unique user identifier |
| Email | `email` | User email address |
| Username | `preferred_username` | Display username |
| First name | `given_name` | User's first name |
| Last name | `family_name` | User's last name |
| Teams | `aap_teams` | Array of `{organization, name}` objects |
| Organizations | `aap_organizations` | Array of `{name}` objects |
| System role | `aap_system_role` | `system_administrator`, `system_auditor`, or `normal_user` |

**Group Extraction** (JMESPath expression):
```
[aap_teams[*].join('/', [organization, name]), aap_organizations[*].name] | []
```

This extracts:
- Team memberships formatted as `organization/team` (e.g., `Default/network-admins`)
- Organization memberships (e.g., `Default`)

**System Role Mapping**:
- `system_administrator` → AO `admins` group
- `system_auditor` → AO `auditors` group  
- `normal_user` → AO `users` group (implicit, via `allow_all_authenticated`)

### Wire Integration

Add new functions to `includes/addon-wire.sh`:

1. **`wire_ao_oauth_app()`**: Creates/reuses OAuth2 application in AAP Gateway
   - Follows portal addon pattern (`addons/portal/deploy.sh:412-500`)
   - Handles credential persistence and `client_secret` retrieval limitation
   - Idempotent: reuses existing app if credentials are available, recreates if lost

2. **`wire_ao_oidc_provider()`**: Configures OIDC identity provider in AO
   - Uses AO API: `POST /api/v1/identity-providers/`
   - Checks for existing provider by name for idempotency
   - Returns success/failure status

3. **`wire_ao_oauth_sso()`**: Orchestrates OAuth2 app creation and OIDC configuration
   - Calls `wire_ao_oauth_app()` to get client credentials
   - Calls `wire_ao_oidc_provider()` with credentials
   - Logs success message with user instructions

4. **`wire_ao_delete_oauth_app()`**: Cleanup function for OAuth app deletion
   - Called from `addons/ao/deploy.sh --delete`
   - Deletes OAuth2 app from AAP Gateway
   - Removes local credential file

Integration point in `aap_demo_wire()`:
```bash
# After existing wire_ao_aap, wire_ao_mcp, wire_ao_llm
if wire_ao_deployed; then
  wire_ao_oauth_sso || wire_warn "Could not configure AAP/AO OAuth SSO"
fi
```

### Credential Management

Following the portal addon pattern, OAuth2 credentials are persisted locally:

**Directory**: `~/.aap-demo/ao/` (existing directory, mode 700)

**File**: `oauth_credentials.json` (new file, mode 600)

**Format**:
```json
{
  "oauth_app_id": "123",
  "client_id": "abc123",
  "client_secret": "xyz789"
}
```

**Rationale**: AAP Gateway API only returns `client_secret` during OAuth application creation (POST response). Subsequent GET requests never include it. Therefore:
- Save credentials immediately after creation
- Check saved credentials before attempting to reuse an existing app
- If app exists but credentials are unavailable, delete and recreate the app

### User Experience

After `aap-demo enable ao` completes, users can:

1. **Navigate to AO UI**: `aap-demo status` shows the AO route
2. **Login options**: AO login page displays:
   - Local admin login (default AO form)
   - "Log in with Ansible Automation Platform" button
3. **SSO flow**:
   - Click "Log in with Ansible Automation Platform"
   - Redirect to AAP Gateway login
   - Enter AAP credentials (or already logged in)
   - AAP Gateway redirects back to AO with authorization code
   - AO exchanges code for token and establishes session
4. **Single logout**: When logging out of AO, AAP session also ends (RP-initiated logout)

## Consequences

### Positive

- **Seamless user experience**: Navigate between AAP and AO without re-authenticating
- **Consistent identity**: Same user account across both systems
- **Automated setup**: No manual OAuth app creation or OIDC configuration required
- **Group mapping**: AAP teams and organizations automatically become AO groups
- **Role mapping**: AAP system administrators automatically have admin access in AO
- **Idempotent wire function**: Safe to run multiple times, handles credential persistence
- **Follows established patterns**: Reuses portal addon's OAuth2 app creation pattern
- **Single logout**: Logging out of AO also ends AAP session, preventing session confusion

### Negative

- **Additional OAuth app**: One more OAuth application to manage in AAP Gateway
- **Credential persistence**: `client_secret` stored locally in `~/.aap-demo/ao/`, requires file permissions management
- **AAP Gateway dependency**: AO SSO depends on AAP Gateway API availability
- **Self-signed certificate complexity**: `disable_tls_verification` required for MicroShift development environment
- **Debugging surface**: More components in the authentication flow (AAP OAuth, OIDC discovery, token exchange)
- **Two login methods**: Users can still log in with local AO admin account, creating potential confusion

### Neutral

- **Local AO admin remains**: Built-in administrator account still exists for emergency access or troubleshooting
- **API integration unchanged**: Existing AAP ↔ AO API integration (OAuth tokens for programmatic access) continues to work
- **No AO CR changes**: OIDC configuration is post-deployment via API, not in `AutomationOrchestrator` spec
- **Namespace isolation**: OAuth app cleanup happens via API deletion, AO identity provider deleted with namespace
- **Group mappings optional**: Automatic role mapping sufficient for most use cases, but custom group mappings can be added manually if needed

## Alternatives Considered

### Automated Template Method

AO documentation describes a simplified "Add Ansible Automation Platform" workflow that automatically:
- Creates the OAuth2 application in AAP
- Configures the OIDC provider in AO
- Sets up all mappings

**Pros**:
- Single API call in AO
- Less code to maintain
- Automatic discovery of AAP capabilities

**Cons**:
- Less transparent (don't know what OAuth app settings were used)
- Not scriptable via standard AAP API (requires AO to call AAP on our behalf)
- Harder to debug when something fails
- Doesn't follow established aap-demo patterns

**Why rejected**: aap-demo prioritizes transparency, scriptability, and consistency with existing patterns. The manual approach gives full control over OAuth app configuration and follows the proven portal addon pattern.

### Separate Authentication Systems

Keep AAP and AO authentication separate, requiring users to log in to each independently.

**Pros**:
- Simpler implementation (no OAuth apps or OIDC configuration)
- No credential management
- Clear separation of concerns

**Cons**:
- User friction (two separate logins)
- Inconsistent user experience
- Doesn't align with product direction (AAP and AO are meant to integrate)
- Breaks demo flow when switching between systems

**Why rejected**: The problem statement explicitly identifies user friction as the core issue to solve. Keeping separate auth systems doesn't address the problem.

### API Tokens Only

Continue using OAuth2 bearer tokens for API access but don't configure user-level SSO.

**Pros**:
- Already implemented
- Sufficient for programmatic API access
- No additional OAuth apps needed

**Cons**:
- Doesn't address UI login friction
- Users still need to log in twice
- No benefit for interactive workflows

**Why rejected**: API tokens solve a different problem (programmatic integration). They don't address the user experience issue of navigating between AAP and AO UIs.

### Environment Variable Configuration

Instead of API-based OIDC configuration, configure OIDC via environment variables on AO backend deployment.

**Pros**:
- Configuration visible in deployment manifest
- No API calls required after deployment
- Easier to inspect current state

**Cons**:
- AO product doesn't support environment-variable-based OIDC configuration
- Would require operator changes (not in scope for addon)
- Less flexible than API-based configuration

**Why rejected**: Not supported by AO product architecture. Identity providers are configured via API, not environment variables.

## References

- [Issue #224: OAuth2 SSO integration for unified AAP/AO authentication](https://github.com/RedHatOfficial/aap-demo/issues/224)
- [AO Documentation: Add Ansible Automation Platform as an identity provider](https://docs.redhat.com/en/documentation/automation_orchestrator/2026.8/)
- [Portal addon OAuth2 implementation](../../addons/portal/deploy.sh) (lines 412-500)
- [ADR-017: Automation Orchestrator Addon](017-ao-addon.md)
- [ADR-023: Addon Auto-Wiring](023-addon-auto-wiring.md)
- [AAP Gateway OAuth2 API](https://access.redhat.com/documentation/en-us/red_hat_ansible_automation_platform/2.7/)
- [OIDC Authorization Code Flow](https://openid.net/specs/openid-connect-core-1_0.html#CodeFlowAuth)
- [OAuth 2.0 RFC 6749](https://datatracker.ietf.org/doc/html/rfc6749)

## Amendment Log

| Date | Change |
|------|--------|
| 2026-10-09 | Initial decision: Implement OAuth2 SSO for AAP/AO using OIDC authorization code flow |
