# Ansible Project Addon

Bootstrap Ansible projects in AAP Controller using Jinja templates.

> **Note**: This addon supports **HTTPS Git URLs only** (`https://...`). SSH URLs (`git@...`) are not supported.

## What It Creates

This addon creates a complete AAP Controller project setup **using Kubernetes Custom Resources (CRs)**:

1. **SourceControlCredential CR** - Git HTTPS authentication for project sync
2. **AnsibleAutomationPlatformCredential CR** - Controller API credentials for playbook to configure AAP
3. **Project CR** - Links to your Git repository
4. **Inventory CR** - Target hosts/groups
5. **JobTemplate CR** - Runs `playbooks/configure_aap.yml` with AAP credential attached

All resources are created as Kubernetes CRs managed by the AAP Operator, which reconciles them into AAP Controller objects.

## Prerequisites

- AAP Controller deployed and accessible (`aap-demo deploy`)
- `kubectl` access to the cluster (automatically available in aap-demo)
- Python 3 with PyYAML and Jinja2: `pip install pyyaml jinja2`

## Quick Start (via aap-demo CLI)

The easiest way to bootstrap a project is using the `aap-demo` CLI:

```bash
# Deploy from git URL (auto-detects credentials from your git config)
aap-demo enable ansible-project https://github.com/your-org/your-repo.git

# Or specify a custom project name
aap-demo enable ansible-project https://github.com/your-org/your-repo.git my-project

# Launch the job template
# Launch from AAP UI at my-project
```

The CLI will:
- Auto-detect your project name from the git URL
- Use your existing git credentials (SSH keys or credential helper)
- Generate project.yml and vault.yml files automatically
- Deploy all AAP Controller resources
- **Note**: Auto-generated vault.yml is UNENCRYPTED - encrypt it for production

## Manual Configuration

For more control or production deployments, use custom configuration files:

```bash
# 1. Copy example files
cp project.yml.example project.yml
cp vault.yml.example vault.yml

# 2. Edit project.yml with non-sensitive settings
vim project.yml

# 3. Edit vault.yml with secrets (git/AAP credentials)
vim vault.yml

# 4. Encrypt vault.yml
ansible-vault encrypt vault.yml

# 5. Deploy to AAP Controller
./deploy.sh --vault-password-file ~/.vault_pass
# Or let ansible-vault prompt for password:
./deploy.sh

# 6. Launch the job template
# Launch from AAP UI at my-ansible-project
```

## Git Authentication (HTTPS Only)

**Important**: This addon **only supports HTTPS Git URLs**. SSH URLs (`git@...`) are not supported.

### Supported URL Format

```
✅ https://github.com/org/repo.git
✅ https://gitlab.com/org/repo.git
✅ https://bitbucket.org/org/repo.git
❌ git@github.com:org/repo.git (SSH not supported)
```

### Automatic Credential Detection

When using quick bootstrap (`aap-demo enable ansible-project <url>`), credentials are automatically detected from your system's git credential helper:

- Queries `git credential fill` to retrieve stored credentials
- Extracts username and password/token
- Works with:
  - **macOS**: Keychain (osxkeychain helper)
  - **Windows**: Credential Manager (wincred helper)
  - **Linux**: libsecret, gnome-keychain, or other configured helpers

### Credential Requirements

For **private repositories**, you must use:
- **Username**: Your git provider username
- **Password**: A Personal Access Token (PAT), **NOT your login password**

| Git Provider | Token Type | Scopes Needed |
|--------------|------------|---------------|
| **GitHub** | Personal Access Token (PAT) | `repo` (full control of private repos) |
| **GitLab** | Personal Access Token | `read_repository` |
| **Bitbucket** | App Password | `repository:read` |

For **public repositories**, credentials are optional (leave empty).

### Creating Personal Access Tokens

**GitHub:**
1. Go to: Settings → Developer settings → Personal access tokens → Tokens (classic)
2. Click "Generate new token" → "Generate new token (classic)"
3. Select scopes: `repo` (Full control of private repositories)
4. Click "Generate token" and copy the token (starts with `ghp_`)

**GitLab:**
1. Go to: Preferences → Access Tokens
2. Name: "AAP Automation"
3. Select scopes: `read_repository`
4. Click "Create personal access token" and copy the token (starts with `glpat-`)

**Bitbucket:**
1. Go to: Personal settings → App passwords
2. Click "Create app password"
3. Permissions: `repository:read`
4. Click "Create" and copy the password

