# Collection Authentication for aap-demo

This guide explains how to configure authentication for downloading collections from Red Hat sources and Private Hub.

## Overview

aap-demo supports multiple collection sources with automatic priority-based selection:

1. **Private Automation Hub** (PAH) — your organization's private collections
2. **console.redhat.com** — Red Hat certified collections
3. **galaxy.ansible.com** — community collections (fallback)

Authentication is optional but recommended for accessing certified collections like `ansible.controller` and `infra.aap_configuration`.

## Getting a console.redhat.com Token

Red Hat Automation Hub offline tokens allow CLI access to certified collections.
They are distinct from Customer Portal API offline tokens generated at
`access.redhat.com/management/api`. Customer Portal tokens use the `rhsm-api`
OAuth client; Automation Hub tokens use `cloud-services`.

`aap-demo enable setup-pah` validates the Automation Hub credential before
configuring remotes. The two tokens remain separate in encrypted storage. Red
Hat requires the Automation Hub token to be generated interactively; the
Customer Portal API does not provide an endpoint that can generate it.

### Steps

1. Log in to [Red Hat Hybrid Cloud Console](https://console.redhat.com)
2. Navigate to **Ansible** → **Automation Hub** → **Connect to Hub**
3. Click **Load token**
4. Copy the **Offline Token** (long base64 string, ~1500 characters)
5. Run the setup command and paste the token at its hidden prompt:

   ```bash
   aap-demo enable setup-pah
   ```

   The token is stored as `ah_offline_token` in the encrypted
   `~/.ansible/conf/env.yml` Vault. Its password file is
   `~/.ansible/conf/.vaultpass.txt`.

### Automated validation, storage, and four-day cron

Run this on the host as the user who owns the Vault (no cluster is required):

```bash
aap-demo credentials keepalive setup
```

The command:

1. Reads the encrypted Vault without printing its contents and checks
   `ah_offline_token`. The older `aap_demo.galaxy.offline_token` key is also
   accepted; subsequent token updates use `ah_offline_token`.
2. Validates the token with a POST to Red Hat SSO using
   `grant_type=refresh_token` and `client_id=cloud-services`. Both HTTP 200 and
   a nonempty JSON `access_token` are required.
3. Reuses a valid stored token without prompting or rewriting the Vault.
   Missing, expired, or revoked tokens trigger a hidden prompt. Empty or
   rejected entries are retried and are never saved.
4. Stops on decryption errors, network failures, server errors, or malformed
   SSO responses. It does not replace credentials merely because validation
   could not complete. Resolve the error and rerun the command.
5. Encrypts token updates with `ansible-vault`, preserving unrelated YAML
   secrets. The Vault directory is mode `0700`; the Vault and password file
   are mode `0600`.
6. Installs or updates one marked entry in the current user's crontab, preserving
   unrelated jobs. Install `crontab` and enable the host's cron service first.

The schedule is **`0 0 */4 * *`** (midnight on days 1, 5, 9, etc., in cron's
configured timezone). This matches the requested four-day cron expression,
but is not an exact 96-hour interval across month boundaries. Cron does not
catch up on missed runs when the host is off.

The cron command invokes
[`scripts/aap-demo-token-keepalive.sh`](../scripts/aap-demo-token-keepalive.sh)
with `run-hub`, capturing the configured Vault, password-file, and tool paths.
It reads the current token at every run, so rotation requires no cron update.
The token is sent to curl over standard input with
`--data-urlencode refresh_token@-`, not embedded in the crontab or curl's
process arguments. Responses and short-lived access tokens are discarded;
only secret-free status/error messages are written to cron output/mail.

```bash
aap-demo credentials keepalive status
bash scripts/aap-demo-token-keepalive.sh run-hub  # Check Hub only
aap-demo credentials keepalive disable           # Remove managed schedules
```

`setup` adds the Hub cron job; it does not remove an existing daily systemd or
LaunchAgent schedule. To switch instead of running both, first run
`aap-demo credentials keepalive disable`, then `setup`. The existing `enable`
action remains available for daily checks of both Customer Portal and Hub
tokens. Neither keepalive can renew a revoked token; rerun `setup` to replace it.

### Supplying the Vault password

Prerequisites are Bash, curl, `ansible-vault`, and Python 3 with PyYAML.
The automation passes `--vault-password-file` to `ansible-vault`. By default it
uses `~/.ansible/conf/.vaultpass.txt`. For a new Vault only, a cryptographically
random password file is created automatically. An existing Vault with a
missing or incorrect password causes an error; its password is never replaced.
An existing shared password file is reused without changing its contents and
is preserved during uninstall, even if no Vault remains. An empty or unusable
password file causes an error rather than being overwritten.

The shared default is:

```bash
export AAP_DEMO_VAULT_PASSWORD_FILE="$HOME/.ansible/conf/.vaultpass.txt"
export AAP_DEMO_VAULT_FILE="$HOME/.ansible/conf/env.yml"
chmod 600 "$AAP_DEMO_VAULT_PASSWORD_FILE"
aap-demo credentials keepalive setup
```

Use absolute paths. Keep the password file available for unattended cron runs.
Do not pass the password or token as CLI arguments or paste them into chat.
Tool paths may also be selected with `AAP_DEMO_ANSIBLE_VAULT` and
`AAP_DEMO_VAULT_PYTHON` when using a virtual environment.

For interactive manual inspection, Ansible can prompt for the Vault password:

```bash
ansible-vault view --ask-vault-pass "$HOME/.ansible/conf/env.yml"
```

That command displays secrets: use it only in a private terminal. A password
prompt cannot be used by unattended cron; supply the password file instead.
The token itself is prompted for only when needed and remains hidden. Do not
run credential setup with shell tracing (`bash -x`) enabled.

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

#### Scenario 1: No authentication configured**

- Downloads from `galaxy.ansible.com` only
- Community collections install successfully
- Certified collections (`ansible.controller`, `infra.aap_configuration`) fail

#### Scenario 2: console.redhat.com token configured**

- Downloads certified collections from console.redhat.com
- Falls back to galaxy.ansible.com for community-only collections
- Recommended for most users

#### Scenario 3: PAH + console.redhat.com both configured**

- Tries PAH first (for private collections)
- Falls back to console.redhat.com (for certified collections)
- Uses galaxy.ansible.com for community collections
- Recommended for enterprise deployments

## Deployment Workflow

When you run `aap-demo deploy`, the tool automatically:

1. **Detects credentials**: Reads the `aap_demo` namespace in `~/.ansible/conf/env.yml` and the non-secret PAH URL from `~/.aap-demo/pah-config.yml`
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

1. **Re-enter and validate the token**:

   ```bash
   aap-demo enable setup-pah
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

**Solution**: Return to console.redhat.com and copy the **Offline Token** (not the Refresh Token). They are ~1500 characters.

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

**Token Storage**: The Hub token is stored as `ah_offline_token`; other managed
credentials remain under `aap_demo` in Ansible Vault-encrypted
`~/.ansible/conf/env.yml`. The password file is
`~/.ansible/conf/.vaultpass.txt`:

```bash
chmod 700 ~/.ansible/conf
chmod 600 ~/.ansible/conf/env.yml ~/.ansible/conf/.vaultpass.txt
```

**Token Rotation**: Offline tokens can expire after 30 days without use and
should be rotated when rejected:

1. Generate a new Automation Hub token from
   `https://console.redhat.com/ansible/automation-hub/token`
2. Run `aap-demo enable setup-pah` and paste the replacement at the hidden prompt
3. No redeployment needed — new collections will use new token

Use `aap-demo credentials keepalive enable` to validate the separate Customer
Portal and Automation Hub tokens daily without storing short-lived access
tokens, or `aap-demo credentials keepalive setup` for the Hub-only four-day
cron workflow described above.

Co-locating the encrypted Vault and password prevents accidental publication,
but does not protect against compromise of the local user account.

## References

- [Red Hat Automation Hub Documentation](https://access.redhat.com/documentation/en-us/red_hat_ansible_automation_platform/)
- [Ansible Galaxy CLI Documentation](https://docs.ansible.com/ansible/latest/galaxy/user_guide.html)
- [ADR-016: Console.redhat.com and PAH Authentication](../adr/016-console-pah-authentication.md)
