#!/usr/bin/env bash
# =============================================================================
# help.sh — show_help command (CLI usage/help text)
# =============================================================================
#
# Extracted from aap-demo.sh. Uses the grouped-by-task format validated by
# test/test-core-commands.sh; the addon list is printed from AVAILABLE_ADDONS
# via _help_print_addons (defined in aap-demo.sh) so it cannot drift.

# Guard against double-sourcing
if [ -n "${_AAP_DEMO_HELP_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_HELP_LOADED=1

show_help() {
  cat <<EOF
aap-demo - Deploy AAP ${AAP_VERSION:-2.7} to OpenShift Local

Usage: aap-demo [options] <command>

Cluster
  create            Create the OpenShift Local cluster
  start             Start a stopped cluster (re-applies CoreDNS config)
  stop              Stop the cluster
  ssh               SSH into the cluster node
  destroy           Delete the local cluster
  repair            Repair the cluster after a crash
  trust-ca          Repair ingress certificate trust only
  setup             Run setup only (storage, CoreDNS)
  storage [DISK] [PV]
                    Show or change the VM disk and persistent-volume size
  kubeconfig        Extract and merge kubeconfig
  redeploy-all      Destroy the cluster and redeploy fresh

AAP
  deploy            Deploy AAP ${AAP_VERSION:-2.7} (operator + CR)
  status            Show cluster and AAP status
  system-info       Export the environment inventory report
  watch             Watch deployment status
  idle              Scale AAP down or up
  clean             Remove the AAP deployment
  redeploy          Clean and redeploy AAP
  wire              Re-run addon wiring
  dashboard         Start the localhost dashboard
  maintenance       Preview or remove safe-to-delete VM data

Health
  preflight         Read-only tools, capacity, storage, and catalog checks
  diagnose          Check environment health
  must-gather       Collect AAP and cluster diagnostics
  redhat-status     Check Red Hat registry status

Addons
  enable            Enable an addon
  disable           Disable an addon
  fleet             Manage fleet node VMs
  keycloak          Configure Keycloak OIDC for AAP and AO

Other
  config            Configure aap-demo settings
  update            Pull latest code and reinstall
  v2 [args...]      Run the Python v2 CLI (for example: aap-demo v2 deploy)
  version           Show version and build timestamp
  help              Show this help

Options
  --kubeconfig=FILE   Path to kubeconfig file (default: ~/.aap-demo/kubeconfig.microshift)
  --context=NAME      kubectl context to use (default: current context)
  --backend=NAME      Fleet backend: qemu, kube-native, or all
  --full-demo         With create: build the complete local demo
  --satellite         With create --full-demo: also build the Satellite lab and demo
  --sno               With create: use Single Node OpenShift (full control plane +
                      web console); skips the tier prompt, fails if SNO minimums unmet
  --microshift        With create: use MicroShift (minimal edge runtime); skips the
                      tier prompt
  --show-secrets      Reveal credentials with interactive status only
  --no-import         With enable fleet --backend kube-native: skip AAP registration
  --refresh-catalog   Refresh supported addon catalogs
  --purge-data        Delete retained addon data when disabling
  --purge-creds       Delete retained addon credentials when disabling

Environment
  NAMESPACE=<name>    Kubernetes namespace (default: aap-operator)
  QUIET=true          Suppress the disclaimer
  FORCE=true          Force reinstall even if AAP exists
  AAP_VERSION=2.6|2.7 AAP version to deploy (default: 2.7)
  AAP_DEMO_ALLOW_REMOTE_KUBECONFIG=true
                      Allow a remote kubeconfig context. Default is to
                      refuse, so oc login cannot retarget deploy or enable.
  AAP_DEMO_ANSIBLE    Use Ansible by default (true/false)
  AAP_PERSISTENT_IMAGE_STORE=true
                      Keep CRI-O image storage on a persistent qcow2 disk
                      (Linux/libvirt only; macOS uses the OCI image cache)
  AAP_IMAGE_STORE_DISK Path to the persistent image disk
  AAP_IMAGE_STORE_SIZE_GB  Persistent disk size (default: 60)
  AAP_IMAGE_STORE_FORMAT=true
                      Explicitly format a blank persistent disk once
  AO_LLM_PROVIDER=ollama|external|none
                      AO LLM provider selection

Notes
  idle                No argument shows state; true scales down; false scales up
  diagnose            Checks cluster, storage, SCCs, pods, PVCs, and DNS
  diagnose --ai       Analyze issues with Claude (requires the claude CLI)
  must-gather [dir]   Uses the AAP must-gather image. Output is
                      must-gather.local.<timestamp>, or the directory given
  destroy             --reset also clears config; --skip-cache skips the image cache
  status --json       Emit machine-readable status without secret values
  system-info [--redact] [--json] [--output FILE]
                      Export redacted, JSON, or custom-path inventory
  dashboard [--no-open]
                      Start the localhost dashboard without opening a browser
  maintenance [--apply]
                      Preview or remove safe-to-delete VM data
  maintenance uninstall [--apply]
                      Remove all aap-demo state; requires
                      AAP_DEMO_UNINSTALL_CONFIRM=UNINSTALL with QUIET=true
  create --full-demo  Build AAP, Product Demos, AO/Ollama, Fleet, and dashboard
  fleet               add, list, remove, destroy
                      --backend qemu|kube-native|all
                      add [N] --image <path> creates N RHEL VMs (requires: enable fleet)
                      (legacy Bash v1; local QEMU VMs only)
                      Kubernetes-native fleet: aap-demo fleet list (Kubernetes pod-backed nodes)
                      --no-import with --backend kube-native skips AAP registration
                      disable --backend kube-native delegates to the Python addon
  fleet auth [configure|status|reset]
                      Manage encrypted Red Hat credentials
  fleet add [count] --image <rhel9|rhel10|local-qcow2-path>
                      Download/cache an entitled image and create VMs
  fleet register      License AAP if needed, register nodes, and ping them
  fleet start         Start preserved Fleet VM overlays
  fleet ssh [index]   Open an admin SSH shell (default: node 1)
  fleet rhc-connect   Enroll running Fleet VMs in RHSM/Insights/remote management
  fleet satellite-register
                      Register running Fleet VMs to the Satellite lab (content
                      from local Pulp, hosts in the Satellite inventory)
  fleet list          List Fleet VM state
  fleet remove [count|name]
                      Deregister and remove newest or named VMs
  fleet destroy       Remove all Fleet VMs and AAP Fleet resources
  local-cache         save, load, or clear. Saves images from a running cluster
  keycloak configure  [--target aap|ao|all] [--map-groups] [--apply]
                      Dry-run unless --apply
                      --map-groups aligns Keycloak groups with AAP roles and AO groups
  aliases             deploy-all = deploy, rh-status = redhat-status

Available addons
EOF
  _help_print_addons
  cat <<EOF

Examples
  aap-demo create
  aap-demo create --full-demo --satellite --sno
  aap-demo deploy
  aap-demo status
  aap-demo enable portal
  aap-demo enable fleet
  aap-demo fleet add 3 --image rhel9
  aap-demo redeploy-all
  aap-demo idle true

Requirements
  - OpenShift Local — https://console.redhat.com/openshift/create/local
  - On Linux: libvirt-daemon, libvirt-daemon-driver-storage, qemu-kvm

  For all deployments:
  - kubectl
  - Pull secret at ~/.aap-demo/pull-secret.txt (from console.redhat.com)
EOF
}
