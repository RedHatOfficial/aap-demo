# AAP API Token Setup

## Why a Token is Needed

AAP 2.7+ uses a unified gateway that requires either:
1. **Session-based auth** (cookies + CSRF tokens) - Complex for CLI automation
2. **OAuth2 tokens** - Simple Bearer token authentication

For the `apme-eap` addon to use AAP's REST API, we need an OAuth2 token.

## Creating an API Token

### Option 1: Via AAP Web UI (Recommended)

1. Open AAP in your browser:
   ```bash
   aap-demo status  # Get the AAP URL
   ```

2. Log in as `admin` (get password with: `aap-demo status`)

3. Navigate to: **Settings** → **Users** → **admin** → **Tokens**

4. Click **Add** to create a new token:
   - **Application**: Leave blank (creates personal access token)
   - **Description**: `aap-demo API access`
   - **Scope**: `Write`

5. **Copy the token** (you won't see it again!)

6. Store the token in a Kubernetes secret:
   ```bash
   kubectl create secret generic aap-api-token \
     -n aap-operator \
     --from-literal=token='YOUR_TOKEN_HERE'
   ```

### Option 2: Via AAP MCP Server (If Available)

If you have the AAP MCP server configured in Claude Code:

```bash
# The MCP server can create tokens programmatically
# (Implementation depends on MCP server capabilities)
```

### Option 3: Direct Database Access (Advanced)

**WARNING**: Direct database manipulation is not supported. Use Option 1 instead.

## Using the Token

Once created, the addon will automatically use the token:

```bash
# The deploy.sh script checks for the token secret
aap-demo enable apme-eap
```

The token is used as a Bearer token:
```bash
curl -k -H "Authorization: Bearer YOUR_TOKEN" \
  https://aap/api/controller/v2/organizations/
```

## Token Security

- **Scope**: Tokens should have minimal scope (`write` for deployment, `read` for queries)
- **Storage**: Stored in Kubernetes secrets (not version controlled)
- **Rotation**: Regenerate tokens periodically
- **Expiration**: Set expiration dates when creating tokens

## Troubleshooting

**Token not working?**
- Verify token exists: `kubectl get secret aap-api-token -n aap-operator`
- Check token hasn't expired in AAP UI
- Ensure scope is `write` (needed for creating resources)

**Can't access AAP UI?**
- Check route: `kubectl get route -n aap-operator`
- Get admin password: `kubectl get secret aap-controller-admin-password -n aap-operator -o jsonpath='{.data.password}' | base64 -d`
