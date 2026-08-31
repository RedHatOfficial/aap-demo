---
name: aap-demo-multi-host-test
description: >
  Runs full aap-demo destroy, deploy, and all first-class addon tests across
  configured Mac, Linux VM, and Windows hosts via SSH or local shell. Use when
  the user asks to test aap-demo on multiple machines, validate addons end-to-end,
  or run a cross-platform regression matrix.
disable-model-invocation: true
---

# aap-demo Multi-Host Test

Orchestrate **destroy → deploy → addon enable → verify** on Mac (bash), Linux VM (bash),
and Windows (native PowerShell) using [`scripts/multi-host-test.sh`](../../../scripts/multi-host-test.sh)
or manual steps below.

Complements the single-host [aap-demo skill](../../../.claude/skills/aap-demo/SKILL.md) for
troubleshooting. Read that skill when `diagnose` fails mid-run.

## Security

- **Development only** — never run against production clusters.
- **Confirm once per session** before any `destroy` on any host.
- **Never commit** `~/.aap-demo/test-hosts.yaml` (contains hostnames; may reference cred paths).
- Pull secrets, galaxy tokens, and Satellite credentials stay on each host under `~/.aap-demo/`.

## Bootstrap

1. Copy the template:

   ```bash
   mkdir -p ~/.aap-demo
   cp .cursor/skills/aap-demo-multi-host-test/machines.example.yaml ~/.aap-demo/test-hosts.yaml
   ```

2. Edit `~/.aap-demo/test-hosts.yaml` with real hosts, repo paths, and prerequisite paths.
3. Ensure each host has `aap-demo` on PATH (Windows: run `powershell/install.ps1` once).
4. Dry-run from repo root:

   ```bash
   ./scripts/multi-host-test.sh --dry-run
   ./scripts/multi-host-test.sh --host mac    # single host first
   ```

## Runtime expectations

| Scope | Typical duration |
|-------|------------------|
| Single host (deploy + 8 addons) | 2–4 hours |
| Full matrix (3 hosts sequential) | 6–10+ hours |

`local-cache` save alone can take 30+ minutes and ~30 GB disk. Run overnight or use
`--skip-addons local-cache` for faster smoke runs.

## Workflow

### Phase 0 — Preflight (non-destructive)

On each target host:

1. Read `~/.aap-demo/test-hosts.yaml` from the **orchestrator** machine (where the agent runs the script).
2. Verify connectivity (`ssh -G` / `ssh host true` or local `aap-demo version`).
3. Check prerequisites **on that host**:
   - `crc`, `oc` or `kubectl`, `helm` (portal, apme-eap), `python3` (apme-eap), `jq` (product-demos)
   - `~/.aap-demo/pull-secret.txt` or `pull-secret.json`
   - `~/.aap-demo/galaxy-token` for `setup-pah`
   - Satellite URL reachable for `product-demo-satellite` (see config `prerequisites.satellite`)
   - Free disk ≥ 50 GB (100 GB recommended if running `local-cache` save)
4. Optional: `git pull` in `repo_path` when `defaults.sync_repo: true`, or checkout a PR with `--pr NUMBER`.

## Testing a pull request

Checkout happens on **each host** during preflight (before `aap-demo version`):

```bash
./scripts/multi-host-test.sh --pr 123 --host mac
./scripts/multi-host-test.sh --pr 123                    # all hosts in config
./scripts/multi-host-test.sh --dry-run --pr 123          # show plan only
```

| Mechanism | When |
|-----------|------|
| `gh pr checkout 123` | Preferred when `gh` is on PATH on that host |
| `git fetch origin pull/123/head:pr-123-multi-host-test && git checkout …` | Fallback |

CLI `--pr` overrides `defaults.pr` in `test-hosts.yaml`. When a PR is set, `sync_repo: true` is
ignored (checkout replaces `git pull`).

Requires the repo at `repo_path` to be a git clone of the GitHub repo the PR targets, with
`origin` (or `defaults.git_remote`) configured on each host.

## Local image cache (default on)

To avoid re-pulling ~30GB of container images on every destroy → deploy cycle:

1. **Preflight** — log whether `~/.aap-demo/local-cache/<preset>/*.tar` exists on the host
2. **Before destroy** — if CRC is running, `aap-demo enable local-cache save`
3. **Destroy** — delete CRC VM (cache files on disk are preserved)
4. **Create** — `aap-demo create` (standalone, so the cluster is up before load)
5. **Load** — `aap-demo enable local-cache load` (before deploy pulls catalog/AAP images)
6. **Deploy** — `AAP_DEMO_LOAD_CACHE=1` also loads during deploy if needed (belt-and-suspenders)
7. **Addon test** — `local-cache` enable at end refreshes cache for the next run

First matrix run has nothing to load; the final `local-cache` addon step seeds cache for the next run.

Disable with `--skip-local-cache` or `defaults.use_local_cache: false` in config.

### Phase 1 — Destroy + deploy

The orchestrator sets **`AAP_DEMO_TRUST_CA=false`** by default (see `defaults.trust_ca` in config)
so deploy never blocks on macOS `sudo security add-trusted-cert` or Windows elevated cert import.
The ingress CA is still saved to `~/.aap-demo/crc-ingress-ca.crt`; CLI tools use `CURL_CA_BUNDLE`
(combined system + ingress bundle). Browsers may show TLS warnings until you import manually.

When **`use_local_cache`** is enabled (default), the orchestrator runs:

