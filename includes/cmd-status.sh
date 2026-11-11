#!/usr/bin/env bash
# =============================================================================
# cmd-status.sh — status and diagnose command handlers
# =============================================================================
#
# Extracted from aap-demo.sh. Expects the caller to have sourced
# aap-demo-paths.sh, preset.sh, system-inventory.sh, and the fleet addon, and
# to define SCRIPT_DIR, NAMESPACE, QUIET, OUTPUT_JSON, and SHOW_SECRETS.

# Guard against double-sourcing
if [ -n "${_AAP_DEMO_CMD_STATUS_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_CMD_STATUS_LOADED=1

cmd_diagnose() {
  echo ""
  printf "\033[1maap-demo diagnose\033[0m - Checking environment health...\n"
  echo ""

  local issues=0
  local warnings=0

  _check_pass() { printf "  \033[32m✓\033[0m %s\n" "$1"; }
  _check_fail() {
    printf "  \033[31m✗\033[0m %s\n" "$1"
    issues=$((issues + 1))
  }
  _check_warn() {
    printf "  \033[33m⚠\033[0m %s\n" "$1"
    warnings=$((warnings + 1))
  }
  _check_info() { printf "  \033[36m·\033[0m %s\n" "$1"; }

  # =========================================================================
  # Cluster connectivity
  # =========================================================================
  echo "Cluster:"
  local crc_state status_json
  status_json=$(crc status -o json 2>/dev/null || echo '{}')
  crc_state=$(aap_demo_json_value crcStatus "$status_json" 2>/dev/null || echo "unknown")
  if [ "$crc_state" = "Running" ]; then
    local ms_version
    ms_version=$(aap_demo_json_value openshiftVersion "$status_json" 2>/dev/null || echo "")
    _check_pass "OpenShift Local running"
  elif [ "$crc_state" = "Stopped" ]; then
    _check_fail "OpenShift Local is stopped — run: crc start"
  else
    _check_fail "OpenShift Local cluster not found — run: aap-demo create"
  fi

  if kubectl cluster-info &>/dev/null; then
    _check_pass "kubectl connected"
  else
    _check_fail "kubectl cannot connect to cluster"
    echo ""
    echo "Cannot proceed without cluster connectivity."
    echo "  Check KUBECONFIG: ${KUBECONFIG:-$AAP_DEMO_KUBECONFIG}"
    return 1
  fi
  echo ""

  # =========================================================================
  # Storage
  # =========================================================================
  echo "Storage:"
  if kubectl get sc topolvm-provisioner &>/dev/null; then
    _check_pass "topolvm-provisioner StorageClass (default)"
  else
    _check_warn "topolvm-provisioner StorageClass not found"
  fi

  if kubectl get sc nfs-local-rwx &>/dev/null; then
    _check_pass "nfs-local-rwx StorageClass (RWX)"
    # Check NFS server health
    local nfs_ready
    nfs_ready=$(kubectl get deployment nfs-server -n nfs-storage -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "${nfs_ready:-0}" -gt 0 ]; then
      _check_pass "NFS server pod running"
    else
      _check_fail "NFS server pod not running — run: aap-demo create (or kubectl rollout restart deployment/nfs-server -n nfs-storage)"
    fi
  else
    _check_warn "nfs-local-rwx StorageClass not found — hub RWX storage unavailable"
    _check_info "Fix: re-run 'aap-demo create' to deploy NFS provisioner, or create the StorageClass manually"
  fi

  # Check disk usage
  local disk_pct
  disk_pct=$(aap_demo_vm_disk_usage_pct 2>/dev/null || true)
  if [ -z "$disk_pct" ]; then
    _check_warn "Disk usage unavailable — check with: aap-demo ssh -- df -h /var"
  elif [ "$disk_pct" -ge 95 ]; then
    _check_fail "Disk usage: ${disk_pct}% — critically low space"
  elif [ "$disk_pct" -ge 80 ]; then
    _check_warn "Disk usage: ${disk_pct}% — consider pruning: aap-demo ssh && sudo crictl rmi --prune"
  else
    _check_pass "Disk usage: ${disk_pct}%"
  fi
  echo ""

  # =========================================================================
  # Security
  # =========================================================================
  echo "Security:"
  local ns_exists=false
  kubectl get namespace "$NAMESPACE" &>/dev/null && ns_exists=true

  local scc_anyuid=0 scc_privileged=0
  if $ns_exists; then
    # SCC grants create ClusterRoleBindings, not namespace RoleBindings
    local _crb_list
    _crb_list=$(kubectl get clusterrolebinding -o wide 2>/dev/null || true)
    scc_anyuid=$(echo "$_crb_list" | grep -c "scc:anyuid.*system:serviceaccounts:${NAMESPACE}" || true)
    scc_privileged=$(echo "$_crb_list" | grep -c "scc:privileged.*system:serviceaccounts:${NAMESPACE}" || true)
    # Fallback: check namespace rolebindings (older oc versions)
    if [ "${scc_anyuid:-0}" -eq 0 ]; then
      scc_anyuid=$(kubectl get rolebinding -n "$NAMESPACE" -o wide 2>/dev/null | grep -c "scc:anyuid" || true)
    fi
    if [ "${scc_privileged:-0}" -eq 0 ]; then
      scc_privileged=$(kubectl get rolebinding -n "$NAMESPACE" -o wide 2>/dev/null | grep -c "scc:privileged" || true)
    fi
  fi

  if [ "${scc_anyuid:-0}" -gt 0 ] && [ "${scc_privileged:-0}" -gt 0 ]; then
    _check_pass "SCCs granted (anyuid + privileged) in $NAMESPACE"
  elif [ "$scc_anyuid" -gt 0 ]; then
    _check_warn "Only anyuid SCC granted — privileged missing in $NAMESPACE"
  elif [ "$scc_privileged" -gt 0 ]; then
    _check_warn "Only privileged SCC granted — anyuid missing in $NAMESPACE"
  else
    if $ns_exists; then
      _check_fail "No SCCs granted in $NAMESPACE — pods will fail to start"
      _check_info "Fix: oc adm policy add-scc-to-group anyuid system:serviceaccounts:$NAMESPACE"
      _check_info "Fix: oc adm policy add-scc-to-group privileged system:serviceaccounts:$NAMESPACE"
    else
      _check_info "Namespace $NAMESPACE does not exist yet (will be created on deploy)"
    fi
  fi

  # Check supplementalGroups on gateway deployment (OpenShift Local needs group 0)
  if $ns_exists; then
    local _gw_deploy _gw_sg
    _gw_deploy=$(kubectl get deployment -n "$NAMESPACE" -o name 2>/dev/null | grep gateway | grep -v operator | head -1)
    if [ -n "$_gw_deploy" ]; then
      _gw_sg=$(kubectl get "$_gw_deploy" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.securityContext.supplementalGroups}' 2>/dev/null || echo "")
      if [ "$_gw_sg" = "[0]" ]; then
        _check_pass "Gateway has supplementalGroups: [0]"
      else
        _check_fail "Gateway missing supplementalGroups: [0] — supervisord will crash with EACCES"
        _check_info "Fix: kubectl patch $_gw_deploy -n $NAMESPACE --type=json -p '[{\"op\":\"add\",\"path\":\"/spec/template/spec/securityContext/supplementalGroups\",\"value\":[0]}]'"
      fi
    fi
  fi

  # Check namespace PSA labels
  local psa_enforce
  if $ns_exists; then
    psa_enforce=$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null || echo "")
    if [ "$psa_enforce" = "privileged" ]; then
      _check_pass "Namespace PSA labels: privileged"
    elif [ -n "$psa_enforce" ]; then
      _check_warn "Namespace PSA enforce: $psa_enforce (expected: privileged)"
    else
      _check_fail "Namespace $NAMESPACE missing PSA labels"
    fi
  fi
  echo ""

  # =========================================================================
  # AAP deployment
  # =========================================================================
  echo "AAP Deployment:"
  local aap_name
  aap_name=$(kubectl get aap -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [ -z "$aap_name" ]; then
    _check_info "No AAP instance found in $NAMESPACE"
  else
    # Check idle state
    local idle_state
    idle_state=$(kubectl get aap "$aap_name" -n "$NAMESPACE" -o jsonpath='{.spec.idle_aap}' 2>/dev/null)
    if [ "$idle_state" = "true" ]; then
      _check_info "AAP '$aap_name' is idle (scaled down)"
    else
      # Check AAP status conditions
      local aap_status
      aap_status=$(kubectl get aap "$aap_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Successful")].status}' 2>/dev/null || echo "")
      local aap_running
      aap_running=$(kubectl get aap "$aap_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Running")].status}' 2>/dev/null || echo "")
      local aap_successful_reason
      aap_successful_reason=$(kubectl get aap "$aap_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Successful")].reason}' 2>/dev/null || echo "")
      local aap_failure
      aap_failure=$(kubectl get aap "$aap_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Failure")].status}' 2>/dev/null || echo "")

      if aap_condition_is_complete "$aap_status" "$aap_running" "$aap_successful_reason" "$aap_failure"; then
        _check_pass "AAP '$aap_name' deployed successfully"
      elif [ "$aap_failure" = "True" ]; then
        local fail_msg
        fail_msg=$(kubectl get aap "$aap_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Failure")].message}' 2>/dev/null || echo "")
        _check_fail "AAP '$aap_name' has failures: ${fail_msg:-unknown}"
      else
        _check_warn "AAP '$aap_name' is still reconciling"
      fi
    fi

    # Check pods
    local total_pods running_pods problem_pods
    total_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -cv "Completed" || true)
    running_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c "Running" || true)
    problem_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -cE "CrashLoopBackOff|Error|ImagePullBackOff|Pending" || true)

    if [ "${problem_pods:-0}" -gt 0 ]; then
      _check_fail "$problem_pods pod(s) in error state ($running_pods/${total_pods:-0} running)"
      local problem_list
      problem_list=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -E "CrashLoopBackOff|Error|ImagePullBackOff|Pending" || true)
      if [ -n "$problem_list" ]; then
        while IFS= read -r line; do
          _check_info "  $line"
        done <<<"$problem_list"
      fi

    elif [ "${total_pods:-0}" -gt 0 ]; then
      _check_pass "All pods healthy ($running_pods/$total_pods running)"
    fi

    # Check PVCs
    local pending_pvcs
    pending_pvcs=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c "Pending" || true)
    if [ "${pending_pvcs:-0}" -gt 0 ]; then
      _check_fail "$pending_pvcs PVC(s) pending"
      local pending_list
      pending_list=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | grep "Pending" || true)
      if [ -n "$pending_list" ]; then
        while IFS= read -r line; do
          _check_info "  $line"
        done <<<"$pending_list"
      fi
    else
      local bound_pvcs
      bound_pvcs=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c "Bound" || true)
      if [ "$bound_pvcs" -gt 0 ]; then
        _check_pass "All PVCs bound ($bound_pvcs)"
      fi
    fi
  fi
  echo ""

  # =========================================================================
  # DNS
  # =========================================================================
  echo ""
  echo "DNS:"
  local coredns_running corefile
  coredns_running=$(kubectl get pods -n openshift-dns --no-headers 2>/dev/null | grep -c "Running" || echo "0")
  if [ "$coredns_running" -gt 0 ]; then
    _check_pass "CoreDNS running ($coredns_running pods)"
  else
    _check_warn "CoreDNS pods not found in openshift-dns"
  fi
  corefile=$(kubectl get configmap dns-default -n openshift-dns \
    -o jsonpath='{.data.Corefile}' 2>/dev/null || echo "")
  if echo "$corefile" | grep -q "router-internal-default"; then
    _check_pass "CoreDNS route rewrite present"
  elif [ -n "$corefile" ]; then
    _check_fail "CoreDNS missing rewrite for apps.<domain> route hostnames"
    _check_info "AO/portal/MCP cannot resolve AAP routes from inside the cluster"
    verify_coredns
    corefile=$(kubectl get configmap dns-default -n openshift-dns \
      -o jsonpath='{.data.Corefile}' 2>/dev/null || echo "")
    if echo "$corefile" | grep -q "router-internal-default"; then
      _check_pass "CoreDNS route rewrite restored"
    else
      _check_info "Fix: aap-demo start   (or aap-demo wire / aap-demo enable ao)"
    fi
  fi
  echo ""

  # =========================================================================
  # Summary
  # =========================================================================
  echo "─────────────────────────────────────"
  if [ "$issues" -eq 0 ] && [ "$warnings" -eq 0 ]; then
    printf "\033[32m✓ All checks passed — environment is healthy\033[0m\n"
  elif [ "$issues" -eq 0 ]; then
    printf "\033[33m⚠ %d warning(s), no critical issues\033[0m\n" "$warnings"
  else
    printf "\033[31m✗ %d issue(s), %d warning(s)\033[0m\n" "$issues" "$warnings"
    echo ""
    echo "For detailed diagnostics: aap-demo must-gather"
    echo "For AI-assisted analysis:  aap-demo diagnose --ai"
  fi

  # AI analysis mode
  if [ "${_DIAGNOSE_AI:-false}" = "true" ]; then
    echo ""

    if ! command -v claude &>/dev/null; then
      echo "✗ 'claude' CLI not found"
      echo "  Install: https://docs.anthropic.com/en/docs/claude-code"
      return 1
    fi

    echo "─────────────────────────────────────"
    printf "\033[1mAI Analysis\033[0m (powered by Claude)\n"
    echo ""

    echo "(Diagnostic data is sent to the Claude API for analysis)"
    echo ""

    # Collect additional context for AI — cache pod list to avoid duplicate kubectl calls
    local pod_output
    pod_output=$(kubectl get pods -n "$NAMESPACE" -o wide --no-headers 2>/dev/null || echo "No pods")
    local problem_pod_names
    problem_pod_names=$(echo "$pod_output" | grep -E "CrashLoopBackOff|Error|ImagePullBackOff|Pending" | awk '{print $1}' || true)
    local problem_pod_logs=""
    if [ -n "$problem_pod_names" ]; then
      while IFS= read -r pod; do
        problem_pod_logs="${problem_pod_logs}--- ${pod} ---
