---
name: aap-demo
description: >
  Manages AAP (Ansible Automation Platform) development environments on local
  MicroShift clusters. Handles cluster lifecycle (create, deploy, destroy),
  diagnostics, troubleshooting, and test execution. Activate when users want to
  deploy AAP, check cluster health, fix deployment issues, run tests, or manage
  their aap-demo environment.
allowed-tools:
  - Bash(aap-demo *)
  - Bash(kubectl *)
  - Bash(oc *)
argument-hint: "[command, question, or intent]"
---

# aap-demo Skill

You manage AAP development environments using the `aap-demo` CLI. Delegate to
CLI commands — do not reimplement their logic.

## Commands Reference

| Intent | Command |
|--------|---------|
| Create cluster | `aap-demo create` |
| Deploy AAP 2.7 | `aap-demo deploy` |
| Deploy operator only | `aap-demo deploy-operator` |
| Check status & creds | `aap-demo status` |
| Health check | `aap-demo diagnose` |
| AI-powered diagnostics | `aap-demo diagnose --ai` |
| Collect full diagnostics | `aap-demo must-gather` |
| Scale down (save resources) | `aap-demo idle true` |
| Scale back up | `aap-demo idle false` |
| Remove AAP (keep cluster) | `aap-demo clean` |
| Destroy entire cluster | `aap-demo destroy` |
| Stop/start cluster | `aap-demo stop` / `aap-demo start` |
| SSH into cluster node | `aap-demo ssh` |
| Run tests | `aap-demo test` |
| Enable addon | `aap-demo enable <name>` |
| Disable addon | `aap-demo disable <name>` |
| Destroy and rebuild from scratch | `aap-demo redeploy-all` |
| Show help | `aap-demo help` |

Available addons: olm, console, registry, mcp-server, devspaces, prometheus

## Deploy Selection

`aap-demo deploy` deploys AAP 2.7.

## Portal VM Addon

Portal VM runs AAP Self-Service Portal via QEMU x86 emulation on macOS:

| Command | Purpose |
|---------|---------|
| `./addons/portal-vm/deploy.sh` | Start portal VM |
| `./addons/portal-vm/deploy.sh --delete` | Stop and cleanup portal VM |

**Access after boot (3-10min)**:
- Portal UI: `https://localhost:8443` (AAP OAuth login)
- SSH: `ssh -i ~/.aap-demo/portal-vm/id_ed25519 -p 2223 admin@localhost`

**Boot progress**: `tail -f ~/.aap-demo/portal-vm/serial.log`

**Prerequisites**:
```bash
brew install qemu cdrtools
```

Portal qcow2 must exist in `~/Downloads/ansible-automation-portal-*-x86_64.qcow2` (download from Red Hat Customer Portal).

**Configuration**: Portal uses AAP OAuth (not GitHub). OAuth app auto-created in AAP during deployment. Cloud-init applies:
- AAP host URL
- OAuth client ID/secret
- Admin SSH key

If login shows GitHub instead of AAP OAuth, portal may have started before cloud-init completed. Wait for cloud-init finish (`cloud-init status --wait` from SSH), then restart portal service.

## Workflow

Before any command, run `aap-demo status` to understand current state. The standard
lifecycle is: `create` -> `deploy` -> use -> `idle`/`clean` -> `destroy`.

- Deploy auto-creates the cluster if needed — no need to run create first
- After deploy completes, run `aap-demo status` to show routes and credentials
- **Destructive operations** (clean, destroy, redeploy-all): always confirm with the user first
- Use `QUIET=true` prefix to skip interactive prompts when running non-interactively

## Environment Awareness

Before suggesting commands, check the user's environment:

1. Read `~/.aap-demo/config` to determine INFRA type (crc, minc, lab)
2. Check `KUBECONFIG`:
   - CRC: `~/.crc/machines/crc/kubeconfig`
   - MINC: `~/.aap-demo/kubeconfig.microshift`
   - Lab: user's own kubeconfig
3. Run `aap-demo status` to see running deployments, namespaces, and pod counts

When the user has multiple AAP deployments (e.g., operator in `aap-operator` + aap-demo in
`aap27`), always clarify which deployment they mean before acting.

## Pull Secret Management

Pull secrets are required for image pulls and live in `~/.aap-demo/`: # pragma: allowlist secret
- `pull-secret.txt` or `pull-secret.json` (from console.redhat.com)
- ATF tests: `atf-vault-password` (for vaulted test vars)  # pragma: allowlist secret

If image pulls fail with 403/unauthorized, check:  # pragma: allowlist secret
1. Correct pull secret exists in `~/.aap-demo/`  # pragma: allowlist secret
2. Pull secret is injected into the namespace: `kubectl get secret -n $NAMESPACE | grep pull`  # pragma: allowlist secret
3. ServiceAccount has imagePullSecrets: `kubectl get sa default -n $NAMESPACE -o yaml`

