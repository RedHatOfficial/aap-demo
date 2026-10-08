# Subscription Attach Addon

Automatically attaches a Red Hat subscription to Ansible Automation Platform (AAP) using Red Hat developer account credentials.

## Overview

This addon eliminates the manual step of logging into AAP UI and registering a subscription (Settings → Subscription). It uses the `infra.aap_configuration.controller_license` role to automatically lookup and attach a Red Hat developer subscription.

## Features

- **Automatic Subscription Lookup**: Queries Red Hat systems for available subscriptions
- **Secure Credential Storage**: Saves credentials locally with chmod 600 permissions
- **Multiple Input Methods**: Supports environment variables, credential files, or interactive prompts
- **Non-Blocking**: Warns on failure but doesn't break AAP deployment
- **Auto-Enabled**: Runs automatically after `aap-demo deploy` via addon-wire.sh integration

## How It Works

1. **After AAP Deployment**: Automatically triggered via `includes/addon-wire.sh` after AAP pods are running
2. **Credential Discovery**: Checks for credentials in this order:
   - Saved credentials file (`~/.aap-demo/redhat-subscription-credentials`)
   - Environment variables (`REDHAT_SUBSCRIPTION_USERNAME`, `REDHAT_SUBSCRIPTION_PASSWORD`)
   - Interactive prompt (if terminal is interactive and not in QUIET mode)
3. **Subscription Lookup**: Uses `infra.aap_configuration.controller_license` role with `use_lookup: true` to query Red Hat subscription API
4. **Automatic Attachment**: Attaches the first matching "Red Hat Ansible Automation Platform" subscription with "Self-Support" level
5. **Verification**: Confirms subscription was attached successfully

## Prerequisites