$(kubectl logs "$pod" -n "$NAMESPACE" --tail=20 2>/dev/null || true)
"
      done <<<"$problem_pod_names"
    fi

    local ai_context
    ai_context="AAP Demo Diagnose Results:
Issues: $issues, Warnings: $warnings
Infra: OpenShift Local (CRC)
Namespace: $NAMESPACE

Cluster State:
$pod_output

PVC State:
$(kubectl get pvc -n "$NAMESPACE" 2>/dev/null || echo "No PVCs")

Storage Classes:
$(kubectl get sc 2>/dev/null || echo "No storage classes")

AAP CR Status:
$(kubectl get aap -n "$NAMESPACE" -o yaml 2>/dev/null | grep -A20 "status:" || echo "No AAP CR")

Recent Events:
$(kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null | tail -20 || echo "No events")

Problem Pods:
$(echo "$pod_output" | grep -E "CrashLoopBackOff|Error|ImagePullBackOff|Pending" || echo "None")

Problem Pod Logs:
${problem_pod_logs:-None}"

    echo "$ai_context" | claude -p \
      "You are an AAP Demo troubleshooting assistant. Analyze the diagnostic output below and:
1. Identify the root cause of any issues
2. Provide specific fix commands the user can run
3. If the issue appears to be a bug in aap-demo itself, suggest filing a GitHub issue at https://github.com/RedHatOfficial/aap-demo/issues

