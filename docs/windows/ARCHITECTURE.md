# aap-demo Windows PowerShell Architecture

Native PowerShell implementation of the aap-demo CLI for Windows 10/11 with OpenShift Local (CRC) on Hyper-V.

## Goals

- Run `aap-demo` from **PowerShell 7+** without WSL or Git Bash
- Reuse existing **YAML manifests**, **Ansible playbooks**, and **addon assets** unchanged
- Mirror the bash CLI command surface; implement incrementally by phase
- Keep platform-specific logic in small adapter modules (CRC/SSH, cert trust, paths)

## Non-Goals (initial phases)

- MINC backend (Linux-only; Windows uses CRC)
- Full parity with all 25+ bash commands in phase 1
- Replacing bash on macOS/Linux (both CLIs coexist)

---

## Repository Layout

```
docs/windows/
  ARCHITECTURE.md          # This document (architecture + implementation plan)
  QUICK-START.md           # Windows install and first deploy

powershell/
  aap-demo.ps1             # Thin command dispatcher (entry point)
  Install.ps1              # PATH shim + module install

  modules/AapDemo/
    AapDemo.psd1           # Module manifest
    AapDemo.psm1           # Dot-sources Public/*.ps1
    Private/
      Common.ps1           # Logging, external commands, repo root, paths
    Public/
      Config.ps1           # ~/.aap-demo/config, env var precedence
      Infra.ps1            # infra-api dispatch layer
      Infra.Crc.ps1        # CRC SSH/SCP, state, VM exec
      Kubeconfig.ps1       # KUBECONFIG setup and refresh
      Cluster.ps1          # create, start, stop, destroy (crc-create port)
      Olm.ps1              # OLM install via operator-sdk
      Deploy.ps1           # deploy, deploy-operator, namespace setup
      Status.ps1           # status command
      Diagnose.ps1         # diagnose (partial in phase 2)
      Help.ps1             # help / welcome text

config/                    # Unchanged — shared with bash CLI
addons/                    # Bash deploy.sh retained; PowerShell ports per phase
aap-demo.sh                # Unchanged — macOS/Linux entry point
```

## Architecture Diagram

```
                    ┌─────────────────┐
                    │  aap-demo.ps1   │  Command router + arg parsing
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
                    │  AapDemo module │
                    └────────┬────────┘
         ┌───────────────────┼───────────────────┐
         │                   │                   │
  ┌──────▼──────┐    ┌───────▼───────┐   ┌──────▼──────┐
  │   Config    │    │  Infra (API)  │   │   Deploy    │
  │  ~/.aap-demo│    └───────┬───────┘   │ kubectl/oc  │
  └─────────────┘            │           │ YAML apply  │
                      ┌──────▼──────┐    └─────────────┘
                      │  Infra.Crc  │
                      │ SSH → CRC VM│
                      └──────┬──────┘
                             │
                      ┌──────▼──────┐
                      │ OpenShift   │
                      │ Local (CRC) │
                      │  Hyper-V VM │
                      └─────────────┘
```

## Design Principles

1. **Subprocess over reimplementation** — Call `crc`, `kubectl`, `oc`, `ssh`, `operator-sdk` as external tools; do not embed Kubernetes client libraries.
2. **Shared assets** — All manifests live in `config/`; both CLIs apply the same files.
3. **Path normalization** — Use `$env:USERPROFILE` and `[System.IO.Path]::Combine`; never hard-code Unix paths in public commands.
4. **Fail clearly** — Check tool presence up front; surface Hyper-V / admin cert trust requirements explicitly.
5. **Phase gates** — Each phase must pass manual smoke test on Windows before expanding scope.

---

## Platform Adaptations (Windows vs Bash)

| Concern | Bash (macOS/Linux) | PowerShell (Windows) |
|---------|-------------------|----------------------|
| Home directory | `$HOME` | `$env:USERPROFILE` |
| SSH null host file | `/dev/null` | `NUL` |
| Ingress CA trust | Keychain / `update-ca-trust` | `Import-Certificate` → `LocalMachine\Root` (admin) |
| CRC daemon | Linux socket + background start | Not needed (Hyper-V) |
| DNS resolver fix | `/etc/resolver/testing` (macOS) | Skipped |
| JSON parsing | `python3 -c` | `ConvertFrom-Json` |
| Template replace | `sed` | `-replace` / `Get-Content -Raw` |
| Process substitution | `<(base64 -d)` | Temp files |
| operator-sdk install | darwin/linux binaries | `windows_amd64` binary |
| Config `sed -i` | in-place edit | Read/modify/write file |

---

## Implementation Plan

### Phase 1 — MVP (this branch, initial commit)

**Target:** `create` → `deploy` → `status` on Windows 11 + Hyper-V.

