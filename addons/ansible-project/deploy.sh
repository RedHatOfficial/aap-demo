#!/usr/bin/env bash
# Deploy Ansible Project to AAP Controller
# ADDON_REQUIRES_AAP=true
#
# Creates AAP Controller objects from Jinja templates:
#   - Credential (SCM/Git)
#   - Project
#   - Inventory
#   - Job Template
#
# Prerequisites:
#   - AAP Controller deployed and accessible
#   - vars.yml configured with your project details OR provide git-url
#
# Usage:
#   ./deploy.sh <git-url> [project-name]  # Quick bootstrap with git URL
#   ./deploy.sh --vars custom.yml         # Use custom vars file
#   ./deploy.sh --delete [project-name]   # Remove project resources

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-aap-operator}"
PROJECT_FILE="${SCRIPT_DIR}/project.yml"
VAULT_FILE="${SCRIPT_DIR}/vault.yml"
RENDERED_DIR="${SCRIPT_DIR}/.rendered"
VAULT_PASSWORD_FILE=""

# Parse arguments
ACTION="deploy"
GIT_URL=""
PROJECT_NAME=""
AUTO_GENERATE=false

# Parse all arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --delete|delete)
      ACTION="delete"
      if [[ -n "${2:-}" ]] && [[ ! "$2" =~ ^-- ]]; then
        PROJECT_NAME="$2"
        shift
      fi
      shift
      ;;
    --project)
      PROJECT_FILE="$2"
      shift 2
      ;;
    --vault)
      VAULT_FILE="$2"
      shift 2
      ;;
    --vault-password-file)
      VAULT_PASSWORD_FILE="$2"
      shift 2
      ;;
    http://*|https://*|git@*)
      # Quick bootstrap mode: git URL provided
      GIT_URL="$1"
      if [[ -n "${2:-}" ]] && [[ ! "$2" =~ ^-- ]]; then
        PROJECT_NAME="$2"
        shift
      fi
      AUTO_GENERATE=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo ""
      echo "Usage:"
      echo "  $0 <git-url> [project-name]              # Quick bootstrap"
      echo "  $0 --project <file> [--vault <file>]     # Use custom config"
      echo "  $0 --vault-password-file <file>          # Vault password file"
      echo "  $0 --delete [project-name]               # Remove project"
      exit 1
      ;;
  esac
done