- AAP deployed via `aap-demo deploy`
- Red Hat developer account (free at [developers.redhat.com/register](https://developers.redhat.com/register))
- Ansible collection `infra.aap_configuration` installed (automatically installed with `aap-demo`)
- Tools: `ansible-playbook`, `kubectl`, `curl`, `jq`

## Usage

### Automatic (Recommended)

The addon runs automatically after `aap-demo deploy`:

```bash
aap-demo deploy
# ... AAP deploys ...
# Subscription prompt appears:
#   Red Hat username (email): your-email@example.com
#   Red Hat password: ********
# ✓ Subscription attached automatically
```

### Manual Trigger

To attach a subscription to an already-deployed AAP:

```bash
aap-demo enable subscription-attach
```

### Environment Variables

Skip interactive prompts by setting environment variables:

```bash
export REDHAT_SUBSCRIPTION_USERNAME="your-email@example.com"
export REDHAT_SUBSCRIPTION_PASSWORD="your-password"
aap-demo deploy
```

### Non-Interactive Mode

For CI/CD pipelines, use QUIET mode to skip prompts:

```bash
QUIET=true aap-demo deploy
# Skips subscription attachment if credentials not provided
```

## Credential Storage

### File Location

Credentials are saved to: `~/.aap-demo/redhat-subscription-credentials`

### File Format

```yaml
username: your-email@example.com
password: your-password
```

### Security

- File permissions: `chmod 600` (owner read/write only)
- Directory created with `umask 077` for restrictive permissions
- Credentials stored in plaintext (follow existing aap-demo pattern)
- Consider using environment variables in shared/CI environments

### Environment Variable Override

```bash
# Use a custom credentials file location
export REDHAT_SUBSCRIPTION_CREDENTIALS_FILE="/path/to/custom/credentials.yml"
aap-demo deploy
```

## Subscription Management

### Check Subscription Status

```bash
# Via API
AAP_ROUTE=$(kubectl get route aap -n aap-operator -o jsonpath='{.spec.host}')
AAP_PASSWORD=$(kubectl get secret aap-admin-password -n aap-operator -o jsonpath='{.data.password}' | base64 -d)

curl -sk -u "admin:${AAP_PASSWORD}" \
  "https://${AAP_ROUTE}/api/controller/v2/config/" | jq '.license_info'
```

### Manual Attachment (UI)

If automatic attachment fails, attach manually:

1. Get AAP route: `aap-demo status`
2. Log into AAP UI with admin credentials
3. Navigate to: **Settings → Subscription**
4. Enter Red Hat account credentials or upload a manifest

### Remove Saved Credentials

```bash
rm ~/.aap-demo/redhat-subscription-credentials
```

## Troubleshooting

### Subscription Already Attached

If AAP already has a valid subscription, the addon skips attachment:

```
✓ AAP already has a valid subscription (type: enterprise)
```

### Invalid Credentials

```
❌ ERROR: Red Hat authentication failed
⚠  Check credentials in ~/.aap-demo/redhat-subscription-credentials
```

**Solution**: Verify credentials at [access.redhat.com](https://access.redhat.com)

### No Matching Subscription

```
❌ ERROR: No Red Hat Ansible Automation Platform subscription found
```

**Solution**: Register for a free developer subscription at [developers.redhat.com/register](https://developers.redhat.com/register)

### Collection Not Found

```
❌ ERROR: infra.aap_configuration collection not found
```

**Solution**:
```bash
ansible-galaxy collection install -r requirements.yml
```

### Ansible Playbook Not Found

```
❌ ERROR: ansible-playbook not found
```

**Solution**:
```bash
pip install ansible-core
```

## Technical Details

### Ansible Collection

The addon uses the `infra.aap_configuration.controller_license` role from the [redhat-cop/infra.aap_configuration](https://github.com/redhat-cop/infra.aap_configuration) collection.

**Role Features**:
- Built-in Red Hat authentication
- Subscription lookup with configurable filters
- Automatic manifest download and upload
- Support for username/password or service account credentials

### Integration Point

The addon is wired into the deployment flow via `includes/addon-wire.sh`:

```bash
aap_demo_wire() {
  # ... other wiring ...
  wire_subscription_attach || true  # Non-blocking
  # ... rest of wiring ...
}
```

### Subscription Filters

Default filters (can be customized in `attach-subscription.yml`):
- **Product Name**: "Red Hat Ansible Automation Platform"
- **Support Level**: "Self-Support" (developer subscriptions)

### API Endpoints

- **Subscription Status**: `GET /api/controller/v2/config/`
- **License Attachment**: Handled by `controller_license` role (uses internal AAP APIs)

## Files

```
addons/subscription-attach/
├── deploy.sh                    # Main script with credential prompting
├── attach-subscription.yml      # Ansible playbook using controller_license role
└── README.md                    # This file
```

**Note**: This addon is auto-enabled via `includes/addon-wire.sh` integration and does not appear in `aap-demo enable` list.

## Development

### Testing

```bash
# Test credential prompting
rm ~/.aap-demo/redhat-subscription-credentials
bash addons/subscription-attach/deploy.sh

# Test with environment variables
export REDHAT_SUBSCRIPTION_USERNAME="test@example.com"
export REDHAT_SUBSCRIPTION_PASSWORD="test-password"
bash addons/subscription-attach/deploy.sh

# Test non-interactive mode
QUIET=true bash addons/subscription-attach/deploy.sh
```

### Playbook Syntax Check

```bash
ansible-playbook --syntax-check addons/subscription-attach/attach-subscription.yml
```

## Related Documentation

- [AAP Subscription Management](https://access.redhat.com/documentation/en-us/red_hat_ansible_automation_platform)
- [Red Hat Developer Program](https://developers.redhat.com)
- [infra.aap_configuration Collection](https://github.com/redhat-cop/infra.aap_configuration)
- [controller_license Role Documentation](https://github.com/redhat-cop/infra.aap_configuration/tree/devel/roles/controller_license)

## License

GPLv3+ (consistent with aap-demo project)
