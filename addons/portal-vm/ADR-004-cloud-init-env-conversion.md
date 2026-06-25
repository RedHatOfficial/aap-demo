# ADR-004: Cloud-Init Environment Variable Conversion Issue

**Status:** Active Investigation
**Date:** 2026-06-25
**Author:** Investigation
**Related:** Portal appliance 2.2.1 deployment

## Context

Portal appliance login fails: "Failed to create user: Failed to fetch user details for admin (ID: 2)".

### Investigation Findings

Portal appliance cloud-init processing incomplete. Some AAP config fields convert to env vars, others don't.

**Cloud-init user-data (confirmed correct per docs p212):**

```yaml
aap:
  host_url: "https://aap-aap-operator.apps.127.0.0.1.nip.io"
  token: "yGGsR5h4KJYwILVerEiBLDAsxldKCWgw"
  check_ssl: false
  oauth:
    client_id: "XK4f3RTrwLDXaEfnWmJJbHFMtJB4QQ4zHXF7i4E7"
    client_secret: "y6rqg7ChLG6iEMmHpP4L3wHx6oiAsaA1nnrVJxHV..."
```

**Portal container env vars (actual):**

```bash
AAP_CHECK_SSL=False
AAP_OAUTH_CLIENT_SECRET=y6rqg7ChLG6iEMmHpP4L3wHx6oiAsaA1nnrVJxHV...
AAP_TOKEN=yGGsR5h4KJYwILVerEiBLDAsxldKCWgw
```

**Missing env vars:**

- `AAP_HOST_URL` (should be https://aap-aap-operator.apps.127.0.0.1.nip.io)
- `AAP_OAUTH_CLIENT_ID` (should be XK4f3RTrwLDXaEfnWmJJbHFMtJB4QQ4zHXF7i4E7)

### Error Chain

1. Portal OAuth flow succeeds (has client_id from somewhere - maybe app-config.production.yaml hardcoded default)
2. After OAuth, catalog backend plugin tries fetch AAP user entity
3. Plugin uses `AAP_HOST_URL` env var for backend API calls
4. Env var missing → API calls fail or go to wrong host
5. User entity fetch fails → "Failed to fetch user details"

## Root Cause Hypothesis

Portal appliance cloud-init processor (custom cloud-init module) has bug converting nested YAML to env vars:

- ✅ Top-level scalar: `aap.token` → `AAP_TOKEN` (works)
- ✅ Top-level boolean: `aap.check_ssl` → `AAP_CHECK_SSL` (works)
- ❌ Top-level string: `aap.host_url` → `AAP_HOST_URL` (FAILS)
- ✅ Nested scalar: `aap.oauth.client_secret` → `AAP_OAUTH_CLIENT_SECRET` (works)
- ❌ Nested scalar: `aap.oauth.client_id` → `AAP_OAUTH_CLIENT_ID` (FAILS)

Pattern: Underscored field names (`host_url`, `client_id`) not converting. Non-underscored work (`token`, `check_ssl` → `checkssl`).

## Workarounds Implemented

### Systemd Environment Override (SUCCESSFUL)

Added second drop-in to inject missing env vars:

```yaml
write_files:
  - path: /etc/containers/systemd/portal.container.d/20-aap-env.conf
    owner: root:root
    permissions: '0644'
    content: |
      [Container]
      Environment=AAP_HOST_URL=https://$aap_route
      Environment=AAP_OAUTH_CLIENT_ID=$client_id
```

Verified fix: all env vars now present in container.

### API Token Fix (REQUIRED)

Second bug discovered: `AAP_TOKEN` was admin password, not API token.

**Root cause:** Portal backend catalog plugin needs Bearer token for `/api/gateway/v1/*` API calls. Admin password works for OAuth app creation but fails for catalog operations.

**Fix:** Modified `get_aap_credentials()` to create API token via AAP Gateway API:

```bash
api_token=$(curl --cacert "$ca_bundle" -s -u "admin:$admin_pass" \
  -X POST "https://$aap_route/api/gateway/v1/tokens/" \
  -H "Content-Type: application/json" \
  -d '{"description":"Portal backend catalog","application":null,"scope":"write"}' | \
  jq -r '.token // empty')
```

Added TLS verification using cluster CA bundle from `router-certs-default` secret.

## Resolution

Status: **RESOLVED**

Both bugs fixed in deploy.sh:

1. Cloud-init env conversion bug → systemd `Environment=` override
2. Wrong token type → API token creation via Gateway API

Portal login now works end-to-end.

## References

- AAP Extend docs p212: Required cloud-init fields
- Portal logs: `Failed to fetch user details for admin (ID: 2)`
- Container env: `sudo podman exec portal env | grep AAP_`
- Cloud-init user-data: `~/.aap-demo/portal-vm/user-data`