## Diagnostics Loop

When troubleshooting:

1. Run `aap-demo diagnose` — parse output for `✗` (fail) and `⚠` (warn) markers
2. Apply the matching fix from the table below
3. Re-run `aap-demo diagnose` to verify
4. If issues persist after 2 attempts, run `aap-demo must-gather` for deeper analysis
5. Check operator logs: `kubectl logs -l app.kubernetes.io/managed-by=aap-gateway-operator -n $NAMESPACE --tail=100`

## Known Fixes

| Diagnose Output | Fix |
|-----------------|-----|
| SCC validation failure | `oc adm policy add-scc-to-group anyuid system:serviceaccounts:$NAMESPACE && oc adm policy add-scc-to-group privileged system:serviceaccounts:$NAMESPACE` |
| PVC pending (hub-file-storage) | Check `kubectl get sc nfs-local-rwx`. Missing: re-run `aap-demo create`. Present but pending: check NFS server `kubectl get pods -n nfs-storage` |
| CatalogSource TRANSIENT_FAILURE | DNS race condition. Check catalog pod: `kubectl get pods -n $NAMESPACE -l olm.catalogSource`. If pod is running but catalog stuck, restart catalog-operator: `kubectl rollout restart deployment/catalog-operator -n openshift-operator-lifecycle-manager`. Verify pull secret exists. |
| Gateway CrashLoopBackOff (EACCES) | Usually self-resolves after reconciliation. If persistent: `kubectl delete pod -l app.kubernetes.io/name=gateway -n $NAMESPACE` |
| DNS resolution failures | `aap-demo start` (re-applies CoreDNS config) or `kubectl rollout restart daemonset/dns-default -n openshift-dns`. Root cause: CoreDNS template plugin returns router ClusterIP directly for *.nip.io — if router IP changes after restart, CoreDNS config is stale. |
| Disk space / pod eviction | `aap-demo ssh` then `sudo crictl rmi --prune` |
| Pods stuck Pending (resources) | `kubectl describe node | grep -A 5 Allocated` — consider `aap-demo idle true` on other deployments |
| Stale pod mounts after crash | Restart kube-proxy and CoreDNS: `kubectl rollout restart daemonset/kube-proxy -n kube-proxy && kubectl rollout restart daemonset/dns-default -n openshift-dns`. Symptom: "transport endpoint is not connected" or "executable file not found" |
| ImagePullBackOff | Pull secret missing or incorrect. Needs `pull-secret.txt` for registry.redhat.io. Check `~/.aap-demo/` for correct file. |
| OLM not installed | `aap-demo enable olm` — MicroShift does not include OLM by default, it's installed during `aap-demo create` but may be missing on older setups |

## Test Orchestration

- Default: `aap-demo test` runs interop tests against auto-detected AAP deployment
- Specific markers: `aap-demo test aap-operator interop,smoke`
- Multiple deployments: specify namespace with `NAMESPACE=<ns> aap-demo test`
- After tests, summarize pass/fail counts from the output
- If tests fail, check AAP health first (`aap-demo diagnose`) before investigating test issues

## Post-Deploy Verification

After any deployment, verify health with this sequence:

1. `aap-demo status` — check all pods are running, routes are accessible
2. `aap-demo diagnose` — automated health checks
3. If diagnose shows issues, apply fixes from the Known Fixes table
4. For latest deployments, check AAP CR status: `kubectl get aap -n $NAMESPACE -o jsonpath='{.items[0].status.conditions}'`

The AAP CR goes through phases: Pending → Running → Successful. A deployment typically
takes 5-10 minutes. If stuck in Running for >15 minutes, check operator logs and diagnose.

## Key Details

- Default namespace: `aap-operator` (override with `NAMESPACE=<ns>`)
- CRC kubeconfig: `~/.crc/machines/crc/kubeconfig`
- Config file: `~/.aap-demo/config` (stores infra type, addons, preferences)
- Backends: CRC (macOS, recommended) uses a VM; MINC (Linux) uses a Podman container
- SCCs are granted at namespace group level, not per ServiceAccount
- NFS provisioner uses `__NFS_SERVER_IP__` placeholder resolved at deploy time
- MicroShift lacks `ingresses.config.openshift.io` API — route hosts use nip.io
- OLM is not built into MicroShift — installed via `operator-sdk olm install` during create
- Latest CatalogSource must be in `aap-operator` namespace (no `openshift-marketplace` on MicroShift)
- Bundle unpack jobs need `privileged` SCC (not just `anyuid`) due to seccomp annotations
- `inotify` sysctl limits (`max_user_instances=2099999999`) are critical for operator performance