| Item | Status |
|------|--------|
| Branch `feature/windows-powershell` | Done |
| Module scaffold + `Install.ps1` | Done |
| `help`, `create`, `start`, `stop`, `destroy` | Done |
| `status`, `deploy`, `deploy-operator` | Done |
| CRC cluster bootstrap (nip.io, NFS, CoreDNS, metrics-server) | Done |
| OLM install on create | Done |
| Windows ingress CA trust | Done |
| `docs/windows/QUICK-START.md` | Done |

**Smoke test checklist:**

- [ ] `.\Install.ps1` adds `aap-demo` to PATH
- [ ] `aap-demo create` completes on Hyper-V host
- [ ] `aap-demo deploy` installs AAP 2.7 operator + instance
- [ ] `aap-demo status` shows routes and credentials
- [ ] `aap-demo stop` / `aap-demo start` cycle works
- [ ] `aap-demo destroy` removes cluster

### Phase 2 — Operational parity

| Command / feature | Notes |
|-------------------|-------|
| `diagnose` | Port health checks from `cmd_diagnose` |
| `idle` | Patch AAP CR `spec.idle_aap` |
| `clean` | Remove AAP without destroying cluster |
| `repair` | Post-crash recovery |
| `ssh` | `ssh` exec wrapper |
| `kubeconfig` | Sync kubeconfig to `~/.kube/config` |
| `enable` / `disable` | Addon dispatch (initially invoke bash or port OLM/console/registry) |
| mkcert CA check | Windows cert store validation |
| `ensure_operator_sdk` | Auto-download windows_amd64 |

### Phase 3 — Addons

Port `addons/*/deploy.sh` to `Invoke-AapDemoAddon` or individual `deploy.ps1` scripts:

- olm (done in phase 1)
- console
- registry
- mcp-server
- devspaces
- prometheus

### Phase 4 — Advanced

| Feature | Notes |
|---------|-------|
| `must-gather` | Diagnostic bundle collection |
| `test` | ATF via Ansible (may require WSL or documented limitation) |
| `diagnose --ai` | Claude CLI integration |
| Tab completion | `Register-ArgumentCompleter` |
| CI | GitHub Actions `windows-latest` smoke job |

### Phase 5 — Polish

- Hyper-V Administrators group detection and actionable errors
- Podman Desktop connection setup on Windows
- README integration; deprecate "in development" wording when phase 1 passes QA
- Optional: extract shared orchestration to Python (long-term dedup with bash)

---

## Command Mapping

| Intent | Bash | PowerShell function |
|--------|------|---------------------|
| Help | `aap-demo help` | `Show-AapDemoHelp` |
| Create cluster | `cmd_create` | `Invoke-AapDemoCreate` |
| Deploy AAP | `cmd_deploy` | `Invoke-AapDemoDeploy` |
| Status | `cmd_status` | `Get-AapDemoStatus` |
| Stop / start | `cmd_stop` / `cmd_start` | `Stop-AapDemoCluster` / `Start-AapDemoCluster` |
| Destroy | `cmd_destroy` | `Remove-AapDemoCluster` |
| Diagnose | `cmd_diagnose` | `Invoke-AapDemoDiagnose` (stub → phase 2) |

---

## Prerequisites (Windows)

- Windows 10/11 Pro/Enterprise/Education (Hyper-V capable)
- Hyper-V enabled; user in **Hyper-V Administrators** group (CRC setup may require reboot)
- [OpenShift Local](https://console.redhat.com/openshift/create/local) installed
- `oc` and `kubectl` on PATH
- OpenSSH Client (Windows optional feature, usually preinstalled)
- PowerShell 7+
- Red Hat pull secret at `%USERPROFILE%\.aap-demo\pull-secret.txt`
- Recommended: 16 GB RAM, 100 GB free disk

Optional: `jq` (CoreDNS patch uses PowerShell JSON instead), `operator-sdk` (auto-install planned phase 2).

---

## Coexistence with Bash CLI

| Platform | Entry point |
|----------|-------------|
| macOS / Linux | `./install.sh` → `aap-demo.sh` |
| Windows | `.\powershell\Install.ps1` → `aap-demo.ps1` |

Both write to the same `~/.aap-demo/config` and use the same CRC kubeconfig path.

---

## Testing Strategy

1. **Manual smoke** on physical Windows 11 + Hyper-V (phase 1 gate)
2. **Module Pester tests** (phase 2+) for Config, path helpers, argument parsing — mock external commands
3. **CI** `windows-latest` job: parse/help, module load, optional CRC (nightly only due to resource cost)

---

## Open Questions

- Should `test` require WSL Ansible or ship a documented skip on Windows?
- Podman remote on Windows: validate `podman system connection` parity with bash create flow
- Single `aap-demo` npm/choco package vs raw git clone install

---

## References

- Bash CLI: `aap-demo.sh`, `includes/crc-create.sh`, `includes/infra-crc.sh`
- Environment comparison: `docs/environment-comparison.md`
- OpenShift Local on Windows: [Red Hat Developer](https://developers.redhat.com/products/openshift-local)