Be concise and actionable. Focus on what the user needs to do next.

Diagnostic data:" 2>&1 || {
      echo ""
      echo "⚠ AI analysis failed. The diagnostic data above should help with manual troubleshooting."
    }
  fi
}

_show_fleet_status() {
  if ! compgen -G "${AAP_DEMO_DIR:-$HOME/.aap-demo}/fleet/node-*/meta" >/dev/null; then
    return 0
  fi
  source "${SCRIPT_DIR}/addons/fleet/fleet.sh"
  local fleet_nodes mode=omit
  [ "$SHOW_SECRETS" != true ] || mode=include
  fleet_nodes=$(fleet_access_inventory "$mode") || return 1
  echo "Fleet:"
  echo "-----------"
  fleet_list
  jq -r '.[] | "  \(.hostname): ssh -p \(.ssh_port) \(.username)@\(.ssh_host)\n    Guest IP: \(.guest_ip // "not discovered")" +
    (if .password != null then "\n    Username: \(.username)\n    Password: \(.password)" else "" end)' <<<"$fleet_nodes"
  echo ""
}

cmd_status() {
  echo ""
  printf "\033[1mAAP Demo Status\033[0m\n"
  echo "==============="
  printf "Tool:        %s\n" "$(aap_demo_version_short)"
  printf "Built:       %s\n" "$AAP_DEMO_GIT_DATE"
  echo ""

  # Check cluster status via infra abstraction
  local cluster_state
  cluster_state=$(infra_get_state 2>/dev/null || echo "not_created")
  local cluster_name
  cluster_name=$(infra_get_name 2>/dev/null || echo "")

  printf "Infra:       OpenShift Local (CRC)\n"

  if [ "$cluster_state" = "running" ]; then
    printf "Cluster:     \033[1;32mrunning\033[0m"
    [ -n "$cluster_name" ] && printf " (%s)" "$cluster_name"
    echo ""
  elif [ "$cluster_state" = "stopped" ]; then
    printf "Cluster:     \033[1;33mstopped\033[0m\n"
    echo ""
    echo "Start with: crc start"
    _show_fleet_status || return 1
    return 0
  else
    printf "Cluster:     \033[1;31mnot running\033[0m\n"
    echo ""
    echo "Start with: aap-demo create"
    _show_fleet_status || return 1
    return 0
  fi

  # Status must inspect CRC state before touching Kubernetes. A stopped CRC
  # VM, or a VM with an unhealthy API server, can leave a stale kubeconfig
  # probe hanging indefinitely.
  setup_kubeconfig

  # Export CA env vars if installed, don't prompt for sudo
  local ca_path
  ca_path=$(get_ingress_ca_cert_path)
  if [ -f "$ca_path" ]; then
    _ingress_ca_export_env "$ca_path"
  fi

  echo ""
  echo "TLS:"
  echo "----"
  ingress_ca_trust_status "$ca_path" || true
  echo ""

  # Show kubeconfig
  echo "Kubeconfig:  $KUBECONFIG"
  echo "Source:      $AAP_DEMO_REPO_ROOT (branch: $AAP_DEMO_GIT_BRANCH)"
  [ -n "$AAP_DEMO_GIT_REMOTE" ] && echo "Repo:        $AAP_DEMO_GIT_REMOTE"

  echo ""
  echo "Host:"
  echo "-----"
  local host_os host_arch
  host_os=$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
  host_arch=$(uname -m 2>/dev/null || echo "unknown")
  echo "  OS:           ${host_os:-unknown}"
  echo "  Architecture: $host_arch"

  # VM stats
  echo ""
  echo "VM:"
  echo "---"
  local vm_info
  vm_info=$(infra_exec_cmd bash -c '
        # RHEL version
        RHEL=$(cat /etc/redhat-release 2>/dev/null || echo "unknown")
        # OpenShift version
        USHIFT=$(microshift version 2>/dev/null | awk "/MicroShift Version:/{print \$3}" || rpm -q microshift --qf "%{VERSION}" 2>/dev/null || echo "unknown")
        # CPU
        CPUS=$(nproc)
        # Memory
        MEM_TOTAL=$(free -h | awk "/Mem:/{print \$2}")
        MEM_USED=$(free -h | awk "/Mem:/{print \$3}")
        MEM_AVAIL=$(free -h | awk "/Mem:/{print \$7}")
        # Load
        LOAD=$(cat /proc/loadavg | awk "{print \$1, \$2, \$3}")
        # Disk
        DISK=$(df -h /var 2>/dev/null | awk "NR==2{print \$3\"/\"\$2\" (\" \$5 \" used)\"}")
        echo "  Guest OS:     $RHEL"
        echo "  OpenShift:    $USHIFT"
        echo "  CPUs:         $CPUS"
        echo "  Memory:       ${MEM_USED} / ${MEM_TOTAL} (${MEM_AVAIL} available)"
        echo "  Load:         $LOAD"
        echo "  Disk:         $DISK"
  ' 2>/dev/null)
  echo "$vm_info"
  persistent_crio_store_status
  echo ""

  # List application namespaces with pod counts (skip openshift-* and kube-* system namespaces)
  echo "Namespaces:"
  echo "-----------"
  NAMESPACES=$(kubectl get ns --no-headers -o custom-columns=':metadata.name' 2>/dev/null \
    | grep -vE '^(openshift|kube-|default$)' | sort)

  if [ -z "$NAMESPACES" ]; then
    echo "  (no application namespaces found)"
  else
    for ns in $NAMESPACES; do
      POD_TOTAL=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -cv Completed 2>/dev/null | tr -d "
" || echo 0)
      POD_RUNNING=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -c "Running" 2>/dev/null || true)
      [ -z "$POD_RUNNING" ] && POD_RUNNING=0
      # Skip empty namespaces
      if [ "$POD_TOTAL" -eq 0 ] 2>/dev/null; then continue; fi
      AAP_CR=$(kubectl get aap -n "$ns" --no-headers 2>/dev/null | awk '{print $1}' | head -1 || true)

      if [ -n "$AAP_CR" ]; then
        AAP_STATUS=$(kubectl get aap "$AAP_CR" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Successful")].status}' 2>/dev/null || echo "")
        AAP_RUNNING=$(kubectl get aap "$AAP_CR" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Running")].status}' 2>/dev/null || echo "")
        AAP_SUCCESSFUL_REASON=$(kubectl get aap "$AAP_CR" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Successful")].reason}' 2>/dev/null || echo "")
        AAP_FAILURE=$(kubectl get aap "$AAP_CR" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Failure")].status}' 2>/dev/null || echo "")
        if aap_condition_is_complete "$AAP_STATUS" "$AAP_RUNNING" "$AAP_SUCCESSFUL_REASON" "$AAP_FAILURE"; then
          printf "  %-30s %s/%s pods   \033[1;32m%s\033[0m\n" "$ns" "$POD_RUNNING" "$POD_TOTAL" "$AAP_CR"
        else
          if [ "$AAP_RUNNING" = "True" ]; then
            printf "  %-30s %s/%s pods   \033[1;33m%s (Deploying)\033[0m\n" "$ns" "$POD_RUNNING" "$POD_TOTAL" "$AAP_CR"
          else
            printf "  %-30s %s/%s pods   %s\n" "$ns" "$POD_RUNNING" "$POD_TOTAL" "$AAP_CR"
          fi
        fi
      else
        printf "  %-30s %s/%s pods\n" "$ns" "$POD_RUNNING" "$POD_TOTAL"
      fi
    done
  fi
  echo ""

  # Show deployment routes (exclude OpenShift/system namespaces)
  echo "AAP Deployments:"
  echo "----------------"
  ROUTES=$(kubectl get route -A --no-headers 2>/dev/null \
    | grep -v -E '^(openshift-|kube-|aap-demo-)' \
    | awk '{printf "  https://%s\n", $3}' | sort -u)
  if [ -n "$ROUTES" ]; then
    echo "$ROUTES"
  else
    echo "  (no routes found)"
  fi
  echo ""

  # Reveal credentials only after an explicit interactive request.
  local _cred_namespaces _cred_found
  _cred_found=false
  if [ "$SHOW_SECRETS" = true ]; then
    _cred_namespaces=$(kubectl get aap -A --no-headers 2>/dev/null | awk '{print $1}' | sort -u)
    for ns in $_cred_namespaces; do
      local ADMIN_PASSWORD=""
      local ADMIN_SECRET
      ADMIN_SECRET=$(kubectl get aap -n "$ns" -o jsonpath='{.items[0].status.adminPasswordSecret}' 2>/dev/null || true)
      if [ -n "$ADMIN_SECRET" ]; then
        ADMIN_PASSWORD=$(kubectl get secret -n "$ns" "$ADMIN_SECRET" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
      fi
      if [ -z "$ADMIN_PASSWORD" ]; then
        for secret_name in myaap-admin-password aap-admin-password aap-controller-admin-password custom-admin-password; do
          ADMIN_PASSWORD=$(kubectl get secret -n "$ns" "$secret_name" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
          [ -n "$ADMIN_PASSWORD" ] && break
        done
      fi

      if [ -n "$ADMIN_PASSWORD" ]; then
        if [ "$_cred_found" = "false" ]; then
          echo "Credentials:"
          echo "------------"
          _cred_found=true
        fi
        printf "  %-20s admin / %s\n" "$ns:" "$ADMIN_PASSWORD"
      fi
    done
    [ "$_cred_found" = "true" ] && echo ""
  else
    echo "Credentials: hidden (run 'aap-demo status --show-secrets' in a terminal to reveal)"
    echo ""
  fi

  # Show credentials for Automation Orchestrator (ao addon)
  if [ "$SHOW_SECRETS" = true ] \
    && { echo "$(_addons_list)" | grep -qw "ao" || kubectl get namespace automation-orchestrator &>/dev/null 2>&1; }; then
    local _ao_ns="automation-orchestrator"
    local _ao_pw="" _ao_secret=""
    _ao_secret=$(kubectl get secret -n "$_ao_ns" -o name 2>/dev/null | grep -i "admin-password" | head -1 || true)
    if [ -n "$_ao_secret" ]; then
      _ao_pw=$(kubectl get "$_ao_secret" -n "$_ao_ns" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
    fi
    if [ -n "$_ao_pw" ]; then
      if [ "$_cred_found" = "false" ]; then
        echo "Credentials:"
        echo "------------"
      fi
      printf "  %-20s admin / %s\n" "$_ao_ns:" "$_ao_pw"
      _cred_found=true
      echo ""
    fi
  fi

  # Show credentials for the Satellite lab (separate libvirt VM, not in-cluster).
  # The admin password lives in the encrypted credential Vault
  # (aap_demo.satellite.admin_password), generated at build time.
  if [ "$SHOW_SECRETS" = true ]; then
    local _sat_host="${SATELLITE_LAB_HOST:-satellite.demo.lab}"
    local _sat_ip="${SATELLITE_LAB_IP:-192.168.122.20}"
    # Only shown when the Satellite VM exists and is reachable.
    if getent hosts "$_sat_host" >/dev/null 2>&1 \
      || ping -c1 -W1 "$_sat_ip" >/dev/null 2>&1; then
      local _sat_user _sat_pass
      _sat_user="${SATELLITE_USERNAME:-admin}"
      _sat_pass="${SATELLITE_PASSWORD:-}"
      # Read from the Vault when not overridden by the environment.
      if [ -z "$_sat_pass" ] && command -v aap_demo_satellite_admin_password >/dev/null 2>&1; then
        _sat_pass=$(aap_demo_satellite_admin_password 2>/dev/null || true)
      fi
      if [ -n "$_sat_pass" ]; then
        if [ "$_cred_found" = "false" ]; then
          echo "Credentials:"
          echo "------------"
          _cred_found=true
        fi
        printf "  %-20s %s / %s\n" "satellite (${_sat_host}):" "$_sat_user" "$_sat_pass"
        echo ""
      fi
    fi
  fi

  if [ "$SHOW_SECRETS" = true ]; then
    local crc_access crc_identity
    crc_access=$(_aap_demo_inventory_crc_access) || return 1
    crc_identity=$(jq -r '.ssh_key // empty' <<<"$crc_access")
    echo "CRC SSH Access:"
    echo "---------------"
    printf '  crc_ip: %s\n' "$(jq -r '.crc_ip // "unavailable"' <<<"$crc_access")"
    echo "  SSH: aap-demo ssh"
    if [ -n "$crc_identity" ]; then
      printf '  Direct command: ssh -i %q -o IdentitiesOnly=yes -p 2222 core@127.0.0.1\n' "$crc_identity"
    fi
    echo ""
  fi

  # Show the credential paths for the Keycloak OIDC lab addon without exposing
  # secret values in terminal output or CI logs.
  local _keycloak_state_dir="${KEYCLOAK_STATE_DIR:-${HOME}/.aap-demo/keycloak}"
  if [ -d "$_keycloak_state_dir" ]; then
    if [ -f "$_keycloak_state_dir/admin-password" ]; then
      if [ "$_cred_found" = "false" ]; then
        echo "Credentials:"
        echo "------------"
        _cred_found=true
      fi
      echo "  Keycloak users: aap-oidc-admin, aap-oidc-operator, aap-oidc-auditor, aap-oidc-developer"
      echo "  Keycloak credential files: ${_keycloak_state_dir}/"
      echo ""
    fi
  fi

  # Show addons with URLs or enable instructions
  local saved_addons
  saved_addons=$(_addons_list)
  echo "Addons:"
  echo "-------"
  for a in $AVAILABLE_ADDONS; do
    local url="" label="" enabled=false
    if echo "$saved_addons" | grep -qw "$a"; then
      enabled=true
    fi
    case "$a" in
      fleet)
        if [ "$enabled" = true ]; then
          if [ -d "${AAP_DEMO_DIR:-$HOME/.aap-demo}/fleet" ] && [ -f "${SCRIPT_DIR}/addons/fleet/fleet.sh" ]; then
            source "${SCRIPT_DIR}/addons/fleet/fleet.sh"
            local _fc
            _fc=$(fleet_count 2>/dev/null || echo "0")
            if [ "$_fc" -gt 0 ] 2>/dev/null; then
              label="${_fc} node(s) running"
            else
              label="enabled (no nodes)"
            fi
          else
            label="enabled"
          fi
        else
          label="disabled"
        fi
        ;;
      mcp-server)
        if [ "$enabled" = true ]; then
          url="https://aap-mcp-${NAMESPACE:-aap-operator}.$(aap_demo_route_domain)/mcp"
          if ! kubectl get ansiblemcpserver aap-mcp-server -n "${NAMESPACE:-aap-operator}" &>/dev/null; then
            label="not-deployed"
          fi
        else
          label="disabled"
        fi
        ;;
      portal)
        if [ "$enabled" = true ]; then
          url="https://$(kubectl get route redhat-rhaap-portal -n redhat-rhaap-portal -o jsonpath='{.spec.host}' 2>/dev/null || kubectl get route redhat-rhaap-portal -n ${NAMESPACE:-aap-operator} -o jsonpath='{.spec.host}' 2>/dev/null || true)"
          if [ -z "$url" ] || [ "$url" = "https://" ]; then
            url=""
            label="not-deployed"
          fi
        else
          label="disabled"
        fi
        ;;
      portal-operator)
        local _note=" (AMD64 only)"
        if [ "$enabled" = true ]; then
          label="enabled${_note}"
        else
          label="disabled${_note}"
        fi
        ;;
      ao)
        if [ "$enabled" = true ] || kubectl get namespace automation-orchestrator &>/dev/null 2>&1; then
          label="enabled"
        else
          label="disabled"
        fi
        ;;
      keycloak)
        local _keycloak_namespace="${KEYCLOAK_NAMESPACE:-aap-demo-keycloak}"
        if [ "$enabled" = true ] || kubectl get namespace "$_keycloak_namespace" &>/dev/null 2>&1; then
          url="https://$(kubectl get route keycloak -n "$_keycloak_namespace" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
          if [ "$url" = "https://" ]; then
            url=""
            label="not-deployed"
          fi
        else
          label="disabled"
        fi
        ;;
      *)
        if [ "$enabled" = true ]; then
          label="enabled"
        else
          label="disabled"
        fi
        ;;
    esac
    if [ -n "$url" ] && [ -z "$label" ]; then
      printf "  %-15s %s\n" "$a" "$url"
    elif [ -n "$label" ]; then
      printf "  %-15s %s\n" "$a" "$label"
    else
      printf "  %-15s disabled\n" "$a"
    fi
  done
  echo ""

  # Show both fleet backends. Bash v1 stores QEMU nodes on the host; Python v2
  # stores pod-backed nodes in Kubernetes, so neither state can be inferred
  # from the other's config or filesystem.
  local _fleet_v2_rows _fleet_v2_total _fleet_v2_ready _fleet_v2_err _fleet_v2_rc
  local _fleet_kubectl
  # status does not run cluster setup, so pass the flags the user already gave.
  _fleet_kubectl=(kubectl)
  if [ -n "${KUBECTL_CONTEXT:-}" ]; then
    _fleet_kubectl+=(--context "$KUBECTL_CONTEXT")
  fi
  if [ -n "${KUBECTL_KUBECONFIG:-}" ]; then
    _fleet_kubectl+=(--kubeconfig "$KUBECTL_KUBECONFIG")
  fi
  _fleet_v2_err=$(mktemp)
  # set -e would exit on a failing assignment before the rc could be read.
  _fleet_v2_rc=0
  # -A because the Fleet namespace is configurable. The label keeps the list
  # small, and the timeout keeps a stopped cluster from slowing status down.
  _fleet_v2_rows=$("${_fleet_kubectl[@]}" --request-timeout=5s get pods -A \
    -l app.kubernetes.io/name=fleet-node \
    --no-headers \
    -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,READY:.status.containerStatuses[0].ready,PHASE:.status.phase' \
    2>"$_fleet_v2_err") || _fleet_v2_rc=$?
  if [ "$_fleet_v2_rc" -ne 0 ]; then
    echo "Kubernetes-native Fleet: kubectl failed ($(head -1 "$_fleet_v2_err" | cut -c1-120))"
    rm -f "$_fleet_v2_err"
  elif [ -n "$_fleet_v2_rows" ]; then
    rm -f "$_fleet_v2_err"
    _fleet_v2_total=$(printf '%s\n' "$_fleet_v2_rows" | awk 'NF {count++} END {print count + 0}')
    _fleet_v2_ready=$(printf '%s\n' "$_fleet_v2_rows" | awk '$3 == "true" {count++} END {print count + 0}')
    echo "Kubernetes-native Fleet:"
    printf "  %s/%s pod nodes ready\n" "$_fleet_v2_ready" "$_fleet_v2_total"
    printf '%s\n' "$_fleet_v2_rows" | sed 's/^/  /'
    echo ""
  else
    rm -f "$_fleet_v2_err"
  fi

  _show_fleet_status
}
