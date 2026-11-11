#!/usr/bin/env bash
# Product Demo - Satellite
#
# Installs Red Hat Satellite integration demos from the Ansible Product Demos collection.
# Requires product-demos-base addon (automatically installed if needed).
#
# Environment variables:
#   PRODUCT_DEMOS_REPO   - Git repository URL (default: https://github.com/ansible/product-demos)
#   PRODUCT_DEMOS_BRANCH - Git branch to use (default: main)
#
# Usage:
#   ./deploy.sh          # Deploy satellite demos
#   ./deploy.sh --delete # Remove satellite demos

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../product-demos-base/lib.sh
source "${SCRIPT_DIR}/../product-demos-base/lib.sh"
NAMESPACE="${NAMESPACE:-aap-operator}"
ACTION="${1:-deploy}"
DEMO_CATEGORY="satellite"

# Product demos configuration
PRODUCT_DEMOS_REPO="${PRODUCT_DEMOS_REPO:-https://github.com/ansible/product-demos}"
PRODUCT_DEMOS_BRANCH="${PRODUCT_DEMOS_BRANCH:-main}"

# ==============================================================================
# DELETE HANDLER
# ==============================================================================

if [ "$ACTION" = "--delete" ] || [ "$ACTION" = "delete" ]; then
  echo "Removing Red Hat Satellite integration demo resources from AAP..."
  echo ""
  echo "To remove satellite demo job templates, log into AAP UI and:"
  echo "  1. Navigate to the 'Ansible Product Demos (APD)' organization"
  echo "  2. Go to Templates"
  echo "  3. Delete templates starting with 'SATELLITE |'"
  echo ""
  echo "✓ product-demo-satellite addon disabled"
  exit 0
fi

# ==============================================================================
# DEPLOYMENT
# ==============================================================================

echo "Deploying Ansible Product Demos - Satellite..."
echo ""

# Check cluster connectivity
if ! kubectl cluster-info &>/dev/null; then
  echo "❌ ERROR: Cannot connect to cluster"
  echo "Please ensure your cluster is running: aap-demo status"
  exit 1
fi

# Check if AAP is deployed
if ! kubectl get aap -n "$NAMESPACE" &>/dev/null; then
  echo "❌ ERROR: AAP not found in namespace $NAMESPACE"
  echo "Please deploy AAP first: aap-demo deploy"
  exit 1
fi

# ==============================================================================
# ENSURE BASE ADDON IS INSTALLED
# ==============================================================================

echo "Checking for product-demos-base..."

if ! apd_base_is_recorded; then
  echo "product-demos-base not found. Installing dependency..."
  echo ""

  if [ -f "$SCRIPT_DIR/../product-demos-base/deploy.sh" ]; then
    bash "$SCRIPT_DIR/../product-demos-base/deploy.sh"
    echo ""
  else
    echo "❌ ERROR: Cannot find product-demos-base addon"
    echo "Please ensure product-demos-base exists in addons/ directory"
    exit 1
  fi
else
  echo "✓ product-demos-base is installed"
  echo ""
fi

# ==============================================================================
# INSTALL VIA AAP JOB TEMPLATE
# ==============================================================================

echo "Retrieving AAP connection details..."

if ! command -v jq &>/dev/null; then
  echo "❌ ERROR: jq is required"
  exit 1
fi

apd_init_aap_connection || exit 1
echo "✓ AAP credentials retrieved"
echo ""

# ==============================================================================
# WIRE SATELLITE CREDENTIALS
# ==============================================================================
# Upstream ships placeholder Satellite credentials (https://satellite.example.com,
# REPLACEME). The "SETUP | Satellite" install job connects to the Satellite, so
# point both APD credentials at the real server before installing. Defaults match
# the satellite-lab VM; override with SATELLITE_URL / SATELLITE_USERNAME /
# SATELLITE_PASSWORD for an external Satellite.
apd_wire_satellite_credentials() {
  local sat_url="${SATELLITE_URL:-https://satellite.demo.lab}"
  local sat_user="${SATELLITE_USERNAME:-admin}"
  # Read the admin password from the encrypted Vault (generated at build time);
  # SATELLITE_PASSWORD overrides for an external Satellite.
  local sat_pass="${SATELLITE_PASSWORD:-}"
  if [ -z "$sat_pass" ] && command -v aap_demo_satellite_admin_password >/dev/null 2>&1; then
    sat_pass=$(aap_demo_satellite_admin_password 2>/dev/null || true)
  fi
  if [ -z "$sat_pass" ]; then
    echo "  ⚠ No Satellite admin password available (Vault); skipping credential wiring" >&2
    return 1
  fi
  local apd_org_id cred_id

  apd_org_id=$(apd_apd_org_id)
  if [ -z "$apd_org_id" ]; then
    echo "  ⚠ APD organization not found; skipping Satellite credential wiring" >&2
    return 1
  fi

  echo "Wiring Satellite credentials to ${sat_url}..."
  local name type_name
  # "Satellite Credential" (Satellite Collection) and "Satellite Inventory"
  # (Red Hat Satellite 6) both use host/username/password inputs.
  for name in "Satellite Credential" "Satellite Inventory"; do
    cred_id=$(apd_find_apd_credential_by_name "$name" "$apd_org_id")
    if [ -z "$cred_id" ]; then
      echo "  ⚠ $name not found yet (created by the install); will wire on next run" >&2
      continue
    fi
    curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
      -X PATCH \
      -H "Content-Type: application/json" \
      -d "$(jq -n \
        --arg host "$sat_url" \
        --arg username "$sat_user" \
        --arg password "$sat_pass" \
        '{inputs: {host: $host, username: $username, password: $password}}')" \
      "${AAP_API}/credentials/${cred_id}/" >/dev/null 2>&1 \
      && echo "  ✓ $name -> $sat_url" \
      || echo "  ⚠ Failed to update $name" >&2
  done
}