# Auto-generate vars file from git URL if provided
if [ "$AUTO_GENERATE" = true ] && [ -n "$GIT_URL" ]; then
  # Extract project name from git URL if not provided
  if [ -z "$PROJECT_NAME" ]; then
    PROJECT_NAME=$(echo "$GIT_URL" | sed -E 's#.*/([^/]+)\.git$#\1#' | sed 's#.*/##' | sed 's/\.git$//')
  fi

  # Validate HTTPS URL
  if [[ "$GIT_URL" != http://* ]] && [[ "$GIT_URL" != https://* ]]; then
    echo "ERROR: Only HTTPS Git URLs are supported"
    echo "  Provided: $GIT_URL"
    echo "  Expected: https://github.com/org/repo.git"
    echo ""
    echo "  SSH URLs (git@...) are not supported by this addon."
    exit 1
  fi

  echo "Auto-generating configuration for: $PROJECT_NAME"
  echo "  Git URL: $GIT_URL"

  # Detect git credentials from the CLI session
  GIT_USERNAME=""
  GIT_PASSWORD=""

  echo "  Detecting HTTPS credentials from git credential helper..."

  # Try to get credentials from git credential helper
  GIT_HOST=$(echo "$GIT_URL" | sed -E 's#^https?://([^/]+).*#\1#')

  # Use git credential fill to get credentials
  CRED_OUTPUT=$(echo -e "protocol=https\nhost=${GIT_HOST}\n\n" | git credential fill 2>/dev/null || true)

  if [ -n "$CRED_OUTPUT" ]; then
    GIT_USERNAME=$(echo "$CRED_OUTPUT" | grep '^username=' | cut -d= -f2)
    GIT_PASSWORD=$(echo "$CRED_OUTPUT" | grep '^password=' | cut -d= -f2)

    if [ -n "$GIT_USERNAME" ]; then
      echo "  ✓ Found credentials for: $GIT_USERNAME@$GIT_HOST"
    fi
  fi

  if [ -z "$GIT_USERNAME" ]; then
    echo "  ⚠️  WARNING: No git credentials found in credential helper"
    echo "  For private repos, you'll need to manually add credentials to vault.yml"
    echo "  For public repos, this is OK - credentials are optional"
  fi

  # Generate project config files
  PROJECT_FILE="${SCRIPT_DIR}/.auto-${PROJECT_NAME}.yml"
  VAULT_FILE="${SCRIPT_DIR}/.auto-${PROJECT_NAME}-vault.yml"

  # Create project.yml (non-sensitive config)
  cat > "$PROJECT_FILE" <<PROJECTEOF
---
# Auto-generated configuration for: $PROJECT_NAME
# Generated from: aap-demo enable ansible-project $GIT_URL

project_name: $PROJECT_NAME
organization: Default
git_url: $GIT_URL
git_branch: main

# Project settings
project_description: "Ansible project: $PROJECT_NAME"
inventory_description: "Inventory for $PROJECT_NAME"
job_template_description: "Configure AAP using $PROJECT_NAME"

# Job template settings
ask_variables_on_launch: true
verbosity: 0

# SCM settings
scm_update_on_launch: true
scm_clean: true
PROJECTEOF

  echo "  ✓ Generated: $PROJECT_FILE"

  # Create vault.yml (sensitive credentials) - UNENCRYPTED for auto-generated
  cat > "$VAULT_FILE" <<VAULTEOF
---
# Auto-generated secrets for: $PROJECT_NAME
# WARNING: This file contains secrets and should be encrypted with ansible-vault
# Run: ansible-vault encrypt $VAULT_FILE

VAULTEOF

  # Add git credentials if found
  if [ -n "$GIT_USERNAME" ]; then
    cat >> "$VAULT_FILE" <<VAULTEOF
# Git HTTPS credentials (from git credential helper)
git_username: "$GIT_USERNAME"
git_password: "$GIT_PASSWORD"
VAULTEOF
  else
    cat >> "$VAULT_FILE" <<VAULTEOF
# Git HTTPS credentials
# For private repos, add your credentials here
# For public repos, leave these empty or omit them
git_username: ""
git_password: ""

# GitHub: Use Personal Access Token (PAT) as password
# GitLab: Use Personal Access Token or Deploy Token
# Bitbucket: Use App Password
VAULTEOF
  fi

  # Add AAP credentials (will be auto-populated at runtime)
  cat >> "$VAULT_FILE" <<VAULTEOF

# AAP Controller credentials (auto-populated from current instance)
# Override these to target a different Controller
# aap_host: https://controller.example.com
# aap_username: admin
# aap_password: secret
# aap_verify_ssl: false
VAULTEOF

  echo "  ✓ Generated: $VAULT_FILE (UNENCRYPTED)"
  echo "  "
  echo "  ⚠️  SECURITY WARNING:"
  echo "  The vault file contains secrets and is currently UNENCRYPTED."
  echo "  For production use, encrypt it with:"
  echo "    ansible-vault encrypt $VAULT_FILE"
  echo ""
fi

# Check project file exists
if [ "$ACTION" = "deploy" ] && [ ! -f "$PROJECT_FILE" ]; then
  echo "ERROR: Project file not found: $PROJECT_FILE"
  echo ""
  echo "Create one from the example:"
  echo "  cp ${SCRIPT_DIR}/project.yml.example ${SCRIPT_DIR}/project.yml"
  echo "  cp ${SCRIPT_DIR}/vault.yml.example ${SCRIPT_DIR}/vault.yml"
  echo "  # Edit project.yml and vault.yml with your project details"
  echo "  ansible-vault encrypt ${SCRIPT_DIR}/vault.yml"
  echo ""
  echo "Or use quick bootstrap:"
  echo "  aap-demo enable ansible-project <git-url> [project-name]"
  exit 1
fi

# Check vault file exists (optional for public repos)
if [ "$ACTION" = "deploy" ] && [ ! -f "$VAULT_FILE" ]; then
  echo "WARNING: Vault file not found: $VAULT_FILE"
  echo "  Continuing without vault (OK for public repos with no credentials)"
  VAULT_FILE=""
fi

# Get AAP route
AAP_ROUTE=$(kubectl get route aap -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
if [ -z "$AAP_ROUTE" ]; then
  echo "ERROR: AAP route not found in namespace '$NAMESPACE'"
  echo "  Deploy AAP first: aap-demo deploy"
  exit 1
fi

AAP_URL="https://${AAP_ROUTE}"

# Get admin credentials
ADMIN_USER="admin"
ADMIN_PASSWORD=$(kubectl get secret -n "$NAMESPACE" aap-admin-password -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
if [ -z "$ADMIN_PASSWORD" ]; then
  echo "ERROR: Could not retrieve AAP admin password"
  exit 1
fi

# Check kubectl is available (should always be available in aap-demo context)
if ! command -v kubectl &>/dev/null; then
  echo "ERROR: kubectl not found"
  exit 1
fi

if [ "$ACTION" = "delete" ]; then
  echo "Removing Ansible project resources..."

  # Load project name from project file if not provided and file exists
  if [ -z "$PROJECT_NAME" ] && [ -f "$PROJECT_FILE" ]; then
    PROJECT_NAME=$(grep '^project_name:' "$PROJECT_FILE" 2>/dev/null | awk '{print $2}' | tr -d '"' || echo "")
  fi

  if [ -z "$PROJECT_NAME" ]; then
    echo "ERROR: Project name not specified"
    echo ""
    echo "Usage: $0 --delete <project-name>"
    echo "   Or: $0 --delete  # (will read from project.yml)"
    exit 1
  fi

  echo "  Project: $PROJECT_NAME"

  # Delete in reverse dependency order (using Kubernetes CRs)
  kubectl delete jobtemplate "$PROJECT_NAME" -n "$NAMESPACE" 2>/dev/null || echo "  Job template not found"
  kubectl delete inventory "$PROJECT_NAME" -n "$NAMESPACE" 2>/dev/null || echo "  Inventory not found"
  kubectl delete project "$PROJECT_NAME" -n "$NAMESPACE" 2>/dev/null || echo "  Project not found"
  kubectl delete ansibleautomationplatformcredential "${PROJECT_NAME}-aap" -n "$NAMESPACE" 2>/dev/null || echo "  AAP credential not found"
  kubectl delete sourcecontrolcredential "${PROJECT_NAME}-scm" -n "$NAMESPACE" 2>/dev/null || echo "  SCM credential not found"

  # Clean up auto-generated files if they exist
  AUTO_PROJECT_FILE="${SCRIPT_DIR}/.auto-${PROJECT_NAME}.yml"
  AUTO_VAULT_FILE="${SCRIPT_DIR}/.auto-${PROJECT_NAME}-vault.yml"
  if [ -f "$AUTO_PROJECT_FILE" ]; then
    rm -f "$AUTO_PROJECT_FILE"
    echo "  ✓ Removed auto-generated project file"
  fi
  if [ -f "$AUTO_VAULT_FILE" ]; then
    rm -f "$AUTO_VAULT_FILE"
    echo "  ✓ Removed auto-generated vault file"
  fi

  echo "✓ Project resources removed"
  exit 0
fi

# Decrypt vault file if it's encrypted
VAULT_TEMP_FILE=""
if [ -n "$VAULT_FILE" ] && [ -f "$VAULT_FILE" ]; then
  # Check if vault file is encrypted
  if head -n 1 "$VAULT_FILE" 2>/dev/null | grep -q '$ANSIBLE_VAULT'; then
    echo "Vault file is encrypted, decrypting..."

    # Check for ansible-vault
    if ! command -v ansible-vault &>/dev/null; then
      echo "ERROR: ansible-vault not found. Install with: pip install ansible-core"
      exit 1
    fi

    # Create temporary decrypted file
    VAULT_TEMP_FILE="${RENDERED_DIR}/vault.decrypted.yml"
    mkdir -p "$RENDERED_DIR"

    # Build vault password file args
    VAULT_PASS_ARGS=""
    if [ -n "$VAULT_PASSWORD_FILE" ]; then
      VAULT_PASS_ARGS="--vault-password-file=$VAULT_PASSWORD_FILE"
    elif [ -n "$ANSIBLE_VAULT_PASSWORD_FILE" ]; then
      VAULT_PASS_ARGS="--vault-password-file=$ANSIBLE_VAULT_PASSWORD_FILE"
    fi

    # Decrypt to temp file
    if ! ansible-vault decrypt $VAULT_PASS_ARGS "$VAULT_FILE" --output="$VAULT_TEMP_FILE" 2>/dev/null; then
      echo "ERROR: Failed to decrypt vault file"
      echo "  Provide password via:"
      echo "    --vault-password-file <file>"
      echo "    export ANSIBLE_VAULT_PASSWORD_FILE=<file>"
      echo "    Or enter password when prompted"
      rm -f "$VAULT_TEMP_FILE"
      exit 1
    fi

    VAULT_FILE="$VAULT_TEMP_FILE"
    echo "  ✓ Vault decrypted"
  fi
fi

# Render templates with Jinja2
echo "Rendering templates..."
mkdir -p "$RENDERED_DIR"

# Use Python to render Jinja templates
python3 <<PYEOF
import sys
import yaml
from jinja2 import Environment, FileSystemLoader

# Load project configuration
with open('$PROJECT_FILE', 'r') as f:
    vars_data = yaml.safe_load(f) or {}

# Load and merge vault variables if vault file exists
vault_file = '$VAULT_FILE'
if vault_file and vault_file != '':
    try:
        with open(vault_file, 'r') as f:
            vault_data = yaml.safe_load(f) or {}
            vars_data.update(vault_data)
    except FileNotFoundError:
        pass  # Vault file is optional

# Inject namespace
vars_data['namespace'] = '$NAMESPACE'

# Inject current AAP credentials if not already specified
if 'aap_host' not in vars_data:
    vars_data['aap_host'] = '$AAP_URL'
if 'aap_username' not in vars_data:
    vars_data['aap_username'] = '$ADMIN_USER'
if 'aap_password' not in vars_data:
    vars_data['aap_password'] = '$ADMIN_PASSWORD'
if 'aap_verify_ssl' not in vars_data:
    vars_data['aap_verify_ssl'] = False

# Setup Jinja environment
env = Environment(loader=FileSystemLoader('${SCRIPT_DIR}/templates'))

# Render each Kubernetes CR template
templates = ['credential_cr.yml.j2', 'aap_credential_cr.yml.j2', 'project_cr.yml.j2', 'inventory_cr.yml.j2', 'job_template_cr.yml.j2']
for template_name in templates:
    template = env.get_template(template_name)
    rendered = template.render(vars_data)

    output_file = '${RENDERED_DIR}/' + template_name.replace('.j2', '')
    with open(output_file, 'w') as f:
        f.write(rendered)
    print(f'  ✓ {template_name} -> {output_file}')

PYEOF

# Clean up temporary vault file
if [ -n "$VAULT_TEMP_FILE" ] && [ -f "$VAULT_TEMP_FILE" ]; then
  rm -f "$VAULT_TEMP_FILE"
fi

echo ""
echo "Creating AAP Controller resources via Kubernetes CRs..."

# Apply resources in dependency order
# SCM credential (for git access)
kubectl apply -f "${RENDERED_DIR}/credential_cr.yml"
echo "  ✓ SCM Credential CR created"

# AAP credential (for playbook to access Controller API)
kubectl apply -f "${RENDERED_DIR}/aap_credential_cr.yml"
echo "  ✓ AAP Credential CR created"

# Project (uses SCM credential)
kubectl apply -f "${RENDERED_DIR}/project_cr.yml"
echo "  ✓ Project CR created"

# Inventory
kubectl apply -f "${RENDERED_DIR}/inventory_cr.yml"
echo "  ✓ Inventory CR created"

# Job template (uses AAP credential and references project/inventory)
kubectl apply -f "${RENDERED_DIR}/job_template_cr.yml"
echo "  ✓ Job Template CR created"

echo ""
echo "✓ Ansible project deployed to AAP Controller!"
echo ""
echo "  Controller URL: $AAP_URL"
echo "  Username:       $ADMIN_USER"
echo "  Password:       <from secret>"
echo ""
echo "  View in AAP UI: ${AAP_URL}/#/templates"
echo ""
echo "  View CRs:"
echo "    kubectl get jobtemplate,project,inventory -n $NAMESPACE"
echo "    kubectl get jobtemplate ${PROJECT_NAME:-<name>} -n $NAMESPACE -o yaml"
echo ""

# Keep auto-generated files for reference
if [ "$AUTO_GENERATE" = true ]; then
  if [ -f "$PROJECT_FILE" ]; then
    echo "  Project config: $PROJECT_FILE"
  fi
  if [ -f "$VAULT_FILE" ]; then
    echo "  Vault (secrets): $VAULT_FILE"
    echo ""
    echo "  ⚠️  Encrypt vault file with: ansible-vault encrypt $VAULT_FILE"
  fi
  echo "  (you can edit these files and re-run to update the project)"
  echo ""
fi