`save` → `destroy` → `create` → `enable local-cache load` → `deploy` (with `AAP_DEMO_LOAD_CACHE=1`)

**Bash (Mac, Linux):**

```bash
export QUIET=true
export AAP_DEMO_TRUST_CA=false   # unattended; set true or trust_ca: true for browser trust
aap-demo destroy              # add --reset if defaults.destroy_reset: true
aap-demo deploy
aap-demo diagnose
```

**Windows (native PowerShell):**

```powershell
$env:QUIET = 'true'
$env:AAP_DEMO_TRUST_CA = 'false'
aap-demo destroy
aap-demo deploy
aap-demo diagnose
```

**Gate:** No `✗` lines in diagnose output before addon phase. Apply fixes from AGENTS.md / aap-demo skill.

**Manual browser trust after a successful matrix run (macOS):**

```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain \
  ~/.aap-demo/crc-ingress-ca.crt
```

### Phase 2 — Addons (dependency order)

Enable in this order; after each addon run checks from [addon-checks.md](addon-checks.md), then `aap-demo diagnose`:

1. `setup-pah`
2. `mcp-server`
3. `portal`
4. `ao`
5. `apme-eap`
6. `product-demos`
7. `product-demo-satellite`
8. `local-cache` (last — triggers image save)

```bash
aap-demo enable <addon>
```

On Windows the same subcommands work via the PowerShell wrapper.

### Phase 3 — Report

Summarize per host: destroy, deploy, diagnose, each addon pass/fail, duration.

Script writes JSON to `~/.aap-demo/test-reports/<timestamp>.json`.

## Connection recipes

| Host type | How to run |
|-----------|------------|
| `type: local` | Execute commands in local shell at `repo_path` (see auto-discovery below) |
| `type: ssh` + `shell: bash` | `ssh -i KEY USER@HOST "bash -lc 'cd REPO && CMD'"` |
| `type: ssh` + `shell: powershell` | `ssh USER@HOST powershell -NoProfile -Command "Set-Location 'REPO'; CMD"` |

**Repo path (`repo_path`):** optional per host and under `defaults`. When omitted, the orchestrator
finds the git checkout by resolving the `aap-demo` launcher symlink:

```bash
ls -l ~/.local/bin/aap-demo
# ~/.local/bin/aap-demo -> .../aap-demo/aap-demo.sh
# repo_path = directory containing aap-demo.sh
```

Local hosts: resolve on the orchestrator machine (`command -v aap-demo`, then `~/.local/bin/aap-demo`).
Remote bash hosts: same logic over SSH on the remote. Remote Windows: `%USERPROFILE%\.aap-demo\repo-path`
(written by `install.ps1`) or `%USERPROFILE%\.local\bin\aap-demo.cmd`.

Override with explicit `repo_path` when the symlink is not how you run aap-demo on that host.

**SSH `repo_path`:** when set explicitly, use a path valid on the **remote** host (`~/aap-demo` or `/home/user/aap-demo`).
Do not rely on the orchestrator Mac path. Tilde is expanded on the remote shell, not locally.
Prerequisites (`galaxy-token`, pull secret) must exist on each remote host under that host's `~/.aap-demo/`.

Windows requires **OpenSSH Server** and `aap-demo` installed via [`powershell/install.ps1`](../../../powershell/install.ps1).

## Command translation

| Bash | PowerShell |
|------|------------|
| `export QUIET=true` | `$env:QUIET = 'true'` |
| `export AAP_DEMO_TRUST_CA=false` | `$env:AAP_DEMO_TRUST_CA = 'false'` |
| `export FORCE=true` | `$env:FORCE = 'true'` |
| `~/.aap-demo/config` | `$env:USERPROFILE\.aap-demo\config` |
| `aap-demo destroy --reset` | same (PS wrapper passes through) |

Set `defaults.trust_ca: true` in `test-hosts.yaml` (or export `AAP_DEMO_TRUST_CA=true`) when running
interactively and you want automatic keychain/cert-store import during deploy.

Portal status: bash CLI has no `status portal` subcommand — use `kubectl get pods,routes -n redhat-rhaap-portal`.
Windows PowerShell wrapper may expose richer portal helpers; prefer kubectl checks for parity.

## Script flags

```bash
./scripts/multi-host-test.sh --dry-run              # print plan only
./scripts/multi-host-test.sh --host mac             # one host
./scripts/multi-host-test.sh --pr 123               # checkout PR #123 on each host
./scripts/multi-host-test.sh --pr 123 --host mac    # PR test on Mac only
./scripts/multi-host-test.sh --skip-local-cache     # skip save-before-destroy / load-on-deploy
./scripts/multi-host-test.sh --skip-addons          # deploy only
./scripts/multi-host-test.sh --only-addons          # skip destroy/deploy
./scripts/multi-host-test.sh --strict               # fail on missing prereqs
./scripts/multi-host-test.sh --config ~/.aap-demo/test-hosts.yaml
```

Requires `yq` (v4) on the orchestrator machine for config parsing.

## Manual fallback

Use manual SSH steps when:

- Windows blocks remote PowerShell (`ExecutionPolicy`, GPO)
- SSH keys need interactive agent unlock
- Script fails on a single addon — fix, then `--host NAME --only-addons`

## Additional resources

- Per-addon verification: [addon-checks.md](addon-checks.md)
- Config template: [machines.example.yaml](machines.example.yaml)
- Addon architecture: [docs/adr/008-addon-system.md](../../../docs/adr/008-addon-system.md)