**Important**: Store the token in `vault.yml` as the `git_password` value, then encrypt the file.

## AAP Credential (Controller API Access)

The job template automatically gets an AAP credential attached, which provides these environment variables to your playbook:

```yaml
CONTROLLER_HOST: https://aap-aap-operator.apps.127.0.0.1.nip.io
CONTROLLER_USERNAME: admin
CONTROLLER_PASSWORD: <admin-password>
CONTROLLER_VERIFY_SSL: false
```

This allows your `playbooks/configure_aap.yml` to use the `infra.aap_configuration` collection or `ansible.controller` collection without additional authentication setup:

```yaml
---
- name: Configure AAP
  hosts: localhost
  connection: local
  collections:
    - infra.aap_configuration

  tasks:
    - name: Create organizations
      infra.aap_configuration.organizations:
        organizations:
          - name: MyOrg
            description: My Organization
      # No need to specify controller_host/username/password
      # They're automatically provided by the AAP credential
```

By default, the AAP credential targets the current AAP instance. To target a different Controller, add these to `vault.yml`:

```yaml
aap_host: https://external-controller.example.com
aap_username: api_user
aap_password: api_password
aap_verify_ssl: true
```

## Configuration Files

Configuration is split into two files for security:

### `project.yml` - Non-Sensitive Configuration

Contains project settings that are safe to commit to git:

```yaml
project_name: my-ansible-project
organization: Default
git_url: https://github.com/your-org/your-repo.git
git_branch: main
project_description: "My automation project"
scm_update_on_launch: true
```

### `vault.yml` - Secrets (Encrypted)

Contains sensitive credentials - **must be encrypted with ansible-vault**:

**For public repositories** (no credentials needed):
```yaml
# Leave credentials empty or omit file entirely
git_username: ""
git_password: ""
```

**For private repositories**:
```yaml
# GitHub example
git_username: "your-username"
git_password: "ghp_YourPersonalAccessToken123"

# GitLab example
git_username: "your-username"
git_password: "glpat-YourPersonalAccessToken"

# Bitbucket example
git_username: "your-username"
git_password: "your-app-password"
```

**AAP credentials** (to target a different Controller):
```yaml
aap_host: https://controller.example.com
aap_username: admin
aap_password: supersecret
aap_verify_ssl: false
```

### Optional Customization

```yaml
# Organization
organization: Default

# Git branch
git_branch: main

# Descriptions
project_description: "Custom description"
credential_description: "Custom credential description"

# Inventory variables
inventory_variables: |
  ---
  ansible_connection: local
  custom_var: value

# Job template extra vars
extra_vars: |
  ---
  env: production
  debug: false

# SCM behavior
scm_update_on_launch: true
scm_clean: true
```

## Vault Management

The `vault.yml` file contains secrets and must be encrypted with ansible-vault.

### Encrypting Vault

```bash
# Encrypt vault file (will prompt for password)
ansible-vault encrypt vault.yml

# Or use a password file
echo "my-vault-password" > ~/.vault_pass
chmod 600 ~/.vault_pass
ansible-vault encrypt vault.yml --vault-password-file ~/.vault_pass
```

### Editing Encrypted Vault

```bash
# Edit encrypted vault (prompts for password)
ansible-vault edit vault.yml

# Or with password file
ansible-vault edit vault.yml --vault-password-file ~/.vault_pass
```

### Viewing Encrypted Vault

```bash
# View encrypted vault without editing
ansible-vault view vault.yml

# Or with password file
ansible-vault view vault.yml --vault-password-file ~/.vault_pass
```

### Decrypting Vault (Temporary)

```bash
# Decrypt to view/edit (makes file unencrypted!)
ansible-vault decrypt vault.yml

# Remember to re-encrypt after editing
ansible-vault encrypt vault.yml
```

### Using Vault Password File

Store your vault password in a file for convenience:

```bash
# Create password file
echo "your-vault-password" > ~/.vault_pass
chmod 600 ~/.vault_pass

# Export for ansible-vault auto-detection
export ANSIBLE_VAULT_PASSWORD_FILE=~/.vault_pass

# Or pass explicitly to deploy.sh
./deploy.sh --vault-password-file ~/.vault_pass
```

**Security tip**: Add `~/.vault_pass` to your global `.gitignore` to prevent committing it.

## Usage

### Deploy Project

