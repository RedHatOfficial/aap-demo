# AAP Demo — AI Assistant Context

## What is aap-demo?

aap-demo is a tool for deploying Ansible Automation Platform (AAP) 2.7 to OpenShift Local (MicroShift) for development and testing.

## Key Commands

```
aap-demo create          # Create local MicroShift cluster
aap-demo deploy          # Deploy AAP 2.7
aap-demo status          # Show cluster status, routes, credentials
aap-demo diagnose        # Quick health check (cluster, storage, SCCs, pods)
aap-demo diagnose --ai   # Health check + AI-powered root cause analysis (requires claude CLI)
aap-demo must-gather     # Collect full diagnostics for troubleshooting
aap-demo idle true       # Scale down AAP to save resources (operator deploys only)
aap-demo idle false      # Scale back up
aap-demo ssh             # SSH into cluster node
aap-demo stop / start    # Stop/start cluster
aap-demo destroy         # Delete cluster
aap-demo help            # Full command reference
```

## Architecture

- **OpenShift Local**: OpenShift Local VM running MicroShift, managed by `crc` CLI
- **Storage**: LVMS (topolvm-provisioner) for RWO, in-cluster NFS server for RWX (nfs-local-rwx)
- **OLM**: Installed via operator-sdk for operator lifecycle management
- **Namespace**: `aap-operator` (default), configurable via `NAMESPACE=`

## Common Issues and Fixes

### Pod creation failures (SCC)
**Symptom**: Pods fail with "unable to validate against any security context constraint"
**Cause**: Service accounts missing anyuid/privileged SCCs
**Fix**:
```bash
oc adm policy add-scc-to-group anyuid system:serviceaccounts:aap-operator
oc adm policy add-scc-to-group privileged system:serviceaccounts:aap-operator
```

### PVC pending (hub file storage)
**Symptom**: `aap-hub-file-storage` PVC stuck in Pending
**Cause**: Missing nfs-local-rwx StorageClass or NFS server not running
**Fix**: Check `kubectl get sc` for nfs-local-rwx. If missing, re-run `aap-demo create`. If present, check NFS server: `kubectl get pods -n nfs-storage`

### CatalogSource not ready (latest deploys)
**Symptom**: CatalogSource stuck in TRANSIENT_FAILURE
**Cause**: Catalog pod can't start due to SCC or pull secret issues
**Fix**: Check `kubectl get pods -n aap-operator` for catalog pod. Verify pull secret exists: `kubectl get secret redhat-operators-pull-secret -n aap-operator`

### Gateway CrashLoopBackOff
**Symptom**: Gateway pod crashes with EACCES on socket
**Cause**: Startup ordering — gateway starts before dependencies are ready
**Fix**: Usually resolves after operator reconciliation. If persistent, delete the pod: `kubectl delete pod -l app.kubernetes.io/name=gateway -n aap-operator`

### DNS resolution failures
**Symptom**: Pods can't resolve nip.io routes or cluster services
**Cause**: CoreDNS config not persisted after CRC restart
**Fix**: `aap-demo start` (re-applies CoreDNS config) or `kubectl rollout restart daemonset/dns-default -n openshift-dns`

### Disk space
**Symptom**: Pods evicted or images fail to pull
**Fix**: `aap-demo ssh` then `sudo crictl rmi --prune` to clean unused images

## File Structure

```
aap-demo.sh                    # Main CLI script
includes/
  crc-create.sh               # OpenShift Local cluster creation (nip.io, NFS, metrics-server)
config/
  crs/                         # AAP Custom Resource templates
    aap-minimal.yaml           # Default CR (RWX via nfs-local-rwx)
  manifests/
    nfs-server.yaml            # In-cluster NFS server
    nfs-provisioner.yaml       # NFS subdir provisioner (__NFS_SERVER_IP__ template)
  olm/                         # OLM subscription and catalog
addons/                        # Optional addons (console, registry, mcp-server, etc.)
ansible/                       # Ansible playbook alternative
```

## Key Technical Details

- **SCCs**: Granted at namespace group level (`system:serviceaccounts:$NAMESPACE`) not per-SA
- **nfs-local-rwx**: In-cluster NFS server backed by topolvm PVC. Provisioner manifest uses `__NFS_SERVER_IP__` placeholder resolved at deploy time because kubelet can't resolve cluster DNS for NFS mounts on MicroShift
- **idle_aap**: Standard AAP CR field — patches `spec.idle_aap: true/false` to scale all components via the gateway operator
- **KUBECONFIG**: CRC uses `~/.crc/machines/crc/kubeconfig`
- **Config file**: `~/.aap-demo/config` stores INFRA type, CRC preset, addons

## When Helping Users

1. Run `aap-demo diagnose` first to identify obvious issues
2. If diagnose shows failures, suggest the specific fix listed
3. For complex issues, suggest `aap-demo diagnose --ai` for AI-powered root cause analysis
4. If still unclear, run `aap-demo must-gather` to collect full diagnostics
5. Check `aap-demo status` for routes and credentials
6. For deployment issues, check operator logs: `kubectl logs -l app.kubernetes.io/managed-by=aap-gateway-operator -n aap-operator --tail=50`