apd_wire_satellite_credentials || true
echo ""

apd_resolve_domain_install_ids || exit 1

echo "Installing $DEMO_CATEGORY demo resources via AAP job template..."
echo "This may take a few minutes..."
echo ""

# The install job creates the Satellite credentials (placeholders) and launches
# "SETUP | Satellite", which fails while the placeholders point at
# satellite.example.com. So: install the templates, wire the real credentials,
# then re-run SETUP | Satellite against the wired server.
install_rc=0
apd_install_domain_demo "$DEMO_CATEGORY" || install_rc=$?

# Wire the credentials now that the install created them.
apd_wire_satellite_credentials || true

# Re-run SETUP | Satellite against the wired Satellite server.
apd_rerun_satellite_setup() {
  local setup_name="SETUP | Satellite"
  local encoded template_id job_id
  encoded=$(jq -rn --arg n "$setup_name" '$n|@uri')
  template_id=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/job_templates/?name=${encoded}" 2>&1 | jq -r '.results[0].id // empty')
  if [ -z "$template_id" ]; then
    echo "  ⚠ $setup_name template not found; skipping re-run" >&2
    return 1
  fi
  echo "Re-running $setup_name against ${SATELLITE_URL:-https://satellite.demo.lab}..."
  job_id=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    -X POST -H "Content-Type: application/json" \
    "${AAP_API}/job_templates/${template_id}/launch/" 2>&1 | jq -r '.id // empty')
  if [ -z "$job_id" ]; then
    echo "  ⚠ Could not launch $setup_name" >&2
    return 1
  fi
  echo "✓ $setup_name launched (ID: ${job_id})"
  apd_monitor_job "$job_id" "Satellite setup" 160
}

if [ "$install_rc" -ne 0 ]; then
  echo ""
  echo "  The install job's SETUP step failed (placeholder Satellite credentials). Retrying SETUP with wired credentials..."
  # SETUP | Satellite bootstraps RHEL 7/8 content views from upstream
  # host_vars; the satellite-lab is RHEL 9/10, so that bootstrap does not apply
  # and is expected to fail on the RHEL 7/8 repositories. The demo templates
  # (SATELLITE | *, LINUX | * with Satellite) are created before that step and
  # work against the lab's RHEL 9/10 content, so a SETUP failure here is a
  # warning only when the templates actually exist — otherwise the install
  # genuinely failed and the addon must not be marked enabled.
  _setup_rc=0
  apd_rerun_satellite_setup || _setup_rc=$?
  if [ "$_setup_rc" -ne 0 ]; then
    echo "  ⚠ SETUP | Satellite did not complete (RHEL 7/8 bootstrap N/A on this RHEL 9/10 lab)" >&2
  fi
  # Verify the demo templates were created before claiming success.
  _tmpl_count=0
  _tmpl_count=$(curl -sk -u "${AAP_USERNAME}:${AAP_PASSWORD}" \
    "${AAP_API}/job_templates/?name__startswith=SATELLITE" 2>/dev/null \
    | jq -r '.count // 0' 2>/dev/null || echo 0)
  if [ "${_tmpl_count:-0}" -gt 0 ]; then
    echo "  ✓ ${_tmpl_count} SATELLITE | * job template(s) present; treating SETUP failure as non-fatal"
    install_rc=0
  else
    echo "  ❌ Install failed and no SATELLITE | * templates were created; not marking the addon enabled" >&2
    # leave install_rc nonzero so the addon reports failure
  fi
fi

if [ "$install_rc" -eq 0 ]; then
  echo ""
  echo "✓ Red Hat Satellite integration demos installed successfully!"
  echo ""
  echo "Job templates created (prefix: SATELLITE |):"
  echo "  - SATELLITE | Server Registration"
  echo "  - SATELLITE | Promote Content"
  echo "  - SATELLITE | OpenSCAP Scan"
  echo "  - SATELLITE | Publish Content View"
  echo "  ... and more"
  echo ""
  echo "Satellite credentials wired to ${SATELLITE_URL:-https://satellite.demo.lab}."
  echo "  - Log into AAP UI at: ${AAP_UI_URL}"
  echo "  - Navigate to 'Ansible Product Demos (APD)' organization"
  echo "  - Run demo job templates"
  echo ""
else
  echo ""
  echo "❌ ERROR: Red Hat Satellite integration demo installation failed"
  echo "Re-run from Templates: $(apd_domain_template_name "$DEMO_CATEGORY")"
  exit 1
fi