```bash
# Use default project.yml and vault.yml
./deploy.sh

# With vault password file
./deploy.sh --vault-password-file ~/.vault_pass

# Use custom config files
./deploy.sh --project my-project.yml --vault my-vault.yml

# Via aap-demo CLI (auto-generates config)
aap-demo enable ansible-project https://github.com/your-org/repo.git
```

### Remove Project

```bash
# Via aap-demo CLI
aap-demo disable ansible-project

# Or directly with project name
./deploy.sh --delete my-project

# Or from project.yml
./deploy.sh --delete
```

### Launch Jobs

Jobs can be launched from the AAP Web UI:

```bash
# Get AAP URL
aap-demo status

# Navigate to: Templates → <your-project-name> → Launch
# Or use direct link: https://aap-aap-operator.apps.127.0.0.1.nip.io/#/templates
```

## Extending Templates

Kubernetes CR templates are located in `templates/`:

- `credential_cr.yml.j2` - SourceControlCredential CR
- `aap_credential_cr.yml.j2` - AnsibleAutomationPlatformCredential CR
- `project_cr.yml.j2` - Project CR
- `inventory_cr.yml.j2` - Inventory CR
- `job_template_cr.yml.j2` - JobTemplate CR

All variables from `project.yml` and `vault.yml` are available in templates. Vault variables override project variables. Use Jinja2 syntax:

```jinja
{{ variable_name }}
{{ variable_name | default('fallback') }}
```

## Multiple Projects

Deploy multiple projects by creating separate config file sets:

```bash
# Project 1
./deploy.sh --project project1.yml --vault vault1.yml

# Project 2
./deploy.sh --project project2.yml --vault vault2.yml
```

## Troubleshooting

**Check CR status:**
```bash
# List all AAP CRs
kubectl get jobtemplate,project,inventory,sourcecontrolcredential,ansibleautomationplatformcredential -n aap-operator

# Check specific resource
kubectl get jobtemplate my-project -n aap-operator -o yaml

# Watch CR reconciliation
kubectl describe jobtemplate my-project -n aap-operator
```

**Python dependencies missing:**
```bash
pip install pyyaml jinja2
```

**AAP not accessible:**
```bash
aap-demo status
aap-demo diagnose
```

**CRs not reconciling:**
- Check AAP operator logs: `kubectl logs -l app.kubernetes.io/name=aap-operator -n aap-operator`
- Verify CR status: `kubectl get <resource-type> <name> -n aap-operator -o yaml | grep -A5 status`
- Check events: `kubectl get events -n aap-operator --sort-by='.lastTimestamp'`

**Git credential authentication fails:**
- Use a Personal Access Token (PAT), **NOT your login password**
- Ensure token has appropriate repository access scopes
- Test git access from command line: `git clone <your-repo-url>`
- Verify credentials are stored: `git credential fill` (see examples above)

**Project sync fails:**
- Check Git URL is correct
- Verify branch name exists
- Check credential has repo access
- Review project logs in AAP UI

## Complete Workflow Example

```bash
# 1. Ensure AAP is deployed
aap-demo deploy

# 2. Bootstrap your project (auto-detects git credentials)
aap-demo enable ansible-project https://github.com/myorg/aap-config.git

# 3. Launch the job template
# Launch from AAP UI at aap-config

# 4. View in Controller UI
aap-demo status  # Get the Controller URL
# Navigate to Templates → aap-config
```

Your repository must contain: `playbooks/configure_aap.yml`

## Example: GitHub Private Repo

**project.yml:**
```yaml
project_name: infra-automation
organization: Default
git_url: https://github.com/myorg/infra-automation.git
git_branch: main
project_description: "Infrastructure automation project"
inventory_variables: |
  ---
  ansible_connection: local
extra_vars: |
  ---
  target_env: staging
```

**vault.yml** (encrypt with `ansible-vault encrypt vault.yml`):
```yaml
# GitHub credentials
git_username: "myuser"
git_password: "ghp_YourGitHubPAT123456789"
```

## Example: GitLab Private Repo

**project.yml:**
```yaml
project_name: network-automation
organization: Default
git_url: https://gitlab.com/myorg/network-automation.git
git_branch: develop
project_description: "Network automation configuration"
```

**vault.yml** (encrypt with `ansible-vault encrypt vault.yml`):
```yaml
# GitLab credentials
git_username: "myuser"
git_password: "glpat-YourGitLabToken"
```
