# Collection Authentication for aap-demo

This guide explains how to configure authentication for downloading Ansible collections from Red Hat's certified content sources and Private Automation Hub (PAH).

## Overview

aap-demo supports multiple collection sources with automatic priority-based selection:

1. **Private Automation Hub** (PAH) — your organization's private collections
2. **console.redhat.com** — Red Hat certified collections
3. **galaxy.ansible.com** — community collections (fallback)

Authentication is optional but recommended for accessing certified collections like `ansible.controller` and `infra.aap_configuration`.

## Getting a console.redhat.com Token

Red Hat Automation Hub offline tokens allow CLI access to certified collections.

### Steps

1. Log in to [Red Hat Hybrid Cloud Console](https://console.redhat.com)
2. Navigate to **Ansible** → **Automation Hub** → **Connect to Hub**
3. Click **Load token**
4. Copy the **Offline Token** (long base64 string, ~1500 characters)
5. Save to `~/.aap-demo/galaxy-token`:

   ```bash
   echo "YOUR_OFFLINE_TOKEN_HERE" > ~/.aap-demo/galaxy-token
   chmod 600 ~/.aap-demo/galaxy-token
   ```

### Token Scope

Offline tokens provide access to:

- Red Hat Certified Content Collections
- Red Hat Ansible Automation Platform collections
- Execution environments

Tokens are tied to your Red Hat account and subscription entitlements.

## Configuring Private Automation Hub (PAH)

If your organization runs a Private Automation Hub, you can prioritize it over console.redhat.com.

### Configuration File Format

Create `~/.aap-demo/pah-config.yml`:

```yaml
# Token-based authentication (recommended)
url: https://pah.example.com
token: YOUR_PAH_TOKEN_HERE
```

Or username/password authentication:

```yaml
# Username/password authentication
url: https://pah.example.com
username: your-username
password: your-password
```

### Getting a PAH Token

Token generation varies by PAH version:

**AAP 2.4+:**

1. Log into PAH web UI
2. Navigate to **User Preferences** → **API Token**
3. Click **Load token** or **Generate new token**
4. Copy and save to `pah-config.yml`

**Earlier versions:** Use username/password in config file.

## Collection Source Priority

aap-demo uses the first available source:

| Priority | Source | Credential Required | Collections Available |
|----------|--------|---------------------|----------------------|
| 1 | Private Automation Hub | PAH token/credentials | Your organization's collections |
| 2 | console.redhat.com | Offline token | Red Hat Certified |
| 3 | galaxy.ansible.com | None | Community |

### Example Scenarios

**Scenario 1: No authentication configured**

- Downloads from `galaxy.ansible.com` only
- Community collections install successfully
- Certified collections (`ansible.controller`, `infra.aap_configuration`) fail

**Scenario 2: console.redhat.com token configured**

- Downloads certified collections from console.redhat.com
- Falls back to galaxy.ansible.com for community-only collections
- Recommended for most users

**Scenario 3: PAH + console.redhat.com both configured**

- Tries PAH first (for private collections)
- Falls back to console.redhat.com (for certified collections)
- Uses galaxy.ansible.com for community collections
- Recommended for enterprise deployments

## Deployment Workflow

When you run `aap-demo deploy`, the tool automatically:

1. **Detects credentials**: Checks `~/.aap-demo/galaxy-token` and `~/.aap-demo/pah-config.yml`
2. **Validates authentication**: Verifies token formats and configuration
3. **Generates ansible.cfg**: Creates galaxy server configuration with detected sources
4. **Installs collections**: Runs `ansible-galaxy collection install -r config/requirements.yml`

### Requirements File

Default collections in `config/requirements.yml`:

```yaml
collections:
  # Red Hat Certified (require console.redhat.com authentication)
  - name: ansible.controller
    version: ">=4.6.0"
  - name: infra.aap_configuration
    version: ">=2.10.0"

  # Community (available without authentication)
  - name: kubernetes.core
    version: ">=2.4.0"
  - name: community.general
    version: ">=6.0.0"
```

You can customize by editing this file or creating your own.

## Skipping Collection Installation

To deploy AAP without installing collections:

```bash
SKIP_COLLECTIONS=true aap-demo deploy
```

Useful for:

- Testing deployment without waiting for collection downloads
- Using pre-installed collections
- Troubleshooting authentication issues

## Checking Collection Status

### View Configured Sources

```bash
aap-demo status
```

Shows:

- Which galaxy servers are configured
- Whether console.redhat.com token is present
- Number of installed certified collections

Example output:

```
Collection Sources:
-------------------
  Red Hat Certified:   console.redhat.com (authenticated)
  Community:           galaxy.ansible.com
  Installed:           4 certified collections
```

### Diagnose Collection Issues

```bash
aap-demo diagnose
```

Validates:

- `ansible.cfg` galaxy server configuration
- Credential file existence
- Required collection installation

Example output:

```
Collection Sources:
  ✓ ansible.cfg exists
  ✓ Galaxy server configuration present
  ✓ console.redhat.com token present
  ✓ Collection ansible.controller installed
  ✓ Collection infra.aap_configuration installed
```

## Troubleshooting

### Error: "Failed to install collections"

**Cause**: Authentication failure or network issue.

**Solutions**:

1. **Verify token format**:

   ```bash
   wc -c ~/.aap-demo/galaxy-token
   # Should show ~1500 characters for offline token
   ```

2. **Test connectivity**:

   ```bash
   curl -H "Authorization: Bearer $(cat ~/.aap-demo/galaxy-token)" \
     https://console.redhat.com/api/automation-hub/v3/collections/
   ```

3. **Check subscription access**:
   - Log into https://console.redhat.com
   - Verify active Red Hat Ansible Automation Platform subscription

4. **Skip collections temporarily**:

   ```bash
   SKIP_COLLECTIONS=true aap-demo deploy
   ```

### Error: "Invalid galaxy token format (too short)"

**Cause**: Token file contains a refresh token instead of an offline token, or is corrupted.

**Solution**: Return to console.redhat.com and copy the **Offline Token** (not the Refresh Token). Offline tokens are ~1500 characters.

### Warning: "Collection ansible.controller not found"

**Cause**: Collection requires Red Hat Certified content access.

**Solutions**:

1. **Configure console.redhat.com token** (see above)
2. **Use community alternative**: Edit `config/requirements.yml` to use `awx.awx` instead of `ansible.controller`

### PAH Connection Failures

**Cause**: PAH URL unreachable or credentials invalid.

**Solutions**:

1. **Verify URL**: Test PAH accessibility:

   ```bash
   curl https://pah.example.com/api/galaxy/
   ```

2. **Check token/credentials**: Log into PAH web UI with same credentials

3. **Remove PAH config temporarily**:

   ```bash
   mv ~/.aap-demo/pah-config.yml ~/.aap-demo/pah-config.yml.bak
   aap-demo deploy
   ```

## Environment Variables

Override default file locations:

```bash
GALAXY_TOKEN_FILE=~/custom/path/token aap-demo deploy
PAH_CONFIG_FILE=~/custom/path/pah.yml aap-demo deploy
SKIP_COLLECTIONS=true aap-demo deploy
```

## Security Considerations

**Token Storage**: Tokens are stored in plaintext files. Protect with file permissions:

```bash
chmod 600 ~/.aap-demo/galaxy-token
chmod 600 ~/.aap-demo/pah-config.yml
```

**Token Rotation**: Offline tokens don't expire automatically, but should be rotated periodically:

1. Generate new token from console.redhat.com
2. Update `~/.aap-demo/galaxy-token`
3. No redeployment needed — new collections will use new token

**Future Enhancement**: Keyring integration for encrypted credential storage (tracked in future ADR).

## References

- [Red Hat Automation Hub Documentation](https://access.redhat.com/documentation/en-us/red_hat_ansible_automation_platform/)
- [Ansible Galaxy CLI Documentation](https://docs.ansible.com/ansible/latest/galaxy/user_guide.html)
- [ADR-016: Console.redhat.com and PAH Authentication](../adr/016-console-pah-authentication.md)
