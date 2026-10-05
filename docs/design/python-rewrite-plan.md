# aap-demo Python Rewrite — Design and Implementation Spec

**Status**: Draft — revision 7 (upstream delta since the rewrite branch point). Implementation is in progress on local branch `v1-python-rewrite`; where each phase stands is §12.6.
**Date**: 2026-09-30 (rev 7; rev 6 2026-09-02; rev 5 2026-09-02; rev 4 2026-09-02; rev 3 2026-09-02; rev 2 2026-09-02; rev 1 2026-09-01)
**Scope**: Full rewrite of the bash `aap-demo.sh` CLI (+ `includes/*.sh`, `powershell/native/*`, `addons/*/deploy.sh`) as a pip-installable Python package, plus a PatternFly web GUI over the same core, a separate day-2 playbooks repo, a signed native desktop application for non-technical users, and a Podman Desktop extension for the technical-operator tier.
**Audience**: The maintainers (for the remaining open questions in §13) and the implementation agent that will build from this document.

The original pass was design only. Implementation has since started on local branch `v1-python-rewrite`; §12.6 is where that work stands.

**Revision 2 changelog.** Distribution decided (public PyPI); Typer confirmed; subprocess-only confirmed; Python floor set to 3.9; config format decided as TOML on platformdirs-native paths (superseded by revision 5: YAML); the addon split reworked into three tiers with a new day-2 playbooks repo run through `ansible-navigator`; `--output json|yaml` promoted to a day-one global option; and a new §9 designing a PatternFly 6 web GUI. Sections 5–10 were renumbered (old §5–§8 → §6–§8/§12) to make room for the new §5 (configuration) and §9 (GUI).

**Revision 3 changelog.** The maintainer disclosed that the primary audience is **not engineers** — managers, IT directors, and sales staff, some of whom must install and run the tool with **zero terminal usage**. That does not change the architecture; it changes distribution. New **§10** designs a second distribution channel alongside PyPI: a signed, double-click native installer per OS (Briefcase, recommended), an embedded-webview desktop shell, a native menu-bar/system-tray icon, a manifest-driven update flow, and the code-signing/notarization dependency on Red Hat release engineering that gates all of it. §10 also resolves R16 (GUI job durability) using the long-lived tray process, and rules day-2 operations out of the desktop channel on §4.5's own tier rule. Old §10–§12 were renumbered to §11–§13 (they are §12–§14 after revision 4's renumber); six risks (R20–R25) and six open questions (Q19–Q24) were added. §1's non-goals were amended (the "no daemon" rule is a CLI rule, and stays one).

**Revision 4 changelog.** A **third distribution channel** was added: a Podman Desktop extension, designed in the new **§11**. It is a parallel channel for the *technical-operator* tier — SEs and solution architects who already run Podman Desktop — and it explicitly **does not replace** §10's standalone signed installer, because Podman Desktop is itself unmistakably a developer tool and the zero-terminal audience cannot be asked to navigate an extension catalog. §10.1's channel table now lists three channels. §11 answers the webview-technology question against the real Podman Desktop source (a prebuilt React SPA is fine; Svelte is a template convention, not a requirement), designs the extension as a thin webview client over the *same* FastAPI backend rather than a TypeScript reimplementation, specifies how the Python backend is provisioned and started from a Node-based extension, recommends declaring an `extensionDependencies` edge on `redhat.openshift-local` and delegating VM lifecycle to it, and records what "official Red Hat adoption" concretely requires. Old §11–§13 were renumbered to §12–§14; four risks (R26–R29) and five open questions (Q25–Q29) were added; a phase **7d** was added to §12.4.

**Revision 5 changelog.** A backlog of maintainer decisions applied in place. **No sections were renumbered** — this pass is corrections, four superseded decisions, one new subsection (§5.5), one new risk, and eleven questions moved to Decided. Substantively:

1. **The day-2 repo is `aap-demo-playbooks`**, not `aap-demo-ops` (Q13, decided). Every `ops`-prefixed identifier renamed: `aap-demo playbooks run`/`list`/`info`/`create`/`update`, `playbooks.repo_url`, `/api/playbooks`, `<cache>/playbooks-repo/`. The playbooks system also gets its own GUI view (§9.2) and its own config block (§5.3), not just a CLI.
2. **Full OpenShift support is back in scope** — the maintainer's decision supersedes ADR-020, which this document previously leaned on for a raft of MicroShift-only assertions. `aap-demo create` supports both CRC presets. §4.5's tier-1 rationale for `olm` is unchanged and still correct (ADR-005's idempotent-skip on full OpenShift already covers it); the MicroShift-*only* claims around it are corrected.
3. **Config format is YAML, not TOML** (Q9, re-decided). Verified this session by direct inspection of `ansible-navigator`'s and `ansible-creator`'s `pyproject.toml` dependency lists: both hard-depend on `pyyaml`, neither uses TOML anywhere. The C-extension objection that drove the TOML choice is answered by **PyYAML's pure-Python mode** rather than by a different format. `pyyaml` becomes a base dependency; `tomli`/`tomlkit` and the `[yaml]` extra disappear.
4. **CLI framework is stdlib `argparse` and the schema mechanism is `jsonschema`**, not Typer and Pydantic (Q2, re-decided). Same verification: `ansible-navigator` depends on `jsonschema`, `ansible-creator` hand-rolls a thin `argparse` wrapper, and neither uses Click, Typer, or Pydantic. §9.3's parity mechanism is redesigned around JSON Schema as the single source of truth. This also removes the `pydantic-core` compiled-extension risk without needing to argue it.
5. **Credentials move to OS-native secure storage** (new §5.5, via `keyring`), and §9.5's status page is redesigned so no secret ever transits the API payload. New risk **R30**; new open question **Q30** on the headless-Linux fallback.
6. **Eleven questions closed**: Q5 (no compatibility shim — clean cutover), Q6 (interactive install prompt), Q10, Q11, Q13, Q15, Q16, Q17, Q19, Q20, Q24. (Q9 and Q2 are not in this count — they were already Decided and are *re-*decided above.) **Q18 (`devspaces`) is explicitly deferred**, not decided. §12.4's phase table is adjusted for the shim-less cutover and for macOS-first installer sequencing.

**Revision 6 changelog.** Full OpenShift preset support is **resequenced, not rescoped**: it remains fully in scope (revision 5 stands, ADR-020 stays superseded), but it no longer needs to land alongside MicroShift from day one. **MicroShift ships first as the v1 target**; full OpenShift preset support becomes its own fast-follow phase, new **phase 4b** in §12.4, explicitly not a v1 blocker. This directly changes how urgently **R26** (the CRC-extension/`aap-demo create` identity conflict over `apps.crc.testing` vs. `nip.io`) needs resolving — it is deferred to phase 4b rather than being a pre-v1 gate, on the maintainer's own framing: "let's not worry about it until we get to full openshift mode." Two candidate resolutions are recorded as the phase 4b starting point, neither pursued now: (a) investigate whether the OpenShift preset can be reconfigured to use `nip.io` the same way MicroShift is, which would make R26 disappear entirely rather than need mitigating; (b) a longer-term possibility — the maintainer may acquire a dedicated domain (e.g. `aap-demo.io`) to host a self-owned wildcard DNS zone, replacing `nip.io` for both presets. Phase 7's GUI exit criterion and phase 4's create-path scope are both narrowed to MicroShift-only for v1, with phase 4b adding OpenShift.

**Revision 7 changelog** (2026-09-30). The local rewrite branched from `RedHatOfficial/aap-demo` `main` at `7374188` (2026-09-01, PR #115). That remote `main` has since moved 47 commits, through `dbc4e6c` (PR #199). This pass does **not** merge those commits into the rewrite branch. It records which of them change the roadmap, which already-ported modules are now stale, and which planned rewrite ADR numbers upstream has since used. The phase status table is §12.6. Command-surface changes are §3.3.1. New addons are in §4.7. ADR renumbering is at the top of §12.5.

---

## 1. Executive summary

`aap-demo` today is a 2,972-line bash dispatcher (`aap-demo.sh`) plus nine sourced helper modules under `includes/`, a parallel hand-maintained PowerShell implementation under `powershell/native/`, and 18 standalone `addons/<name>/deploy.sh` scripts totalling ~8,500 lines. It orchestrates `crc`, `kubectl`/`oc`, `helm`, `operator-sdk`, `ssh`/`scp`, `ansible-playbook`, and `curl` as external processes to stand up AAP 2.7 on an OpenShift Local VM (the MicroShift preset today; the full OpenShift preset is back in scope per revision 5, and sequenced into its own fast-follow phase 4b per revision 6 — MicroShift is the v1 target, §12.4).

Three structural problems drive this rewrite:

1. **Dual-implementation drift.** ADR-010 accepted "two parallel CLI implementations sharing behavior but not code" and explicitly lists the cost under *Negative*: dual maintenance, parity gaps (`portal`, `test`, `diagnose --ai` on Windows all fall back to Git Bash), and "subtle semantic differences risk drift (e.g., SCC grant timing)". Windows is now a business priority, which makes that tradeoff untenable.
2. **Addon sprawl with no contract.** ADR-008 defines the addon interface as a *convention*: a `deploy.sh` that accepts `--delete`, an optional `# ADDON_REQUIRES_AAP=true` header comment grepped by `includes/crc-create.sh:522`, and a hardcoded `AVAILABLE_ADDONS` string at `aap-demo.sh:2617`. ADR-008 itself flags the consequences: "No formal addon metadata schema", "`AVAILABLE_ADDONS` list can drift from `addons/` directory contents", "Status reporting is per-addon switch/case, not auto-discovered". The result is measurable duplication — `addons/ao/deploy.sh` and `addons/ao-eap/deploy.sh` are byte-identical (both md5 `9cc3abd1…`, 1,089 lines) and the six `product-demo-*` scripts are near-verbatim copies of each other, carrying copy-paste bugs into production (e.g. `addons/product-demo-cloud/deploy.sh:19` says "Deploy Linux demos" and its delete handler at line 41 prints "Removing Linux demo resources"). New addon requests (OPA, ALIA, x2ansible, Grafana, EDA Playground) all land as PRs against the core repo.
3. **Untestable core.** ADR-014 accepts grep-based, non-destructive CLI tests (`test/*.sh`, 459 lines total) precisely because "mock maintenance cost [is] high for monolithic bash script". The tests assert on human-readable output strings, so any wording change breaks them, and they cover none of the actual deploy logic.

The rewrite delivers **one core, several thin frontends, and three distribution channels**:

- A single Python 3.9+ package on **public PyPI** — `pip install aap-demo` → `aap-demo` on PATH via `project.scripts`; one codebase for macOS/Linux/Windows with platform dispatch isolated to a `platform/` subpackage.
- A **web GUI** (`pip install "aap-demo[gui]"`, §9): a prebuilt PatternFly 6 React SPA served by a small FastAPI app that calls the *same* `core/` package the CLI calls. Visual presentation is a product requirement for this tool's audience, not a nicety — the CLI alone is insufficient. CLI/GUI configuration parity is enforced structurally by a single JSON Schema both surfaces generate from (§9.3), specifically to avoid recreating the dual-maintenance drift ADR-010 documents for bash/PowerShell.
- A **three-tier extension model** replacing today's flat `addons/` directory (§4.5):
  1. **Built-in** — `olm` and `setup-pah`, mandatory plumbing on the core deploy path, shipped in the base wheel and not removable.
  2. **First-party product addons** — `portal`, `mcp-server`, `ao` (absorbing `ao-eap`), `apme-eap`, `product-demos` + its six domain addons. Team-maintained official Red Hat content, shipped as separate installable distributions discovered via `importlib.metadata` entry points, plus the same entry-point API open to genuinely third-party addons.
  3. **Day-2 playbooks repo** (§4.8) — a separate `aap-demo-playbooks` git repo of Ansible playbooks with a self-describing manifest each, run through `aap-demo playbooks run <name>` which shells out to `ansible-navigator` against a dedicated Execution Environment (implementing open issue #92). `registry` and `local-cache` move here out of the addon system entirely. Like addons, playbooks are a first-class surface in the GUI (§9.2) and in config (§5.3), and the manifest format is the extension point for anyone writing their own.

  The sorting rule for tiers 2 vs. 3: **is this something the demo audience needs to see in the running environment (audience-facing content → Python addon, selectable in the GUI wizard), or something an operator does behind the scenes to maintain the environment (operator-facing maintenance → the `aap-demo-playbooks` repo, never in the wizard)?**
- A **native desktop application and a second distribution channel** (§10): the same package, frozen with Briefcase into a signed `.dmg`/`.pkg` and `.msi`, with an embedded-webview dashboard and a macOS menu-bar / Windows system-tray icon. This exists because the primary audience is managers, IT directors, and sales staff, some of whom must never touch a terminal. `pip install aap-demo` remains the channel for developers, CI, and technical operators; the installer is a packaging wrapper around the same wheel, not a fork.
- A **Podman Desktop extension** (§11): a third distribution channel for the *technical-operator* tier — SEs and solution architects who already have Podman Desktop installed and who already use its Red Hat OpenShift Local extension to manage the CRC VM. The extension is a thin webview client over the same FastAPI backend the standalone GUI serves; it contains no orchestration logic and no TypeScript reimplementation of anything in `core/`. **It does not replace the standalone installer.** Podman Desktop's own UI is a developer tool, and asking a sales director to install Podman Desktop, find the Extensions catalog, install two extensions, and locate an aap-demo panel is strictly harder than double-clicking a `.dmg`. The three channels serve three different user tiers and all three are needed (§10.1).
- Structured configuration: **YAML** on **platformdirs-native** per-OS paths, replacing the flat `~/.aap-demo/` `KEY=VALUE` file, with automatic migration on first run (§5).
- Secrets in **OS-native credential storage** (`keyring`) rather than in files or environment variables — the admin password, portal OAuth state, Galaxy/PAH tokens, and the `apme-eap` GitHub credentials (§5.5), with a status page redesigned so no plaintext secret transits the HTTP API at all (§9.5).
- `--output json|yaml` as a global option from day one, so the GUI's API and any future automation read the same data the human output renders (§5.4).
- A pytest suite with a `FakeRunner` seam that makes every `crc`/`oc`/`kubectl`/`ansible-navigator` invocation assertable, plus a `@pytest.mark.integration` tier for real cluster runs; and Commitizen-driven semver with real git tags.

**Non-goals.** This rewrite does not change what gets applied to the cluster. The YAML under `config/crs/`, `config/olm/`, `config/manifests/` ships unchanged as package data. It does not replace `crc`/`oc`/`kubectl` with client libraries — subprocess-only is now decided, not open (§13 Q4). It does not take an Ansible Python dependency: day-2 playbooks are executed by shelling out to `ansible-navigator`, the same "delegate, don't reimplement" pattern ADR-001 applies to `oc`. It does not add a daemon: **each CLI invocation stays a short-lived process, per ADR-001**, and the GUI server is an explicitly user-started foreground process (`aap-demo gui`), not a background service. The desktop app (§10) is long-lived but is not a daemon either — it is a user-launched, user-quittable, user-visible foreground application in the same category as a text editor. It is never installed as a service, never runs elevated, never auto-starts without an explicit opt-in (§10.7), and never starts a cluster or a job on its own.

---

## 2. Package layout

### 2.1 Proposed tree

```text
pyproject.toml                     # build backend, deps, entry points, [tool.commitizen] (kept)
VERSION                            # kept — see §8.2
src/aap_demo/
  __init__.py                      # __version__ (single source, read by CLI + packaging)
  __main__.py                      # python -m aap_demo
  cli/
    __init__.py
    main.py                        # root command group, global options, dispatch
    _schema_args.py                # add_schema_arguments(): walks a JSON Schema document and
                                   #   emits argparse arguments — the parity mechanism (§9.3)
    lifecycle.py                   # create, deploy, start, stop, destroy, clean, redeploy, redeploy-all, repair, setup
    observe.py                     # status, watch, diagnose, must-gather
    ops.py                         # idle, ssh, kubeconfig, config, update, version, redhat-status
    addons.py                      # enable, disable, addon list/create/info
    day2.py                        # `playbooks list/info/run/create/update` — day-2 playbooks (§4.8).
                                   #   Named day2.py because cli/ops.py already holds idle/ssh/config.
    gui.py                         # `aap-demo gui` — starts the FastAPI server (§9)
    testing.py                     # test (ATF)
    completion.py                  # completion bash|zsh|powershell|fish
  core/
    context.py                     # AppContext: namespace, quiet, force, kubeconfig, context, paths, runner, console
    config.py                      # YAML load/save, layered resolution, legacy KEY=VALUE migration (§5)
    schema.py                      # JSON Schema documents — the single source of truth for CLI
                                   #   arguments, GUI forms, and config file keys (§9.3)
    paths.py                       # platformdirs-backed config/cache/state dirs, kubeconfig resolution,
                                   #   pull-secret discovery, legacy ~/.aap-demo relocation (§5.2)
    secrets.py                     # SecretStore over the OS keyring — the ONLY module that
                                   #   reads or writes a credential (§5.5)
    events.py                      # Event + EventSink — the one progress-reporting abstraction the
                                   #   CLI console, the GUI's SSE stream, the tray, and the
                                   #   extension all consume (§9.4)
    output.py                      # --output text|json|yaml renderers over structured result models
    clipboard.py                   # per-OS clipboard write (pbcopy / Set-Clipboard / wl-copy,
                                   #   value on stdin, never argv) — §9.5.1's copy affordance
    version.py                     # package version + git build metadata (when running from a checkout)
    errors.py                      # AapDemoError hierarchy → exit codes
    console.py                     # all user-facing output; ✓/✗/⚠/· glyphs, color, QUIET handling
    prompts.py                     # confirm_destructive(), timed_prompt() — the read -t 10 semantics
  exec/
    runner.py                      # CommandRunner protocol + SubprocessRunner; the single subprocess seam
    kubectl.py                     # KubectlClient: get/apply/patch/delete/wait/jsonpath/logs/exec
    oc.py                          # OcClient: adm policy add-scc-to-group, adm must-gather
    crc.py                         # CrcClient: status(json), config set/get, setup, start, stop, delete
    helm.py                        # HelmClient (portal addon)
    operator_sdk.py                # run bundle, cleanup, auto-install
    ssh.py                         # SSH/SCP to the CRC VM (replaces infra-crc.sh)
    ansible.py                     # ansible-galaxy / ansible-playbook (ATF)
  infra/
    base.py                        # InfraBackend ABC: exec_cmd, copy_to, copy_from, service_action,
                                   #   get_state, get_kubeconfig, get_name
    crc.py                         # CrcBackend implementation
    registry.py                    # backend selection by INFRA_TYPE (crc today; minc/lab reserved)
  cluster/
    bootstrap.py                   # the ordered, named Step list ported from crc-create.sh (§14 R1)
    deploy.py                      # deploy.run(ctx, plan) — the one entry point cli/ and gui/ share
    kubeconfig.py                  # extract, rename contexts, merge, chmod 600
    namespace.py                   # create, PSA labels, terminating-namespace force-clear
    scc.py                         # anyuid + privileged group grants (oc path + kubectl CRB fallback)
    storage.py                     # NFS server + provisioner, topolvm, aap-storage-pvcs
    coredns.py                     # Corefile patch/verify/re-patch
    olm.py                         # CatalogSource/OperatorGroup/Subscription, CSV wait
    catalog_signature.py           # signature policy relaxation + catalog pull recovery
    aap.py                         # AAP CR render+apply, gateway capability patch, idle, watch
    pull_secret.py                 # discovery + secret creation + SA patching
  trust/
    __init__.py                    # install_ingress_ca_trust(), status(), purge()
    fetch.py                       # pull ca.crt from the VM, persist to ~/.aap-demo/crc-ingress-ca.crt
    bundle.py                      # combined system+ingress bundle, CURL_CA_BUNDLE/SSL_CERT_FILE policy
    stores/
      base.py                      # TrustStore ABC
      macos.py                     # security add-trusted-cert / find-certificate / delete-certificate
      linux.py                     # ca-trust anchors + update-ca-trust
      windows.py                   # certutil -user -addstore Root, LocalMachine w/ elevation
      nss.py                       # certutil NSS DBs (Linux + anywhere certutil exists)
  platform/
    __init__.py                    # current() -> Platform enum; capability probes
    posix.py                       # macOS/Linux specifics (host CPU/mem, resolver file, sudo)
    windows.py                     # Hyper-V, %USERPROFILE%, elevation check, no-sudo paths
  addons/
    api.py                         # Addon ABC/Protocol + AddonManifest + lifecycle result types
    manifest.py                    # manifest schema + validation
    registry.py                    # entry-point discovery, name normalization, dependency ordering
    state.py                       # enabled-addon persistence in the YAML config (§5.3)
    scaffold.py                    # `aap-demo addon create` templates
    builtin/                       # built-in, non-removable (§4.5 tier 1)
      olm.py                       # thin alias over cluster/olm.py for repair workflows
      setup_pah.py
  day2/                            # `aap-demo-playbooks` repo integration (§4.8).
                                   #   Named day2/ rather than playbooks/ because the CLI module
                                   #   cli/day2.py already carries that reason; the user-facing
                                   #   noun everywhere is "playbooks".
    repo.py                        # clone/update/pin the playbooks repo into the cache dir
    manifest.py                    # manifest.yaml schema (JSON Schema) + validation
    catalog.py                     # discovery of playbooks across the repo (+ local overlay dirs)
    navigator.py                   # ansible-navigator invocation, EE image resolution, arg mapping
    scaffold.py                    # `aap-demo playbooks create` templates
  gui/                             # only imported when the [gui] extra is installed (§9)
    __init__.py                    # lazy import guard with a clear "pip install aap-demo[gui]" error
    app.py                         # FastAPI app factory, static mount, SPA fallback
    api/
      lifecycle.py, addons.py, day2.py, status.py, schema.py, secrets.py, stream.py
    jobs.py                        # Job registry: id → running task, ring-buffered output, SSE fanout
    static/                        # BUILT ARTIFACT — the PatternFly SPA bundle (§9.6)
  desktop/                         # only imported when the [desktop] extra is installed (§10.6.1)
    __init__.py                    # lazy import guard with a clear "pip install aap-demo[desktop]" error
    app.py                         # toga.App: status icon + webview window + server thread + quit interlock
    server.py                      # uvicorn on a daemon thread; port selection; <state>/desktop/runtime.json
    tray.py                        # icon states, menu construction, menu actions (§10.6.2, §10.6.3)
    poller.py                      # cluster-status poll -> DesktopState
    updater.py                     # release-manifest update check (§10.5)
    autostart.py                   # per-OS login-item registration (§10.7)
    single_instance.py             # instance lock + focus-existing (§14 R21)
    resources/                     # macOS template PNGs (@1x/@2x) + Windows .ico
  diagnostics/
    checks.py                      # each diagnose check as a Check object (id, severity, fix hint)
    report.py                      # rendering + issue/warning counters
    ai.py                          # `claude -p` invocation for diagnose --ai
    must_gather.py
  data/                            # package data
    schema/*.yaml                  # the JSON Schema documents core/schema.py merges (§9.3)
    crs/*.yaml                     # the rest — verbatim copies of today's YAML
    olm/*.yaml
    manifests/*.yaml
    patches/*.yaml
frontend/                          # NOT shipped in the sdist/wheel source; build input only (§9.6)
  package.json, vite.config.ts, tsconfig.json
  src/                             # PatternFly 6 React SPA (§9.2)
                                   # NOTE: the Podman Desktop extension (§11) lives in its own
                                   #   repository, not in this tree — it must be able to move
                                   #   under a Red Hat GitHub org (§11.8, §13 Q28), and it is
                                   #   released as an OCI image rather than as part of the wheel.
tests/
  unit/ …                          # see §7
  integration/ …
  fixtures/                        # recorded crc/oc/kubectl/ansible-navigator outputs
  conftest.py
```

### 2.2 Mapping table — bash → Python

| Current file / section | Lines | New home |
|---|---|---|
| `aap-demo.sh` arg parse loop | 94–186 | `cli/main.py` (`argparse` subparsers + the §9.3 schema walker) + `core/context.py` |
| `aap-demo.sh` `check_kubectl` | 200–263 | `exec/kubectl.py::ensure_available()` + `platform/` install hints |
| `aap-demo.sh` `setup_kubeconfig` | 264–309 | `cluster/kubeconfig.py::ensure_kubeconfig()` |
| `aap-demo.sh` `verify_cluster_type` | 310–327 | `infra/base.py` + `cli/main.py` preflight |
| `aap-demo.sh` `check_mkcert_ca` | 328–386 | `trust/__init__.py` (mkcert path; see §14 R7) |
| `aap-demo.sh` `show_welcome` / `show_help` | 387–504 | framework-generated help + `cli/main.py` no-args banner |
| `aap-demo.sh` `determine_pull_secret` | 506–517 | `cluster/pull_secret.py::discover()` |
| `aap-demo.sh` `cmd_repair` | 519–548 | `cli/lifecycle.py::repair` |
| `aap-demo.sh` `_show_cluster_info` | 550–568 | `core/console.py::cluster_summary()` |
| `aap-demo.sh` `_prune_unused_images`, `_check_disk_space` | 569–620 | `infra/crc.py::prune_images()`, `::disk_usage()` |
| `aap-demo.sh` `_verify_crc_version` | 621–674 | `exec/crc.py::verify_version()` |
| `aap-demo.sh` `_verify_cluster` | 675–718 | `cluster/__init__.py::ensure_reachable()` (incl. auto-create prompt) |
| `aap-demo.sh` `cmd_clean` / `_clean_operator` | 719–784 | `cli/lifecycle.py::clean` + `cluster/aap.py::teardown()` |
| `aap-demo.sh` `cmd_config` | 785–791 | `cli/ops.py::config` — **currently a stub that only mkdirs**; see §14 R2 |
| `aap-demo.sh` `cmd_version` | 793–795 | `cli/ops.py::version` + `core/version.py` |
| `aap-demo.sh` `cmd_update` | 797–832 | `cli/ops.py::update` — semantics change, see §12.3 |
| `aap-demo.sh` `cmd_redhat_status` | 834–883 | `cli/ops.py::redhat_status` (RSS parse → `xml.etree` + `httpx`/`urllib`) |
| `aap-demo.sh` `cmd_idle` | 885–946 | `cluster/aap.py::set_idle()` + `cli/ops.py::idle` |
| `aap-demo.sh` `cmd_must_gather` | 948–1010 | `diagnostics/must_gather.py` |
| `aap-demo.sh` `cmd_diagnose` (+`_check_*`) | 1012–1338 | `diagnostics/checks.py` + `report.py` + `ai.py` |
| `aap-demo.sh` `cmd_test` / `_run_atf` | removed in #184 | Do not port. |
| `aap-demo.sh` `cmd_ssh` | 1596–1604 | `cli/ops.py::ssh` → `exec/ssh.py::interactive_shell()` |
| `aap-demo.sh` `cmd_kubeconfig` | 1606–1683 | `cluster/kubeconfig.py::sync()` |
| `aap-demo.sh` `cmd_status` | 1685–1884 | `cli/observe.py::status` + per-addon `status()` hooks (§4) |
| `aap-demo.sh` `cmd_redeploy` / `cmd_redeploy-all` | 1886–1912 | `cli/lifecycle.py::redeploy`, `::redeploy_all` (note: bash function name `cmd_redeploy-all` contains a hyphen — invalid as a Python identifier, rename only internally) |
| `aap-demo.sh` `cmd_destroy` | 1914–1942 | `cli/lifecycle.py::destroy` |
| `aap-demo.sh` `cmd_stop` / `cmd_start` / `_start_crc_cluster` | 1944–1977 | `cli/lifecycle.py::stop`, `::start` |
| `aap-demo.sh` `cmd_create` | 1979–1996 | `cli/lifecycle.py::create` → `cluster/bootstrap.py` (see `crc-create.sh` rows) |
| `aap-demo.sh` `cmd_setup` | 1998–2000 | `cli/lifecycle.py::setup` (still a message; kept for compatibility) |
| `aap-demo.sh` `cmd_deploy` | 2002–2070 | `cli/lifecycle.py::deploy` |
| `aap-demo.sh` `patch_operator_serviceaccounts` | 2072–2083 | `cluster/pull_secret.py::patch_service_accounts()` |
| `aap-demo.sh` `deploy_latest` | 2085–2214 | `cluster/olm.py::install_operator()` orchestration |
| `aap-demo.sh` `verify_coredns` | 2216–2244 | `cluster/coredns.py::verify()` |
| `aap-demo.sh` `_grant_sccs` | 2246–2279 | `cluster/scc.py::grant_namespace_sccs()` |
| `aap-demo.sh` `setup_namespace` | 2281–2352 | `cluster/namespace.py::ensure()` |
| `aap-demo.sh` `deploy_operator_sdk` | 2354–2372 | `exec/operator_sdk.py::run_bundle()` |
| `aap-demo.sh` `_load_local_cache` | 2374–2383 | **removed from the deploy path.** Local image caching becomes a day-2 operation (§4.8.5); the deploy path no longer branches on it. |
| `aap-demo.sh` `_ensure_aap_storage_pvcs` | 2385–2405 | `cluster/storage.py::ensure_aap_pvcs()` |
| `aap-demo.sh` `create_aap_instance` | 2407–2459 | `cluster/aap.py::create_instance()` |
| `aap-demo.sh` `_patch_gateway_capability` | 2461–2496 | `cluster/aap.py::patch_gateway_capability()` |
| `aap-demo.sh` `watch_aap` | 2498–2609 | `cluster/aap.py::watch()` + `cli/observe.py::watch` |
| `aap-demo.sh` addon block (`AVAILABLE_ADDONS`, `_normalize_addon_name`, `_addons_*`, `cmd_enable`, `cmd_disable`) | 2611–2790 | `addons/registry.py` + `addons/state.py` + `cli/addons.py` |
| `aap-demo.sh` `_check_for_updates` | 2792–2853 | `cli/ops.py::_update_notice()` — semantics change, see §12.3 |
| `aap-demo.sh` final dispatch `case` | 2855–2972 | `cli/main.py` |
| `includes/aap-demo-paths.sh` | 29 | `core/paths.py` — **paths change**: platformdirs-native config/cache/state dirs replace the flat `~/.aap-demo/` (§5.2) |
| `~/.aap-demo/config` `KEY=VALUE` reader/writer (`crc-create.sh:30` `_save_config_key`) | — | `core/config.py` — **format changes** to YAML with one-time auto-migration (§5.1, §5.3) |
| `addons/registry/deploy.sh` | 93 | day-2 playbook `registry-mirror` in `aap-demo-playbooks` (§4.8.5), not a Python addon. **Preset-aware**: on the full OpenShift preset it should enable the built-in `image-registry-operator` instead of standing up the bespoke in-cluster registry (§4.8.5). |
| `addons/local-cache/deploy.sh` | 211 | day-2 playbook `image-store` in the playbooks repo, **redesigned** (§4.8.5) |
| `includes/aap-demo-version.sh` | 54 | `core/version.py` |
| `includes/aap-demo-notice.sh` | 43 | `core/console.py::show_notice()` (respects `QUIET`, `AAP_DEMO_NOTICE_SHOWN`) |
| `includes/infra-api.sh` | 95 | `infra/base.py` + `infra/registry.py` (ABC replaces `_infra_${INFRA_TYPE}_*` name-mangled dispatch) |
| `includes/infra-crc.sh` | 146 | `infra/crc.py` + `exec/ssh.py` (incl. `_detect_crc_ssh_key` ed25519/ecdsa probe, `_detect_crc_preset`) |
| `includes/crc-create.sh` | 602 | `cluster/bootstrap.py` (ordered steps, see §14 R1) + `cluster/coredns.py` + `cluster/storage.py` |
| `includes/ingress-ca-trust.sh` | 512 | `trust/` package (§6.2) |
| `includes/olm-catalog-signature.sh` | 271 | `cluster/catalog_signature.py` |
| `includes/galaxy-auth.sh` | 231 | `addons/builtin/setup_pah.py` + `core/secrets.py` — **the Galaxy/PAH tokens move out of files and into OS-native credential storage** (§5.5) |
| `install.sh` / `powershell/install.ps1` | 8.3 KB / — | **deleted** — replaced by `pip install aap-demo`; dependency preflight (`oc`, `kubectl`, `jq`, `ansible-navigator`, `operator-sdk`) becomes `aap-demo doctor`-style checks in `platform/`, with an interactive install prompt per §13 Q6 |
| `powershell/native/**` | 14 files | **deleted** — behavior absorbed into the single Python codebase (§6.3) |
| `config/**/*.yaml` | 17 files | `src/aap_demo/data/**` as package data, loaded via `importlib.resources` |
| `test/*.sh` | 459 | `tests/unit/**` (§7.4) |

Module-boundary rules for the implementer:

- **Only `exec/runner.py` may call `subprocess`.** Everything else takes a `CommandRunner`. This is the single mocking seam and the single place where Windows quoting, timeouts, and env propagation are handled.
- **Only `core/console.py` may write to stdout/stderr.** No `print()` elsewhere. This keeps `QUIET`, color, and non-TTY handling in one place and makes output assertions cheap in tests.
- **`cluster/` never imports `cli/`.** The command layer is a thin adapter; all logic is importable and testable without the CLI.
- **`addons/` never imports `cli/`.** Addons receive an `AddonContext` (§4.2).
- **`desktop/` never imports `cli/`, contains no orchestration logic, and never calls its own HTTP API.** It is a third adapter on the same footing as `cli/` and `gui/`. Tray actions go through the `JobManager` (§9.4), and tray state comes from the same `core/events.py` sink the SSE stream fans out from (§10.6.1).
- **`gui/` never imports `cli/`, and contains no orchestration logic.** Every GUI route is a thin adapter over the same `core/`, `cluster/`, `addons/`, and `day2/` calls the CLI makes. If a GUI route needs behavior that does not exist as a callable in those packages, the fix is to add it there, not in `gui/api/` (§9.1).
- **The Podman Desktop extension (§11) is a fourth adapter and lives outside this tree.** It is TypeScript, it holds no orchestration logic, and it reaches the core only over the §9.1 HTTP API — the same routes the browser calls, with no extension-specific endpoints. If it appears to need behavior that is not already a callable in `core/`/`cluster/`/`addons/`/`day2/`, that behavior is added there and exposed through the existing API, never reimplemented in TypeScript (§11.3).
- **`core/schema.py` is the only place a user-settable field is defined.** Neither an `argparse` argument nor a GUI form field may introduce a setting that is not in the schema (§9.3, R17).
- **Only `core/secrets.py` may read or write a credential.** No other module touches the OS keyring, and no credential is ever placed in the config file, an environment variable, a log line, a job event, or an API response body (§5.5, §9.5, R30).

---

## 3. CLI command surface

### 3.1 Framework: **stdlib `argparse`** — **DECIDED (revision 5; supersedes rev 2's Typer decision)**

Revision 2 decided Typer, on install-weight and feature grounds. That is superseded, and the reason is not that the earlier analysis was wrong on its own terms — it is that it optimized for the wrong thing. The governing criterion is **alignment with the Ansible tooling ecosystem this product lives in**, and that was checkable rather than arguable:

- **`ansible-navigator`** — the tool this rewrite already shells out to for day-2 playbooks (§4.8) — has **no Click, Typer, or Pydantic dependency**. Its validation dependency is **`jsonschema`**.
- **`ansible-creator`** — Red Hat's own scaffolding tool, the closest structural analogue to `aap-demo addon create` / `playbooks create` — likewise depends on none of them, and its `cli.py` drives a hand-rolled `arg_parser.Parser` that is a thin wrapper over stdlib **`argparse`**.

Both were inspected directly this session (their `pyproject.toml` dependency lists and their `cli.py` imports). Two independent Red Hat Ansible CLIs converging on `argparse` + `jsonschema` is a stronger signal than a feature comparison, because it is what a contributor arriving from that ecosystem already knows, and it is what a reviewer from that ecosystem expects to read.

| Candidate | Verdict |
|---|---|
| **`argparse` (stdlib)** | **Chosen.** Zero dependencies. Subparsers give the subcommand groups; a `parents=[global_parser]` argument gives the shared global options; and the per-command flags are **not hand-written at all** — they are generated by walking a JSON Schema (§9.3), which is the same mechanism that removes the boilerplate objection Typer was chosen to answer. Precedent: `ansible-creator`. |
| Typer / Click | **Rejected on ecosystem grounds**, not capability grounds. Both are perfectly good libraries; neither appears anywhere in the Ansible tooling this product sits next to. Their main concrete advantage over the chosen design is automatic multi-shell completion — see the note below. |
| `cleo` / `cyclopts` / `fire` | Heavier, less standard, or too magical. Rejected, unchanged from rev 2. |

**Two consequences, stated plainly rather than glossed.**

1. **Completion generation is now ours.** Click's `shell_completion` would have emitted bash/zsh/fish/PowerShell completers for free; `argparse` emits none. The rewrite compensates with **`argcomplete`** — a pure-Python, single-purpose library (no framework, no C extension) that reads an `argparse` parser and completes it for bash and zsh, plus a **hand-written PowerShell completer shipped as package data**, which rev 2 had already budgeted for because Click's PowerShell class was version-dependent anyway. `aap-demo completion [bash|zsh|fish|powershell]` (§3.3) keeps exactly the surface it had; only what is behind it changes. `argcomplete` is a base dependency and is small; if even that is judged too much, the fallback is four hand-written completer scripts as package data, and the CLI surface is small and schema-derived enough that generating them from the schema in CI is a realistic option.
2. **Console styling is ours too.** Rev 2's `core/console.py` leaned on Click's `echo`/`style`. Without Click, `core/console.py` writes through `sys.stdout`/`sys.stderr` directly and does its own ANSI handling and Windows-console probing — roughly the amount of code the module already needed for `QUIET`, TTY detection, and the `✓/✗/⚠/·` ASCII fallback (§6.1). No `rich`, unchanged.

One decided consequence carried over intact: **per-command arguments are not hand-written.** `core/schema.py`'s JSON Schema documents are the source of truth and `cli/` derives its arguments from them (§9.3). Hand-written `add_argument()` calls are permitted only for genuinely CLI-shaped concerns with no config or GUI analogue (`--output`, `--quiet`, `--yes`, `--config`, `--verbose`), and R17's test enforces exactly that allowlist.

### 3.2 Global options

Today's parser (`aap-demo.sh:94–186`) is a whitelist loop: it accepts flags and command names in any order, exports bare `KEY=VALUE` arguments into the environment (`aap-demo.sh:170–173`), and hard-codes the list of valid addon names in the parser itself. Preserve the user-visible behavior, drop the accidental behavior:

| Current | New | Notes |
|---|---|---|
| `--kubeconfig=FILE` / `--kubeconfig FILE` | `--kubeconfig PATH` | Both `=` and space forms work natively in `argparse`. |
| `--context=NAME` / `--context NAME` | `--context TEXT` | |
| `--branch=NAME` / `--branch NAME` | **drop** | Sets `UPDATE_BRANCH` at `aap-demo.sh:100,115` and **nothing ever reads it** — verified dead. Call this out in the changelog. |
| `NAMESPACE=<name>` positional | `--namespace/-n` **and** `AAP_DEMO_NAMESPACE` env | Keep reading bare `NAMESPACE=x` for one release for muscle memory (§12.4), but document the flag as canonical. Must preserve `_NAMESPACE_EXPLICIT` semantics (`aap-demo.sh:59`) — `test` behaves differently when the namespace was set explicitly vs. defaulted. |
| `QUIET=true` | `--quiet/-q` + `QUIET` env | Gates the disclaimer **and** the destructive-action confirmation (`aap-demo.sh:743`, `1930`). Non-negotiable behavior. |
| `FORCE=true` | `--force` + `FORCE` env | `deploy` skips the "already exists" short-circuit (`aap-demo.sh:2044`); addons read `FORCE=1`. |
| *(none — new)* | `--output text\|json\|yaml` (default `text`), plus `AAP_DEMO_OUTPUT` | Global, day one. See §5.4. All three formats work in the base install — `pyyaml` is a base dependency now that YAML is the config format (§5.1), so there is no extra to gate on. |
| *(none — new)* | `--config PATH` | Explicit YAML config file, overriding discovery (§5.2). Replaces `AAP_DEMO_CONFIG`, which keeps working. |
| bare `KEY=VALUE` → `export` | `--set KEY=VALUE` (repeatable), plus continue honoring real env vars | The blanket `export "$arg"` is an injection-shaped footgun; the escape hatch stays but becomes explicit. Env vars that must keep working unchanged: `CR`, `PUBLIC_URL`, `POD_NAME`, `POD_NAMESPACE`, `BASE_DOMAIN`, `AAP_OCP_VERSION`, `CRC_VERSION`, `CRC_CPUS`, `CRC_MEMORY`, `CRC_DISK`, `CRC_PV_SIZE`, `CRC_PRESET`, `PULL_SECRET_PATH`, `GALAXY_TOKEN_FILE`, `PAH_CONFIG_FILE`, `SKIP_COLLECTIONS`, `AAP_DEMO_TRUST_CA`, `AAP_DEMO_MKCERT`, `AAP_DEMO_LOAD_CACHE`, `AAP_DEMO_CONFIG`, `AAP_DEMO_DIR`, `AAP_DEMO_KUBECONFIG`, `NAMESPACE`, `QUIET`, `FORCE`, `CI`. **Two removals from rev 2's list**: `AAP_DEMO_ANSIBLE` is deleted outright — confirmed dead, §13 Q10 — and `GALAXY_TOKEN_FILE`/`PAH_CONFIG_FILE` keep working as *read* paths for migration only, because the tokens themselves move into OS-native credential storage (§5.5). |

### 3.3 Command table

Every command in the dispatch `case` at `aap-demo.sh:2876–2972`:

| Command | Args/flags today | Python | Preflight today (`aap-demo.sh:2862–2874`) |
|---|---|---|---|
| `create` | — | `cli.lifecycle:create` | `setup_kubeconfig` only |
| `deploy`, `deploy-all` (alias) | env `CR=`, `PUBLIC_URL=`, `FORCE=` | `cli.lifecycle:deploy` (`deploy-all` as hidden alias) | `setup_kubeconfig` only |
| `redeploy` | — | `cli.lifecycle:redeploy` | `setup_kubeconfig` only |
| `redeploy-all` | — | `cli.lifecycle:redeploy_all` | `setup_kubeconfig` only |
| `setup` | — | `cli.lifecycle:setup` | kubeconfig + cluster-type check |
| `start` | — | `cli.lifecycle:start` | kubeconfig + cluster-type check |
| `stop` | — | `cli.lifecycle:stop` | kubeconfig + cluster-type check |
| `destroy` | `--reset` | `cli.lifecycle:destroy --reset` | **none** (works with no cluster) |
| `clean` | accepts arbitrary trailing args (`aap-demo.sh:176`) | `cli.lifecycle:clean` | kubeconfig + cluster-type check |
| `repair` | — | `cli.lifecycle:repair` | kubeconfig + cluster-type check |
| `status` | — | `cli.observe:status` | kubeconfig + cluster-type check; also runs `_check_for_updates` (§12.3) |
| `watch` | — | `cli.observe:watch` | kubeconfig + cluster-type check |
| `diagnose` | `--ai` | `cli.observe:diagnose --ai` | kubeconfig + cluster-type check |
| `must-gather` | `[DIR]` | `cli.observe:must_gather [DEST]` | kubeconfig + cluster-type check |
| `idle` | `[true\|false]`, no-arg = show state | `cli.ops:idle [STATE]` where STATE is an optional bool | kubeconfig + cluster-type check |
| `ssh` | — | `cli.ops:ssh` (execs an interactive `ssh`) | kubeconfig + cluster-type check |
| `kubeconfig` | — | `cli.ops:kubeconfig` | kubeconfig + cluster-type check |
| `config` | `github` pass-through arg | `cli.ops:config` — real `get/set/list/edit/path`; the `github` arg is **dropped** (§13 Q11) | none |
| `update` | — | `cli.ops:update` | none |
| `version`, `--version`, `-V` | — | `cli.ops:version` + `--version` eager flag | none |
| `redhat-status`, `rh-status` (alias) | — | `cli.ops:redhat_status` | kubeconfig + cluster-type check |
| `test` | — | **Removed.** Upstream #184 deleted `aap-demo test`. Do not reintroduce `cli/testing.py`. | — |
| `enable` | `<addon> [--force] [--refresh-catalog]`; `local-cache` also takes `save\|load\|clear`; no-arg lists addons | `cli.addons:enable` | kubeconfig + cluster-type check |
| `disable` | `<addon> [options]`; `apme-eap` takes `--purge-creds`; no-arg shows usage | `cli.addons:disable` | kubeconfig + cluster-type check |
| `help`, `--help`, `-h` | — | framework help | none |
| `setup-pah` (bare) | — | deprecation message → "Run: aap-demo enable setup-pah" | none |
| *(no args)* | — | welcome banner (`show_welcome`) | none |

**New commands** (additive, no behavior removed):

| Command | Purpose |
|---|---|
| `addon list` | Replaces the untyped listing inside `enable` with no args; shows name, source package, version, enabled state, requires-AAP. |
| `addon info <name>` | Manifest dump: description, hooks implemented, dependencies, env vars. |
| `addon create <name>` | Scaffolds a new addon package (§4.6) — the structural answer to copy-paste. |
| `completion [bash\|zsh\|fish\|powershell]` | Emits a completion script; replaces the manual completion files `install.sh` drops into `~/.zsh/completions/` and `~/.local/share/bash-completion/completions/`. Backed by `argcomplete` for bash/zsh and by packaged hand-written scripts for fish/PowerShell (§3.1). |
| `playbooks list` | Lists day-2 operations available in the playbooks repo: name, summary, tags, `requires` (§4.8.3). |
| `playbooks info <name>` | Manifest dump for one playbook: description, variables and their types/defaults, requirements, estimated runtime. |
| `playbooks run <name> [-e k=v]…` | Runs the playbook via `ansible-navigator run` against the dedicated EE. Streams output. `--check` maps to `--check`. |
| `playbooks create <name>` | Scaffolds manifest + playbook + README in the playbooks repo working copy (§4.8.6). |
| `playbooks update` | Fetches/pins the playbooks repo checkout in the cache dir; `--ref` selects a tag/branch. |
| `gui [--port] [--no-browser]` | Starts the FastAPI server and opens a browser (§9). Requires the `[gui]` extra. **No `--host`** — the bind is loopback-only by design (§9.7, §13 Q15). |
| `config secrets list/set/delete/migrate` | Inspect and manage the OS-keyring credential store (§5.5.2). `list` shows names and backend, never values. |
| `config get/set/list/edit/path` | Real config command over the YAML file (§5.3), replacing today's no-op stub. Closes §14 R2's second artifact. **`config github` is dropped** — see §13 Q11. |

#### 3.3.1 Command-surface delta since the branch point (revision 7)

Upstream `main` changed the bash command surface after the table above was written. Treat this list as the current target:

| Change | Upstream | Rewrite consequence |
|---|---|---|
| **`test` removed** | PR #184 deletes `aap-demo test` and the ATF fetch/runtime path. Closes #168. | `cli/testing.py` is not part of this tree. Help text on upstream already matches the removal. |
| **`wire` added** | `cmd_wire` re-runs addon auto-wiring. Deploy and enable call the same path (`includes/addon-wire.sh`, grown substantially since ADR-023). | Phase 5+6. Not a phase-3 command. Deploy's post-deploy addon replay (§13 Q7) includes this wiring once the addon platform exists. |
| **`fleet` added** | Top-level `cmd_fleet` plus a `fleet` addon (ADR-026, PR #47). | Phase 5+6, as both a command and an addon. `destroy` must not tear down fleet VMs when the user asked to destroy CRC, and must not tear down CRC when the user asked to destroy fleet (PR #195). |

### 3.4 Exit codes

Today the script is inconsistent: some failures `exit 1`, some `return 1` from a function whose value is discarded, some print an error and continue. Standardize in `core/errors.py`:

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | generic failure |
| 2 | usage error (framework default) |
| 3 | prerequisite missing (`kubectl`/`crc`/`operator-sdk`/`ansible-playbook` not found) |
| 4 | cluster unreachable / not created |
| 5 | user aborted a confirmation |
| 6 | addon error |
| 7 | day-2 playbook run failed (`playbooks run`) — the `ansible-navigator` exit code is reported in the message, not passed through, so playbook rc 2/4 do not collide with the codes above |

Keep 0/1/2 exactly as today for anything scripted against the tool; 3–6 are refinements of what is currently 1.

---

## 4. Addon / plugin architecture

### 4.1 Discovery

Addons are ordinary Python packages that advertise themselves under the `aap_demo.addons` entry-point group:

```toml
# in a third-party addon's pyproject.toml
[project.entry-points."aap_demo.addons"]
grafana = "aap_demo_grafana:GrafanaAddon"
```

`addons/registry.py` enumerates `importlib.metadata.entry_points(group="aap_demo.addons")` at startup. This is the pytest/Flask-extension model: nothing in the core repo needs to change for a new addon to appear in `aap-demo addon list`.

Rules:

- Entry-point **name** is the addon's CLI name; it must match `^[a-z][a-z0-9-]{1,31}$`.
- A broken addon (import error, bad manifest) is reported as `⚠ addon 'x' failed to load: …` and skipped — one bad plugin must never break `aap-demo status`. Load errors are surfaced in `diagnose`.
- **Name collisions**: first-party (`builtin/`) wins; a third-party addon claiming a builtin name is refused with a clear message naming the conflicting distribution.
- **Aliases** replace `_normalize_addon_name` (`aap-demo.sh:2619`, which today hardcodes `ao-eap → ao`). Aliases are declared in the manifest and resolved by the registry.
- A **debug/local escape hatch**: `AAP_DEMO_ADDON_PATH=/path/to/dir` adds directories containing `addon.yaml`+`addon.py` to discovery without installing them, so addon authors get an edit-run loop.

### 4.2 The addon interface

```python
# aap_demo/addons/api.py  (illustrative — shapes, not final code)

class AddonManifest:                     # a plain dataclass, validated against a JSON Schema
    name: str
    version: str
    summary: str
    aliases: tuple[str, ...] = ()
    requires_aap: bool = False          # replaces the grepped "# ADDON_REQUIRES_AAP=true" comment
    requires_cluster: bool = True       # local-cache clear needs no cluster (aap-demo.sh:2734)
    requires_tools: tuple[str, ...] = () # ("helm",), ("jq",), ("operator-sdk",)
    depends_on: tuple[str, ...] = ()     # product-demo-* -> ("product-demos-base",)
    namespaced: bool = True              # consumes ctx.namespace
    hidden: bool = False                 # not shown in `addon list` (product-demos-base, olm today)
    auto_enable_on_create: bool = False  # participates in the crc-create.sh:508 saved-addon replay
    reentrant: bool = True               # re-enable upgrades in place (ADR-008 rule 4)
    homepage: str | None = None

class AddonContext:                      # what an addon is handed — no globals, all injected
    namespace: str
    quiet: bool
    force: bool
    console: Console
    kubectl: KubectlClient
    oc: OcClient
    helm: HelmClient
    infra: InfraBackend                  # SSH into the VM (registry, local-cache need this)
    paths: Paths                         # ~/.aap-demo/<addon-name>/ scoped state dir
    config: ConfigStore
    secrets: SecretStore                 # OS-native credential storage, addon-scoped (§5.5)
    aap: AapClient                       # route host, admin password, org/token helpers
    data: Traversable                    # the addon's own packaged files (importlib.resources)

class Addon(abc.ABC):
    manifest: ClassVar[AddonManifest]

    def preflight(self, ctx) -> None: ...          # raise AddonError to abort; default checks manifest
    @abstractmethod
    def enable(self, ctx) -> None: ...             # == today's ./deploy.sh — must be idempotent
    def disable(self, ctx, *, purge: bool = False) -> None: ...  # == ./deploy.sh --delete
    def status(self, ctx) -> AddonStatus: ...      # replaces cmd_status's per-addon switch/case
    def diagnose(self, ctx) -> list[Check]: ...    # contributes to `aap-demo diagnose`
    def arguments(self) -> dict: ...               # optional JSON Schema for extra CLI args (§9.3)
```

`enable` / `disable` / `status` / `diagnose` / `preflight` / `arguments` are the six lifecycle hooks. `enable` and `disable` are the only two required to match today's contract; the rest are opt-in with sane defaults, so porting an existing addon is mechanical.

**Extra CLI args** (today: `--force`, `--refresh-catalog` for `ao`; `save|load|clear` for `local-cache`; `--purge-creds` for `apme-eap`; `aap-demo.sh:2731–2741`, `2778–2781`) are declared as a JSON Schema returned by `arguments()`, fed through the same §9.3 walker that generates every other flag — so `aap-demo enable local-cache --help` becomes real help text instead of a comment in a shell script, **and** the same schema renders the addon's option form in the GUI (§9.2) with no second declaration.

### 4.3 Manifest format

The manifest is a Python object (the `manifest` class var) — it is the contract, it is validated against a JSON Schema at load, and it cannot drift from the code. For addons that prefer declarative packaging, an equivalent `addon.yaml` is supported and parsed into the same object:

```yaml
addon:
  name: grafana
  version: "0.2.0"
  summary: Grafana dashboards for the AAP demo cluster
  requires_aap: true
  requires_tools: [helm]
  depends_on: []
```

`AVAILABLE_ADDONS` (`aap-demo.sh:2617`) disappears — the list is derived from discovery, which structurally fixes ADR-008's "list can drift from directory contents".

### 4.4 Enabled-state persistence and create-time replay

Enabled addons move from the `ADDONS=a,b,c` line to the YAML config's `addons.enabled` list (§5.3); the legacy line is read and converted once at migration time (§5.1). `addons/state.py` owns read/normalize/dedupe/write, replacing `_addons_list`/`_addons_add`/`_addons_remove`/`_addons_save` (`aap-demo.sh:2626–2687`) including their alias-normalization and dedupe behavior.

`includes/crc-create.sh:508–531` replays saved addons at the end of `create`, skipping those with `# ADDON_REQUIRES_AAP=true` and continuing past failures with a warning. That becomes `registry.replay_saved(ctx, phase="post-create")` filtered on `manifest.requires_aap`, with the same continue-on-failure semantics. Additionally, addons whose `requires_aap` is true should be replayed at the end of `deploy` — today they are silently skipped at create time and never re-attempted, which is a latent gap worth confirming with the maintainers (§13 Q7).

### 4.5 The three-tier extension model — **DECIDED**

Rev 1 proposed a two-axis core/first-party/community split and left it open as Q3. The maintainer's decision replaces it with three tiers sorted by two questions, applied in order:

1. **Is it mandatory plumbing on the core deploy path?** → **Tier 1, built-in.** Not removable, not listed as an optional addon, ships in the base wheel.
2. Otherwise: **is this something the demo audience needs to see in the running environment, or something an operator does behind the scenes to manage the environment?**
   - Audience-facing content → **Tier 2, Python addon.** Appears in `addon list` and as a selectable step in the GUI deploy wizard (§9.2).
   - Operator-facing maintenance → **Tier 3, day-2 playbooks repo** (§4.8). An Ansible playbook run through `ansible-navigator`. **Never appears in the wizard.**

That second question is the governing rule for all future additions and should be quoted verbatim in `CONTRIBUTING.md`.

#### Tier 1 — built-in (base wheel, not removable) — 2 items

| Item | Current | Why built-in |
|---|---|---|
| `olm` | `addons/olm/deploy.sh` (137 L) | **Confirmed mandatory via ADR-005**: "Full OpenShift includes OLM by default; **MicroShift does not**". Without OLM there is no CatalogSource, no Subscription, no CSV, and therefore no AAP at all on the MicroShift preset. `cmd_deploy` already calls it directly (`aap-demo.sh:2059`) and fails hard. It is a deploy step wearing an addon costume. Implementation lives in `cluster/olm.py`; `addons/builtin/olm.py` remains only as a thin `enable olm` alias for repair workflows, and it is not listed as optional or offered in the wizard. **Unaffected by full-OpenShift support returning to scope (rev 5):** ADR-005's own reasoning already covers both presets — the install step detects an existing OLM and skips idempotently, so on the OpenShift preset it is a no-op rather than a branch. Being built-in is what makes that skip free; making it optional would put a preset conditional in the wizard for no user-visible benefit. |
| `setup-pah` | `addons/setup-pah/deploy.sh` (62 L) + `includes/galaxy-auth.sh` (231 L) | Unchanged from rev 1: credential plumbing on the core happy path. `GALAXY_TOKEN_FILE` and `PAH_CONFIG_FILE` are core-level paths, and `deploy` prints "run this next" as part of the normal flow (`aap-demo.sh:2212`). |

The `operator-sdk` auto-download that `addons/olm/deploy.sh:20` performs today is a separate concern and is governed by §13 Q6 (detect vs. install), not by this tier decision.

#### Tier 2 — first-party product addons (separate distributions, team-maintained)

Official Red Hat content, maintained by the aap-demo team, shipped as separate installable packages discovered via the `aap_demo.addons` entry-point group (§4.1). **Not** in the base wheel, and **not** community/self-service: there is no open PR queue and no expectation of external contributions to these.

| Addon | Current size | Distribution | Notes |
|---|---|---|---|
| `portal` | 1,043 L + Helm values template | `aap-demo-portal` | ADR-002/004. Helm-based, own OAuth state (now under the state dir, §5.2). |
| `mcp-server` | 324 L | `aap-demo-mcp-server` | ADR-011. Audience-facing (it is a thing you *show*), so tier 2 rather than built-in — a change from rev 1, which put it in core on parity grounds. Parity is no longer an argument for core placement because there is only one implementation now. |
| `ao` (aliases `ao-eap`) | 1,089 L **× 2, byte-identical** | `aap-demo-ao` | ADR-017. **This resolves rev 1's Q3**, which flagged the tension of ao being Red Hat internal content in a "community" tier. It is first-party. Ships as **one** Addon class with `aliases=("ao-eap",)`, deleting 1,089 duplicated lines outright. |
| `apme-eap` | 815 L | `aap-demo-apme-eap` | ADR-019/019b/022. Own credential store. |
| `product-demos` + `product-demos-base` + 6 × `product-demo-*` | 676 + 638 (lib) + ~820 L | `aap-demo-product-demos` | ADR-018. One distribution, 7 entry points, one shared base class (§4.6a). |

`pip install "aap-demo[demos]"` installs the tier-2 set (§8.1). Individual installs also work.

#### Tier 2b — genuinely third-party addons

The entry-point API stays open. Anything outside Red Hat content (the OPA / ALIA / x2ansible / Grafana / EDA Playground requests) ships as its own distribution on PyPI, discovered identically, reviewed by nobody on the core team. `devspaces` (138 L, CheCluster CR) is only meaningful on a full OpenShift preset — which, as of revision 5, is **back in scope**, so the "delete it" lean rev 2 carried is withdrawn. It is **deferred**, not deleted and not ported: it does not ship in v1, and that is not a statement about its future (§13 Q18). `console` is referenced in ADR-008 but has no directory: already-drifted proof that discovery beats a hardcoded list.

#### Tier 3 — day-2 playbooks repo

`registry` and `local-cache` move **out of the Python addon/plugin system entirely** (§4.8):

| Item | Why tier 3 |
|---|---|
| `registry` (`addons/registry/deploy.sh`, 93 L) | **Confirmed via ADR-013**: it exists so "developers building custom execution environments or testing image workflows" can push images; it is dev tooling, not audience-facing content. It is not enabled by default and is not on the mandatory deploy path. Its actual work — SSH to the VM, write `/etc/containers/registries.conf.d/999-aap-demo-registry.conf`, `systemctl reload crio` — is exactly what an Ansible playbook does well and what a Python addon does awkwardly. |
| `local-cache` (`addons/local-cache/deploy.sh`, 211 L) | **Confirmed via ADR-021**: a dev-loop speed optimization ("pull time dominates the create-deploy-test loop"), ~30 GB of cache, entirely operator-facing. Nobody in a demo audience ever sees it. It is also the strongest candidate for redesign rather than port — see §4.8.5. |

Consequence for the deploy path: `_load_local_cache` (`aap-demo.sh:2374–2383`) is **deleted**, not ported. The deploy path stops branching on whether a cache addon is enabled. Cache warming becomes an explicit day-2 operation the operator runs before deploying.

### 4.6 Designing out the duplication

Two concrete mechanisms:

**(a) Shared base classes replacing `product-demos-base/lib.sh`.** The 25 `apd_*` functions in `addons/product-demos-base/lib.sh` (638 lines) are already a de-facto base class — they just aren't one, so each of the six domain scripts re-implements the same 130-line envelope around them (cluster check, AAP-present check, dependency bootstrap by grepping `~/.aap-demo/config`, `jq` check, `apd_init_aap_connection`, `apd_resolve_domain_install_ids`, `apd_install_domain_demo "$CATEGORY"`, then a bespoke success banner). Under the new API each domain addon becomes roughly:

```python
class LinuxDemos(ProductDemoAddon):                 # base does everything the envelope did
    manifest = AddonManifest(
        name="product-demo-linux", version=..., summary="Linux automation demos",
        requires_aap=True, depends_on=("product-demos-base",), requires_tools=("jq",),
    )
    category = "linux"
    template_prefix = "LINUX |"
    highlights = ("Register with Insights", "Fact Scan", "Patching", ...)
```

~15 lines each instead of ~137, and the copy-paste bugs (`product-demo-cloud/deploy.sh:19,41` still saying "Linux") become impossible because the strings are derived from `category`/`template_prefix`.

Also worth providing as base classes: `HelmAddon` (portal), `ManifestAddon` (apply packaged YAML with `__PLACEHOLDER__` substitution — used by registry, mcp-server, nfs), `OlmAddon` (CatalogSource/Subscription/CSV-wait, used by ao).

**(b) `aap-demo addon create <name>` scaffolding.** Generates a complete installable package: `pyproject.toml` with the entry point wired, an `Addon` subclass with the hooks stubbed, a `data/` dir, a `tests/` dir with the shared addon-contract test (§7.5) already parameterized, and a README. The point is that the cheapest path to a new addon becomes "scaffold a package", not "copy the nearest `deploy.sh`".

**(c) Duplicate detection in CI.** A `tests/unit/test_addon_contract.py` check that fails when two registered addons produce identical hook bytecode/source hashes — a cheap tripwire against the exact `ao`/`ao-eap` failure recurring.

### 4.7 Migration of existing addons

Four classes of effort. Note that two of today's addons are **not ported as addons at all**:

| Class | Addons | Approach |
|---|---|---|
| Straight port | `olm` (→ `cluster/olm.py`), `setup-pah`, `mcp-server` | ≤330 lines each, mostly `kubectl apply` + waits. Direct translation to `ManifestAddon` subclasses. |
| Base-class refactor | 6 × `product-demo-*`, `product-demos`, `product-demos-base` | Port `lib.sh`'s `apd_*` helpers into `ProductDemoAddon`; domain classes become declarative. |
| Large / behavior-preserving | `ao` (1,089, collapsing `ao-eap`), `portal` (1,043), `apme-eap` (815) | Port function-by-function with a golden-output test per stage. These carry the most implicit ordering; do them last. With no shim (§13 Q5), "do them last" means they gate the release — budget accordingly rather than discovering it in the release week. |
| **Reimplemented as day-2 playbooks, not ported** | `registry` (93), `local-cache` (211) | Rewritten as Ansible playbooks in the playbooks repo (§4.8.5), not translated line-by-line. `local-cache` is additionally **redesigned** — the ADR-021 skopeo/SSH/md5 mechanism is the fallback, not the target. Neither appears in `addon list` or in the GUI wizard after this lands. |
| **Deferred, not ported and not deleted** | `devspaces` (138) | Meaningful only on the full OpenShift preset, which is back in scope (rev 5) — so the deletion argument no longer holds, but nobody has asked for it either. **Explicitly out of v1 and explicitly not a deletion decision** (§13 Q18). It must not block the v1 migration: the v1 exit criterion is "every other addon is ported", not "every addon is resolved". |
| **New since the branch point — tier 2** | `ollama` (ADR-024), `opa`, `portal-operator` (ADR-025), `fleet` (ADR-026) | Not in the 2026-09-01 inventory this table was written from. They are first-party addons under the same tier rule: audience-facing content, ported in phase 5+6, not day-2 playbooks. `fleet` is also a top-level command (§3.3.1). `portal-operator` sits beside the existing Helm `portal` addon; do not collapse them. |
| **Same addon, different behavior** | `local-cache`, `ao`, `portal`, `apme-eap`, `product-demos` | Line counts above are from 2026-09-01 and are stale. Since then: `local-cache` auto-loads on deploy and prompts to save on destroy (PR #158; ADR-021 updated), and `includes/persistent-crio-store.sh` adds an opt-in Linux host disk (macOS stays on the OCI cache). `ao` gained demo sync, one-replica defaults (ADR-027), agentic model binding (ADR-028), catalog-health and password/SSL fixes. `portal` auto-installs Helm (PR #120). `apme-eap` uses a chart image with runtime OCI plugins (PR #161). `product-demos` is gated on API and subscription (PR #146). Phase 5+6 ports **current** upstream, not the branch-point scripts. Phase 3 left `_load_local_cache` unported on purpose; against today's bash that is a behavior gap, absorbed by phase 6b rather than by reopening phase 3. |

**Compatibility shim — DECIDED: none. Clean cutover (§13 Q5).** Rev 2 recommended a builtin `LegacyShellAddon` wrapping any `addons/<name>/deploy.sh` still on disk. The maintainer decided against it: **there is no compatibility shim, and the core rewrite plus the full addon and playbooks migration ship together in one release.**

The tradeoff is real and worth stating in both directions, because the rejected option was the one that shipped sooner:

- **Cost of the decision:** a longer time to first release. Nothing goes out until the addon tier is complete, so the phase 5 / phase 6 split stops being a shipping boundary (§12.4 adjusts for this).
- **What it buys:** no deprecated legacy path to build, document, support on POSIX-only, and then remove; no divergence between an addon's shell behavior and its ported behavior while both exist; and — the decisive one — **no way to forget an unported addon.** A shim makes "we never got to `apme-eap`" invisible for a release or two. Without one, an unported addon is a missing command on day one, which is a thing someone notices immediately.

`AAP_DEMO_ADDON_PATH` (§4.1) remains the escape hatch for locally-developed *Python* addons; it is not a shell-addon path and does not become one. Teams with private shell addons port them in the same window the first-party ones are ported, and `addon create` (§4.6b) plus the documented `AddonContext` API is what makes that tractable.

### 4.8 The `aap-demo-playbooks` repo (tier 3)

#### 4.8.1 What it is and why it is not a Python plugin

A **separate git repository** of Ansible playbooks for operator-facing environment maintenance, consumed by `aap-demo playbooks` and executed by `ansible-navigator` against a dedicated Execution Environment. It is deliberately *not* part of the Python plugin system:

- These operations are not demo content. Putting them in the plugin system means they show up in `addon list` and in the GUI wizard, where they are noise at best and a footgun at worst (nobody wants "warm the 30 GB image cache" as a checkbox in a deploy wizard).
- Their work is overwhelmingly "SSH somewhere, write a file, restart a service, copy some bytes" — the thing Ansible is for. Reimplementing it as Python that shells out to `ssh` is how `addons/local-cache/deploy.sh` ended up 211 lines with a documented `ssh -n` stdin-consumption bug (ADR-021, "Technical details").
- Their release cadence should not be coupled to the CLI's. A new day-2 playbook should not require a `pip install -U`.
- It gives us a real use for the Execution Environment work already requested in **open issue #92** ("Implement dedicated Execution Environment and migrate to ansible-navigator"), and it demonstrates to customers the same containerized-EE execution model AAP itself uses — which is the stated point of that issue.

**Critically, this adds no Ansible dependency to the Python package.** `day2/navigator.py` builds an argv and hands it to the same `CommandRunner` used for `oc`, `kubectl`, and `crc`. No `ansible-runner`, no `ansible-core`, no collections resolved in-process. This is ADR-001's "delegate, don't reimplement" applied unchanged, and it is what keeps the base wheel at four pure-Python dependencies (§8.1).

#### 4.8.2 Repo name and layout — **DECIDED: `aap-demo-playbooks` (§13 Q13)**

Rev 2 proposed `aap-demo-ops` and asked the maintainer to choose rather than picking silently. The answer is **`aap-demo-playbooks`**, and the CLI noun follows it: `aap-demo playbooks run …`, `playbooks.repo_url` in config, `/api/playbooks` in the GUI API. Alternatives considered and rejected: `aap-demo-ops` (shorter, but "ops" is a role, not an artifact — the repo contains playbooks, and calling them ops invites anything operator-shaped to land there); `aap-demo-day2` (jargon that ages badly); `aap-demo-common` (the junk-drawer name — naming it "common" is how it becomes one).

The one thing the chosen name gives up, recorded so nobody re-opens it: it says *what* is in the repo but not *when* you run it. That is handled by the manifest's `tags` field and by the GUI's Operations nav section (§9.2), not by the repo name.

```text
aap-demo-playbooks/                       # separate git repo
  playbooks.yaml                    # repo-level metadata: schema version, minimum aap-demo version
  execution-environment/
    execution-environment.yml       # EE build definition (issue #92 Option B)
    requirements.yml                # kubernetes.core, community.general, containers.podman.
                                    #   Seeded from the aap-demo repo's own orphaned
                                    #   requirements.yml (§13 Q10) rather than deleted there.
  operations/
    image-store/
      manifest.yaml                      # per-playbook manifest (§4.8.3)
      playbook.yml
      README.md
      tasks/…, templates/…
    registry-mirror/
      manifest.yaml
      playbook.yml
      README.md
    prune-images/
    rotate-pull-secret/
    collect-vm-logs/
  templates/                        # scaffolding source for `aap-demo playbooks create` (§4.8.6)
  tests/                            # ansible-lint + a --check smoke run per playbook in CI
```

The repo is **cloned into the cache dir** (`<cache>/playbooks-repo/`, §5.2) — it is reconstructible from the network, so it is cache, not state. `aap-demo playbooks update` clones or fetches it; the resolved ref is pinned in config (`playbooks.ref: v1.2.0`) so a demo does not silently change behavior between runs.

#### 4.8.3 Manifest format

One `manifest.yaml` per operation directory — YAML, like everything else an Ansible author touches, and like the config file (§5.1). It is validated in `day2/manifest.py` against a JSON Schema shipped as package data (`jsonschema.validate`, §9.3), and the **same** schema is what the GUI's form generator consumes — so a day-2 playbook's variables become a real form with no extra work and no second declaration.

```yaml
operation:
  name: image-store                   # ^[a-z][a-z0-9-]{1,31}$, must match directory name
  summary: Persistent local image store for the CRC VM
  description: |
    Maintains a host-side container image store mounted into the CRC VM so that
    create/destroy cycles do not re-pull ~50 images from registry.redhat.io.
  version: "1.0.0"
  tags: [performance, dev-loop, images]   # free-form; `playbooks list --tag performance`
  playbook: playbook.yml                  # relative to the operation directory
  estimated_minutes: 15                   # shown in the CLI and GUI before you commit to it
  destructive: false                      # true → confirmation prompt / GUI confirm modal
  concurrent: false                       # false → refuse to start if another run is active
  presets: [microshift, openshift]        # which CRC presets this playbook applies to (§4.8.5).
                                          #   Omitted means both. `playbooks list` filters on the
                                          #   live preset, so an OpenShift user never sees a
                                          #   MicroShift-only playbook.

requires:
  cluster: true                 # a reachable cluster is needed
  aap: false                    # a deployed AAP instance is needed
  vm_ssh: true                  # needs SSH into the CRC VM (day2 injects the connection vars)
  tools: []                     # host binaries beyond ansible-navigator, e.g. [skopeo]
  aap_demo: ">=2.0.0"           # minimum CLI version
  collections: [kubernetes.core]   # must be present in the EE; checked at build time, not run time

vars:                           # every playbook variable the operator may set
  - name: store_path
    type: path                  # str | int | bool | path | choice | secret
    default: "{cache_dir}/image-store"   # {cache_dir}/{state_dir}/{config_dir} interpolated by day2
    description: Host directory backing the image store

  - name: mode
    type: choice
    choices: [hostmount, skopeo]
    default: hostmount
    description: Backing mechanism; see README

  - name: prune_after
    type: bool
    default: false
    description: Remove images from the VM store after export
```

Rules:

- The manifest is **the contract**. `playbooks list`/`playbooks info`/the GUI read only the manifest; they never parse the playbook.
- A manifest that fails validation is reported (`⚠ operation 'x' has an invalid manifest: …`) and skipped — one bad playbook must never break `playbooks list`, mirroring the addon-registry rule in §4.1. Report the `jsonschema` validation error's JSON path, not just its message; "`vars[1].type` is not one of […]" is actionable and "invalid manifest" is not.
- `vars` entries become `-e name=value` extra-vars. `type: secret` values are **read from the OS keyring by name, never written into the manifest or the config file** (§5.5); they are never echoed, never logged into the SSE stream (§9.4), and are passed via a mode-0600 temporary vars file rather than argv, so they do not appear in `ps`.
- `requires.*` is checked by `day2/catalog.py` **before** invoking `ansible-navigator`, so a missing prerequisite is a clean exit-code-3 message rather than a wall of Ansible output.

#### 4.8.4 `playbooks` command surface and execution

```text
aap-demo playbooks list [--tag TAG] [--output json|yaml]
aap-demo playbooks info <name>
aap-demo playbooks run <name> [-e KEY=VALUE]… [--check] [--yes] [--verbose]
aap-demo playbooks create <name>
aap-demo playbooks update [--ref REF]
```

`day2/navigator.py` builds, for `playbooks run image-store -e mode=hostmount`:

```text
ansible-navigator run <cache>/playbooks-repo/operations/image-store/playbook.yml
  --execution-environment-image quay.io/redhatofficial/aap-demo-ee:<pinned tag>
  --mode stdout                       # never the TUI; we own the terminal and the SSE stream
  --pull-policy missing
  --container-engine auto             # podman preferred, docker fallback
  --enable-prompts false
  --extra-vars @<tmp>/vars.json       # merged manifest defaults + config + -e overrides
  --set-environment-variable KUBECONFIG=<resolved kubeconfig>
  --execution-environment-volume-mounts <host>:<container>:Z   # kubeconfig, ssh key, store path
```

Decisions embedded there, each of which the implementer must not casually change:

- **`--mode stdout` always.** `ansible-navigator`'s default TUI is unusable inside a subprocess pipe and impossible to stream over SSE.
- **The EE image tag is pinned in config**, defaulting to a tag matching the CLI's minor version. A floating `:latest` EE would make demos non-reproducible, which is the exact problem issue #92 is trying to solve.
- **Volume mounts are explicit and minimal.** The kubeconfig, the CRC SSH key, and any `type = "path"` var the operation declares. Nothing else from the host is visible to the EE.
- **Preflight `ansible-navigator` and a container engine** with an actionable message when absent (`pip install ansible-navigator` / `brew install podman`), consistent with §13 Q6 — which, as of rev 5, means **interactively offering to install it** rather than only naming it.
- **`--check`** maps to Ansible check mode and is advertised in `playbooks info` output when the playbook supports it.

#### 4.8.5 `local-cache` and `registry` as day-2 operations

**`registry-mirror`** is a near-mechanical translation of `addons/registry/deploy.sh` + ADR-013: apply the registry namespace/Deployment/Service/Route, then use `ansible.builtin.template` + a `systemd` reload over the CRC SSH connection to write `999-aap-demo-registry.conf`. The ClusterIP substitution that today happens with shell interpolation becomes a `kubernetes.core.k8s_info` lookup feeding a template variable. Low risk; do it first as the proof that the tier-3 mechanism works end to end.

**Preset-aware behavior, worth designing rather than fully speccing here.** With the full OpenShift preset back in scope (rev 5), this playbook has an obviously better path on that preset: **enable OpenShift's built-in `image-registry-operator`** instead of standing up the bespoke in-cluster registry at all. On a full OpenShift cluster the registry operator already exists, already has a route, already integrates with the cluster's auth and image streams, and only needs its management state flipped and storage pointed somewhere — which is a handful of `kubernetes.core.k8s` tasks against `configs.imageregistry.operator.openshift.io/cluster`. The bespoke Deployment exists because MicroShift ships no registry operator, not because it is better. The shape to build: one playbook, a `when: crc_preset == 'openshift'` branch selecting the operator path, and the manifest's `presets` key left as both. **This branch belongs to phase 4b, not to phase 6b** (rev 6): the MicroShift path is what ships with v1, and the `image-registry-operator` path lands when full-OpenShift preset support does (§12.4). **Not fully specced here** — the operator's storage requirement on a single-node CRC cluster (`emptyDir` versus a topolvm PVC, and what survives a restart) needs a look before the task list is written. Flagged as design work for whoever builds `registry-mirror`, not as a decision left open.

**`image-store` — redesign, do not port.**

ADR-021's mechanism is: enumerate images with `crictl images -o json` over SSH, `skopeo copy … docker-archive:/dev/stdout` each one back over SSH to a host file named by the md5 of its reference, with a `.ref` sidecar because image references contain `/`, `@`, and `:`; then stream each tarball back in on load. Its own Consequences section admits ~30 GB uncompressed, 10–15 minutes to save, and no layer deduplication — i.e. saving the cache costs about what pulling the images costs. It is a large amount of machinery to work around one fact: **CRI-O's image store lives inside the VM and dies with it.**

The maintainer's reframing — "a persistent local image store on the host machine, mounted into CRC" — attacks that fact directly. If a host directory can be mounted into the CRC VM and used as CRI-O's backing image storage (via `additionalimagestores` in `/etc/containers/storage.conf`, or by relocating `graphroot`), then the store simply survives `crc delete` because it was never inside the VM. The entire skopeo-export / SSH-streaming / md5-filename / `.ref`-sidecar apparatus disappears, along with the 10–15-minute save step, the 30 GB duplication, and the `ssh -n` stdin bug.

**This requires a feasibility spike before it is committed to.** I do not have confirmed knowledge of whether CRC supports host-directory sharing into the VM on all three host platforms, and the answer plausibly differs per hypervisor (vfkit on macOS, libvirt/KVM on Linux, Hyper-V on Windows). The spike must answer, in order:

1. Does `crc` expose a supported host-mount mechanism at all — a `crc config` key, a documented `--memory`-style flag, or a per-hypervisor share (virtiofs / 9p / SMB)? Check the CRC docs and `crc config --help` for the target CRC version, and test on macOS first since it is the primary dev platform.
2. If a share exists, can CRI-O actually use it? A `[storage] additionalimagestores` entry pointing at the mount is the least invasive form: CRI-O reads images from it but writes elsewhere, so a read-only or slow share is tolerable. Relocating `graphroot` onto the share is stronger but far more fragile (overlayfs on a virtiofs/9p mount frequently does not work).
3. Does the store survive `crc delete && crc start`, and does a deploy against a warm store actually skip the pulls (measured, not assumed)?
4. What is the write path — how do images *get into* the host store? Likely `skopeo copy docker://… containers-storage:[overlay@<store>]…` run on the host, which is a normal host-side operation with no SSH involved at all.

Outcome handling, designed up front so the spike is not a fork in the road:

- **If feasible** → `mode = "hostmount"` is the default. The playbook configures the share, drops a `storage.conf` dropin into the VM, and populates the store on the host. This must be re-applied after each `crc start` (the VM's `/etc` is not durable across recreate), which is fine — it is a fast, idempotent operation, and re-running it is exactly what a day-2 playbook is for.
- **If not feasible** → `mode = "skopeo"` is the default and the playbook implements ADR-021's mechanism as-is, with the known details preserved verbatim (`ssh -n`, `--remove-signatures`, `containers-storage:` transport, md5 filenames + `.ref` sidecars). The manifest already carries the `mode` choice var precisely so the fallback is a config value, not a rewrite.

Either way the on-disk location moves from `~/.aap-demo/local-cache/<preset>/` to `<cache>/image-store/<preset>/` (§5.2). **The preset path segment stays**, as `<cache>/image-store/<preset>/` — rev 2 dropped it on the strength of ADR-020 being declined, and with both presets supported again (rev 5) a MicroShift image set and a full-OpenShift image set are genuinely different collections that must not share a directory. This is a one-line correction to rev 2, not a redesign, and it restores the behavior today's `local-cache` addon already has.

#### 4.8.6 `aap-demo playbooks create <name>` — scaffolding

The same philosophy as `addon create` (§4.6b), mirrored for playbooks: the cheapest path to a new day-2 operation must be "scaffold from template", never "copy the nearest playbook", because copy-the-nearest is precisely how `addons/product-demo-cloud/deploy.sh:19` ended up saying "Deploy Linux demos".

`aap-demo playbooks create prune-images` generates, in the playbooks repo working copy:

```text
operations/prune-images/
  manifest.yaml  # pre-filled with name/summary/version, one example vars entry, requires.* stubs
  playbook.yml   # a real playbook: hosts: crc_vm, gather_facts: false, one no-op debug task,
                 #   the standard pre_tasks block that asserts requires.* were injected
  README.md      # what it does / when to run it / variables table generated from manifest.yaml
  tests/test_check_mode.yml
```

and prints the two follow-ups: `aap-demo playbooks run prune-images --check`, and the PR checklist. The generator runs against the local checkout of the playbooks repo (`playbooks.repo_path` in config, §5.3) — it is an authoring tool, not something end users invoke against the read-only cached clone; it errors clearly if no writable checkout is configured.

`manifest.yaml`'s variables table in the README is **generated**, not hand-written, so the manifest stays the single source of truth for the CLI, the GUI form, and the docs simultaneously.

#### 4.8.7 Testability

`day2/navigator.py` produces an argv and calls `CommandRunner` — so `FakeRunner` (§7.2) asserts the exact `ansible-navigator` invocation, including EE image, mount list, and extra-vars file contents, with no container runtime present. Manifest parsing and `requires` gating are pure functions over fixture directories. Actually running a playbook is an `@pytest.mark.integration` concern. The playbooks repo has its own CI (ansible-lint plus a `--check` run per playbook against a live cluster) and is versioned independently; the CLI's contract with it is only the manifest schema, which is version-gated by `manifest.yaml`'s `schema_version`.

---

## 5. Configuration, filesystem layout, credentials, and output formats

### 5.1 Config format: **YAML** — DECIDED (revision 5; supersedes revision 2's "DECIDED: TOML", which superseded rev 1's Q9)

This decision has now been made three times and it is worth showing the full chain rather than quietly landing on the current answer.

- **Rev 1** said: keep `KEY=VALUE` during the bash/Python overlap and revisit later.
- **Rev 2** superseded that with **TOML**, on two grounds: `KEY=VALUE` cannot express nested per-addon and per-playbook settings, and TOML avoids PyYAML's optional `libyaml` C extension, which has known build failures on a fresh macOS machine with no Xcode Command Line Tools. A `pip install` that fails with a compiler stack trace before the tool has run once is exactly the friction this rewrite exists to remove.
- **Rev 5 supersedes the format but keeps both of rev 2's concerns intact.** The config is **YAML from the first release**, with the same automatic migration of the legacy file.

**Why the format changed.** The rev 2 analysis was correct about `KEY=VALUE` and correct about the C-extension failure mode; it was wrong about which axis mattered most. TOML is a **Python-packaging** convention (`pyproject.toml`), not an Ansible one. This tool ships to Ansible users, is maintained by an Ansible team, delegates its day-2 work to `ansible-navigator`, and applies YAML manifests to a cluster all day. Verified directly this session, by reading their actual dependency lists: **`ansible-navigator` and `ansible-creator` both hard-depend on `pyyaml`, and neither uses TOML anywhere.** There is no TOML precedent in the Ansible tooling ecosystem at all. Asking an Ansible user to hand-edit a TOML file, in a tool whose every other artifact is YAML, is a papercut with no compensating benefit.

**The C-extension objection is answered, not ignored — and answered better than by switching formats.** Use **PyYAML in pure-Python mode**: `yaml.safe_load` / `yaml.safe_dump` with the default pure-Python `SafeLoader`/`SafeDumper`, never `CSafeLoader`/`CSafeDumper`. The `libyaml` C extension is a **speed optimization for large documents and nothing else** — it is entirely optional, PyYAML's own pure-Python path is the reference implementation, and a config file, an addon manifest, and a playbook manifest are all a few kilobytes. There is no scenario in this tool where the C path's throughput is observable. Concretely: never import `CSafeLoader`, and add a unit test asserting the loader in use is the pure-Python one, so nobody "optimizes" it back in and reintroduces the build dependency by accident.

**What this changes mechanically:**

| Rev 2 | Rev 5 |
|---|---|
| `<config>/config.toml` | `<config>/config.yaml` |
| `tomllib` (3.11+) / `tomli` backport (<3.11) for reads | `yaml.safe_load` — no version-conditional dependency at all |
| `tomlkit` for comment-preserving writes | `yaml.safe_dump` for writes; see the comment-preservation note below |
| `pyyaml` shipped only as an optional `[yaml]` extra for `--output yaml` (§5.4) | `pyyaml` is a **base dependency**; `--output yaml` simply reuses it and the extra disappears |
| `addon.toml`, `ops.toml` | `addon.yaml`, `manifest.yaml` |

**The one thing genuinely lost, and how it is handled.** `tomlkit` round-tripped comments and key order, which mattered for `aap-demo config set` not eating the header comment the migration writes. `yaml.safe_dump` does not preserve comments. Two options, and the recommendation is the first:

1. **Regenerate the header on every write.** `core/config.py` owns the header block (a generated-by line, the docs URL, and the `config edit` hint) and re-emits it on every save, along with `sort_keys=False` and an explicit key order taken from the schema. The user's *values* round-trip; the *comments* are ours and are regenerated rather than preserved. This is simple, has no extra dependency, and means the file's shape stays consistent with the schema as fields are added.
2. `ruamel.yaml`'s round-trip mode preserves user comments genuinely. It is already a candidate dependency for the CR-editing problem (§5.4, §13 Q14) — so if that spike lands on keeping `ruamel.yaml`, using its round-trip loader for the config file too is free. **Do not add it for the config file alone.**

Either way, YAML is now the one format for the addon manifest (§4.3), the playbook manifest (§4.8.3), the user config, and every cluster manifest the tool applies — one parser, one mental model, and the same one the audience already reads.

### 5.2 Filesystem layout: strict XDG paths on every OS — DECIDED (revised; supersedes the platformdirs-native-per-OS decision below)

**Revision, 2026-09:** the original decision below (platformdirs, native per-OS conventions) is superseded for now. The maintainer decided that the CLI/core uses **strict XDG-style paths under `$HOME` on every OS, including macOS and Windows** — `~/.config/aap-demo`, `~/.cache/aap-demo`, `~/.local/state/aap-demo`, honoring `$XDG_CONFIG_HOME`/`$XDG_CACHE_HOME`/`$XDG_STATE_HOME` when set — not macOS's `~/Library/Application Support`/`~/Library/Caches` or Windows' `%APPDATA%`. This is implemented in `core/paths.py` by hand-rolling the XDG env-var resolution (not via `platformdirs`, which is no longer a dependency) so the override is obvious and testable against an injected environment rather than real `os.environ`. **Native-per-OS conventions are explicitly deferred, to be revisited specifically when the web GUI/desktop app is built (§9, §10) — not before.** The reasoning below for native-per-OS is preserved as the record of that still-pending future decision, not as what the code currently does.

Today everything lives flat in `~/.aap-demo/`: config, kubeconfig, pull secret, CA certs, Galaxy tokens, portal OAuth state, apme-eap GitHub credentials and private key, the ~30 GB image cache, and an update-check timestamp. Config, secrets, and 30 GB of reconstructible cache in one directory is the kind of thing that makes a tool feel like a script.

**Original decision (superseded for now, see above):** use **`platformdirs`** (pure Python, no dependencies, no C extensions) with its **native per-OS defaults** — not literal XDG paths forced onto every OS. The "look like a real product" goal favors OS-idiomatic paths over spec purity: a macOS user expects `~/Library/Application Support`, and a Windows user expects `%APPDATA%`. On Linux, platformdirs' defaults *are* XDG and honor `XDG_CONFIG_HOME`/`XDG_CACHE_HOME`/`XDG_STATE_HOME`, so XDG users get exactly what they expect for free.

```python
from platformdirs import PlatformDirs
_dirs = PlatformDirs(appname="aap-demo", appauthor=False, ensure_exists=True)
CONFIG_DIR = _dirs.user_config_path     # macOS ~/Library/Application Support/aap-demo
CACHE_DIR  = _dirs.user_cache_path      # macOS ~/Library/Caches/aap-demo
STATE_DIR  = _dirs.user_state_path      # macOS ~/Library/Application Support/aap-demo
                                        # Linux  ~/.local/state/aap-demo
```

Classification rule, now in **four** classes rather than three: **config** is what a human writes and would put in dotfiles; **secret** is a credential, and it does not live on the filesystem at all — it lives in the OS credential store (§5.5); **state** is machine-generated non-secret data whose loss costs the user something (certificates, kubeconfigs); **cache** is anything reconstructible from the network or the cluster.

The kubeconfig and the pull secret are the two deliberate exceptions to the secret rule, and the reason is mechanical rather than a lapse: both are consumed by *other programs* (`oc`, `kubectl`, `crc`) that take a **file path**, not a string. A keyring entry cannot be handed to `KUBECONFIG=`. They stay files at mode 0600, and §5.5 says so explicitly so that nobody reads the rule as having been forgotten here.

| Today | New home | Class | Rationale |
|---|---|---|---|
| `~/.aap-demo/config` | `<config>/config.yaml` | config | Hand-editable; the only file `aap-demo config edit` opens. |
| `~/.aap-demo/kubeconfig.microshift` | `<state>/kubeconfig.microshift` | state | Machine-generated, credential-bearing, mode 0600. |
| `~/.aap-demo/pull-secret{,.txt,.json}` | `<state>/pull-secret.json` | state | Secret. **Discovery keeps reading the legacy locations and `PULL_SECRET_PATH` indefinitely** — users hand-place this file from the Red Hat console and muscle memory is strong. |
| `~/.aap-demo/crc-ingress-ca.crt`, `ca-bundle.crt` | `<state>/certs/` | state | Regenerable in principle, but `CURL_CA_BUNDLE`/`SSL_CERT_FILE` point at the bundle path (§6.2) — a cache eviction mid-session would break TLS. State. |
| `~/.aap-demo/galaxy-token`, `pah-config.yml` | **OS keyring** (§5.5) | secret | **Not a file any more.** The token moves into the OS credential store; `pah-config.yml`'s non-secret fields (hostname, verify_ssl) stay in `config.yaml`. Legacy paths are read once at migration and then deleted. |
| `~/.aap-demo/atf-vault-password` | left in `~/.aap-demo/` | — | The ATF command is gone (#184). Migration does not import this file and does not delete it. |
| `~/.aap-demo/apme-eap-github-creds.yml` + key | **OS keyring** (§5.5), addon-scoped | secret | ADR-019's credential store. The token goes in the keyring; the SSH private key stays a file (keyrings are for strings, and `ssh` needs a path) at `<state>/addons/apme-eap/` mode 0600, with its passphrase — if any — in the keyring. |
| `~/.aap-demo/portal/` (OAuth state) | **OS keyring** (§5.5) for the tokens; `<state>/addons/portal/` for the rest | secret + state | ADR-002/004's OAuth state is a mix: the access/refresh tokens are secrets and go in the keyring; client ids, endpoints, and expiry timestamps are not and stay on disk. |
| `~/.aap-demo/local-cache/<preset>/` | `<cache>/image-store/<preset>/` | cache | ~30 GB, fully reconstructible; belongs where OS cleanup tools expect to find it. Preset segment **retained** — both presets are supported again (rev 5) and their image sets differ (§4.8.5). |
| *(new)* `aap-demo-playbooks` clone | `<cache>/playbooks-repo/` | cache | Re-clonable from git. |
| *(new)* EE image pull metadata | *(container engine's own store)* | — | Not ours to manage. |
| `~/.aap-demo/.last_update_check` | `<cache>/last_update_check` | cache | Losing it costs one redundant check. |

`ctx.paths.addon_dir(name)` returns `<state>/addons/<name>/` and `ctx.paths.addon_cache(name)` returns `<cache>/addons/<name>/`, so addons inherit the split without thinking about it. `AAP_DEMO_DIR` continues to be honored as an override that collapses everything back under one root — needed for CI, for the migration escape hatch, and for anyone who genuinely wants the old layout.

**One caution for the implementer, from the superseded native-per-OS decision**: on macOS, platformdirs returns the *same* directory for config and state by default. Do not rely on the two being distinct paths; rely on the accessor names. (Moot under the current strict-XDG implementation, where config/cache/state are always distinct — kept here in case native-per-OS returns.)

### 5.3 Config schema

`config.yaml`, with every key defined in the JSON Schema documents in `core/schema.py` (§9.3) — the schema is the documentation, and it is what generates both the CLI flags and the GUI form fields.

```yaml
# aap-demo configuration. Generated by aap-demo 2.0.0.
# Docs: https://github.com/…/docs/CONFIG.md   Edit with: aap-demo config edit
# This file contains NO credentials. Secrets live in the OS credential store (§5.5);
# inspect them with `aap-demo config secrets list`.
schema_version: 1

core:
  namespace: aap-operator           # was NAMESPACE
  infra: crc                        # was INFRA
  output: text                      # default for --output (§5.4)
  quiet: false

crc:
  preset: microshift                # was CRC_PRESET. microshift | openshift — BOTH are supported
                                    #   again as of rev 5; this is a real choice, not a fixed value.
  cpus: 8                           # was CRC_CPUS
  memory_mb: 24576                  # was CRC_MEMORY
  disk_gb: 120                      # was CRC_DISK
  pv_size_gb: 100                   # was CRC_PV_SIZE
  version: ""                       # was CRC_VERSION; "" = no pin

deploy:
  channel: stable-2.7
  base_domain: apps.127.0.0.1.nip.io    # was BASE_DOMAIN
  cr: ""                                # was CR — path/name of the AAP CR template
  public_url: ""                        # was PUBLIC_URL
  pull_secret_path: ""                  # was PULL_SECRET_PATH (a path, not a secret — §5.5)

trust:
  install_ca: true                  # was AAP_DEMO_TRUST_CA
  mkcert: true                      # was AAP_DEMO_MKCERT (pending §14 R7)

addons:
  enabled: [mcp-server, product-demo-linux]      # was ADDONS=a,b,c
  options:                          # per-addon options — the shape KEY=VALUE could not express
    portal:
      values_file: ""
      oauth_client_id: ""           # the client SECRET is in the keyring, not here
    product-demos:
      skip_collections: false       # was SKIP_COLLECTIONS

playbooks:                          # the aap-demo-playbooks repo (§4.8)
  repo_url: https://github.com/…/aap-demo-playbooks.git
  ref: v1.2.0                       # pinned; `playbooks update --ref` changes it
  repo_path: ""                     # authoring checkout for `playbooks create`; "" = cached clone
  ee_image: quay.io/redhatofficial/aap-demo-ee
  ee_tag: "2.0"
  container_engine: auto
  overlay_paths: []                 # extra local directories scanned for operations (§2.1 catalog.py)
  vars:                             # persisted answers for a playbook's `vars` (§4.8.3)
    image-store:
      mode: hostmount
      store_path: ""                # "" = <cache>/image-store/<preset>

gui:
  host: 127.0.0.1                   # FIXED — not settable to anything else (§9.7, §13 Q15)
  port: 8720
  open_browser: true
  allow_reveal: false               # gate the reveal endpoint at all; copy-to-clipboard is the
                                    #   default affordance and needs no setting (§9.5.1)

secrets:                            # §5.5 — how credentials are stored, never the credentials
  backend: auto                     # auto | keyring | none(fail-loudly). "auto" resolves the OS
                                    #   keyring and errors if there is no backend; it never
                                    #   silently falls back to a file.
```

Note the two structural changes from rev 2's sketch beyond the syntax: **`addons.options.<name>`** replaces `[addons.<name>]`, because a YAML mapping cannot both hold `enabled` and be indexed by addon name without ambiguity; and **`playbooks`** is a first-class top-level block with the same standing `addons` has, because the maintainer's requirement is that day-2 playbooks be configurable — not merely runnable — from every surface, the GUI included (§9.2).

Resolution order, highest wins: explicit CLI flag / GUI form value → environment variable → `--config` file → discovered `config.yaml` → schema default. Every env var listed in §3.2 keeps working and maps to exactly one schema field; the mapping is declared **in the schema itself** as an `x-env` annotation on the property (§9.3), so it too is single-sourced rather than a second lookup table.

### 5.4 `--output text|json|yaml` — DECIDED, day one

Rev 1's R12/Q12 proposed `--output json` as a defensive measure against breaking stdout consumers. **The maintainer has confirmed nothing scripts against `aap-demo`'s stdout today**, so that defensive framing is gone: human-readable output is free to be redesigned. Structured output ships anyway, for two better reasons:

1. The GUI's API returns the same structured objects the CLI renders (§9.1). Building `status`/`diagnose`/`playbooks list` as functions returning typed result models — with `text`, `json`, and `yaml` as three renderers over them in `core/output.py` — is what makes "one core, two frontends" true rather than aspirational.
2. Tests assert against result models, not banner strings, which is the point of §7.4.

Every command that produces a report (`status`, `diagnose`, `addon list`, `addon info`, `playbooks list`, `playbooks info`, `version`, `config list`) supports all three. Commands that stream progress (`deploy`, `create`, `watch`, `playbooks run`) emit their human stream unchanged and a final structured summary object under `--output json|yaml`.

**All three formats work in the base install — the `[yaml]` extra is gone.** Rev 2 shipped PyYAML only as an optional extra, specifically so that a C-extension build failure could not break a first install. That tension no longer exists: §5.1 makes YAML the **config** format, so `pyyaml` is a base dependency the tool cannot run without anyway, and it is used in **pure-Python mode** where no compiler is involved at any point. `--output yaml` simply calls the `yaml.safe_dump` that `core/config.py` already imports. Nothing to gate, nothing to install, no "install `aap-demo[yaml]` for YAML output" error message to write.

One residual, unchanged by the format decision: cluster YAML that aap-demo *applies* ships as package data and is handed to `kubectl apply -f` unparsed wherever possible. Where the rewrite must **edit** a CR (§14 R6), `yaml.safe_load`/`safe_dump` round-trips the *data* correctly but discards comments and key order, which is what §13 Q14 is actually about. `ruamel.yaml` remains the fallback answer there and `kubectl patch` remains the better one; **Q14 is narrower now than in rev 2** — it is no longer "does the base wheel need a YAML parser at all" (it does, and it has one) but only "do the CR edits need a *comment-preserving round-trip*, or can they be expressed as patches".

### 5.5 Credential storage: OS-native, via `keyring`

**The requirement, from the maintainer:** *"aap-demo is not made for shared access or hosted access. it is a LOCAL demo tool"* — so the GUI needs no authentication (§13 Q15, Q16) — *"but it should also not have anything sensitive exposed in it… things like auth need to be stored in secure os-native methods… not as env vars in files."*

Those two statements are not in tension and it is worth being precise about why, because a careless reading makes the second look redundant given the first. Localhost-only removes the *network* attacker. It does not remove the other three exposures that actually happen to this tool: a credential file synced into a backup or a Dropbox folder; a token visible in `ps` output or a shell history or a CI log because it was passed as an environment variable; and a password rendered on a projector during the demo the tool exists to give. Each of those is a filesystem or presentation problem, not a network one, and each is what §5.5 and §9.5 address.

#### 5.5.1 What moves, and what deliberately does not

**Moves into the OS credential store:** the AAP admin password (cached for `Copy Admin Password`, §10.6.3), the AO credentials `cmd_status` prints today (`aap-demo.sh:1846–1859`), the portal addon's OAuth access and refresh tokens (`~/.aap-demo/portal/` today), the Galaxy token and the PAH token (`GALAXY_TOKEN_FILE` / `PAH_CONFIG_FILE` today), the `apme-eap` GitHub token (ADR-019's credential store), the ATF vault password, and the GUI/extension backend session token (§11.3).

**Stays a file, for a mechanical reason rather than an exception to the rule:** the kubeconfig, the Red Hat pull secret, and the `apme-eap` SSH private key. All three are consumed by *other programs* — `oc`, `kubectl`, `crc`, `ssh` — that take a **path**, not a string. A keyring entry cannot be handed to `KUBECONFIG=` or to `ssh -i`. These keep mode 0600 and the §5.2 state-dir treatment, and the pull secret keeps its legacy read paths because users hand-place it. Writing this down matters: without it, the next reader assumes the rule was forgotten rather than bounded.

#### 5.5.2 The mechanism

**`keyring`** (pure Python, no compiled extension) with its default per-OS backends: **macOS Keychain**, **Windows Credential Manager**, and on Linux the **Secret Service** API via `keyring.backends.SecretService` (gnome-keyring, KWallet, or any other Secret Service provider).

```python
# core/secrets.py — the only module in the package that touches the keyring

SERVICE = "aap-demo"                       # keyring "service"; entries are keyed <service>/<name>

class SecretStore:
    def get(self, name: str) -> str | None: ...
    def set(self, name: str, value: str) -> None: ...
    def delete(self, name: str) -> None: ...
    def list(self) -> list[SecretRef]: ...     # names + which backend, NEVER values
    def scoped(self, addon: str) -> "SecretStore": ...   # prefixes names with "addon:<name>:"
```

Naming convention, so entries are legible in Keychain Access and `secret-tool` and so an uninstall can find them all: `aap-demo` as the service, and the account name is `<namespace>:<kind>` for cluster-scoped secrets (`aap-operator:admin-password`) and `addon:<addon>:<kind>` for addon-scoped ones (`addon:portal:oauth-refresh-token`).

**Where it plugs in.** `ctx.secrets` sits alongside the existing `ctx.config` and `ctx.infra` accessors on `AddonContext` (§4.2) and on `AppContext` (§2.1). An addon calls `ctx.secrets.set("oauth-refresh-token", tok)` and gets an automatically addon-scoped entry; it never sees the service name, never picks a key format, and never has a reason to open a file. `SecretStore` is also the natural test seam — an in-memory implementation for unit tests, exactly like `FakeRunner` and the `Console` sink (§7.2), so no test ever touches a real keyring.

**A new CLI surface, small:** `aap-demo config secrets list` (names and backend, never values), `config secrets set <name>` (reads from a TTY prompt or stdin — **never** an argv value, which would land in shell history), `config secrets delete <name>`, and `config secrets migrate` (the one-time import from the legacy files, also run automatically by §12.2's migration). `secrets list` is what makes the store inspectable without making it readable.

#### 5.5.3 The Linux problem, and the recommendation

`keyring` on Linux needs a **Secret Service provider**, which is a desktop-session thing. A headless RHEL box over SSH, a container, or a CI runner has no `gnome-keyring` and no D-Bus session, so `keyring.get_keyring()` resolves to `keyring.backends.fail.Keyring` and every operation raises. This is a real and common shape for this tool — RHEL 9 is a primary target (§8.1) and plenty of that usage is over SSH.

Two options were weighed:

| Option | Assessment |
|---|---|
| **Hard-require a working backend; fail loudly with an actionable message** | Simple, honest, and impossible to get subtly wrong. The cost is that a headless RHEL user cannot use any feature that stores a credential until they install and unlock a keyring — which, on a server, may not be a thing they can do at all. |
| **Encrypted-file fallback** (e.g. `keyrings.cryptfile`, or our own `cryptography`-backed file keyed by a machine-derived value) | Keeps headless working. But a "system-derived key" sitting on the same filesystem as the ciphertext is obfuscation, not encryption — anyone who can read the file can derive the key. The honest version requires a **user-supplied passphrase**, which means prompting on every invocation or holding an agent, both of which are their own projects. And this is precisely the mechanism that silently degrades back into "secrets in a file" the moment someone makes the passphrase optional "just for CI". |

**Recommendation: hard-require a backend, with two narrow, explicit escapes.**

1. **Default (`secrets.backend: auto`):** resolve the OS keyring at first credential access. If the resolved backend is `fail.Keyring`, **exit 3 with a specific message** naming the platform and the fix — on Linux, "install and start a Secret Service provider (`gnome-keyring`, `kwallet`), or see the headless guidance in the docs". Never a warning-and-continue, and never an automatic fallback to a file: the failure must be loud, because the failure mode of getting this wrong is a plaintext credential nobody knows about (R30).
2. **Escape 1 — `secrets.backend: keyring` with an explicit `KEYRING_BACKEND`.** `keyring` already supports selecting a backend by env var, so a user who has installed `keyrings.cryptfile` and understands the passphrase tradeoff can point us at it. We do not ship it, do not recommend it, and do not test it; we simply do not block it. This keeps the "encrypted file" option available to someone who has actually thought about it, without us shipping the version that rots.
3. **Escape 2 — no credential storage at all.** Every command that does not need a credential must keep working with no backend present. A headless user running `create`, `deploy`, `status`, `diagnose`, and `playbooks run` should never hit the keyring; only `setup-pah`, `apme-eap`, `portal`, and the credential-display paths do. The implementation rule is therefore **lazy resolution — never resolve the keyring at startup**, only at first `SecretStore` access. Getting this wrong turns a keyring-less machine into a machine where `aap-demo status` fails, which would be a self-inflicted regression.

The residual judgment call — whether escape 2's coverage is wide enough that hard-requiring is genuinely acceptable for headless RHEL, or whether a supported encrypted-file mode has to exist — is recorded as **§13 Q30** rather than declared closed, because it depends on how many headless users actually need `setup-pah`, which nobody currently knows.

#### 5.5.4 Consistency with the Podman Desktop channel (§11.7)

§11.7 already decided that the extension puts its own secrets in Podman Desktop's `extensionContext.secrets` (`SecretStorage`), and separately that `registry.redhat.io` authentication is the **Red Hat Account extension's** business, not ours. Both remain correct and neither conflicts with this section, but the boundary is worth stating explicitly because it is easy to misread:

- **The Red Hat Account extension's token storage is a separate, already-secure mechanism** belonging to that extension and to that channel. We consume what it and CRC have already arranged (the pull secret path, §11.7 part 2); we store nothing on its behalf and we do not mirror its tokens into our keyring.
- **aap-demo's own credentials use `keyring`, uniformly, across all three channels.** The CLI, the standalone GUI, the desktop app, and the extension all run the **same FastAPI backend and the same `core/secrets.py`** — so the admin password stored during a deploy run from Podman Desktop is the same keyring entry the CLI reads afterwards. Two stores for one credential would be a bug, not a feature.
- The one thing that legitimately belongs in Podman Desktop's `SecretStorage` is the **extension-to-backend session token** (§11.3) — a value that exists only for the lifetime of that extension's backend process and means nothing to the CLI. §11.7's third clause should be read as scoped to that, and its aside that OS-native storage "does not generalize" to the pip and installer channels is **superseded by this section**: it generalizes now, and `keyring` is how.

---

## 6. Cross-platform strategy

### 6.1 Principle

One code path everywhere; platform dispatch only where the OS genuinely differs. Concretely, `subprocess` calls to `oc`/`kubectl`/`crc`/`helm`/`operator-sdk`/`ssh` are **identical** on all three platforms — they are all cross-platform binaries and `exec/runner.py` never uses `shell=True`, so no quoting divergence arises. The genuinely divergent surface is small:

| Divergence | Module | Detail |
|---|---|---|
| Ingress CA trust store | `trust/stores/{macos,linux,windows,nss}.py` | §6.2 |
| Host resource detection | `platform/posix.py` / `platform/windows.py` | Today: `sysctl -n hw.ncpu`/`hw.memsize` on Darwin, `nproc`/`/proc/meminfo` on Linux (`includes/crc-create.sh:41–56`). Windows: `os.cpu_count()` + `GlobalMemoryStatusEx`/`psutil`-free WMI-lite. Note `os.cpu_count()` works everywhere and could replace the CPU branch entirely. |
| CRC daemon management | `infra/crc.py` | `includes/crc-create.sh:167–177` starts `crc daemon` on Linux only; macOS/Windows manage it themselves. Existing bash already has an `_is_mingw()` probe (`crc-create.sh:168`) — formalize as `Platform.WINDOWS`. |
| CRC hypervisor | `infra/crc.py` | Hyper-V on Windows vs. KVM/libvirt (Linux) / vfkit-HyperKit (macOS). Affects prerequisite messaging and the "is virtualization available" preflight, not the command surface. |
| Privilege escalation | `platform/*.py` | POSIX: `sudo`. Windows: no `sudo`; elevation is `Start-Process -Verb RunAs` / an `IsUserAnAdmin` check. `trust/stores/windows.py` is the only caller. |
| `/etc/resolver/testing` removal | `platform/posix.py` | macOS-only MicroShift-preset bug workaround (`aap-demo.sh:1973–1976`, `crc-create.sh:336–343`). No-op elsewhere. |
| Paths | `core/paths.py` | `platformdirs` resolves the native config/cache/state roots per OS (§5.2), including `%APPDATA%`/`%LOCALAPPDATA%` on Windows. All path building via `pathlib`; **no** string concatenation with `/`. `tests/unit/test_paths.py` runs on all three OS runners and asserts the classification, not the literal strings. |
| Interactive `ssh` | `exec/ssh.py` | `cmd_ssh` uses `exec ssh …` (`aap-demo.sh:1596`). Python: `os.execvp` on POSIX; `subprocess.run` + `sys.exit(rc)` on Windows (no `execvp` semantics). OpenSSH ships with Windows 10+; if absent, error with the `Add-WindowsCapability` hint. |
| File permissions | `core/paths.py` | `chmod 600` on kubeconfig/inventory (`aap-demo.sh:1633,1677`, `_run_atf` umask 077). On Windows `chmod` is near-meaningless — use an ACL helper or, minimally, document it and still create files with restrictive `os.open` flags. |
| Terminal/TTY | `core/console.py` | `[ -t 0 ]` checks (`aap-demo.sh:2799`, `1394`, `697`) → `sys.stdin.isatty()`. `tput lines` (`aap-demo.sh:1396`) → `shutil.get_terminal_size()`. Color/UTF-8 glyphs: Click handles Windows console color; fall back to ASCII markers when the code page can't encode `✓/✗/⚠/·`. |
| `read -t 10` timed prompt | `core/prompts.py` | POSIX uses `select` on stdin; Windows needs `msvcrt.kbhit` polling or a watchdog thread. Isolate in one function — see §14 R4. |

Everything else — YAML rendering, jsonpath extraction, base64 decode of admin passwords, RSS parsing, timing loops — becomes platform-neutral Python and **stops shelling out to `python3 -c`, `jq`, `sed`, `awk`, `grep`, `base64`, and `tr`**, which is where most of today's Windows-parity pain comes from. Note the current script already depends on `python3` at runtime in six places (e.g. `aap-demo.sh:625`, `1036`, `1044`, `2093`, `2294`, `infra-crc.sh:98`) — the rewrite makes that dependency the *only* one.

### 6.2 Trust module design (ADR-015 preserved exactly)

```python
class TrustStore(ABC):
    def installed_fingerprint(self) -> str | None: ...
    def install(self, pem: Path) -> bool: ...
    def purge(self) -> None: ...
    @property
    def requires_elevation(self) -> bool: ...
```

Implementations and their current bash/PowerShell sources:

| Store | Source today | Behavior to preserve |
|---|---|---|
| `MacosKeychainStore` | `ingress-ca-trust.sh:57,311,328` | `security find-certificate -a -p -c ingress-ca /Library/Keychains/System.keychain`; delete stale in a loop; `sudo security add-trusted-cert -d -r trustRoot`. |
| `LinuxAnchorStore` | `ingress-ca-trust.sh:45,243` | RHEL anchor `/etc/pki/ca-trust/source/anchors/crc-ingress-ca.crt`, Debian `/usr/local/share/ca-certificates/`, then `sudo update-ca-trust`. |
| `NssStore` | `ingress-ca-trust.sh:91–137,265–309` | `~/.pki/nssdb` and `~/.local/share/pki/nssdb` (Chromium M146+); `certutil -d sql:… -A -t "C,," -n crc-ingress-ca`. Delete-then-add for staleness. |
| `WindowsStore` | `powershell/native/Private/Helpers.ps1::Import-AapIngressCaCertificate` (per ADR-015) | SHA-1 thumbprint compare; purge stale `CN=ingress-ca` from CurrentUser **and** LocalMachine; import to CurrentUser Root (never needs elevation); best-effort LocalMachine via `certutil -addstore` with UAC — required for Chrome/Edge. Failures warn, never abort `status`. |

The `CURL_CA_BUNDLE`/`SSL_CERT_FILE` policy from `_ingress_ca_export_env` (`ingress-ca-trust.sh:180–212`) must be ported **verbatim in behavior** — this is the fix from PR #105 ("do not replace curl CA store with ingress CA"), the most recent commit on `main`:

- CA already in the OS store → **unset** both vars.
- Not in the store, a system bundle exists → write the combined bundle to `~/.aap-demo/ca-bundle.crt` and point both vars at it.
- No system bundle → standalone PEM **with a warning**.

A regression here breaks public HTTPS during OLM install. `tests/unit/test_trust_bundle.py` should encode all three branches (today's `test/test-ingress-ca-export.sh`, 107 lines, is the reference).

Also note `AAP_DEMO_TRUST_CA=false` skips all automatic import (ADR-010/015) — keep it.

### 6.3 Retiring PowerShell

`powershell/native/Private/Commands.ps1` alone defines 16 `Invoke-AapDemo*` functions plus **two** definitions of `Write-AapClusterSummary` (lines 63 and 486 — a live symptom of drift). ADR-010's parity table lists five gaps: `diagnose --ai`, `enable portal`, `test`, `watch`, and general Git Bash delegation. All five disappear by construction, because there is one implementation.

Rollout for Windows users:

1. `pip install aap-demo` (or `pipx`) — the whole install story; `powershell/install.ps1`'s winget-based `oc` install becomes a preflight *check* with an install hint, not an action (§13 Q6).
2. `powershell/` is deleted from the repo in the same release the Python CLI reaches parity. Keep the ADR-010 file as a historical record and add ADR-023 superseding it.
3. Windows CI: a `windows-latest` GitHub Actions job running the unit suite (no cluster) validates the platform-dispatch branches; `trust/stores/windows.py` gets a mocked `certutil` runner test, and `tests/unit/test_paths.py` runs on all three OSes to catch path assumptions. Real Windows CRC/Hyper-V validation is manual or a self-hosted runner — out of scope here, but the pytest `integration` marker (§7.3) is the seam it plugs into.

---

## 7. Testing strategy

### 7.1 Layout

```text
tests/
  conftest.py                 # shared fixtures: fake_runner, tmp_home, app_ctx, fake_cluster
  fixtures/
    crc/status_running.json   # real `crc status -o json` captures
    kubectl/get_pods_*.txt
    kubectl/get_aap_*.json
    certs/ingress-ca.pem
  unit/
    test_cli_surface.py       # every command exists, help renders, aliases resolve
    test_arg_parsing.py       # ports test/test-aap-demo.sh assertions
    test_config_store.py      # config.yaml round-trip, header regeneration, addons dedupe/alias
    test_secrets.py           # SecretStore scoping, no-backend hard failure, lazy resolution (§5.5)
    test_yaml_loader.py       # asserts the pure-Python SafeLoader is in use, not CSafeLoader (§5.1)
    test_migration.py         # legacy KEY=VALUE -> YAML + path relocation, over fixtures/legacy_home/ (§12.2)
    test_schema_parity.py     # every schema property -> CLI flag + config key; no hand-written
                              #   arguments outside the allowlist (§9.3, R17)
    test_day2_catalog.py      # manifest.yaml validation, requires + preset gating, navigator argv (§4.8.7)
    test_gui_api.py           # httpx.ASGITransport over the FastAPI app with FakeRunner (§9.4)
    test_sse_stream.py        # SSE framing, Last-Event-ID backfill, ring-buffer gap handling (§9.4, R15)
    test_paths.py             # runs on macos/linux/windows runners
    test_crc_version_check.py # ports test/test-crc-version-check.sh
    test_trust_bundle.py      # ports test/test-ingress-ca-export.sh (3 branches)
    test_scc.py               # oc path + kubectl CRB fallback
    test_namespace.py         # terminating-namespace force-clear
    test_diagnose_checks.py   # each Check against fixture cluster states
    test_destructive_guards.py# destroy/clean/redeploy-all confirmation, QUIET bypass
    test_addon_registry.py    # discovery, aliases, collisions, broken-plugin isolation
    test_addon_contract.py    # parameterized over every registered addon
  integration/                # @pytest.mark.integration — real cluster
    test_create_deploy.py
    test_addon_enable_disable.py
  slow/                       # @pytest.mark.slow — network but no cluster (redhat-status RSS)
```

### 7.2 The mocking seam

Everything funnels through `CommandRunner`:

```python
class CommandRunner(Protocol):
    def run(self, argv: Sequence[str], *, input: str | None = None,
            timeout: float | None = None, env: Mapping[str, str] | None = None,
            check: bool = False, capture: bool = True) -> CompletedCommand: ...
```

`FakeRunner` is registered with `(argv-prefix-pattern) -> CompletedCommand | Callable | Exception`, records every invocation in order, and **fails the test on any unmatched invocation**. That last property is the whole point: it makes "did we call `oc adm policy add-scc-to-group anyuid system:serviceaccounts:aap-operator` before the first pod-creating apply?" a one-line assertion, which is exactly the SCC-grant-timing class of bug ADR-010 flagged as a drift risk.

A `FakeCluster` fixture layers on top: a dict-backed model of namespaces/pods/PVCs/CRs that answers `kubectl get -o jsonpath=…` from fixture data, so `diagnose` and `status` can be tested against dozens of cluster states (no NFS SC, pending PVC, gateway missing `supplementalGroups`, AAP idle, CatalogSource `TRANSIENT_FAILURE`) without a cluster. Each state in `docs/adr` and in `.claude/CLAUDE.md`'s "Common Issues" section becomes a fixture + a test.

Also mock at these seams: `Console` (capture output for assertions instead of grepping stdout), `Clock` (inject sleep/deadline so the 60-minute `watch_aap` loop and the 10-minute CSV wait run instantly), and `Prompt` (scripted answers for the `read -t 10` confirmations).

### 7.3 Markers

```toml
[tool.pytest.ini_options]
markers = [
  "integration: requires a real CRC cluster; destructive; not run in PR CI",
  "slow: hits the network (Red Hat status RSS, GitHub releases)",
  "windows_only: platform-specific trust store paths",
  "posix_only: sudo / resolver / execvp paths",
]
addopts = "-m 'not integration and not slow'"
```

PR CI runs the default selection (target: < 30 s, ADR-014's "< 1 minute" property preserved and improved). The parallel real-deployment initiative runs `pytest -m integration` on a runner that has CRC and a pull secret; because integration tests use the *same* `AppContext` with a real `SubprocessRunner`, no test code is duplicated between tiers. Integration tests must be `--namespace`-parameterized and must not assume they own the cluster.

### 7.4 Mapping the existing bash tests

| Current assertion (from `test/README.md`, `test/test-core-commands.sh`, ADR-014) | New test |
|---|---|
| `status` runs and prints "AAP Demo Status", "Infra:", "Cluster:" | `test_cli_surface.py::test_status_sections` — asserts on a structured `StatusReport`, not on a banner string |
| `stop` invokes `crc stop` (mocked via a `PATH` shim script at `test/mocks/crc`) | `test_lifecycle.py::test_stop_calls_crc` — `FakeRunner` assertion; the PATH-shim hack disappears |
| `help`/`-h`/`--help` render usage; no args → welcome | `test_cli_surface.py` |
| `NAMESPACE`/`QUIET`/`FORCE` env parsing | `test_arg_parsing.py` |
| `--context=NAME` and `--context NAME` both parse | `test_arg_parsing.py` (framework-native, but keep the test) |
| unknown command / unknown addon errors | `test_cli_surface.py`, `test_addon_registry.py` |
| `idle notabool` errors | `test_ops.py::test_idle_rejects_non_bool` |
| `diagnose` runs with no cluster | `test_diagnose_checks.py::test_no_cluster_state` |
| `destroy`/`clean` print warnings (grep-only, never executed) | `test_destructive_guards.py` — now actually *executes* the code path with a `FakeRunner`, asserting no destructive command is issued when the prompt is declined |
| CRC version check (`test/test-crc-version-check.sh`, 197 L) | `test_crc_version_check.py` |
| Ingress CA export (`test/test-ingress-ca-export.sh`, 107 L) | `test_trust_bundle.py` |

Net effect: every assertion survives, the brittle "grep the wording" coupling ADR-014 flagged as *Negative* is gone, and the deploy logic ADR-014 admitted it "does not catch regressions in" becomes reachable.

### 7.5 Addon contract test

`tests/unit/test_addon_contract.py` is parameterized over every discovered addon and asserts: manifest validates; `enable` is idempotent (running twice yields the same fake-cluster state and issues no destructive command on the second run — ADR-008 design rule 4); `disable` only touches resources the addon created; `status` returns without a cluster; declared `requires_tools` are actually checked in `preflight`. Third-party addon authors import this module and run it against their own addon — that is how the core team keeps quality without reviewing community PRs.

---

## 8. Packaging and versioning

### 8.1 `pyproject.toml` shape

```toml
[build-system]
requires = ["hatchling"]              # simple, no setup.py; setuptools is an equally fine choice
build-backend = "hatchling.build"

[project]
name = "aap-demo"
description = "Deploy Ansible Automation Platform 2.7 to OpenShift Local (MicroShift or OpenShift preset)"
requires-python = ">=3.9"             # DECIDED — RHEL 9's system python3 is the real floor (§13 Q8)
dynamic = ["version"]                 # sourced from src/aap_demo/__init__.py
dependencies = [
  # CLI parsing is stdlib argparse (§3.1) — no Click, no Typer.
  "pyyaml>=6.0",                      # config, manifests, --output yaml. PURE-PYTHON MODE ONLY:
                                      #   never CSafeLoader/CSafeDumper, so no C extension and no
                                      #   compiler is ever required to install (§5.1).
  "jsonschema>=4.0",                  # schema validation for config, addon and playbook manifests
                                      #   (§9.3). Same choice ansible-navigator makes.
  "keyring>=24.0",                    # OS-native credential storage (§5.5). Pure Python; its
                                      #   backends are OS APIs, not compiled deps of ours.
  "platformdirs>=4.0",                # native per-OS config/cache/state dirs (§5.2)
  "argcomplete>=3.0",                 # bash/zsh completion over the argparse parser (§3.1)
  "ruamel.yaml>=0.18",                # CR round-trip editing only (§5.4, §14 R6) — pending Q14
]

[project.optional-dependencies]
gui     = ["fastapi>=0.110", "uvicorn>=0.29"]   # §9; the SPA bundle itself is package data, see §9.6
desktop = ["aap-demo[gui]", "toga>=0.4.7"]      # §10 — tray icon + webview shell; what the
                                                #   frozen installer installs into its bundle
demos   = ["aap-demo-portal", "aap-demo-mcp-server", "aap-demo-ao",
           "aap-demo-apme-eap", "aap-demo-product-demos"]     # tier 2 (§4.5)
all     = ["aap-demo[gui,desktop,demos]"]
dev    = ["pytest>=8", "pytest-cov", "pytest-asyncio", "httpx", "mypy", "ruff", "commitizen"]

[project.scripts]
aap-demo = "aap_demo.cli.main:main"

[project.entry-points."aap_demo.addons"]
olm = "aap_demo.addons.builtin.olm:OlmAddon"          # tier 1, hidden/non-removable
setup-pah = "aap_demo.addons.builtin.setup_pah:SetupPahAddon"

[tool.hatch.build.targets.wheel]
packages = ["src/aap_demo"]

[tool.briefcase]                      # §10.2 — the native installer channel; same package, no fork
project_name = "aap-demo"
bundle = "com.redhat"
version = "2.0.0"                     # kept in lockstep by [tool.commitizen].version_files below

[tool.briefcase.app.aap-demo]
formal_name = "AAP Demo"
sources = ["src/aap_demo"]
requires = ["aap-demo[gui,desktop,demos]"]   # pip-installed INTO the bundle — this is what
                                             #   preserves .dist-info entry points (§10.2 reason 1)
console_app = false

[tool.commitizen]                     # UNCHANGED from today's pyproject.toml, plus one addition
name = "cz_conventional_commits"
tag_format = "v$version"
version_scheme = "semver"
version_provider = "commitizen"
update_changelog_on_bump = false
version_files = [
  ["VERSION", ""],
  ["src/aap_demo/__init__.py:__version__"],   # NEW — keeps the package version in lockstep
  ["pyproject.toml:^version"],                # NEW — [tool.briefcase].version, so the installer
]                                             #   can never ship a version the wheel does not (§10.11)
bump_message = "chore: bump version to $new_version"
```

Changes from **rev 2's** dependency list (which itself changed rev 1's), and why:

- **`click`, `typer`, and `pydantic` are all removed.** Rev 2 added Typer for the CLI and Pydantic as the schema source of truth. Both are superseded by §3.1 and §9.3: the CLI is stdlib `argparse` and the schema is plain JSON Schema validated by `jsonschema`, matching what `ansible-navigator` and `ansible-creator` actually do. Two useful side effects fall out of that and are worth naming rather than claiming as the reason: the base dependency count drops from seven to six *without* the compiled `pydantic-core`, so rev 2's "verify prebuilt wheels exist for the 3.9 floor on every target platform" implementation risk disappears entirely; and `core/console.py` stops depending on Click's `echo`/`style` (§3.1).
- **`pyyaml` is now a base dependency**, not the `[yaml]` extra — §5.1 makes YAML the config format, so the tool cannot start without it. Pure-Python mode only; the `[yaml]` extra is deleted and `--output yaml` needs no gate (§5.4).
- **`jsonschema` is new.** It validates the config file, the addon manifest (§4.3), and the playbook manifest (§4.8.3) against the same schema documents that generate the CLI arguments and the GUI forms (§9.3). Pure Python.
- **`keyring` is new** — §5.5. Pure Python; on each OS it calls that OS's own credential API. Note its Linux backend requirement, which §5.5.3 treats as a real constraint rather than a footnote.
- **`argcomplete` is new**, and exists only because dropping Click drops its completion generator (§3.1).
- **`tomli`/`tomlkit` are gone.** Nothing in the tool reads TOML any more except the build backend reading `pyproject.toml`, which is not our dependency.
- **`platformdirs`** — unchanged, §5.2.
- **`ruamel.yaml`** for CR round-tripping only (§5.4, §14 R6). Pending §13 Q14 — if the CR edits turn out to be expressible as `kubectl patch` calls instead, this dependency disappears entirely and should. If it stays, §5.1 notes it can also serve the config file's comment preservation.
- **Still excluded**: `kubernetes`/`openshift` client libraries (§13 Q4, now decided against), `ansible-runner`/`ansible-core` (§4.8.1 — we shell out to `ansible-navigator`), `rich`, `requests` (`urllib.request` covers the Red Hat status RSS and the ATF test-suite YAML fetch; `httpx` appears only in `dev` for testing the FastAPI app).

**Python 3.9 floor — decided, with a caveat that must be documented in the README, not just here.** RHEL 9 ships Python 3.9 as its system `python3`, and RHEL users are a primary audience who should not be asked to install a second Python; macOS and Windows users install Python independently and are unaffected by the floor. The caveat: **CPython 3.9 reached upstream end-of-life in October 2025.** For the life of this tool on RHEL 9, security patches for that interpreter come from Red Hat's own backports, not from upstream CPython. That is a defensible position on RHEL specifically — it is what RHEL's support model is for — but it is not a defensible position for a user running an unsupported 3.9 from python.org or Homebrew. The tool should therefore emit a one-line warning on a non-RHEL 3.9 interpreter, and the floor should be revisited when RHEL 10 (Python 3.12) becomes the common denominator. Practical consequences for the implementer: no `match` statements, no `X | Y` union syntax at runtime (use `from __future__ import annotations` plus `Optional`/`Union`), no `dict | dict` merge operator, and — a rev 2 consequence that **no longer applies** — no `tomllib` backport is needed, because §5.1 replaced TOML with YAML.

The `demos` extra is what "tier 2 first-party addons" (§4.5) means mechanically; `gui` is §9.6. Note the entry point is a plain `main()` function, not a framework app object — an `argparse` consequence, and one that makes `python -m aap_demo` and the console script the same code path.

### 8.2 Version, VERSION file, and tags

Current state: `VERSION` contains `1.0.5`; Commitizen's `version_provider = "commitizen"` reads it via `version_files`; `includes/aap-demo-version.sh` reads `VERSION` plus live `git rev-parse`/`git log` for build metadata; **the repo has zero git tags** despite `tag_format = "v$version"`.

Going forward:

- **`VERSION` stays** as the human-readable single source, and Commitizen keeps bumping it. Add `src/aap_demo/__init__.py:__version__` to `version_files` so one `cz bump` updates both. `pyproject` reads `dynamic = ["version"]` from `__init__.py` — nothing is hand-edited.
- **`cz bump` starts creating tags.** Because there are no tags today, the first bump needs a one-time reconciliation: tag the current `main` as `v1.0.5` retroactively, then `cz bump` from there. Conventional-commit history already exists (`.commitlintrc.json`, commits like `fix:`/`feat(ao):`), so changelog generation will work; `update_changelog_on_bump = false` means CHANGELOG stays manual unless the maintainers flip it.
- **Git build metadata** (`AAP_DEMO_GIT_SHA`, `GIT_DATE`, `GIT_BRANCH`, `GIT_REMOTE`, printed by `aap-demo version` and in the `status` header) is meaningful only from a checkout. For an installed wheel: report the package version plus the distribution's install location and, if built in CI, a build SHA baked into `__init__.py` at release time. `core/version.py` reports `source: <site-packages path>` instead of `AAP_DEMO_REPO_ROOT` when not in a git tree. Nothing should crash when `git` is absent — today's helper already falls back to `"unknown"`.
- **Version floor for the rewrite**: `2.0.0`. It is a breaking change (install method, dropped `--branch`, addon contract).

### 8.3 Distribution — **DECIDED: public PyPI** (§13 Q1)

`pip install aap-demo`. Tier-2 addon distributions (`aap-demo-portal`, `aap-demo-ao`, …) publish to PyPI as well, as does the EE image to a public registry. This is the best install UX and the one consistent with the "look like a real product" goal; it also means community addons have an obvious, working home.

Work items this decision creates, all of which must be handled before the first release:

1. **Claim the `aap-demo` name on PyPI** (and the `aap-demo-*` names for tier-2 distributions) before announcing anything. Verify availability early — it is a hard blocker on the release plan, not a formality.
2. **Audit for internal-only references before the first public upload.** Known: `cmd_test` fetches ATF content from `gitlab.cee.redhat.com` and uses `aapqa` collections (`aap-demo.sh:1340–1594`). A public wheel containing VPN-only URLs is not a leak, but it *is* a broken experience for every public user who runs `aap-demo test`. Options: keep `test` in the base wheel but have it fail with an explicit "this requires Red Hat internal network access" message, or move it behind an `[internal]` extra. Recommend the former — the message is more discoverable than a missing command. Anything that is genuinely confidential must not ship at all; that audit is a release-gate checklist item, not an implementation detail.
3. **Trusted publishing from CI** (PyPI OIDC) rather than a long-lived API token in repo secrets.
4. **Set up the release job to build the GUI bundle before the wheel** (§9.6) — the wheel must never be built from a working tree with a stale or missing `gui/static/`.

PyPI is now **one of three channels, not the only one**. The signed native installers for macOS and Windows (§10) ship the same wheel to a non-technical audience that cannot use pip at all, and the Podman Desktop extension (§11) surfaces the same backend inside a tool the technical-operator tier already runs. See §10.1 for the split and §10.11 / §11.9 for what that does to the release pipeline. Note that the PyPI channel is load-bearing for the other two: the extension **installs the wheel from PyPI** (§11.4), so anything that breaks the public wheel breaks the extension channel too.

---

## 9. Web GUI — new

### 9.0 Requirement and toolchain decision

The requirement, from the maintainer: *"the visual presentation is everything for the audience we're designing this for… I don't want to rely on just the cli… create a web-gui wizard styled with PatternFly 6 to look like an official AAP/Red Hat tool and simply give users a way to click through the options they want to deploy. This would all be leveraging the same python configuration system underneath that the cli is using… I want everything configurable via the GUI to have full parity with the CLI, and vice versa. I want addon and day-2 operation management in the GUI too, plus a status page equivalent of `aap-demo status`."*

Toolchain, **decided**: a **prebuilt PatternFly 6 React SPA, bundled as static assets in the Python wheel**, served by a small **FastAPI** app that exposes a JSON API over the same `core/` the CLI uses.

Alternatives rejected, recorded so this is not relitigated:

| Option | Verdict |
|---|---|
| (a) Server-rendered Jinja2 + PatternFly CSS, no Node anywhere | Rejected. Keeps the single-toolchain story but produces weaker fidelity, and several PatternFly components (Wizard, DataList with expandable rows, the drawer/notification patterns, Table with sortable/selectable state) assume React state management. Reimplementing them in CSS-plus-vanilla-JS is how a page stops looking like an official Red Hat tool. |
| (b) **Prebuilt React SPA in the wheel** | **Chosen.** Node/npm is needed only by maintainers and release engineers building the bundle as part of the release process. End users `pip install "aap-demo[gui]"` and never see a `package.json`. |
| (c) Full React dev workflow exposed to all contributors | Rejected. Breaks the single-Python-toolchain story the rest of this rewrite optimizes for. A Python contributor fixing a `status` bug must not need `npm ci`. |

The (b) compromise has a real cost, stated plainly: the frontend and backend are versioned together but built separately, which creates a skew failure mode (§14 R14) and a bus-factor concern (whoever can build the bundle gates GUI releases). Both are mitigated in §9.6, not wished away.

### 9.1 Backend architecture

```text
src/aap_demo/gui/
  __init__.py        # create_app() with a lazy-import guard:
                     #   ImportError -> "GUI requires: pip install 'aap-demo[gui]'"
  app.py             # FastAPI factory: routers, static mount, SPA fallback, lifespan
  deps.py            # FastAPI dependency providing the SAME AppContext the CLI builds
  jobs.py            # JobManager: long-running work + streamed output (§9.4)
  api/
    schema.py        # GET /api/schema
    config.py        # GET/PUT /api/config
    lifecycle.py     # deploy wizard: preflight, plan, start
    addons.py        # list/enable/disable/configure
    day2.py          # playbooks list/info/run/configure/update
    status.py        # status + diagnose
    secrets.py       # §9.5 — reveal/copy actions ONLY; never part of the status payload
    jobs.py          # job list, job detail, SSE stream, cancel
  static/            # built SPA (§9.6)
```

**The rule that keeps this from becoming a second implementation:** every route body is at most (1) parse/validate the request into a schema model, (2) call one function in `core/`, `cluster/`, `addons/`, or `day2/`, (3) return its result model. If a route needs three steps of orchestration, that orchestration belongs in the core package where the CLI can call it too. `gui/` is on the same footing as `cli/` — both are adapters, neither is the product.

Concretely, `cli/lifecycle.py::deploy` and `api/lifecycle.py::start_deploy` both call `cluster.deploy.run(ctx, plan)`. The CLI renders its progress events to a terminal; the GUI pushes the same events onto an SSE stream. The *event stream itself* is a core concept, not a GUI one — see §9.4.

**AppContext construction.** `gui/deps.py` builds an `AppContext` per request from the same config resolution as the CLI (§5.3), with `console` bound to a collecting sink rather than stdout. This is the same substitution the tests already make (§7.2's `Console` mock), so it is a seam that exists for two reasons instead of one.

#### JSON API surface

All paths under `/api`. Request and response bodies are validated against the **same JSON Schema documents** in `core/schema.py` that generate the CLI arguments — the API schema and the config schema are the same schema (§9.3). FastAPI's own Pydantic-based request modelling is deliberately **not** used for these bodies: routes take a `dict` and call `jsonschema.validate` against the shared document, so there is exactly one definition of a field and no second modelling layer to drift from it. (FastAPI still depends on Pydantic internally — that is its business, not a schema source of ours, and it is why `pydantic` leaves §8.1's *base* dependency list but not the `[gui]` extra's transitive set.) Response bodies are the same result dataclasses `core/output.py` renders.

| Method + path | Purpose | Backed by |
|---|---|---|
| `GET /api/schema` | Full JSON Schema for config, addon options, playbook variables, and command arguments (§9.3) | `core/schema.py` |
| `GET /api/config` / `PUT /api/config` | Read/write `config.yaml`; PUT validates against the schema and returns field-level errors | `core/config.py` |
| `GET /api/status` | Everything `aap-demo status` prints, structured (§9.5) | `cli`-free `observe.status_report(ctx)` |
| `GET /api/diagnose` | Check list with id, severity, message, fix hint | `diagnostics/checks.py` |
| `GET /api/cluster` | Cluster state, VM stats, preset, CRC version | `infra/` |
| `GET /api/addons` | All discovered addons: manifest, enabled state, `status()` result, tier | `addons/registry.py` |
| `POST /api/addons/{name}/enable` / `/disable` | Starts a job; returns `{job_id}` | `addons/registry.py` |
| `GET /api/addons/{name}/schema` | The addon's own option schema, for its config form | `AddonManifest` |
| `GET /api/playbooks` / `GET /api/playbooks/{name}` | Day-2 catalog and one manifest, filtered to the live CRC preset (§4.8.3) | `day2/catalog.py` |
| `GET /api/playbooks/{name}/schema` | JSON Schema for that playbook's `vars`, for its run form | `day2/manifest.py` |
| `POST /api/playbooks/{name}/run` | Starts a playbook job; returns `{job_id}` | `day2/navigator.py` |
| `GET /api/playbooks/runs` | Run history: name, started/finished, exit status, job id | `gui/jobs.py` + `<state>/gui-jobs/` |
| `POST /api/playbooks/update` | Fetch/pin the playbooks repo checkout; returns `{job_id}` | `day2/repo.py` |
| `GET /api/secrets` | **Names only** — which credentials exist and which backend holds them. Never a value (§5.5, §9.5). | `core/secrets.py` |
| `POST /api/secrets/{name}/copy` | Copies one credential to the **OS clipboard, server-side**. Returns `{ok: true}` and no value (§9.5). | `core/secrets.py` |
| `POST /api/deploy/plan` | Dry-run: validates a wizard payload, returns the ordered step list and warnings, changes nothing | `cluster/bootstrap.py` step model |
| `POST /api/deploy` | Starts create/deploy; returns `{job_id}` | `cluster/` |
| `GET /api/jobs` / `GET /api/jobs/{id}` | Job registry and one job's metadata + buffered output | `gui/jobs.py` |
| `GET /api/jobs/{id}/events` | **SSE stream** of that job's events (§9.4) | `gui/jobs.py` |
| `POST /api/jobs/{id}/cancel` | Cooperative cancel | `gui/jobs.py` |
| `GET /api/version` | CLI version, GUI bundle version, schema version (skew check, §14 R14) | `core/version.py` |

Mutating endpoints all return a job id rather than blocking. There is exactly one long-running-work mechanism, and everything slow uses it.

### 9.2 Frontend architecture

A Vite + React + TypeScript SPA using `@patternfly/react-core` v6 (and `@patternfly/react-table`). Structure:

```text
frontend/src/
  main.tsx, App.tsx            # router + PatternFly Page/Masthead/Nav shell
  api/client.ts                # typed fetch wrappers; types generated from /api/schema
  api/useJobStream.ts          # EventSource hook (§9.4)
  schema/FormRenderer.tsx      # JSON Schema -> PatternFly Form (§9.3)
  pages/
    DeployWizard.tsx           # PatternFly <Wizard>
    Addons.tsx                 # DataList of addons, per-addon config drawer
    Playbooks.tsx              # day-2 playbooks: catalog, settings, run modal, history (§9.2a)
    Status.tsx                 # §9.5
    Jobs.tsx                   # running/recent jobs, reattachable output
    Settings.tsx               # raw config editor over /api/config
```

Routes: `/` (redirects to Status if a cluster exists, else Deploy Wizard), `/deploy`, `/addons`, `/playbooks`, `/status`, `/jobs`, `/settings`.

**Deploy Wizard** is the centerpiece and the reason the GUI exists. Steps, each generated from the schema rather than hand-built:

1. **Prerequisites** — read-only check list (crc, oc/kubectl, container engine, pull secret found, disk space, virtualization). Blocking failures disable Next and link to the fix.
2. **Cluster** — `crc.*` fields: cpus, memory, disk, PV size, and **preset as a real choice** — `microshift` or `openshift`. Rev 2 showed this control disabled with an ADR-020 tooltip; full OpenShift is back in scope (rev 5), but resequenced to phase 4b rather than shipping with v1 (rev 6) — so **until phase 4b lands, the field shows both options but `openshift` is disabled with a "coming soon" tooltip**, the same UI pattern as before with a different reason behind it. Once 4b ships, it becomes fully live, and it is the highest-consequence field on the page from that point on: it changes the resource minimums the step validates against, whether OLM is installed or skipped (§4.5), which day-2 playbooks are offered (§4.8.3's `presets`), and — per §14 R26, deferred to 4b alongside it — whether an existing CRC VM has to be recreated. Selecting a preset that differs from an already-created cluster's must surface that consequence in this step, not at deploy time.
3. **AAP** — `[deploy]` fields: namespace, channel, base domain, CR template choice, pull secret path.
4. **Addons** — checkbox list of tier-2 addons with per-addon option forms revealed on selection. **Tier-1 built-ins are not listed** (they are not optional) and **tier-3 day-2 operations are not listed** (§4.5's governing rule, enforced here in code by filtering on tier, not by remembering).
5. **Review** — the resolved plan from `POST /api/deploy/plan`, the exact equivalent CLI invocation (see below), and Deploy.
6. **Progress** — live streamed output (§9.4), which on completion links to Status.

**Show the equivalent CLI command on the Review step.** This is cheap (the schema already knows every field's CLI flag, §9.3) and it does three useful things: it teaches the CLI to GUI users, it makes demos reproducible in a terminal, and it is a continuous visible proof that parity holds — if the GUI can render a CLI command for every wizard state, the parity mechanism is working.

**Addon Management** page: DataList with name, summary, tier badge, version, source distribution, enabled state, and the addon's `status()` result. Enable/disable start jobs. Per-addon options render from `GET /api/addons/{name}/schema`. Addons that failed to load appear as a warning row (§4.1) rather than vanishing.

#### 9.2a Playbooks page — the day-2 surface, at the same level of detail as Addon Management

The maintainer's requirement is explicit and is not satisfied by the CLI alone: *"the addons and day 2 operations should also be configurable via the web gui… I think we should create the interface for others to create their own addons/plugins."* So the playbooks system is a **first-class GUI view**, not a link to a terminal, and it mirrors Addon Management feature for feature:

- **Catalog** — a DataList over `GET /api/playbooks`, grouped by the manifest's `tags`, each row showing name, summary, version, `estimated_minutes`, and `requires` badges (cluster / AAP / VM SSH / tools). Rows whose `requires` are unmet are **shown disabled with the reason on the badge** rather than hidden — the same rule §10.6.3 applies to tray items, and for the same reason: an absent row reads as a broken app, a disabled row teaches the prerequisite. Playbooks whose manifest `presets` excludes the live preset are filtered out server-side (§4.8.3), because that is not a prerequisite the user can satisfy without recreating the cluster.
- **Run** — a modal whose form is **generated from `GET /api/playbooks/{name}/schema`** by the same `FormRenderer` that renders addon options and wizard steps (§9.3). `destructive: true` requires a typed confirmation. `type: secret` vars render as a password field whose value goes straight to the keyring and is referenced by name in the run request — the plaintext never appears in the job payload (§5.5, §4.8.3).
- **Live output** — the run starts a job and streams into a drawer over the existing SSE mechanism (§9.4). No new transport, no polling: this is the fourth consumer of `core/events.py`, alongside the CLI console, the tray, and the extension.
- **Run history** — a table over `GET /api/playbooks/runs`: playbook, when, duration, exit status, and a link that re-opens the stored log from `<state>/gui-jobs/`. This is the piece the CLI genuinely cannot offer, and it is the reason an operator would prefer this page to a terminal.
- **Settings** — the `playbooks.*` config block (§5.3) edited in place through `PUT /api/config`: repo URL, pinned `ref`, EE image and tag, container engine, and the persisted per-playbook `vars` answers. A "Update playbooks" button calls `POST /api/playbooks/update` and shows the resolved ref afterwards, so pinning is visible rather than a file nobody opens.
- **Authoring** — the page links to the `playbooks create` scaffold docs and shows the manifest schema. Scaffolding itself stays a CLI action (§4.8.6): it writes into a git checkout the GUI has no business managing, and its output is a pull request, not a cluster change.

This page is visually distinct from Addons — different iconography, its own "Operations" nav section — because the audience must never confuse "content I am demoing" with "maintenance I am performing" (§4.5's governing rule, enforced in the layout as well as in the wizard's filtering).

**Desktop-channel note:** this whole view is absent from the desktop app's navigation per §10.9, and present in the Podman Desktop extension per §11.11. Its presence is a per-channel setting, not a per-user one.

### 9.3 The schema-driven parity mechanism

This is the load-bearing design in §9. ADR-010 already documents what happens without it: two surfaces "sharing behavior but not code", with a parity table that degrades over time. The requirement is that **adding a config field once makes it appear correctly in both the CLI and the GUI automatically** — not that someone remembers to update both.

**Single source of truth: JSON Schema documents in `core/schema.py` — revision 5, superseding rev 2's Pydantic models.**

Rev 2 made Pydantic models the source of truth, deriving CLI flags by introspecting the models and GUI forms from `model_json_schema()`. Rev 5 removes the middle step: **the JSON Schema *is* the artifact, hand-written and shipped as package data**, and both surfaces read it directly. This follows §3.1's ecosystem decision (`ansible-navigator` validates with `jsonschema`; neither it nor `ansible-creator` uses Pydantic), and it makes the mechanism simpler rather than merely different — the GUI's consumer is unchanged, because it was already consuming JSON Schema; only the thing that *produced* the schema goes away.

```yaml
# src/aap_demo/data/schema/crc.yaml — authored as YAML, served as JSON.
# YAML because a human maintains it (§5.1) and because comments are the field docs.
$schema: "https://json-schema.org/draft/2020-12/schema"
$id: "aap-demo/crc"
type: object
additionalProperties: false
title: Cluster
properties:
  cpus:
    type: integer
    minimum: 2
    maximum: 64
    default: 8
    title: CPUs
    description: vCPUs allocated to the OpenShift Local VM.
    x-cli: {flag: "--cpus"}            # argparse option string; defaults to --<kebab-cased key>
    x-env: CRC_CPUS                    # legacy env var (§3.2)
    x-config: crc.cpus                 # dotted path in config.yaml (§5.3)
    x-gui: {group: cluster, widget: number, step: 2}
    x-order: 10

  memory_mb:
    type: integer
    minimum: 8192
    default: 24576
    title: Memory (MB)
    x-cli: {flag: "--memory"}
    x-env: CRC_MEMORY
    x-config: crc.memory_mb
    x-gui: {group: cluster, widget: number, step: 1024}
    x-order: 20
```

The `x-*` keys are the same annotation vocabulary rev 2 defined; only their home changed (from `json_schema_extra` to the document itself), and one is renamed — `x-toml` → **`x-config`**, since the file is YAML now and the annotation was never really about the format.

**A note on how the documents are assembled.** Keep this at `ansible-creator`'s level of ceremony, not a framework's. `core/schema.py` loads the `data/schema/*.yaml` documents with `yaml.safe_load`, merges them into one root document under `properties`, and exposes three functions: `root()` (the whole thing), `section(name)`, and `validate(instance, section)` → `jsonschema.validate`. Addons and playbooks contribute their own documents at runtime through `arguments()` (§4.2) and the manifest's `vars` (§4.8.3), which are merged into the root under `addons.options.<name>` and `playbooks.vars.<name>`. There is **no schema builder DSL, no code generation, and no registry class** — a dict, a merge, and a validator.

Three consumers, all generated:

1. **Config file** — `core/config.py` loads `config.yaml`, merges it with env vars and CLI values per §5.3's resolution order, and validates the result with `jsonschema.validate` against the root document. Validation errors are per-property and identical whether they came from a file, a flag, or the GUI, because there is one validator call over the merged result rather than three. Report `jsonschema`'s `ValidationError.json_path` — "`crc.cpus`: 96 is greater than the maximum of 64" — not its default message.

2. **CLI** — `cli/_schema_args.py` walks a schema document's `properties` and calls `add_argument()`. This is the piece rev 2 got for free from Typer and now must exist, so here it is concretely; it is about sixty lines:

   ```python
   # cli/_schema_args.py
   _TYPES = {"string": str, "integer": int, "number": float}

   def add_schema_arguments(parser, doc, *, resolved):
       """Add one argparse argument per property in `doc`.
       `resolved` is the post-config-resolution value map, so --help shows
       the EFFECTIVE default rather than the schema default."""
       for key, prop in sorted(doc["properties"].items(),
                               key=lambda kv: kv[1].get("x-order", 1000)):
           if prop.get("x-cli") is False:          # config-only, no flag
               continue
           flag = (prop.get("x-cli") or {}).get("flag") or "--" + key.replace("_", "-")
           kwargs = {
               "dest":    key,
               "help":    prop.get("description"),
               "default": resolved.get(key, prop.get("default")),
           }
           if prop["type"] == "boolean":
               kwargs["action"] = "store_true" if not kwargs["default"] else "store_false"
           else:
               kwargs["type"]    = _TYPES[prop["type"]]
               kwargs["metavar"] = prop.get("x-gui", {}).get("widget", key).upper()
               if "enum" in prop:
                   kwargs["choices"] = prop["enum"]
           parser.add_argument(flag, **kwargs)
   ```

   Three deliberate omissions, each with a reason: **`minimum`/`maximum` are not turned into an `argparse` type-checker**, because the merged result is validated by `jsonschema` immediately afterwards and a second range check in a second place is exactly the drift this section exists to prevent — `argparse` handles *parsing*, `jsonschema` handles *validity*. **`required` is not enforced here** either, for the same reason: a value may arrive from config or an env var, so requiredness is a property of the resolved document, not of the command line. And **nested objects are not flattened into dotted flags** — a nested section gets its own document and its own `add_schema_arguments` call against the same parser, which is how `crc.*` and `deploy.*` both land on `aap-demo create`.

   A command wires it up explicitly, which is `ansible-creator`'s shape and reads better than a decorator:

   ```python
   p = subparsers.add_parser("create", parents=[global_parser], help="Create the local cluster")
   add_schema_arguments(p, schema.section("crc"), resolved=resolved["crc"])
   add_schema_arguments(p, schema.section("deploy"), resolved=resolved["deploy"])
   p.set_defaults(func=cli.lifecycle.create)
   ```

3. **GUI** — **unchanged from rev 2 except for what produces the document.** `GET /api/schema` serves the merged root document; `FormRenderer.tsx` maps schema `type` and `x-gui.widget` to PatternFly controls (`TextInput`, `NumberInput`, `Select`, `Switch`, `FormSelect`), groups by `x-gui.group`, orders by `x-order`, and renders `description` as `FormHelperText`. Validation keywords (`minimum`/`maximum`/`pattern`/`enum`) become client-side validation *and* are re-validated server-side by the same document — the client copy is UX, not enforcement. Rev 2's endpoint shape, renderer, and build-time type generation all survive intact; this is the point of choosing JSON Schema rather than some other source of truth.

**Delivery mechanism for the JSON Schema: both, deliberately.**

- A **build step** (`make schema`) merges `src/aap_demo/data/schema/*.yaml` into `frontend/src/schema/schema.json` and generates TypeScript types from it, so the frontend has compile-time types and CI fails on a mismatch. This step is now a YAML→JSON merge rather than a Pydantic export, which also means it runs without importing the package.
- A **live `GET /api/schema` endpoint** the SPA fetches at runtime, and which the renderer actually renders from. The build-time copy is for types and tests; the runtime copy is what the user sees. This matters because an installed third-party addon contributes schema the release-time build could not have known about — its option form must render without a frontend rebuild.

**The enforcement, without which this is just a convention (§14 R17):**

- `tests/unit/test_schema_parity.py` asserts, for every property in every schema document: a CLI flag exists and is reachable from `--help` (unless the property carries `x-cli: false`); its `x-config` path is unique and round-trips through `config.yaml`; and its `x-env` var, if declared, is honored by resolution. It also asserts each document is itself a valid JSON Schema (`jsonschema.Draft202012Validator.check_schema`), which is the check a hand-written schema needs and a generated one did not.
- The inverse check is the important one: it walks every subparser's `_actions` and fails on any argument that is not schema-derived and not on the allowlist of genuinely CLI-only options (`--output`, `--quiet`, `--yes`, `--config`, `--verbose`, plus `argparse`'s own `-h`). Adding a hand-written `add_argument()` breaks CI. Note this check is *easier* against `argparse` than it was against Typer: a parser's actions are introspectable at runtime with no framework knowledge, and each action carries the `dest` the test matches against the schema key.
- A corresponding frontend test asserts `FormRenderer` renders every field in the committed `schema.json` without falling through to an "unsupported widget" branch, so a new field type cannot silently render as nothing.

**Worked example: `CRC_CPUS`** — the same example rev 2 used, re-traced through the new path so the two designs are directly comparable. Today it is an environment variable read by `includes/crc-create.sh` (host-resource detection around lines 41–56) and documented in the §3.2 env table — nothing more. After the rewrite, the single `cpus` property in `data/schema/crc.yaml` above yields, with no further work:

| Surface | Path from the schema | Result |
|---|---|---|
| CLI flag | `schema.section("crc")` → `add_schema_arguments()` → `parser.add_argument("--cpus", type=int, default=8, help=…)` | `aap-demo create --cpus 12`, with `--help` reading "vCPUs allocated to the OpenShift Local VM. (default: 8)" |
| Legacy env var | `x-env: CRC_CPUS` read by `core/config.py`'s resolution | `CRC_CPUS=12 aap-demo create` still works |
| Config file | `x-config: crc.cpus` | `crc: {cpus: 12}` in `config.yaml`; `aap-demo config set crc.cpus 12` |
| Validation | `jsonschema.validate` over the **resolved** merged document | `--cpus 96` fails with "`crc.cpus`: 96 is greater than the maximum of 64" — identically whether 96 came from the flag, the env var, the file, or the API |
| GUI form field | `GET /api/schema` → `FormRenderer.tsx` reads `x-gui` | A PatternFly `NumberInput` labelled "CPUs", min 2 / max 64 / step 2, in the wizard's Cluster step, helper text from `description` |
| API | the same document | `{"crc": {"cpus": 12}}` accepted by `PUT /api/config` and `POST /api/deploy` |
| Review step | `x-cli.flag` | "Equivalent CLI: `aap-demo create --cpus 12`" |

Changing `maximum: 64` to `maximum: 96` changes the CLI validation, the config validation, the API validation, and the GUI's spinner bound in one edit — the same one-edit property rev 2's design had, reached without a modelling library.

### 9.4 SSE streaming design

**The core concept is an event stream, not an SSE stream.** Long-running core operations already need progress reporting for the CLI. Define it once:

```python
# core/events.py
@dataclass(frozen=True)
class Event:
    kind: Literal["step", "log", "progress", "warning", "error", "result"]
    ts: float
    seq: int                     # monotonic per job — the SSE event id (§reconnect below)
    step: str | None             # e.g. "grant-sccs", "wait-csv"
    text: str | None
    data: dict | None            # structured payload for kind="result"
```

Core functions take an `EventSink`. The CLI passes a sink that renders to the terminal via `core/console.py`. The GUI passes a sink that appends to a job's ring buffer and fans out to subscribers. Tests pass a sink that collects into a list and asserts on it. **This is the same shape as the `Console` and `CommandRunner` seams, so it costs nothing new conceptually.**

**Subprocess output → events.** `SubprocessRunner` grows a streaming mode: instead of `capture_output`, it reads the child's stdout/stderr line-by-line off a pipe and emits `kind="log"` events. This is what turns a 15-minute `ansible-navigator run` or `crc start` into live output. `ansible-navigator --mode stdout` writes plain lines, so no parsing is needed; if we later want per-task progress in the GUI, `--mode stdout` plus the `ansible.posix.jsonl` callback would give structured events without changing this design.

**Job lifecycle.** `POST` handlers create a `Job` (uuid, command descriptor, created-at, state) and run the core call in a worker thread (not an asyncio task — the core is synchronous and subprocess-bound; a thread with `run_in_threadpool` is the honest fit). The job keeps a bounded ring buffer of the last N events (N ≈ 5,000) plus the full log on disk under `<state>/gui-jobs/<id>.log`, so the buffer bound never loses the record.

**The SSE endpoint.**

```python
@router.get("/api/jobs/{job_id}/events")
async def events(job_id: str, request: Request, last_event_id: str | None = Header(None)):
    job = jobs.get(job_id)
    async def gen():
        for ev in job.replay_since(int(last_event_id or -1)):   # backfill first
            yield sse(ev)
        async for ev in job.subscribe():
            if await request.is_disconnected(): break
            yield sse(ev)
        yield sse(job.terminal_event())
    return StreamingResponse(gen(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})
```

Each frame carries `id: <seq>`, so the browser's `EventSource` automatically sends `Last-Event-ID` on reconnect and `replay_since` backfills the gap. **This is why events carry a monotonic `seq`** — reconnect correctness falls out of the design rather than being bolted on. Consequences:

- **Browser refresh mid-deploy is safe.** The SPA re-fetches `GET /api/jobs`, finds the running job, and re-subscribes from seq 0 (or from the last seq it had in `sessionStorage`). The deploy is running in the server process, not in the tab.
- **Network interruption is safe** for the same reason, within the ring-buffer window; beyond it, the client falls back to `GET /api/jobs/{id}` for the on-disk log and re-subscribes at the tail with a visible "some output was skipped" marker rather than silently lying.
- **Closing the browser does not cancel the deploy** — an explicit, documented choice. Cancellation is `POST /api/jobs/{id}/cancel` only. The alternative (cancel on disconnect) would make an accidental laptop-lid-close destroy a demo setup. In the desktop channel this becomes genuinely durable rather than merely tab-scoped, because the server is a long-lived tray application rather than a foreground process tied to a terminal — see §10.8, which is where §14 R16 is resolved.
- A **heartbeat comment frame** every 15 s keeps intermediaries and some browsers from timing the connection out during the long silent stretches of an image pull.

**Does SSE complicate the §7.2 testing seam? No — and this is worth being explicit about, because it is the kind of thing that quietly does.** The `FakeRunner` seam is unaffected: streaming is a mode of `SubprocessRunner`, and `FakeRunner` simply yields its scripted output as a sequence of log events. Three test layers:

1. **Core, no HTTP** — run a core operation with a collecting `EventSink` and assert the event sequence. This is where deploy-logic tests live, exactly as in §7.
2. **Job manager, no HTTP** — assert ring-buffer bounds, `replay_since` correctness across a simulated gap, terminal-event delivery, and cancel semantics. Pure unit tests.
3. **HTTP layer** — `httpx.ASGITransport` against the FastAPI app with a `FakeRunner`-backed context: assert that `POST /api/deploy` returns a job id, that the SSE stream yields the expected `id:`/`event:`/`data:` frames, and that a reconnect with `Last-Event-ID: 12` backfills from 13. No browser, no server process, no cluster; runs in the default pytest selection.

The one genuinely new risk is thread-safety of the job registry under concurrent subscribers — mitigated by keeping `Job` state behind a lock and having subscribers own their own `asyncio.Queue`.

### 9.5 Status page

Mirrors `cmd_status` (`aap-demo.sh:1685–1884`) section for section, reading `GET /api/status`. What that function actually prints today, and where it lands:

| `cmd_status` section (line) | GUI |
|---|---|
| Header, infra type, cluster state/name (1685–1700) | Masthead status chip: Running / Stopped / Not created, with the CRC preset. |
| "Start with: aap-demo create / crc start" hints (1707–1713) | An empty-state card with a **button** that starts the corresponding job — the wizard's entry point when nothing exists. |
| TLS section (1724–1727) | Card: ingress CA trust state per store (§6.2), with a "Trust CA" action when not installed. |
| Kubeconfig path, source repo/branch (1731–1733) | Collapsible "Environment" section; for a pip install this shows the package version and install path (§8.2), not a git branch. |
| VM section — RHEL version, MicroShift version, CPUs, memory used/total/available, load, disk (1737–1762) | Card with PatternFly progress bars for memory and disk. These are the numbers people ask about mid-demo; make them glanceable. |
| Namespaces + AAP CR `Successful`/`Running` conditions (1766–1800) | Table of namespaces with a status label per AAP instance. |
| AAP Deployments / routes (1803–1811) | Table of routes as **clickable links** (this is the single highest-value affordance the terminal cannot offer). |
| Credentials — `admin` + password from `*-admin-password` secrets (1815–1844) | See §9.5.1 — **redesigned in rev 5**. |
| AO credentials (1846–1859) | Same treatment. |
| Addons list with enabled markers (1883–1888) | Reuses the Addons page's row component; links there. |
| `_check_for_updates` (invoked from status) | A non-blocking toast if a newer version exists (§12.3), never a modal. |

#### 9.5.1 Credentials on the status page — redesigned in revision 5

Rev 2's design: the admin password flows to the browser inside `GET /api/status`, is masked client-side, and a reveal toggle un-masks it. Rev 2 was explicit that this was "not a security boundary… it is demo hygiene."

**That is now wrong, and it is wrong for a reason rev 2 could not have anticipated.** §5.5's requirement is that nothing sensitive is *exposed* by the tool at all — not merely that it is hard to read off a projector. Under rev 2's design the plaintext password is in the HTTP response body, in the browser's memory, in the React component tree, in the DOM (masking is CSS, not absence), in devtools' network tab, and in any HAR a user exports for a support ticket. Client-side masking hides it from the audience in the room and from nobody else. The redesign is therefore structural: **the secret never enters the status payload.**

**`GET /api/status` returns credential *references*, not values.** Each is `{name, username, source, available: true}` — enough to render the row, the label, and the button. There is no `password` field in the schema, so there is no way for one to be reintroduced by a well-meaning change without editing the schema, and `tests/unit/test_gui_api.py` asserts on that absence directly (a scan of the serialized status payload for any value present in the test's fake keyring).

**The reveal action, and the recommendation between the two ways to do it.**

| Option | Assessment |
|---|---|
| **A — a dedicated, separately-scoped reveal endpoint.** `POST /api/secrets/{name}/reveal` reads `core/secrets.py` on demand and returns the value, only on an explicit user action. | Strictly better than rev 2 — the value is out of the general payload every page load fetches, and reaches the browser only when a human asks. But it still puts plaintext in the response body and therefore in the DOM, devtools, and any exported HAR. It solves the "every page load" problem, not the "in the browser at all" problem. |
| **B — server-side copy to the OS clipboard.** `POST /api/secrets/{name}/copy` reads the keyring and writes the value directly to the **host's** clipboard. The response is `{ok: true}`. The frontend never receives the plaintext, and it never exists in the DOM. | **RECOMMENDED.** Feasible: the FastAPI server runs on the user's own machine as the user, in the same session that owns the clipboard — so this is an ordinary local API call, not a remote one, and it is only sensible *because* §13 Q15 makes localhost-only permanent. It is also the action people actually want: rev 2 already observed that "copy is the common action, revealing is not", and §10.6.3's tray already offers copy-with-no-reveal. |

**Recommend B as the primary affordance, with A available and off by default.** Concretely:

- **Copy** is the default button on every credential row, in the GUI and in the tray (§10.6.3), and it goes through `POST /api/secrets/{name}/copy`. The UI confirms with a transient "Copied to clipboard" toast and nothing else.
- **Implementation and its dependency cost.** `pyperclip` is the obvious choice (pure Python, cross-platform) but is not free of caveats: on Linux it shells out to `xclip`/`xsel`/`wl-copy` and fails cleanly when none is present. Given the tool already owns `exec/runner.py`, the honest assessment is that a **`core/clipboard.py` with three small platform implementations — `pbcopy` on macOS, `clip.exe`/PowerShell `Set-Clipboard` on Windows, `wl-copy`/`xclip` on Linux — costs about as much as taking the dependency and fails more legibly** (it can name the missing binary). Recommend that over `pyperclip`; the platform-dispatch pattern and its test seam already exist (§6.1). Either way it is one small module, and **the value must be passed on the child's stdin, never in argv**, or it lands in `ps`.
- **Clipboard hygiene:** the copy handler clears the entry after 60 seconds if the clipboard still holds the value it wrote, and says so in the toast. That mirrors what password managers do and costs one timer.
- **Reveal (option A) remains available behind `gui.allow_reveal: false`**, default off, for the case a copy cannot serve — a user reading a password onto a phone, or a broken clipboard on a headless-ish Linux desktop. When enabled, a reveal is one-shot, auto-re-masks after 60 s, and is logged to the job log as an event (not the value — the fact) so it is at least visible in a must-gather. `gui.reveal_credentials` from rev 2's §5.3 is renamed to this and inverted in meaning: it no longer sets a masking default, it gates whether the endpoint exists at all.

**What this does not claim.** Anyone who can run `aap-demo status` on this machine can read the same secret from the same keyring, and anyone with the kubeconfig can read it from the cluster. This design does not create a boundary between the user and their own credentials — it removes the *incidental* copies: the ones in a screenshot, a screen share, a devtools tab, a HAR attached to a bug report, and a browser's memory for the rest of the session. Those are the exposures that actually happen.

A **Diagnose** tab on the same page renders `GET /api/diagnose`: each check as a row with severity icon, message, and its fix hint (the same hints §14's checks carry and `.claude/CLAUDE.md` documents), with a "Copy fix command" button. `diagnose --ai` is a button that starts a job and streams the `claude -p` output — it is long-running, so it uses the same mechanism as everything else.

### 9.6 Packaging

**The SPA bundle ships in the base wheel; only the server dependencies are gated by the extra.**

- `src/aap_demo/gui/static/**` is package data included in every wheel. It is roughly 1–3 MB of minified JS/CSS/fonts, which is acceptable weight for a tool whose install already implies a multi-GB cluster, and it removes an entire class of failure (a `[gui]` install landing without matching assets, or a data-only companion distribution drifting in version).
- `[gui]` gates only `fastapi` + `uvicorn`. `aap-demo gui` without the extra prints the install command and exits 3.
- **PatternFly fonts and CSS are vendored into the bundle**, never fetched from a CDN. The tool runs on laptops in conference rooms with hostile wifi and in disconnected environments; a status page that loads unstyled because a CDN is unreachable is worse than no GUI.

**Build process — a release step, never a runtime build.**

```make
frontend-build:                       # requires node >= 20; maintainers only
	cd frontend && npm ci && npm run build
	rm -rf src/aap_demo/gui/static && cp -r frontend/dist src/aap_demo/gui/static
	python -m aap_demo.gui._stamp     # writes static/build.json: {bundle_version, schema_hash, built_at}

schema: ; python -m aap_demo.core.schema --emit frontend/src/schema/schema.json

dist: schema frontend-build
	python -m build
```

- `frontend/` is excluded from the sdist and wheel; `gui/static/` is included. Contributors who never touch the frontend never install Node.
- **`gui/static/` is committed to git.** This is the pragmatic call: it keeps `pip install git+…` and editable installs working for contributors without Node, and it makes the bundle diffable in review. The cost is noisy diffs on frontend changes — accepted, and mitigated by keeping bundle rebuilds to their own commits.
- CI enforces freshness: a job runs `make schema frontend-build` and fails if `git diff --exit-code` shows changes, so a merged frontend source change without a rebuilt bundle cannot pass (§14 R14).
- `build.json`'s `schema_hash` is compared at server startup against the live schema; a mismatch logs a loud warning and surfaces a banner in the SPA rather than failing silently with a form that is missing fields.

### 9.7 Server binding and access — **localhost-only, permanently (revision 5)**

`host = "127.0.0.1"`, `port = 8720`, browser opened automatically. **The bind address is not user-settable.** Rev 2 framed loopback as a strong default with `--host` available behind a warning, and treated remote access as a feature to scope later. That framing is superseded by a product principle, in the maintainer's words:

> *"aap-demo is not made for shared access or hosted access. it is a LOCAL demo tool."*

So: **remote and shared access are out of scope by design, not deferred.** There is no `--host` flag, no `gui.host` value other than `127.0.0.1`, and no roadmap item to add one. The schema property is fixed rather than merely defaulted, and `tests/unit/test_gui_api.py` asserts the app cannot be constructed with a non-loopback bind. Anyone determined to expose it can put a reverse proxy in front of the port — that is their decision, made outside the tool, and it is not one we make easier by shipping a flag that looks sanctioned.

Three things follow, and they are why this is a simplification rather than a restriction:

- **No authentication is needed and none is built** (§13 Q16). On a loopback bind, anyone who can reach the port can already run `aap-demo status` as the same user. A login page would protect nothing and would imply a boundary that does not exist.
- **The remaining exposure is not the network** — it is credentials in payloads, screenshots, and screen shares. That is what §5.5 and §9.5.1 address, and it is the exposure that actually occurs on a single-user laptop.
- **Server-side clipboard access is coherent** (§9.5.1 option B). It is only a sane design because the server is definitionally on the user's own machine, in the user's own session. Under a "maybe remote someday" framing it would be a latent absurdity; under this one it is the obvious implementation.

One acknowledged edge, unchanged from rev 2's Q16 note: a shared machine with several local user accounts is a real, if uncommon, counterexample to "loopback is private". It is not addressed, and that is a stated limit rather than an oversight — the tool's secrets live in the *user's* keyring (§5.5), so another local user gets a running server they can talk to but no credential store to read, which is a meaningfully smaller hole than rev 2's design left.

---

## 10. Desktop application, native installers, and the tray icon — new

### 10.0 Requirement and the audience it comes from

The requirement, from the maintainer, arrived after §9 was written and changes the distribution story rather than the architecture: *"the primary audience for this tool is not engineers — it's managers, IT directors, and sales staff. Some of them need to install and run aap-demo themselves with zero terminal usage: no `pip install`, no command line, ever."* Paired with it: a native OS tray presence — macOS menu bar, Windows system tray — giving status at a glance and quick actions without keeping a browser tab open or a terminal alive.

This does not replace anything in §§1–9. It adds a second way to *ship* the same package, plus one new subpackage (`desktop/`) that hosts the app shell. Every architectural rule in §2 still holds: `desktop/` is a third adapter alongside `cli/` and `gui/`, it contains no orchestration logic, and it never imports `cli/`.

One line in §1's non-goals needs amending rather than reinterpreting. It says the tool "does not add a daemon — each CLI invocation stays a short-lived process, per ADR-001; the GUI server is an explicitly user-started foreground process." That remains true of the **CLI**, which is what ADR-001 was about. The desktop app is a **user-launched, user-quittable, user-visible foreground application that happens to be long-lived** — the same category as a text editor, not the same category as a systemd unit. It is never installed as a service, never runs as root, never starts on its own without an explicit opt-in (§10.7), and quitting it is one menu item away at all times. §1 is amended to say exactly that.

### 10.1 Three coexisting distribution channels

There are now **three channels shipping one package**, none of them a fork and none of them a replacement for another:

| Channel | Artifact | Audience | Entry points |
|---|---|---|---|
| **PyPI** (§8.3) | `aap-demo` wheel + sdist, plus the `aap-demo-*` tier-2 distributions | Developers, CI, technical operators, anyone who wants day-2 ops | `pip install aap-demo` → `aap-demo` CLI; `pip install "aap-demo[gui]"` → `aap-demo gui`; `pip install "aap-demo[desktop]"` → `aap-demo desktop` |
| **Native installer** (this section) | Signed `.dmg`/`.pkg` (macOS) **built first**, signed `.msi` (Windows) after (§13 Q19) | Managers, IT directors, sales staff — **zero terminal** | Double-click to install; app icon in Applications / Start Menu; tray icon |
| **Podman Desktop extension** (§11) | OCI image in the Podman Desktop extension catalog | **Technical operators** — SEs, solution architects, anyone who already runs Podman Desktop | Podman Desktop → Extensions → install; an "AAP Demo" webview panel inside Podman Desktop |

**These are three tiers of user, not three ways to reach one tier.** The maintainer's own assessment, which this document takes at face value rather than papering over: a Podman Desktop extension **does not solve the zero-terminal problem**. Podman Desktop's UI is unmistakably a developer tool, and "install Podman Desktop, open the Extensions catalog, install two extensions, then find our panel" is a longer and more failure-prone path for a sales director than double-clicking a signed installer. The extension is a **parallel channel for people who already have Podman Desktop open**, and its existence changes nothing about the non-technical audience's needs: **§10's standalone installer still has to exist and still has to be built.** Do not let §11 be read as a cheaper substitute for this section.

The installer is a **packaging wrapper around the same wheel**. Briefcase (§10.2) installs `aap-demo[gui,desktop,demos]` into the app bundle from the same artifact PyPI serves. There is no desktop-only code path, no desktop-only fork of a core module, and no separate version number: one `cz bump`, one tag, three artifacts (§10.11). The frozen app's own entry point, `aap_demo.desktop.app:main`, is *also* reachable from the pip channel as `aap-demo desktop`, which is what keeps the two honest — the tray app is developed and tested as an ordinary Python entry point and only *packaged* differently.

Release-engineering consequence, stated plainly: CI must now produce (a) the PyPI wheel and sdist, (b) a signed+notarized macOS installer, (c) a signed Windows installer, (d) the update manifest (§10.5), and (e) the multi-platform extension OCI image (§11.9), per release. That is materially heavier than the CLI-only rewrite originally scoped, and it is a real addition to the separate **enterprise CI workstream** tracked outside this document — flagged here as a dependency, not designed here.

### 10.2 Freezing and bundling: **Briefcase** — RECOMMENDED (spike-gated, §13 Q21)

Python must be bundled. A manager's laptop has no Python, or has 3.8 from a vendor image, or has a corporate-managed 3.12 nobody is allowed to `pip install` into. Assuming otherwise reintroduces exactly the "works on my machine" friction §5.1 already rejected PyYAML over.

| Candidate | Verdict |
|---|---|
| **Briefcase** (BeeWare) | **Recommended.** See the four reasons below. |
| PyInstaller | Rejected as primary, kept as the fallback if the spike fails. More mature and far more widely used, but it produces an `.app`/`.exe`, not an installer — macOS `.pkg`/`.dmg` would need hand-rolled `pkgbuild`/`productbuild`/`create-dmg` and Windows would need WiX or Inno Setup, i.e. two more build systems to own. Its module-graph analysis is also the wrong shape for this codebase specifically: see reason 1. Tray icons would come from `pystray` (or `rumps` on macOS) bolted on separately, with a per-OS event-loop integration problem we would own. |
| Nuitka | Rejected. Compiling to native code buys startup time we do not need (this app launches once and lives for hours) and costs the thing we cannot lose: robustness under dynamic imports and `importlib.metadata`. The addon registry (§4.1) and the day-2 catalog both resolve things by name at runtime. Long build times and a licensing split for some features make it a poor fit for a tool whose bottleneck is release-pipeline complexity, not runtime speed. |

**Why Briefcase, concretely:**

1. **It installs dependencies with pip into the bundle rather than static-analyzing imports.** This is the decisive reason, and it is specific to this architecture. `addons/registry.py` discovers addons through `importlib.metadata.entry_points(group="aap_demo.addons")` (§4.1); `day2/` and `gui/` load package data through `importlib.resources` (§2.1 `data/`, §9.6 `gui/static/`). Both mechanisms need real `.dist-info` metadata and real package data on disk. Briefcase gets that for free because the bundle *contains a pip-installed environment*. PyInstaller needs a `copy_metadata()` hook per distribution and a `datas` entry per data directory, and the failure mode when one is missing is silent — `addon list` comes back empty in a signed release nobody can reproduce locally (§14 R24).
2. **One config produces installers for both target OSes.** `[tool.briefcase.app.aap-demo]` in the existing `pyproject.toml` yields a macOS `.dmg`/`.pkg` and a Windows `.msi` (WiX) from the same declarations. The alternative is two packaging toolchains plus their per-OS quirks, owned by a team whose stated bottleneck is already maintaining two of something (ADR-010).
3. **Signing and notarization are first-class commands, not scripts we write.** `briefcase package macOS --identity "Developer ID Application: …"` performs the codesign sweep over every Mach-O in the bundle, submits to `notarytool`, waits, and staples. That is precisely the work §10.4 otherwise makes us build and maintain, and getting it subtly wrong is how an installer ships that Gatekeeper rejects.
4. **The tray icon and the app window come from one toolkit with native backends.** Toga's status-icon support gives a real `NSStatusItem` on macOS and a real notification-area icon on Windows, and `toga.WebView` gives a native `WKWebView`/`WebView2` host for the SPA (§10.3) — no second GUI dependency, no hand-written event-loop bridge.

**Honest costs.** Briefcase has a far smaller community than PyInstaller, so an obscure packaging bug is more likely to be ours to fix — a real bus-factor concern for a release-blocking tool. Toga's status-icon API is comparatively young. Windows MSI builds need the WiX toolset present on the runner. And because Briefcase does not tree-shake, the bundle is larger than an equivalent PyInstaller `--onedir` build. These are why §13 Q21 asks for a **timeboxed prototype spike before the choice is locked**: build a hello-world Briefcase app that starts uvicorn on a thread, serves one page in a webview, shows a status icon, and — the actual acceptance criterion — successfully resolves an `aap_demo.addons` entry point from a packaged tier-2 distribution on both OSes. If that spike fails, fall back to PyInstaller plus WiX/`productbuild` and accept the extra maintenance, with the entry-point metadata problem solved explicitly by `copy_metadata()` and covered by the packaged-app CI test in §14 R24.

**What goes in the bundle:** the CPython runtime; `aap-demo` and the tier-2 addon distributions (`[demos]`, §4.5); `fastapi` + `uvicorn` (`[gui]`); `toga` and its platform backend (`[desktop]`); the SPA static bundle (already package data per §9.6); the packaged cluster YAML under `data/`. **What does not:** `oc`, `kubectl`, `crc`, `helm`, `operator-sdk`, `podman`, `ansible-navigator`. Those stay detect-and-offer (§13 Q6, §10.9, §10.10) — bundling them would take the download past a gigabyte, and CRC in particular has its own signed installer and pull-secret flow that we should not be in the middle of.

**Size, reasoned rather than guessed.** Uncompressed: CPython runtime and stdlib ≈ 40 MB; FastAPI/starlette/uvicorn/anyio/pyyaml/jsonschema/keyring/argcomplete/platformdirs/ruamel ≈ 12 MB (rev 5: `pydantic` and its compiled `pydantic-core`, previously 15–20 MB, are gone — so the estimate below is if anything conservative); the PatternFly SPA bundle 1–3 MB (§9.6); tier-2 addon distributions (Python plus YAML data) ≈ 5 MB; Toga and its backend ≈ 10 MB on macOS and ≈ 25 MB on Windows, where the WinForms backend drags in `pythonnet`. That lands at roughly **120–160 MB installed on macOS and 150–200 MB on Windows**, compressing to a **~70–110 MB download**. This is a mid-sized download, not a small one — closer to a developer tool than to a utility — and §14 R23 treats that as a real deployment friction rather than a rounding error, with a hard **150 MB compressed budget enforced in CI** (§10.11). Worth keeping in perspective for the *architecture* but not for the *first impression*: the tool then proceeds to pull multiple gigabytes of container images, so the installer is never the bandwidth bottleneck — it is only the bottleneck at the moment the user is deciding whether this thing works.

### 10.3 Window model: embedded webview, with automatic browser fallback

Recommended: **the dashboard opens in an embedded `toga.WebView` window pointed at the local server**, with "Open in Browser" always available from the tray, and automatic fallback to the default browser when the webview cannot be created.

| Model | Tradeoff |
|---|---|
| Browser-launch only | Simplest — start uvicorn, `webbrowser.open("http://127.0.0.1:8720")`, done; zero extra runtime dependency. But the user sees a `localhost:8720` address bar, which reads as a developer tool, and it directly undercuts the "looks like an official Red Hat tool" goal §9.0 exists to serve. Tab-vs-app confusion is also real for this audience: closing the tab does not stop the app, and closing the app does not close the tab. |
| **Embedded webview** | **Chosen.** Feels like a native application: its own window, its own Dock/taskbar entry, no address bar. Cost: a dependency on the OS webview component. On macOS this is `WKWebView`, always present, no action needed. On Windows it is **WebView2**, which is preinstalled on Windows 11 and on most Windows 10 machines via the Evergreen runtime but is **not guaranteed** — so the Windows `.msi` chains the Microsoft-redistributable WebView2 Evergreen Bootstrapper (~2 MB, downloads the runtime if absent), handling it at install time rather than at first launch. Adds bundle size and one more thing that can fail. |

The fallback is what makes the choice safe rather than brave: `desktop/app.py` attempts to construct the webview window; on failure it logs the reason to `<state>/desktop/desktop.log`, opens the default browser at the same URL, and shows a tray notification saying the app is running in browser mode. A non-technical user gets a working dashboard either way, and we get a diagnosable log line instead of a blank white window.

"Open in Browser" stays a permanent tray menu item regardless of mode, for two concrete reasons: screen-sharing a browser window is a workflow people already know, and browser zoom is how a status page becomes readable on a projector.

### 10.4 Code signing and notarization — a cross-team dependency, not a coding task

This is the hardest external dependency in this section and it has weeks of lead time. It must be requested at project kickoff, not at release.

**macOS.** Required: an **Apple Developer ID Application** certificate (signs the `.app` and every `.dylib`/`.so` inside it) and, for a `.pkg`, a **Developer ID Installer** certificate. The bundle must be signed with the **hardened runtime** and a **secure timestamp**, then submitted to Apple with `notarytool` and the ticket **stapled** to the distributed `.dmg`/`.pkg`. Without notarization, Gatekeeper on a current macOS refuses to open the app at all on first launch — not a warning, a block, with a dialog that suggests the app may be malware. For a tool whose entire purpose is establishing credibility in front of a customer, that is the worst possible first frame. Use an **App Store Connect API key** for notarization rather than an app-specific password, because the key is designed for CI and does not break when an individual's Apple ID changes. Practical note for the implementer: Python bundles contain many Mach-O binaries and every one must be signed — a thing Briefcase does correctly and a hand-rolled script gets wrong.

**Windows.** Required: an **Authenticode code-signing certificate**. Two grades matter differently:

- A standard **OV** certificate signs the binary but starts with zero SmartScreen reputation, so a brand-new installer still shows *"Windows protected your PC — Microsoft Defender SmartScreen prevented an unrecognized app from starting"* until enough downloads accumulate. For a tool distributed to a few hundred sales staff, that reputation may never accumulate.
- An **EV** certificate (or **Azure Trusted Signing**, which behaves equivalently for reputation purposes) grants SmartScreen reputation immediately. **This is the one to ask for.**

Also note a constraint that surprises people: under the CA/Browser Forum's 2023 rules, code-signing private keys must live on FIPS-validated hardware. That means **there is no `.pfx` to put in a CI secret** — signing runs against a cloud HSM signing service (Azure Trusted Signing, DigiCert KeyLocker, SSL.com eSigner) or on a machine with a hardware token attached. Design the release pipeline for that from the start; retrofitting it is painful.

**The ask to make, and to whom.** Red Hat almost certainly already holds both identities for other shipped products. The request is for *use of the existing identities and the pipeline that wraps them*, routed through Release Engineering / IT / Product Security, and it should name: the Developer ID Application and Installer certificates, an App Store Connect API key for notarization, and an EV-grade Windows signing identity. Treat availability as a **hard release gate**, tracked as §13 Q22 and §14 R20 — not as a formality to discover in the release week.

**Interim, internal-only.** For dogfooding before the identities land, ship ad-hoc-signed builds (`briefcase package --adhoc-sign`) circulated internally with the `xattr -dr com.apple.quarantine` incantation documented. That is explicitly **not** something the target audience is ever asked to do; it exists so the team can test the packaging while the certificate request is in flight.

### 10.5 Auto-update: manifest check + user-consented reinstall — v1

`pip install --upgrade` does not apply to a frozen app, and §12.3's index-query update notice does not either. The desktop app needs its own mechanism, and it should be the least surprising one that works.

**v1 design — decided:**

- A **static JSON manifest** at a stable HTTPS URL, published *after* the artifacts it names are uploaded and verified (publish order matters — a manifest ahead of its artifacts hands users a 404):

  ```json
  {
    "schema_version": 1,
    "latest": {
      "version": "2.1.0",
      "released": "2026-11-14",
      "notes_url": "https://…/releases/v2.1.0",
      "artifacts": {
        "macos-universal2": {"url": "https://…/aap-demo-2.1.0.dmg", "size": 94371840, "sha256": "…", "min_os": "13.0"},
        "windows-x64":      {"url": "https://…/aap-demo-2.1.0.msi", "size": 108003328, "sha256": "…", "min_os": "10.0.19041"}
      }
    },
    "minimum_supported": "2.0.0"
  }
  ```

- **The check** runs at app start and at most once per 24 h (reusing `<cache>/last_update_check`, §5.2), never blocks startup, never opens a modal, and is skipped entirely under `CI=true`. It **must not run while a job is active** — an update banner mid-deploy is noise at the exact moment the user needs the screen.
- **The result** is a tray menu item that changes to "Update available (2.1.0)" plus a dismissible banner in the dashboard showing the version, the release-notes link, and **the download size before the user commits** (§14 R23).
- **The action** downloads the installer to the user's Downloads folder, verifies the SHA-256 against the manifest, reveals it in Finder/Explorer, and shows one sentence of instruction. It does **not** replace binaries in place, does not restart itself, and does not run the installer for the user.
- **Downgrades are refused** unless explicitly chosen from the release page. Serving an older, vulnerable build is a real attack on any update channel.
- `minimum_supported` lets a build be marked as must-upgrade (e.g. a broken contract against a new EE). The app then shows a *persistent* banner. It still never forces.

**Deferred, deliberately: silent auto-update** (Sparkle on macOS, Squirrel or the MSIX app installer on Windows). Not an oversight — a scope cut with three reasons. It introduces a **second signing trust chain** to get right (Sparkle wants its own EdDSA appcast key, independent of the Apple certificate, and Sparkle's CVE history is largely misconfigured feeds). It requires an update-and-restart dance that must be interlocked with the job registry so it cannot fire mid-deploy. And the audience uses this tool in bursts around demos, not daily, so the marginal value of silence over one click is small. Revisit if the install base grows past the point where "please download the new one" stops scaling.

**Why the security boundary is the OS, not our hash.** The SHA-256 in the manifest is an **integrity** check against a truncated or corrupted download. It is *not* a security boundary: the manifest and the artifact come from the same origin, so an attacker who can rewrite one can rewrite the other. The actual boundary is the OS verifying the installer's Authenticode / Developer ID signature at install time. This is why §10.4 is a hard prerequisite for shipping §10.5 at all, and why the flow ends at "here is the signed installer" rather than "we ran it for you." See §14 R22 for the rest of the threat model, including the `CURL_CA_BUNDLE` interaction that will otherwise bite.

### 10.6 The tray icon

#### 10.6.1 Process model: one process — DECIDED

The tray icon, the webview window, and the FastAPI server all live in **one process**.

```text
src/aap_demo/desktop/          # new subpackage; imported only with the [desktop] extra
  __init__.py                  # lazy-import guard -> "pip install 'aap-demo[desktop]'"
  app.py                       # toga.App: builds the status icon, starts the server thread,
                               #   owns the webview window and the quit interlock (§10.8)
  server.py                    # uvicorn.Server on a daemon thread; port selection, readiness
                               #   event, graceful shutdown; writes <state>/desktop/runtime.json
  tray.py                      # icon-state mapping, menu construction, menu action handlers
  poller.py                    # background cluster-status poll -> DesktopState (cadence below)
  updater.py                   # §10.5 manifest check
  autostart.py                 # per-OS login-item registration (§10.7)
  single_instance.py           # lock + focus-existing-instance (§14 R21)
  resources/                   # template PNGs (macOS, @1x/@2x) + .ico (Windows)
```

Rejected alternative: a tray process supervising a separate backend process, talking over the local HTTP API. It sounds cleaner and is worse here. It invents an IPC contract we would have to version, adds an orphaned-backend failure mode (tray dies, uvicorn keeps serving cluster admin credentials on a port nobody knows about), doubles the startup surface, and gives us two candidates for "which one is the singleton." One process has one lifecycle, one job registry, and one thing to quit.

The single-process model is also already the shape §9.4 chose: jobs run in **worker threads** because the core is synchronous and subprocess-bound. Adding a uvicorn server thread beneath a Toga main loop is the same pattern one level up, not a new one.

**How the tray talks to the backend: it does not use HTTP.** `tray.py` reads a `DesktopState` object updated from two sources — `poller.py` (cluster/AAP state) and the `JobManager` (§9.4). The tray subscribes to the same `core/events.py` `EventSink` the SSE endpoint fans out from, making it a **third consumer of the event stream** alongside the CLI's console renderer and the browser. That is the point: it costs nothing conceptually because §9.4 already defined the abstraction. Symmetrically, a tray menu action (start, stop, idle) calls the same core function the API route calls, **via the JobManager**, so a cluster start begun from the menu bar appears in the dashboard's Jobs page and streams over SSE like any other job. There is exactly one long-running-work mechanism, per §9.1.

**Poll cadence** matters more than it looks, because every poll is a `crc status` subprocess and a battery complaint is a support ticket: every 10 s while the dashboard window is open or a job is running; every 60 s otherwise; exponential backoff to 5 minutes after three consecutive failures, resetting on the first success. Polling is suspended while the machine reports sleep.

#### 10.6.2 Icon states

macOS menu-bar icons must be **template images** (monochrome, alpha-only, auto-inverting for light/dark menu bars and for the highlighted state) — a colored PNG in the macOS menu bar is the single most reliable way to look like a third-party toy. Windows notification-area icons are full-color 16×16/32×32 `.ico`.

So: **one glyph, one badge.** A single template mark, with a small badge dot in the lower-right conveying state. Ship template PNGs at @1x/@2x for macOS and a multi-resolution `.ico` for Windows.

| State | Badge | Tooltip / first menu line |
|---|---|---|
| `unknown` — starting up, or probing | none (glyph dimmed) | "Checking…" |
| `no-cluster` | none | "No cluster — click to get started" |
| `stopped` | grey | "Cluster stopped" |
| `running` | green | "AAP: Running · aap-operator" |
| `idled` | blue | "AAP: Idled (scaled to zero)" |
| `deploying` | amber | "Deploying — step 7/14: waiting for CSV" |
| `error` | red | "Deploy failed — open Diagnostics" |

**No animation, deliberately.** An animating menu-bar icon is a battery and attention cost, and the native APIs make it awkward in both toolkits. Progress is carried by *text in the menu* — "step 7/14: waiting for CSV", updated from the same step events (§9.4) the GUI's progress view renders — which tells the user more than a spinner does. If a deploy stalls, a spinner says "still going"; the step text says "still waiting for the CSV", which is the sentence that gets a useful screenshot into a support channel.

#### 10.6.3 Menu contents

```text
 AAP: Running · aap-operator            (disabled label — live status)
 ─────────────────────────────
 Open Dashboard                          (default action; also the click action on Windows)
 Open in Browser
 ─────────────────────────────
 Cluster ▸  Start Cluster
            Stop Cluster
            Idle AAP                     (checkbox — reflects spec.idle_aap)
            Open AAP Console             (opens the gateway route in the browser)
            Copy Admin Password
 ─────────────────────────────
 Deploy…                                 (opens the dashboard at /deploy — does NOT deploy)
 ─────────────────────────────
 Check for Updates…                      (becomes "Update available (2.1.0)")
 Launch at Login                         (checkbox — default OFF, §10.7)
 Settings…
 Quit aap-demo
```

Rules the implementer must not casually change:

- **Deploy is never executed from the tray.** "Deploy…" opens the wizard. A deploy is a 15+ minute, multi-gigabyte, configuration-dependent operation; a one-click menu item with no review step is exactly the misfire that burns a demo, and §9.2's wizard exists precisely to collect those choices and show the plan first. The tray *starts the wizard*; the wizard starts the deploy.
- **Nothing destructive is in the tray. Ever.** No `destroy`, no `clean`, no `redeploy-all`. They live in the GUI behind a typed confirmation, where the blast radius can actually be shown.
- **Unavailable actions are disabled, not hidden.** "Stop Cluster" greyed out when nothing is running teaches the state; "Stop Cluster" absent reads as the app being broken. This audience does not debug menus.
- **`Copy Admin Password` copies; it never reveals.** Same reasoning as §9.5.1, and stronger — a menu bar is even more likely to be on a shared screen than a browser tab. There is no reveal affordance in the tray at all. Mechanically it uses the same `core/secrets.py` → `core/clipboard.py` path the GUI's copy button uses (in-process, no HTTP hop), so the plaintext is read from the keyring and written to the clipboard without passing through any rendered surface.
- **`Open AAP Console`** is the highest-value item here for the actual audience. It is the thing a sales person opens the laptop to do, and today it requires reading a route out of `aap-demo status`.

### 10.7 Startup behavior: installed, not auto-started

**Recommended default: the installer registers no login item. "Launch at Login" is a checkbox in the tray menu, default off.**

Silently adding a login item is precisely the move that erodes trust with a non-technical audience — they notice the laptop got slower, they cannot find what added itself, and the tool becomes the thing IT tells them to remove. The cost of the opt-in is one click by a user who wants it; the cost of the opt-out is a reputation.

The dashboard's first-run view shows a single dismissible card offering to turn it on, with plain copy about what it does. Implementation, per OS:

- **macOS**: `SMAppService.mainApp` register/unregister (macOS 13+), which puts the item in System Settings → General → Login Items where the user can see and remove it. Fall back to a `~/Library/LaunchAgents/` plist only if the deployment floor turns out to include macOS 12.
- **Windows**: a shortcut in the per-user `shell:startup` folder, **not** an `HKCU\…\Run` registry value. Both work; the shortcut is visible in File Explorer *and* in Task Manager → Startup, so a user can remove it without a registry editor.
- Per-user always. Never machine-wide, never elevated, never during install.

One piece of copy is load-bearing and should ship verbatim: **"Starts aap-demo in the menu bar when you log in. It does not start your cluster."** A non-technical user will otherwise assume login-launch means the environment boots — which would silently start a 24 GB VM every morning. **Launching at login never starts the cluster and never starts a job.** It starts the tray icon and the local server, nothing else.

### 10.8 Job durability, quitting mid-deploy, and the resolution of R16

§14 R16 flagged that GUI job state is in-process and dies with the server, which creates a durability expectation the browser-tab-scoped SSE connection alone does not meet. The tray architecture changes that calculus, and this subsection is the resolution R16 now points at.

**What the long-lived app buys, for free.** A deploy started from the wizard runs in the app's process, not the browser's. So:

- Closing the browser tab, or the webview window, does **not** stop the deploy — and the tray icon keeps showing amber with live step text, which is the visible proof that it did not stop. The window's close button **hides the window rather than quitting** (the macOS convention already; on Windows, show the standard one-time "aap-demo is still running in the notification area" balloon, which is the single thing that prevents "I closed it, why is my fan spinning").
- Laptop sleep, wifi drop, and tab refresh are already handled by §9.4's `Last-Event-ID` backfill; reopening the dashboard reconnects to the in-progress job and backfills the gap.
- This is the common case, and it is now genuinely durable.

**What happens if the user quits the app entirely mid-deploy.** A confirm dialog naming the job: *"A deploy is in progress (step 7/14: waiting for CSV). Quitting will stop it and may leave the cluster partly configured."* — **Cancel** (default) / **Quit anyway**. An OS-initiated shutdown or logout is treated as Quit anyway, but writes state first.

**The subprocess question, decided: children are killed, not orphaned.** Each job's subprocesses run in their own process group (POSIX `setsid`) or Windows Job Object, and the group is terminated on quit.

The honest reasoning, because the alternative sounds more impressive: the subprocesses in question — `crc start`, `oc`, `kubectl`, `ansible-navigator` — are *orchestration*, not the durable work. The durable state is the CRC VM and the cluster, and both outlive the tool regardless of how it exits. Orphaning would require detaching the children, reparenting their pipes to files, and building a reattach protocol — and it would produce a genuinely worse failure mode than the one it fixes: a headless `ansible-navigator` mutating a cluster with nothing watching it, no way to cancel it, and no UI that knows it exists. **Full process survival across an app restart is overkill, and this is a deliberate scope cut rather than an oversight.**

**Resume on next launch — the pragmatic v1.** On startup, `desktop/app.py` scans `<state>/gui-jobs/` for any job whose last recorded state is `running` or `interrupted`. It does **not** assume the work is still happening. It reconciles against reality using the same read-only probes `status` and `diagnose` already run, and surfaces a card in the dashboard:

> **A deploy was interrupted.** Started 2 Sep at 14:12, stopped at step 7/14 (waiting for CSV).
> Current cluster state: AAP CR present, gateway not ready.
> **[Resume deploy]** **[View log]** **[Dismiss]**

"Resume deploy" re-submits the **saved plan**. This is cheap precisely because `POST /api/deploy` already takes a validated plan object (§9.1), so persisting it next to the job log is one file write, and resuming is one re-submission of an operation the addon contract and `repair` already require to be idempotent (§7.5, §14 R16). It is not a reattach; it is a re-run that converges.

A stale `<state>/desktop/runtime.json` from a crash is detected on startup by PID liveness plus a port probe, and removed.

**Net effect on R16:** the durability expectation is now *met* for the cases that actually happen (tab closed, window closed, laptop asleep, network dropped), and for the cases that happen rarely (app quit, crash, reboot) it degrades to a truthful, actionable resume card instead of a silent lie about a job that is not running.

### 10.9 Day-2 operations in the desktop channel: out of v1, on principle

§4.8 runs day-2 playbooks through `ansible-navigator` against a containerized Execution Environment, which needs both `ansible-navigator` and a container runtime. A zero-terminal desktop user has neither, and cannot `pip install` the first one.

**Decision: the desktop channel ships without day-2 operations in v1.** The Operations page and its nav entry are absent from the desktop app's primary navigation.

The reason is §4.5's own governing rule, not the packaging difficulty. Tier 3 is defined as *"something an operator does behind the scenes to maintain the environment"* — and the desktop audience is explicitly not the operator. Shipping "warm the 30 GB image cache" to a sales laptop would violate the sorting rule the rest of this document is built on. That it also saves roughly 100 MB of bundle (ansible-core plus navigator plus their dependencies) is a happy consequence, not the argument.

**But it must be discoverable rather than mysterious.** Settings → Advanced carries a disabled section stating plainly: *"Day-2 operations are operator maintenance tooling. They require Podman and ansible-navigator. Install aap-demo with `pip install aap-demo` to use them — [documentation]."* A `[desktop] enable_day2 = true` config key exists for a technical user who has both tools on PATH; setting it performs real runtime detection and, if something is missing, shows the specific message (*"Day-2 operations require Podman — [install guide]"*) rather than failing inside `ansible-navigator`. Detection must check more than PATH: on macOS and Windows, `podman` on PATH with no running `podman machine` is the common broken state, so probe `podman machine list` / `docker info`, not just the binary.

**Bundling a container runtime is explicitly out of scope, and this is a deliberate scope cut.** Podman Desktop is a several-hundred-megabyte install with its own VM, its own admin prompts, and its own update cadence; chaining a third-party installer inside ours makes us the owner of its failure modes and its redistribution terms, for a feature this channel's audience does not use. Detect-and-link only, consistent with §13 Q6. Revisit only if day-2 ever becomes desktop-facing — tracked as §13 Q20.

### 10.10 First run, and the prerequisites the installer does not solve

What happens on the first double-click, in order: the app launches, the tray icon appears in `unknown`, the server binds, the dashboard window opens on the **Prerequisites step** (§9.2 wizard step 1).

That step is the most important screen in the desktop channel, because a signed installer gets aap-demo onto the laptop and **does not get the user a cluster**. Each check gets an affordance, not just a red X:

| Check | Affordance when missing |
|---|---|
| OpenShift Local (`crc`) | "Download OpenShift Local" button deep-linking to the Red Hat console download page for the user's OS. Not bundled (§10.2) — it is a multi-hundred-megabyte signed installer of its own, with its own admin prompt. |
| Red Hat pull secret | **A paste box.** Deep-link to the console page, a "Paste your pull secret here" textarea, validation that it parses as JSON with the expected auth keys, and a write to `<state>/pull-secret.json` (§5.2). This replaces "download a file and put it in the right directory", which is the step a zero-terminal user is most likely to get wrong. |
| `oc` / `kubectl` | Install link per OS; note that CRC bundles `oc`, so this usually resolves itself once CRC is installed. |
| Hardware — RAM, disk, virtualization | Checked and reported **here**, with the actual numbers and the required numbers side by side. Failing this check 40 minutes into a deploy is the worst version of this failure; failing it in the first 30 seconds is a good product. |
| Podman / `ansible-navigator` | Not shown in the desktop channel (§10.9). |

The residual honesty, which belongs in the docs and not only here: **"zero terminal" is true of aap-demo and not yet true of the whole first run.** Until CRC's own installation is verified as genuinely double-click on both target OSes — and on a *corporate-managed* laptop, where the user may lack the admin rights CRC's installer needs — the claim should not be made in marketing copy. See §14 R25.

### 10.11 Release pipeline and versioning

One version, one tag, five artifacts (§11.9 adds the extension image). **macOS is the first installer built**; the Windows `.msi` follows. That is a build-order decision only — Windows has full CLI, GUI, and tray parity through the PyPI channel from day one, and Linux does too (§13 Q19). `cz bump` (§8.2) drives everything; the desktop app reports the same `__version__` the CLI does, and `GET /api/version` (§9.1) gains the bundle format so a support conversation can distinguish "installed from PyPI" from "installed from the `.msi`".

| Artifact | Built by | Signed with | Published to |
|---|---|---|---|
| `aap_demo-X.Y.Z-py3-none-any.whl` + sdist | `python -m build` after `make schema frontend-build` (§9.6) | PyPI trusted publishing (OIDC) | PyPI |
| `aap-demo-X.Y.Z.dmg` (or `.pkg`) | `briefcase package macOS` on a macOS runner | Developer ID Application (+ Installer), notarized and stapled (§10.4) | Release page / CDN |
| `aap-demo-X.Y.Z.msi` | `briefcase package windows` on a Windows runner with the WiX toolset | Authenticode, EV or Trusted Signing (§10.4) | Release page / CDN |
| `latest.json` | Release job, **last** | — (served over HTTPS from the same origin as the artifacts) | Stable URL (§10.5) |

Constraints on the pipeline:

- **Publish the manifest last**, after every artifact is uploaded and its SHA-256 recomputed from the uploaded object rather than from the build output.
- **Signing jobs run only on protected tag refs**, in a CI environment with protection rules. Forks and pull requests build **unsigned** artifacts for testing; they must never be able to reach a signing identity.
- **macOS architecture**: verify during the §13 Q21 spike whether a single `universal2` build serves both Apple Silicon and Intel (the python.org support packages Briefcase uses are universal2, so one build plausibly does), or whether two runners are needed. This changes the runner matrix and is worth knowing before the pipeline is written.
- **A bundle-size check** fails the build above the §14 R23 budget, so growth is caught at the commit that causes it.
- **A packaged-app smoke test** per OS: install the artifact on a clean runner, launch it headless, assert the server binds, assert `GET /api/addons` lists the tier-2 set (this is the §14 R24 tripwire), then quit cleanly.

This is a materially heavier release than `python -m build && twine upload`, and it is the concrete cost of the second distribution channel. It belongs to the enterprise CI workstream referenced in §10.1.

---

## 11. Podman Desktop extension — the third distribution channel — new

### 11.0 Requirement, audience, and what this channel is *not*

The maintainer's framing: *"if we can create a good extension for this then it could possibly be adopted officially by Red Hat."* That raises the bar for this section from "make it work" to "make it look like something `redhat-developer` would adopt", which is why §11.8 researches the actual conventions instead of guessing at them.

The maintainer's own counterweight, recorded here because a design that hides it would be dishonest: **this channel does not solve the problem §10 exists to solve.** The zero-terminal audience is not helped by an extension inside a developer tool. The channel this section designs is for the **technical-operator tier** — solution engineers and solution architects, who mostly already have Podman Desktop installed, already use its Red Hat OpenShift Local extension to run CRC, and would rather not keep a terminal open next to it. §10's signed standalone installer remains a hard requirement, unchanged (§10.1).

### 11.1 Why the channel is cheap enough to be worth building anyway

Three facts make it so:

1. **The CRC integration already exists and is Red Hat's own.** `crc-org/crc-extension`, published as `redhat.openshift-local`, ships in the catalog as `ghcr.io/crc-org/crc-extension` and is part of the Red Hat Extension Pack. It manages the VM lifecycle for both the **openshift** and **microshift** presets (its `crc.factory.preset` enum is exactly `["openshift", "microshift"]`) and explicitly refuses the `podman` preset. aap-demo does not have to build any of that.
2. **The webview API can host an arbitrary prebuilt SPA** (§11.2) — so the PatternFly React bundle §9.6 already produces is reusable as-is.
3. **Podman Desktop is itself a signed, notarized, cross-platform Red Hat–distributed installer.** This channel inherits §10.4's hardest dependency for free: nothing in it needs an Apple Developer ID or an EV Authenticode identity, because we ship an OCI image into someone else's signed application. That does **not** make it a substitute for §10 (the audience is wrong), but it does mean this channel can ship while §13 Q22 is still unanswered.

**Preset scope note.** Both CRC presets are in scope for this channel. **The correction §11 anticipated has now landed** — revision 5 applies the full-OpenShift decision throughout, so the stale MicroShift-only assertions this note referred to are gone and ADR-020 is superseded rather than relied on (§12.5). Nothing in §11 assumes a single preset — and §11.6 treats preset handling as a first-class interop concern precisely because the CRC extension has a known bug there.

### 11.2 Webview technology spike — mostly answered from source

**Question:** must the UI be rewritten in Svelte to match Red Hat's official template, or can `createWebviewPanel()` host the PatternFly React SPA §9.6 already builds?

**Answer: no rewrite is required, and this is verifiable from the Podman Desktop source rather than inferred.** The relevant mechanics:

- The extension API's `Webview` interface exposes `html: string` ("This should be a complete, valid html document"), `asWebviewUri()`, `cspSource`, `postMessage`/`onDidReceiveMessage`, and `WebviewOptions.localResourceRoots`. It is a VS Code–shaped webview API with **no framework binding whatsoever** ([`extension-api.d.ts`](https://github.com/podman-desktop/podman-desktop/blob/main/packages/extension-api/src/extension-api.d.ts)).
- The official **webview template** sets `panel.webview.html` to a literal HTML string and says nothing about a framework; the **full template** reads a *built* `media/index.html` off disk, rewrites its `<script src>` / `<link href>` through `asWebviewUri()`, and assigns the result to `webview.html` ([extension-template-webview](https://github.com/podman-desktop/extension-template-webview/blob/main/src/extension.ts), [extension-template-full](https://github.com/podman-desktop/extension-template-full/blob/main/packages/backend/src/extension.ts)). That is a **bundler-agnostic** pattern — a Vite-built React bundle satisfies it exactly as well as a Vite-built Svelte bundle. Svelte + Tailwind + `@podman-desktop/ui-svelte` is a *convention of the template*, not a requirement of the API.
- Under the hood, Podman Desktop runs a local **express** server bound to `127.0.0.1` on a free port from 44000, serves each webview's files out of that extension's install directory under a per-webview hostname `<uuid>.webview.localhost:<port>`, and renders it in an Electron `<webview>` element whose `src` is that origin ([`webview-registry.ts`](https://github.com/podman-desktop/podman-desktop/blob/main/packages/main/src/plugin/webview/webview-registry.ts), [`webview-impl.ts`](https://github.com/podman-desktop/podman-desktop/blob/main/packages/main/src/plugin/webview/webview-impl.ts), [`Webview.svelte`](https://github.com/podman-desktop/podman-desktop/blob/main/packages/renderer/src/lib/webview/Webview.svelte)). Two consequences that matter: the page is served over **plain HTTP from a loopback origin** (so talking to another loopback HTTP server is not a mixed-content problem), and `asWebviewUri()` **passes `http`/`https` URIs through unchanged** — the API was written expecting extensions to point at HTTP resources.

That leaves two viable hosting options, and they differ in one thing that this document has already been bitten by: version skew (§14 R14).

| Option | How | Verdict |
|---|---|---|
| **A — ship the bundle in the extension** | Copy `src/aap_demo/gui/static/**` into the extension image's `media/` at build time; rewrite asset URLs with `asWebviewUri()` per the full template; the SPA calls `http://127.0.0.1:<port>/api/…` cross-origin. | **Fallback.** Works, and it is the officially-templated path. Costs: the SPA now exists in two artifacts with independent release cadences (catalog image vs. PyPI wheel), which is R14 recreated across a channel boundary; and every API call and the SSE stream become cross-origin, so FastAPI needs a CORS policy admitting `http://<uuid>.webview.localhost:<port>` — an origin whose port is chosen at Podman Desktop startup, so the allowlist must be a regex, which is exactly the kind of permissive CORS rule §14 R18 should not want on a server that returns admin credentials. |
| **B — frame the backend's own server** | `webview.html` is a ~20-line shell document containing a full-bleed `<iframe src="http://127.0.0.1:<port>/?embedded=1">`, plus a `<meta http-equiv="Content-Security-Policy">` permitting `frame-src http://127.0.0.1:*`. The SPA is served by the same FastAPI app that serves it in the standalone GUI, **same-origin with its own API**. | **RECOMMENDED.** One SPA artifact, no CORS, no cross-channel skew, and the extension carries no frontend build at all — it is a few hundred lines of TypeScript. The `?embedded=1` flag lets the SPA drop its own masthead chrome so it reads as a Podman Desktop page. |

**What is genuinely unverified, and needs hands-on time.** Whether an Electron `<webview>`'s guest page may frame a *different* loopback origin without Podman Desktop interfering. Nothing in the express router sets `X-Frame-Options` or a CSP response header (it is a bare `res.sendFile`), and our own FastAPI server controls its own headers, so the expected answer is yes — but "expected" is not "observed", and the second-order question (whether the extension host can `postMessage` into a *cross-origin* iframe without a relay in the shell page) has no answer from reading alone. This is spike-gated as **§13 Q25**, in the same style as Q21, and it is cheap: the fallback is Option A, which is known to work because it is what the official template does.

**Either way the answer to the framing question is the same and can be locked now: no Svelte rewrite, and no second UI implementation.** §9's SPA is the GUI for all three channels.

### 11.3 Extension architecture — a fourth adapter, not a fourth implementation

The discipline this document enforces everywhere else applies here without exception. `cli/`, `gui/`, and `desktop/` are adapters over one core (§2 module-boundary rules); the extension is the fourth, and it is the only one written in another language, which makes the rule *more* important rather than less:

> **The Podman Desktop extension contains no orchestration logic.** It does not know what an SCC is, what a CatalogSource is, or in what order `cluster/bootstrap.py`'s steps run. It starts a backend process, opens a webview onto it, mirrors a little status into Podman Desktop's own UI, and gets out of the way. Any behavior the extension appears to need that does not exist as a callable in `core/`/`cluster/`/`addons/`/`day2/` is added *there*, not in TypeScript — identical to §9.1's rule for `gui/`.

Concretely, the extension's TypeScript owns exactly five things:

1. **Backend lifecycle** — resolve, spawn, health-check, and shut down the Python server (§11.4).
2. **The webview panel** — create it, point it at the backend, dispose it (§11.2).
3. **Podman Desktop surface** — commands, configuration properties, an onboarding flow, and a status contribution so the cluster's state is visible in Podman Desktop's own chrome without opening the panel.
4. **Interop with `redhat.openshift-local`** — detection, preset reporting, and the three known-failure-mode messages (§11.6).
5. **Credential brokering** — reading the pull secret path CRC already knows about, and holding any aap-demo-specific secret in Podman Desktop's `SecretStorage` (§11.7).

Everything else is an HTTP call to `http://127.0.0.1:<port>/api/…` — the **same API surface already tabulated in §9.1**, with no extension-specific routes. If the extension needs a status summary it calls `GET /api/status`; if it needs to start a deploy it `POST`s `/api/deploy` and gets a job id back, exactly as the browser does. The event stream (§9.4) is the mechanism for progress here too: the extension subscribes to `GET /api/jobs/{id}/events` with an `EventSource`-equivalent and maps `kind="step"` events onto a Podman Desktop status label, making it a **fourth consumer of `core/events.py`** alongside the CLI console renderer, the browser, and the tray (§10.6.1). No new abstraction is introduced by this section anywhere in the Python package.

**One new backend requirement, and it is small:** the FastAPI app must accept an `--embedded` mode that (a) binds an ephemeral port rather than the fixed 8720, (b) writes its chosen port and a session token to a file the parent process names, and (c) exits when its parent dies or when a shutdown token is presented. Points (a) and (b) already have an analogue in `desktop/server.py`'s `runtime.json` (§10.6.1) and should share that code rather than duplicating it.

### 11.4 Getting the Python backend onto the machine — **DECIDED: a managed, pinned venv**

This is the hard part of the channel and the one a naive design gets wrong. Podman Desktop extensions are Node/TypeScript running inside Electron; they cannot import Python. The extension needs a real `aap-demo` on the machine, at a version it can rely on.

| Option | Verdict |
|---|---|
| **Require a preexisting `pip install aap-demo` on `PATH`** | Rejected as the *only* mechanism. It reproduces the exact gap Podman Desktop's own tracker records against the CRC extension — it "does not automatically download the `crc`/`microshift` binaries when they are missing" ([podman-desktop#2659](https://github.com/podman-desktop/podman-desktop/issues/2659)) — and the maintainer explicitly asked for this one to actually work. Kept only as a *detection* path (see the resolution order below), because a developer with an editable checkout must be able to point the extension at it. |
| **Bundle a full embedded CPython in the extension image** | Rejected for v1, not on principle but on arithmetic and process. The publish docs support **per-platform OCI images referenced through a manifest**, so it is mechanically possible — but it inflates a normally single-digit-megabyte extension image by ~40 MB of interpreter plus ~35 MB of dependencies per platform, and it moves every aap-demo backend fix onto the *catalog's* release path (an `extensions.json` PR in someone else's repo) instead of PyPI's. It also duplicates the §8.1 Q8 decision in a place where the 3.9 floor no longer applies at all. Revisit only if §13 Q26's failure rate says to. |
| **Run the backend in a container** (podman is guaranteed present here) | Rejected, and worth writing down because it looks clever. The backend's whole job is to drive `crc`, `oc`, `kubectl`, and `ssh` **on the host**, mutate the host kubeconfig, and manipulate the host trust store (§6.2). A container would need host PID/network/filesystem access broad enough that it is a container in name only, and CRC's own socket layout differs per OS. Delegation to host binaries is ADR-001; containerizing the delegator inverts it. |
| **A managed virtual environment created by the extension** | **CHOSEN.** |

**The decided mechanism.** On activation the extension resolves a backend in this order, first hit wins, and reports which one it used in its status output so support conversations are not guesswork:

1. `aapDemo.backend.path` — an explicit path from extension configuration. This is the developer/editable-checkout escape hatch and the CI hook.
2. The **managed venv** at `<extensionContext.storagePath>/venv`, if present *and* its `aap-demo --version` matches the version this extension pins.
3. `aap-demo` on `PATH`, if present and version-compatible — with a **warning, not adoption**, when the version is outside the pinned range.
4. Nothing found → the extension does not fail. It surfaces an **onboarding step** (§11.5) titled "Install the aap-demo backend", which on confirmation:
   - probes for a host Python ≥ 3.9 (`python3`, `python`, and the OS-typical locations), via `extensionApi.process.exec` — never `shell: true`;
   - creates `<storagePath>/venv` with `-m venv`, upgrades pip inside it, and runs `pip install "aap-demo[gui]==<pinned version>"` into it, streaming output into the onboarding log so a proxy or a corporate TLS interception failure is visible rather than mysterious;
   - re-runs the resolution and reports the result.

**The pin is the important part.** The extension's own version and the wheel version it installs are the **same number**, bound by `cz bump` exactly as `[tool.briefcase].version` already is (§8.1, §10.11). An extension at 2.3.0 installs `aap-demo==2.3.0`. This makes the extension/backend pair as skew-proof as the desktop bundle, and it means a backend upgrade is delivered by Podman Desktop's own extension-update mechanism with no `pip` in the user's face.

**If no host Python ≥ 3.9 exists** — realistic on Windows — the onboarding step does not dead-end. It offers to download a [python-build-standalone](https://github.com/astral-sh/python-build-standalone) runtime into `<storagePath>/runtime`, verified against a SHA-256 pinned in the extension image, then builds the venv from it. This is the same detect-then-offer-to-install shape `crc-extension` already uses for the `crc` binary itself, and the same pattern §13 Q6 settled on for the CLI (`detect and instruct` by default, explicit opt-in to install) — here the opt-in is a button, which is what a GUI channel is for. It is also, deliberately, the fix for #2659's *class* of problem rather than a note that someone else has it.

**Process lifecycle.** The extension spawns the backend as a child process with `--embedded`, on an ephemeral loopback port, with a per-session token; kills it on `deactivate()` and on window close; never leaves it running after Podman Desktop exits (an orphaned server holding cluster admin credentials on an unknown port is §14 R18's nightmare). Long-running *jobs* are unaffected in the way that matters — a deploy's durability story here is §10.8's, minus the tray: quitting Podman Desktop ends the backend and therefore the job's subprocesses, and the interrupted-job resume card (§10.8) is what the user sees next time. The extension must present the same "a deploy is in progress" confirmation before it tears the backend down.

### 11.5 Extension manifest and contribution points

Repository layout (a **separate repo**, for the reasons in §11.8 — it must be able to live under a Red Hat org):

```text
aap-demo-podman-desktop/            # separate git repo
  package.json                      # the extension manifest — sketched below
  icon.png                          # 128×128, required by the catalog
  LICENSE.txt  README.md            # required assets for the catalog entry
  src/
    extension.ts                    # activate()/deactivate() — the only two entry points
    backend/resolve.ts              # §11.4 resolution order
    backend/install.ts              # venv creation, pinned pip install, runtime download
    backend/process.ts              # spawn, health probe, token, shutdown
    webview/panel.ts                # §11.2 shell document + panel lifecycle
    crc/interop.ts                  # §11.6 detection + the three known-failure messages
    status.ts                       # /api/status + job events -> Podman Desktop status
  vite.config.ts  tsconfig.json
  Containerfile                     # scratch image with the required OCI labels (§11.9)
```

`package.json`, at the level of detail §4.3's addon manifest and §9.1's API table are specified:

```jsonc
{
  "publisher": "redhat",                       // see §11.8 — this is a claim, and it has to be earned
  "name": "aap-demo",
  "displayName": "Ansible Automation Platform Demo",
  "description": "Deploy Ansible Automation Platform to OpenShift Local",
  "version": "2.3.0",                          // == the aap-demo wheel version it installs (§11.4)
  "icon": "icon.png",
  "license": "Apache-2.0",
  "type": "module",
  "engines": { "podman-desktop": ">=1.10.0" }, // the floor createWebviewPanel needs
  "main": "./dist/extension.cjs",

  "extensionDependencies": ["redhat.openshift-local"],   // §11.6

  "contributes": {
    "commands": [
      { "command": "aapDemo.open",            "title": "AAP Demo: Open dashboard" },
      { "command": "aapDemo.status",          "title": "AAP Demo: Show cluster status" },
      { "command": "aapDemo.openConsole",     "title": "AAP Demo: Open AAP web console" },
      { "command": "aapDemo.copyAdminPassword", "title": "AAP Demo: Copy admin password" },
      { "command": "aapDemo.backend.install", "title": "AAP Demo: Install or repair the backend" },
      { "command": "aapDemo.backend.restart", "title": "AAP Demo: Restart the backend" },
      { "command": "aapDemo.mustGather",      "title": "AAP Demo: Collect diagnostics (must-gather)" }
    ],
    "configuration": {
      "title": "AAP Demo",
      "properties": {
        "aapDemo.backend.path":      { "type": "string", "default": "",
                                       "format": "file",
                                       "description": "Path to an existing aap-demo executable. Leave empty to use the managed environment." },
        "aapDemo.backend.autoInstall": { "type": "boolean", "default": false,
                                       "description": "Create the managed Python environment without asking." },
        "aapDemo.namespace":         { "type": "string", "default": "aap-operator" },
        "aapDemo.pullSecretPath":    { "type": "string", "default": "", "format": "file",
                                       "description": "Leave empty to reuse the pull secret configured for OpenShift Local." },
        "aapDemo.day2.enabled":      { "type": "boolean", "default": true,
                                       "description": "Show day-2 operations (requires a container engine — see §11.11)." }
      }
    },
    "onboarding": {
      "title": "AAP Demo Setup",
      "priority": 50,
      "enablement": "!onboardingContext:aapDemoReady",
      "steps": [
        { "id": "checkCrcExtension", "title": "Checking OpenShift Local",
          "command": "aapDemo.internal.checkCrc",
          "completionEvents": ["onCommand:aapDemo.internal.checkCrc"] },
        { "id": "installBackend",    "title": "Install the aap-demo backend",
          "when": "!onboardingContext:aapDemoBackendPresent",
          "command": "aapDemo.backend.install",
          "completionEvents": ["onCommand:aapDemo.backend.install"] },
        { "id": "pullSecret",        "title": "Red Hat pull secret",
          "when": "!onboardingContext:aapDemoPullSecret",
          "command": "aapDemo.internal.resolvePullSecret",
          "completionEvents": ["onCommand:aapDemo.internal.resolvePullSecret"] }
      ]
    }
  }
}
```

Notes the implementer must not casually change:

- **No `activationEvents`.** Neither `crc-extension` nor the Red Hat account extension declares any; Podman Desktop activates the extension and the work belongs in `activate()`. `activate()` must return fast and do its probing asynchronously — the CRC extension does exactly this (`activate` delegates to an unawaited `_activate(...).catch(console.error)`).
- **The onboarding shape is copied from `redhat.redhat-authentication`'s**, which is the closest official precedent for "this extension needs something set up before it is useful": a check step, a do-it step gated on an `onboardingContext:` key, and a failure step. Mirroring an existing Red Hat extension's structure is a §11.8 conformance decision, not a stylistic one.
- **Nothing destructive gets a command.** `destroy`, `clean`, and `redeploy-all` are reachable only inside the webview behind the typed confirmation §10.6.3 already requires. A Podman Desktop command palette entry that can delete a cluster is the same misfire the tray menu rules out.
- **`aapDemo.copyAdminPassword` copies and never reveals**, per §10.6.3.

### 11.6 Relationship to `crc-org/crc-extension` — **DECIDED: depend on it**

**Decision: declare `"extensionDependencies": ["redhat.openshift-local"]` and delegate VM lifecycle — create, start, stop, delete, preset — to the CRC extension. aap-demo's extension never runs `crc start` itself.**

The manifest field is **verified to exist and to be used exactly this way**: the extension API documents `extensionDependencies` as the mechanism for depending on another extension, and `crc-extension`'s own `package.json` declares `"extensionDependencies": ["redhat.redhat-authentication"]` (as does the account extension for `podman-desktop.podman`). So this is the ecosystem's own idiom, not an invention.

**Why depend rather than manage CRC directly.** Duplicating `crc-create.sh`'s logic across a fourth frontend is precisely what §2's module rules exist to prevent — but note that in *this* channel the duplication argument cuts differently from how it does for the CLI: the Python backend still contains all of `cluster/bootstrap.py`, and the extension could simply call it. The reason not to is ecosystem, and it is the same reason the whole section exists: two Red Hat extensions racing each other for the same VM — one via `provider.registerKubernetesProviderConnection`, one via a Python subprocess — is a bad citizen, produces contradictory state in Podman Desktop's own UI, and is the first thing a reviewer from `crc-org` would object to. Delegating is the choice consistent with the adoption goal.

**What delegation actually buys, and does not.** A material finding: **`crc-extension` exports no public API.** Its `activate()` returns `void`, so `extensions.getExtension('redhat.openshift-local').exports` is empty and there is no typed surface to call. Delegation therefore means:

- **Presence and activation ordering** are guaranteed by the dependency edge, and Podman Desktop installs the dependency for the user. That is the real value.
- **VM state** is read through Podman Desktop's own API — `provider.onDidUpdateKubernetesConnection` for connection state and `kubernetes.getKubeconfig()` for the active kubeconfig — not through the other extension. Note the asymmetry the implementer will hit: there is a `provider.getContainerConnections()` but no `getKubernetesConnections()`, so the current connection state must be tracked from the event plus a `crc status` read at activation.
- **Actions the user must take on the VM** (create it, start it, switch preset) are *directed*, not performed: the extension's empty-state panel says what is needed and points at Podman Desktop's own Resources page, in the same "fail with fixes, not just errors" spirit as ADR-001 and §10.10's prerequisite affordances.

**Inheriting the dependency's bugs, and designing for them explicitly.** This is the cost of the decision and it must be paid in code, not in a caveat. Three known upstream defects become aap-demo's user-visible failure modes; each gets detection and a specific message rather than a confusing crash:

| Known defect | How it surfaces to an aap-demo user | Required handling |
|---|---|---|
| **Preset cannot be switched after cluster creation without recreating** ([podman-desktop#4617](https://github.com/podman-desktop/podman-desktop/issues/4617)) | A user with an existing `openshift`-preset cluster picks a MicroShift-targeted configuration (or the reverse) and the deploy fails deep inside OLM or storage with an unrelated-looking error. | At panel open and again at deploy-plan time, read the live preset (`crc config get preset` via the backend, cross-checked against the `crc.crcPreset` context key the CRC extension sets) and compare it to the deploy plan. On mismatch, **block the deploy** with: what preset the cluster is, what the plan needs, and the fact that changing it requires deleting and recreating the cluster — with a link to the Resources page, and the upstream issue number so the user knows it is not our bug. This check belongs in `POST /api/deploy/plan`'s warnings (§9.1) so the CLI gets it too. |
| **Extension self-update failures** ([crc-org/crc-extension#176](https://github.com/crc-org/crc-extension/issues/176)) | The CRC extension is present but at a version whose behavior we did not test against; or an update silently did not apply. | Record a tested-against version range in our own manifest, read the dependency's `packageJSON.version` through `extensions.getExtension('redhat.openshift-local')`, and show a non-blocking banner naming both versions when it is outside the range. Never hard-fail on it — a version we have not tested is usually fine, and blocking on it would make our channel hostage to someone else's release cadence. |
| **`crc`/`microshift` binaries are not auto-downloaded when missing** ([podman-desktop#2659](https://github.com/podman-desktop/podman-desktop/issues/2659)) | Extension installed, no `crc` on the machine, nothing obviously wrong — just nothing works. | Detect it ourselves in the onboarding's `checkCrcExtension` step and render the same deep-linked download affordance §10.10 specifies for the desktop channel. We do **not** install `crc` on the CRC extension's behalf (that is its job and its update story), but we refuse to let its absence be silent. |

**One more interop hazard, not previously recorded anywhere in this document.** `crc-extension` registers its Kubernetes connection with a **hardcoded** `apiURL = 'https://api.crc.testing:6443'`, while `includes/crc-create.sh` deliberately reconfigures the cluster's base domain to `nip.io` — a step that, per §14 R1, *wipes MicroShift data* because CRC starts on `crc.testing` before the dropin can be written. Running `aap-demo create` under this extension therefore leaves Podman Desktop displaying a stale API URL for a cluster whose ingress no longer matches, and the `nip.io` reconfiguration may not be a thing a user of the CRC extension expects to happen to their VM. This is tracked as **§14 R26** and it is the single most likely source of "the two extensions disagree" bug reports.

### 11.7 Credentials, and the Red Hat Account extension — **DECIDED: consume, do not integrate**

Verified: the account extension (`redhat.redhat-authentication`) registers an authentication provider with id `redhat.authentication-provider`, and on sign-in **creates or reuses a Red Hat registry service account and registers `registry.redhat.io` in Podman Desktop's own registry list**. `crc-extension` depends on it, and CRC's own `crc.factory.pullsecretfile` setting documents that when no pull-secret file is given the user is prompted to sign in with Red Hat SSO and download the pull secret. Podman Desktop also exposes an OS-native `SecretStorage` on the extension context (`get`/`store`/`delete`), which is what §13 Q16's "credentials in OS-native secure storage, not files or env vars" asks for.

**The decision, in three parts:**

1. **Do not register our own authentication provider, and do not build an SSO flow.** Two Red Hat sign-in prompts inside one application is a worse experience than one, and re-implementing SSO is a security surface we have no reason to own.
2. **For the pull secret: consume what CRC already has, rather than integrating with the account extension for v1.** The extension resolves `PULL_SECRET_PATH` in the order: `aapDemo.pullSecretPath` setting → the path CRC is configured with (`crc config get pull-secret-file`) → `<state>/pull-secret.json` (§5.2) → the legacy `~/.aap-demo/` locations. This is a handful of lines, it reuses a credential the user has already placed for a cluster they have already created, and it removes the §10.10 paste-box step entirely in this channel. It is also honest about scope: an OpenShift pull secret is a multi-registry document, whereas what the account extension mints is a **registry service account for `registry.redhat.io`** — related, but not the same artifact, and composing one from the other is a v1.1 feature, not a v1 shortcut. Tracked as **§13 Q27**.
3. **For aap-demo's own secrets — the boundary moved in revision 5, and this clause is narrowed accordingly.** When §11 was written, Podman Desktop's `SecretStorage` was the *only* OS-native credential store in the design, and this clause noted that it did not generalize to the other channels. **§5.5 now generalizes it**: every channel — CLI, standalone GUI, desktop app, and this extension — stores aap-demo's own credentials in the OS keyring through the *same* `core/secrets.py`, because all four run the same Python backend. So:

   - **The AAP admin password, the Galaxy/PAH tokens, the portal OAuth tokens, and the `apme-eap` GitHub credential live in the OS keyring (§5.5), not in `SecretStorage`.** They are the backend's data, they must be readable by the CLI afterwards, and duplicating them into a second store would be a bug rather than defense in depth. `aapDemo.copyAdminPassword` therefore calls the backend, which reads the keyring and writes the host clipboard (§9.5.1) — the extension never holds the value.
   - **`extensionContext.secrets` holds exactly one thing: the extension-to-backend session token** (§11.3). It is created per backend process, means nothing outside this extension, and is precisely what a per-extension secret store is for.
   - **The Red Hat Account extension's own token storage stays entirely its own.** It mints a `registry.redhat.io` registry service account and stores it; we consume the *pull secret path* CRC already knows about (part 2 above) and store nothing on its behalf. Two separate, already-secure mechanisms with a clean boundary — not a contradiction, and not something to unify.

### 11.8 What "official adoption" actually requires — researched, with the honest gaps

**What is documented, and verified:**

- **Publishing is an OCI image plus a catalog PR.** An extension is packaged as a `scratch`-based OCI image carrying `org.opencontainers.image.title`/`.description`/`.vendor` and — mandatory — `io.podman-desktop.api.version` declaring the minimum compatible Podman Desktop, with `package.json`, the icon, and the built output under `/extension`. Platform-specific binaries are handled with per-platform images behind a manifest ([publishing docs](https://github.com/podman-desktop/podman-desktop/blob/main/website/docs/extensions/publish/index.md)).
- **Listing is a pull request** against `podman-desktop/podman-desktop-catalog`, adding an entry to `static/api/extensions.json` along with the README, LICENSE, and icon assets. The entry shape is concrete and worth matching exactly: `publisher: {publisherName, displayName}`, `extensionName`, `displayName`, `shortDescription`, `license`, `categories`, `keywords`, and a `versions[]` array each with `version`, `preview`, `lastUpdated`, `ociUri`, and the asset `files[]`.
- **The Red Hat extension pack is itself an extension.** `redhat-developer/podman-desktop-redhat-pack-ext`'s `package.json` is nothing but an `extensionPack` array listing `redhat.ai-lab`, `redhat.bootc`, `redhat.openshift-local`, `redhat.redhat-authentication`, `redhat.openshift-checker`, `redhat.redhat-sandbox`. **"Adopted officially by Red Hat" therefore has a concrete, checkable meaning**: a PR adding `redhat.aap-demo` to that array — which nobody will merge for a repo Red Hat does not own.
- **The existing official extensions share observable conventions**, and matching them from day one costs nothing: publisher `redhat`; Apache-2.0; TypeScript + Vite building a single bundled `dist/extension.cjs`; an `engines.podman-desktop` floor; `@podman-desktop/api` as a **devDependency** pinned to an exact version (it is provided by the host at runtime, so bundling it is wrong); vitest for unit tests and `@podman-desktop/tests-playwright` for e2e; ESLint + Prettier; all runtime deps bundled into the final artifact; images published to `ghcr.io` or `quay.io` under the owning org.

**What is not documented, stated plainly rather than invented.** There is **no published review rubric, quality bar, or acceptance criteria** for the catalog — the catalog repo has no README or CONTRIBUTING to that effect, and the publishing doc describes a mechanical process ending in "get your PR merged". Likewise there is **no published process for joining the Red Hat extension pack**; the developers.redhat.com page describing the pack lists its contents and says nothing about how something gets into it. So the following are assumptions to be **confirmed with the Podman Desktop and CRC teams**, not findings:

- That catalog acceptance is at maintainer discretion and effectively unreviewed for code quality, meaning listing is *not* the bar to aim for — pack membership is.
- That pack membership realistically requires the repository to live under `redhat-developer` (or `crc-org`, as the CRC extension does), the image to be published under a Red Hat-controlled registry namespace, and an internal owner/maintenance commitment — because every current pack member has all three.

**The design consequence, and it is not a small one:** the `publisher: "redhat"` field in §11.5 and the `redhat.aap-demo` id are a **claim of ownership that must be granted before it is published**. Publishing an extension under the `redhat` publisher name from a repository Red Hat does not control is exactly the wrong first impression to make on the team whose adoption is the goal. Until ownership is arranged, publish under a neutral publisher and rename at donation time — a rename is cheap at that point because the catalog entry is a PR, and expensive later once users have it installed. This ask should ride along with §13 Q22's signing-identity request, since both are the same conversation with the same organization. Tracked as **§13 Q28**.

**Day-one conformance checklist**, so nothing here is retrofitted: Apache-2.0 + DCO sign-off; TypeScript with the same ESLint/Prettier configuration the CRC extension uses; `@podman-desktop/api` pinned as a devDependency; vitest unit tests with coverage; a `@podman-desktop/tests-playwright` smoke test; conventional commits (the aap-demo repo already enforces them via `.commitlintrc.json`); a README with screenshots; an `icon.png`; and telemetry via `env.createTelemetryLogger` **off by default and respecting the host's telemetry setting** — every official extension has one, and adding it later is a privacy-review conversation nobody wants mid-donation.

### 11.9 Packaging, versioning, and the release pipeline

One version, one tag; the extension image becomes the fifth artifact in §10.11's table:

| Artifact | Built by | Signed with | Published to |
|---|---|---|---|
| `ghcr.io/<org>/aap-demo-podman-desktop:X.Y.Z` (multi-platform manifest) | `vite build` + `podman build` from the `Containerfile`, on a tag ref | Not code-signed — it runs inside Podman Desktop's signed application (§11.0). Sign the image with sigstore/cosign anyway; it costs nothing and the ecosystem is moving that way. | GHCR/Quay, then a catalog PR (§11.8) |

Pipeline constraints, in addition to §10.11's:

- **The extension version and the wheel version are the same number**, added to `[tool.commitizen].version_files` alongside `VERSION`, `__init__.py`, and `[tool.briefcase].version` — this is what makes §11.4's pin work, and it is the same anti-drift move §13 Q24 already settled for the desktop app.
- **Publish order: PyPI first, extension image second, catalog PR third.** An extension that pins `aap-demo==X.Y.Z` before that wheel exists on PyPI is an extension whose install step 404s. This is the same "manifest last" discipline as §10.5, applied one channel over.
- **A packaged-extension smoke test**, mirroring §10.11's packaged-app test and §14 R24's tripwire: on a clean runner, install the built OCI image into a Podman Desktop instance, activate it, let it build the managed venv, and assert that `GET /api/addons` through the spawned backend lists the full tier-2 set. This is the check that catches "the venv install worked on the maintainer's machine".
- **Skew guard.** The extension refuses to drive a backend whose `GET /api/version` reports a version outside its pinned range, and says which two versions disagree — the same failure §14 R14 designs against for the SPA bundle, in the one place where two independently-released artifacts must agree.

### 11.10 Testing

The extension is thin by construction, so its test burden is small and mostly about the seams:

- **vitest unit tests** over `backend/resolve.ts` (each branch of the resolution order, including a version-mismatch on `PATH`), `crc/interop.ts` (each of the three known-defect detections and its message), and the webview shell's URL/CSP construction — with `@podman-desktop/api` mocked, which is how `crc-extension`'s own `*.spec.ts` files are written.
- **No test in this repo asserts cluster behavior.** That is `tests/unit/` in the Python package (§7) and it is not duplicated here; the extension's contract with the backend is the §9.1 API, which already has `httpx.ASGITransport` coverage.
- **One Playwright e2e** via `@podman-desktop/tests-playwright`: install the extension, activate, assert the panel opens and renders the SPA against a `FakeRunner`-backed backend started with `--embedded`. This is the test that would have caught a webview/CSP regression, and it is the empirical answer to §13 Q25 once it exists.

### 11.11 Scope for v1 — and the one thing this channel gets that the desktop channel does not

**Day-2 operations are IN scope for this channel**, which is a deliberate inversion of §10.9 and follows from §4.5's own sorting rule rather than contradicting it. §10.9 excludes tier 3 from the desktop channel because *that* audience is not the operator and has no container engine. Here both premises flip: the audience **is** the operator, and a container engine is not merely present but is the entire reason the application exists. `ansible-navigator` still has to be installed — it comes along with the managed venv at no extra cost, since the venv is ours (`pip install "aap-demo[gui]"` plus `ansible-navigator`) — and the Podman machine's readiness is already Podman Desktop's own concern, so §10.9's "podman on PATH with no running machine" detection problem is one Podman Desktop has already solved and displays. The Operations page (§9.2) is therefore shown, gated on `aapDemo.day2.enabled` and on a runtime probe.

**Out of scope for v1**, each as an explicit cut rather than an omission:

- **A native Podman Desktop UI beyond the webview panel.** No custom Kubernetes-page contributions, no image-page menu items. One panel plus the status contribution; grow later if the pattern proves out.
- **Managing the CRC VM ourselves** (§11.6).
- **Bundling a Python runtime** in the image (§11.4, §13 Q26).
- **Composing a pull secret from the account extension's registry service account** (§11.7, §13 Q27).
- **Linux packaging concerns** — irrelevant here in a way they are not for §10: Podman Desktop runs on Linux, the extension is platform-neutral TypeScript, and so this channel gives Linux users the GUI experience §13 Q19 declines to build an installer for. That is a genuine, free win worth stating.

---

## 12. Migration and rollout

### 12.1 Coexistence

The bash tool and the Python tool can be installed side by side. Both would claim the name `aap-demo` on PATH (`install.sh` symlinks `~/.local/bin/aap-demo`; pip installs to the same kind of location), so the transition needs one of:

- **Recommended**: during the overlap, the Python package installs as `aap-demo` and the bash tool is renamed by the user to `aap-demo-legacy` (a one-line note in the migration doc), or
- the Python package ships as `aap-demo2`/`aapd` during beta and takes the canonical name at 2.0.0 GA.

Rev 1 assumed both tools would share `~/.aap-demo/` byte-for-byte, which made coexistence free. The YAML and platformdirs decisions (§5) end that: **there is now a real state migration**, and it constrains how long the two tools can overlap. See §12.2.

### 12.2 State migration — **required** (supersedes rev 1's "no migration required")

Two changes land together: the config file's format (`KEY=VALUE` → YAML, §5.1) and the directory layout (flat `~/.aap-demo/` → platformdirs-native config/cache/state, §5.2). Both must be automatic, one-time, and reversible.

**Migration behavior, on first run of any command:**

1. If `<config>/config.yaml` exists → nothing to do. (Check this first; migration must cost nothing on every subsequent invocation.)
2. Else if `~/.aap-demo/` exists → run the migration:
   - Parse the legacy `config` file's `KEY=VALUE` lines with the same permissiveness bash had (ignore blanks and `#` comments, strip surrounding quotes, last-wins on duplicates). Map each key to its schema field via the `x-env`/legacy-name mapping in `core/schema.py` (§9.3) — the same table that makes the env vars work, so there is no second mapping to drift.
   - Split `ADDONS=a,b,c` into `addons.enabled`, normalizing aliases (`ao-eap` → `ao`) through the registry, and **dropping `registry` and `local-cache`** with an explicit message naming their day-2 replacements (§4.8.5) — silently dropping them would look like data loss.
   - Write `<config>/config.yaml` with a header comment recording the migration date and the source path.
   - **Move** state files (kubeconfig, certs, addon state dirs) to `<state>/` per the §5.2 table. **Move**, not copy — a stale kubeconfig that silently keeps working is a debugging nightmare.
   - **Import credentials into the OS keyring and then delete the source files** (§5.5): the Galaxy token, the PAH token, the `apme-eap` GitHub token, and the portal OAuth tokens. Deleting is the point — a migration that leaves the plaintext behind has not migrated anything, it has made a second copy. The pull secret is not a keyring candidate (§5.5.1). A leftover `atf-vault-password` is neither imported nor deleted. If no keyring backend is available (§5.5.3), the credential import **is skipped with a loud message naming the files it did not touch** and the rest of the migration proceeds — a migration must never be the thing that hard-fails on a headless box.
   - **Leave the ~30 GB `local-cache/` where it is** and print its path with the reclaim command. Moving 30 GB during what the user thinks is a `status` invocation is unacceptable; so is deleting it.
   - Leave `~/.aap-demo/` itself in place with a `MIGRATED.txt` naming the new locations. Do not delete a directory containing user-placed files.
3. Else → write a fresh `config.yaml` from schema defaults.

**Guarantees the implementer must hold:**

- **Idempotent and crash-safe.** Write the new config to a temp file and `os.replace` it; move state files one at a time and re-check existence, so an interrupted migration resumes correctly.
- **Dry-runnable.** `aap-demo config migrate --dry-run` prints the plan without touching anything, and `--force` re-runs it. The automatic path must also be skippable via `AAP_DEMO_SKIP_MIGRATION=1`.
- **`AAP_DEMO_DIR` still collapses everything back under one root** (§5.2). Users who genuinely want the old shape, and CI, set it and nothing moves.
- **Legacy read paths persist for the user-placed pull secret.** Discovery keeps checking `~/.aap-demo/` for `pull-secret*` indefinitely, and `PULL_SECRET_PATH` keeps working. A leftover `atf-vault-password` is ignored.
- **Test it with a fixture of a real legacy directory** — `tests/unit/test_migration.py` over a `tests/fixtures/legacy_home/` tree covering: full config, empty config, config with only `ADDONS`, config with `registry`/`local-cache` enabled, no config at all, and a partially-migrated directory.

**Coexistence consequence.** Once migrated, the bash tool no longer sees the user's config: it reads `~/.aap-demo/config`, which the Python tool has stopped writing. So the two tools **cannot** be flipped between per-invocation after migration, and rev 1's phase plan (which assumed they could through phase 4) needs the adjustment in §12.4: run the Python tool with `AAP_DEMO_DIR=~/.aap-demo` during the overlap, which keeps both in the legacy layout, and perform the layout migration at the 2.0.0 cutover rather than at first install of a beta. The **format** migration is unavoidable at first run; the **location** migration is deferrable, and deferring it is what preserves the phased rollout.

New addons get `<state>/addons/<name>/` via `ctx.paths.addon_dir` and `<cache>/addons/<name>/` via `ctx.paths.addon_cache`.

### 12.3 `update` and the auto-update nag — behavior change (called out)

`cmd_update` (`aap-demo.sh:797`) does `git pull` + re-run `install.sh`, and `_check_for_updates` (`aap-demo.sh:2792`) fetches from the git remote before `status`, throttled to once per 4 hours, prompting with a 10-second timeout, skipped in CI and non-TTY. Neither is meaningful for a pip-installed package.

New behavior:

- `aap-demo update` → detects the install mode. Git checkout (editable/dev install) → keep `git pull` and tell the user to re-run `pip install -e .` if metadata changed. Wheel install → `pip install -U aap-demo` (or print the exact command; running pip on yourself from inside the process is fragile — prefer printing, and gate actually doing it behind `--yes`).
- The `status` auto-check → query the configured index for a newer version, same 4-hour throttle via `.last_update_check`, same CI/non-TTY skip, same non-blocking behavior. If distribution is git-based (§8.3), keep the `git fetch` form.

Flag this in release notes: the 10-second auto-pull prompt disappears for wheel installs.

### 12.4 Phased command coverage

The rewrite should not land atomically. Suggested order, each phase independently shippable and testable:

| Phase | Contents | Exit criterion |
|---|---|---|
| **0. Skeleton** | `pyproject`, `exec/runner.py`, `core/{console,context,errors,version}`, **`core/schema.py` (the JSON Schema documents + `cli/_schema_args.py`) + `core/config.py` (YAML) + `core/paths.py` (strict XDG paths, §5.2) + `core/secrets.py` (§5.5) + the legacy-config and credential migration**, `core/events.py`, CLI skeleton with every command stubbed, `FakeRunner`, CI wired | `aap-demo --help` matches today's `show_help` content; `test_schema_parity.py` green; migration fixtures pass; `test_secrets.py` green including the no-backend hard-failure path; unit CI green on macOS/Linux/Windows. **The schema, config, and secrets layers must land in phase 0** — everything downstream derives its flags from it, and retrofitting it later is the one thing that would guarantee the parity mechanism never happens. |
| **1. Read-only** | `status`, `version`, `config`, `redhat-status`, `diagnose` (no `--ai`), `kubeconfig`, `ssh` | Output parity with bash on a live cluster, verified manually side by side |
| **2. Cluster ops** | `start`, `stop`, `idle`, `watch`, `repair`, `must-gather`, `diagnose --ai` | Same |
| **3. Deploy path** | `deploy`, `clean`, `redeploy`, `setup`, `cluster/{namespace,scc,olm,storage,coredns,aap,catalog_signature}` | A real `deploy` reaches a healthy AAP; first `@pytest.mark.integration` tests land |
| **4. Create path** | `create`, `destroy`, `redeploy-all`, `cluster/bootstrap.py`, `trust/` on all three OSes. **MicroShift preset only** — the OpenShift preset is phase 4b, not this phase (rev 6). Port upstream's post-branch-point create behavior with it: CRC stability wait (PR #199), the Linux temp-swap prompt (PR #130), and the unsupported-CRC warning (PR #167). | Windows user creates a cluster end-to-end with no Git Bash, on MicroShift |
| **4b. Full OpenShift preset support** | Preset-aware branches in `create`/`destroy`; the wizard's preset selector goes from disabled to live (§9.2's preset field); `registry-mirror`'s `image-registry-operator` path (§4.8.5); **R26 resolution** — first investigate reconfiguring the OpenShift preset onto `nip.io` (which would eliminate R26 rather than mitigate it), fall back to R26's confirmation-before-recreate mitigation if that doesn't pan out; ADR-038 written (rev 7 renumber; this row originally said ADR-032) | Full `create`→`deploy`→`destroy` on the OpenShift preset, on at least one OS. **Not a v1 blocker** (rev 6) — can land any time after phase 4, including after GUI/desktop/extension phases, at the maintainer's discretion. |
| **5 + 6. Addon platform and migration — one combined phase** | `addons/` API, discovery, state, `addon list/info/create`, the `wire` command (§3.3.1), the tier-1 built-ins, **and** the full tier-2 port: product-demos family, portal, portal-operator, mcp-server, apme-eap, ao (collapsing ao-eap), ollama, opa, fleet (§4.7) | **Merged in rev 5 because §13 Q5 decided against the `LegacyShellAddon` shim.** Rev 2 split these into two shippable phases precisely because the shim let phase 5 go out before the ports were done; with no shim there is no shipping boundary between them, and pretending otherwise would hide the real release date. Exit criterion: `enable`/`disable` parity for every ported addon, tier-2 distributions published to PyPI, third-party addon authoring documented — and **nothing ships before all of it is done** except `devspaces`, which is deferred and explicitly not a blocker (§13 Q18). The internal split is still useful as a work order; it is just not a release boundary. |
| **6b. Day-2 playbooks repo** | `aap-demo-playbooks` repo created, EE built and published (issue #92), `day2/` package, `playbooks list/info/run/create/update`, `registry-mirror` playbook (**MicroShift path only** — its OpenShift-preset `image-registry-operator` branch belongs to phase 4b, §4.8.5, rev 6), **`image-store` feasibility spike (§4.8.5) then the chosen mode**. Read upstream's updated ADR-021 and `includes/persistent-crio-store.sh` before the spike (rev 7): bash now auto-loads the OCI cache on deploy and prompts to save it on destroy (PR #158), and Linux has an opt-in host disk that macOS does not. | `playbooks run registry-mirror` matches the old `enable registry` result on the MicroShift preset; the spike's answer is recorded in an ADR either way. Can run **in parallel with phase 5+6** — different repo, different people, no shared code beyond the manifest schema. Ships in the same combined release, since §13 Q5's clean cutover means `registry`/`local-cache` disappear as addons on the same day these replace them. |
| **7. GUI** | `gui/` package, FastAPI API, job/SSE layer, PatternFly SPA, `[gui]` extra, bundle build in CI, **the Playbooks view (§9.2a) and the credential copy/reveal endpoints (§9.5.1)** | Wizard performs a full create→deploy→enable-addon on all three OSes, **on the MicroShift preset** (rev 6 — OpenShift-preset wizard support activates once phase 4b lands, whether that's before or after phase 7); Status page matches `aap-demo status` and contains no credential value in any payload (asserted, §9.5.1); Playbooks view runs a playbook end to end with live output and history; `test_schema_parity.py` still green with the GUI consuming the schema |
| **7b. Desktop shell** | `desktop/` package, tray icon + states + menu, embedded webview with browser fallback, single-instance lock, login-item toggle, interrupted-job resume card (§10.8), `aap-demo desktop` entry point | Runs from a `pip install "aap-demo[desktop]"` on macOS and Windows: tray reflects state, dashboard opens in the webview, quitting mid-deploy prompts and leaves a resumable record. **No installer yet** — this phase is pure Python and does not block on §10.4's certificates. |
| **7c. Native installers — macOS first, Windows second** | Briefcase config; **the macOS `.dmg`/`.pkg` build, signing, and notarization land first (§13 Q19)**, then the Windows `.msi` + Authenticode; `latest.json` update manifest and `updater.py`; packaged-app smoke test; bundle-size gate | A signed, notarized macOS installer opens on a clean machine with **no security warning**, then the same for Windows. Sequencing only: both OSes already have full function through the PyPI channel, so shipping the macOS installer first delays nobody's *capability*, only their double-click convenience. Gated on §13 Q21 (the freezer spike, which should run during phase 0) and §13 Q22 (signing identities, which must be requested at kickoff — this is the long pole, §14 R20). |
| **7d. Podman Desktop extension** | Separate `aap-demo-podman-desktop` repo; backend resolution + managed-venv bootstrap; webview panel over the same SPA; `extensionDependencies` on `redhat.openshift-local` plus the three known-defect detections; onboarding flow; OCI image build and catalog PR (§11) | Installing the extension on a clean machine with Podman Desktop and the OpenShift Local extension yields a working dashboard, a full create→deploy→enable-addon, and a day-2 `playbooks run`, with the backend installed by the onboarding flow and no terminal used. **Independent of 7c** — it needs no code-signing identity (§11.0), so it can ship while §13 Q22 is still outstanding. Gated on §13 Q25 (the webview spike, half a day, run it first) and on the phase-7 GUI existing. |
| **8. Retire** | Delete `aap-demo.sh`, `includes/`, `addons/*/deploy.sh`, `powershell/`, `install.sh`, and the bash tests; perform the §12.2 **location** migration at the 2.0.0 cutover; write the rewrite ADRs at their revision-7 numbers (§12.5, ADR-029..039) | Repo is Python-only; users are on the strict XDG paths (§5.2) |

During phases 1–4, users keep using the bash tool for anything not yet ported. **Note what §13 Q5 changed about this paragraph**: the coexistence window is now the whole of phases 1 through 6b rather than ending at phase 5, because nothing ships until the addon and playbooks migration is complete. That makes the overlap longer and the guidance below more load-bearing, not less. Because the config **format** migration is unavoidable (§12.2), the overlap instruction is: run the Python beta with `AAP_DEMO_DIR=$HOME/.aap-demo` so both tools stay in the legacy layout, and accept that the config file itself is now YAML — the bash tool's `grep`-based reads of `ADDONS=` will not see it. In practice this means addon *enablement* diverges during the overlap and should be driven from one tool only; document that explicitly rather than letting users discover it.

**Why the GUI is phase 7 and not parallel with the CLI.** The GUI is a thin frontend over the core by construction (§9.1), so building it before the core operations exist means building against stubs. Two things make the ordering safe rather than a bottleneck: the schema layer it depends on lands in phase 0, and the event/SSE layer it depends on (`core/events.py`) is the same progress-reporting mechanism the CLI needs from phase 3 onward. By phase 7 the GUI is genuinely mostly frontend work. The counter-argument — that the GUI is the *reason* for the project and shipping it last risks it never shipping — is real; the mitigation is to build the Status page and Addon Management pages during phase 5/6 as a vertical slice proving the API shape, and hold only the Deploy Wizard for phase 7.

### 12.5 ADRs to write

**Revision 7 — do not use numbers 023–028 for the rewrite.** Upstream `main` already has ADR-023 (addon auto-wiring, present in this tree before the rewrite) through ADR-028 (AO agentic model binding). The subjects below keep their meaning and move:

| Originally | Subject | Write as |
|---|---|---|
| 023 | Python CLI architecture | **029** |
| 024 | Addon plugin API and the three-tier model | **030** |
| 025 | pytest strategy | **031** |
| 026 | Packaging and distribution | **032** |
| 027 | Versioning and release | **033** |
| 028 | Configuration format and filesystem layout (YAML + strict XDG, §5) | **034** |
| 029 | Web GUI architecture | **035** |
| 030 | Desktop distribution, freezing, and the tray application | **036** |
| 031 | Podman Desktop extension channel | **037** |
| 032 | Full OpenShift preset support | **038** |
| 033 | Credential storage | **039** |

The paragraphs under this heading still use the original numbers. The table wins.

The rewrite supersedes or amends: ADR-001 (CLI architecture), ADR-003 (backend abstraction — the ABC replaces the sourced-function dispatch but the *decision* stands), ADR-008 (addon system), ADR-010 (cross-platform — superseded outright), ADR-013 (registry — mechanism preserved, delivery moves to the playbooks repo), ADR-014 (testing), ADR-021 (local-cache — likely superseded outright, pending the §4.8.5 spike). New ADRs: **023 Python CLI architecture** (supersedes 001/010), **024 Addon plugin API and the three-tier model** (supersedes 008), **025 pytest strategy** (supersedes 014), **026 Packaging and distribution**, **027 Versioning and release**, **028 Configuration format and filesystem layout** (YAML + platformdirs, §5), **029 Web GUI architecture** (§9, including the schema-driven parity mechanism), **030 Desktop distribution, freezing, and the tray application** (§10 — the multi-channel model, the Briefcase choice and the spike that confirmed or overturned it, the single-process tray/server design, and the decision that job subprocesses are killed rather than orphaned), **031 Podman Desktop extension channel** (§11 — the webview-hosting decision Q25 lands on, the managed-venv backend bootstrap, the `extensionDependencies` edge on `redhat.openshift-local` and the failure modes it inherits, and the publisher/ownership position from Q28). Plus, in the playbooks repo: an ADR recording the §4.8.5 host-mount spike result whichever way it lands, superseding or reaffirming ADR-021.

ADR-005 (OLM on MicroShift), ADR-012 (SCC/PSA), and ADR-015 (trust) are *preserved*, not superseded — the behavior is identical, only the implementation language changes; add an "implemented by" pointer to each.

**ADR-020 (full OpenShift support, previously Declined) is superseded by the maintainer's revision-5 decision and needs a new ADR reversing it** — call it **032 Full OpenShift preset support**, recording that `aap-demo create` supports both presets, that ADR-005's OLM reasoning is unaffected (the built-in step detects and skips idempotently on full OpenShift, §4.5), that `registry-mirror` gains a preset-aware path using the built-in `image-registry-operator` (§4.8.5), that the image-store cache regains its preset path segment (§5.2), and that `devspaces` — the one addon that only ever made sense on full OpenShift — is deferred rather than deleted (§13 Q18). Rev 2 wrote that "if ADR-020 is ever revisited, §4.5's tier-1 rationale for `olm` and §4.8.5's dropped preset segment both need review"; it has been revisited, and both were reviewed in this pass. **Rev 6 note:** ADR-032 lands with phase 4b, not with v1 — it records that OpenShift-preset support is in scope, not that it ships day one; write it when phase 4b starts, not before, so it can also record R26's resolution rather than leaving that half open.

Two more ADRs are needed for revision 5's other decisions: **039 Credential storage** (originally 033 in this paragraph; §5.5 — the keyring, the four-way config/secret/state/cache classification, the headless-Linux position from Q30, and §9.5.1's no-secrets-in-the-payload rule), and an amendment to **034** and **035** (originally 028 and 029) rather than new numbers for the YAML and `argparse`/JSON Schema decisions, since those sections are being written for the first time and should simply record the final answer with the superseded alternatives noted (Q9, Q2).

### 12.6 Where implementation stands (revision 7)

Local branch `v1-python-rewrite` contains the design spec plus the Python package. It is based on upstream `7374188` and is **not** a merge of later `main`. The commits through phase 3 are authored correctly and are **not** GPG-signed. Later commits on this work are signed, with `Assisted-by: Cursor (<model>)` and `Signed-off-by`.

| Phase | State on 2026-09-30 |
|---|---|
| **0. Skeleton** | Done. Strict XDG paths replaced the original platformdirs decision (`core/paths.py`, §5.2). |
| **1. Read-only** | Done, including review fixes (diagnose exit code, kubeconfig file mode, preflight, output shape). Live side-by-side parity with current bash is still open. Catch-up: `infra/crc.py` does not yet have upstream's 2-second `crc status` timeout (`includes/infra-crc.sh`, landed with the create-stability work). |
| **2. Cluster ops** | Not started. `start`, `stop`, `idle`, `watch`, `repair`, `must-gather`, and `diagnose --ai` still raise `NotImplementedYetError`. Not a blocker for phase 4. |
| **3. Deploy path** | Done against the 2026-09-01 bash, including unit tests, live-cluster integration tests, and the fixes those runs found (remote-command quoting, line-buffered console). Stale relative to current upstream, and the staleness is in modules this phase already owns: `cluster/coredns.py` rewrites one domain and does not yet rewrite `*.apps.127.0.0.1.nip.io` (PR #127); `cluster/catalog_signature.py` was ported from `includes/olm-catalog-signature.sh` before PRs #150 and #165. `_load_local_cache` was left out on purpose; PR #158 has since made cache load part of deploy, which phase 6b absorbs (§4.7). |
| **4. Create path** | Not started. This is the next feature phase after the phase-1/phase-3 catch-up above. Scope includes PRs #199, #130, and #167 (§12.4). |
| **4b and later** | Not started. Phase 5+6's addon list is the upstream list, including `ollama`, `opa`, `portal-operator`, and `fleet` (§4.7). `aap-demo test` is not a future command (§3.3.1). |

**Next implementation slice.** Re-port the stale phase-1 and phase-3 behavior (`crc status` timeout, the CoreDNS nip.io rewrite, catalog-signature PRs #150 and #165) so `deploy` matches current bash. Then phase 4, MicroShift create/destroy. Phase 2 stays open and does not gate that work.

---

## 13. Open questions

Decided questions are **kept as a decision log**, not deleted — the reasoning is worth more than the row is worth removing, and two of them (Q2, Q9) have now been decided twice, which is itself the most useful thing on the page.

**Revision 5's changes to this section**: Q2 and Q9 were **re-decided** and their rows rewritten to show the supersession rather than overwrite it. Q5, Q6, Q10, Q11, Q13, Q15, Q16, Q17, Q19, Q20, and Q24 moved from Still-open to Decided. Q18 stays in Still-open but is re-marked as a **deliberate deferral** rather than a lean toward deletion. Q14 is narrowed. **Q30 is new** and concerns §5.5's headless-Linux keyring fallback.

Still open after this pass: **Q14** (YAML round-trip vs. `kubectl patch` for CR edits), **Q18** (`devspaces`, deferred), **Q21–Q23** and **Q25–Q29** (the desktop and extension channels' spikes and organizational asks), and **Q30**. Four remain on the critical path and should be started immediately: **Q21** (the freezer spike) during phase 0, **Q22** (signing identities) at kickoff, **Q25** (the webview spike) before any extension code is written, and **Q28** (publisher/org ownership) in the same conversation as Q22.

### 13.1 Decided

| # | Question | Resolution |
|---|---|---|
| **Q1** | PyPI vs. internal index vs. git install? (§8.3) | **DECIDED: public PyPI.** `pip install aap-demo`. Creates four work items — claim the names, audit internal references (`gitlab.cee.redhat.com` in `cmd_test`), trusted publishing, and building the GUI bundle before the wheel. See §8.3. |
| **Q2** | Which CLI framework, and what mechanism carries CLI/GUI parity? (§3.1, §9.3) | **DECIDED (rev 5): stdlib `argparse` + `jsonschema`. This supersedes rev 2's "DECIDED: Typer" and the Pydantic-based parity mechanism** — recorded rather than overwritten, because rev 2's reasoning was sound on its own axis (install weight, free completion, declarative options) and it is worth knowing why that axis lost. **The verification:** both `ansible-navigator` and `ansible-creator` were inspected directly this session — their `pyproject.toml` dependency lists and their `cli.py` imports. Neither uses Click, Typer, or Pydantic anywhere. `ansible-navigator` depends on **`jsonschema`**; `ansible-creator` wraps stdlib **`argparse`** in a thin `arg_parser.Parser`. Two independent Red Hat Ansible CLIs converging is a stronger signal than a feature table, and it is the same native-tooling-alignment reasoning that decided Q9. **Two consequences, both handled rather than absorbed silently:** (a) Click's free multi-shell completion is lost — compensated with `argcomplete` (pure Python, no framework) for bash/zsh plus hand-written fish and PowerShell completers as package data, which rev 2 had already budgeted for PowerShell anyway; (b) `core/console.py` loses Click's `echo`/`style` and does its own ANSI/Windows-console handling, which is a small amount of code it largely needed for `QUIET` and the ASCII-glyph fallback regardless. **A third consequence is a pure win and should not be claimed as the reason:** dropping Pydantic removes the compiled `pydantic-core` and with it rev 2's "verify prebuilt wheels for the 3.9 floor on every target platform" implementation risk. §9.3 is redesigned around JSON Schema as the single source of truth; the GUI side is unchanged, because it was already consuming JSON Schema. |
| **Q3** | Is the core/community split right? | **DECIDED, and restructured** into three tiers (§4.5). `olm` + `setup-pah` built-in; `portal`, `mcp-server`, `ao` (absorbing `ao-eap`), `apme-eap`, `product-demos` first-party; `registry` + `local-cache` out of the addon system entirely and into the day-2 playbooks repo. The `ao`/`ao-eap` tension this question flagged is resolved by the first-party tier: team-maintained, no open PR queue. |
| **Q4** | Raw `subprocess`, or the `kubernetes`/`openshift` client libraries? | **DECIDED: subprocess only, full stop.** The maintainer's framing: "everything should use `oc` like a customer/developer/admin would." This is now a product decision (the tool should model what a real operator types), not only a dependency-weight one, which also settles the `watch`-needs-informers caveat rev 1 left — it does not get an exception. Extended to Ansible: `ansible-navigator` is shelled out to, not imported (§4.8.1). |
| **Q5** | Ship the `LegacyShellAddon` compatibility shim? (§4.7) | **DECIDED (rev 5): no shim. Clean cutover.** Rev 2 leaned "ship it, POSIX-only, clearly marked deprecated with a removal release named"; the maintainer decided against it. The core rewrite and the full addon + playbooks migration ship **together, in one release**. The tradeoff, both directions, because the rejected option was the one that shipped sooner: **cost —** a longer time to first release, and phases 5 and 6 stop being independent shipping boundaries (§12.4 merges them); **benefit —** no deprecated legacy path to build, document, support on POSIX-only, and then remove; no window in which an addon's shell behavior and its ported behavior both exist and can diverge; and, decisively, **no way to forget an unported addon** — a shim makes "we never got to `apme-eap`" invisible for a release or two, whereas without one it is a missing command on day one. `AAP_DEMO_ADDON_PATH` remains the escape hatch for locally-developed *Python* addons and does not become a shell-addon path. |
| **Q6** | Should the tool install missing prerequisites (`oc`, `kubectl`, `jq`, `ansible-navigator`, `operator-sdk`), or only detect and instruct? | **DECIDED (rev 5): interactively prompt.** When a required tool is missing, aap-demo **asks whether it should install it** — not a silent auto-install, and not detect-and-instruct-only. This supersedes rev 2's lean ("detect + instruct by default; `aap-demo doctor --install` as an explicit opt-in"), and the difference is smaller than it looks: the opt-in survives, it just moves from a flag the user has to know about to a question asked at the moment it matters. **Mechanism: reuse `core/prompts.py::timed_confirm()`** — the same confirm/prompt machinery already designed for the destructive-action guards (§14 R4), with the same non-negotiable properties: skipped entirely under `--quiet`, `--yes`/`--no-input`, `CI=true`, or a non-TTY stdin, where it degrades to the instruct-only message and exit code 3. The prompt must name **what** will be installed, **from where**, and **to where** before asking — a tool that downloads binaries without saying so is the supply-chain concern rev 2 flagged, and naming them is what answers it. In the GUI and extension channels the same decision surfaces as a button (§10.10, §11.4), which is what a graphical channel makes of a prompt. |
| **Q7** | Should `requires_aap` addons be replayed at the end of `deploy`? | **DECIDED: fix it and announce it** — rev 1's lean stands. The maintainer's 2026-09-02 answers did not address this directly, but nothing in them changes the reasoning: today `crc-create.sh:522` skips `requires_aap` addons at create time and nothing ever retries, so `enable mcp-server` → `destroy` → `create` + `deploy` silently loses the addon. Replay them post-deploy with the same continue-on-failure semantics (§4.4), and list the recovered addons in the deploy summary so the behavior change is visible rather than magic. Recorded here rather than left open because leaving a known data-loss bug "open" invites shipping it. |
| **Q8** | Minimum Python version? | **DECIDED: 3.9**, because RHEL 9's system `python3` is 3.9 and RHEL users should not need a second interpreter. **Caveat to document in the README**: CPython 3.9 passed upstream end-of-life in October 2025, so the project relies on Red Hat's backported patches for that interpreter, not upstream ones. Warn on a non-RHEL 3.9. Bans `match`/`X \| Y`/`dict \| dict`. **Rev 5 removes rev 2's other consequence**: the `tomli` backport is no longer forced, because the config format is YAML and `pyyaml` has no version-conditional dependency (§5.1). Revisit when RHEL 10 is the common denominator. See §8.1. |
| **Q9** | What format is the config file? | **DECIDED (rev 5): YAML. This supersedes rev 2's "DECIDED: TOML", which itself superseded rev 1's "keep `KEY=VALUE` during the overlap".** Shown rather than silently changed, because rev 2's two arguments were both correct and only one of them was about TOML: `KEY=VALUE` genuinely cannot express nested per-addon and per-playbook settings (still true, still the reason the format changed at all), and PyYAML's optional `libyaml` C extension genuinely can fail to build on a fresh macOS machine with no Xcode CLT (still true). **What changed:** TOML has no precedent whatsoever in the Ansible tooling ecosystem — it is a Python-*packaging* convention (`pyproject.toml`). Verified this session by direct inspection: `ansible-navigator` and `ansible-creator` both hard-depend on `pyyaml` and neither uses TOML anywhere. Every other artifact this tool touches — cluster manifests, playbooks, EE definitions, the addon and playbook manifests — is YAML, and so is everything its audience reads. **The C-extension objection is answered rather than dodged**, and better than by changing format: use **PyYAML in pure-Python mode** (`yaml.safe_load`/`safe_dump`, never `CSafeLoader`/`CSafeDumper`). The C extension is a throughput optimization for large documents and nothing else; no compiler is involved on any install path. A unit test asserts the pure-Python loader is in use so nobody optimizes the build dependency back in. **Consequences:** `config.toml`→`config.yaml`, `addon.toml`→`addon.yaml`, `ops.toml`→`manifest.yaml`; `tomli`/`tomlkit` are dropped and `pyyaml` becomes a base dependency; the `[yaml]` extra disappears because `--output yaml` now reuses what is already there (§5.4); Q8's "forces the `tomli` backport" consequence is void; and comment preservation, which `tomlkit` gave for free, is handled by regenerating the header block on write (§5.1). Auto-migration on first run and the platformdirs pairing (§5.2, §12.2) are unchanged. |
| **Q10** | What happens to `ansible/` and `AAP_DEMO_ANSIBLE`? | **DECIDED (rev 5), by investigation rather than by asking.** Three findings: (1) the **`ansible/` directory referenced by the help text and by rev 2's own reasoning does not exist in the repo** — a `find` over the repo root returns nothing for it, so there is no alternative Ansible flow to port and rev 2's "it may be the seed of the playbooks repo" hope has no content behind it; (2) **`AAP_DEMO_ANSIBLE` is confirmed dead** — documented at `aap-demo.sh:485`, read by no code path; (3) **`requirements.yml` at the repo root is orphaned** — it declares `kubernetes.core` and `community.general` and nothing currently uses them. **Resolution:** delete the flag and its help-text line, and note the deletion in the release notes alongside `--branch` (§3.2, §14 R2). Do **not** simply delete `requirements.yml` — its two collections are exactly what the EE needs, so they become the seed of `aap-demo-playbooks`'s own `execution-environment/requirements.yml` (§4.8.2) and the file is removed from this repo once that lands. |
| **Q11** | `aap-demo config` is a no-op today yet is documented and accepts a `github` argument. What was it for? | **DECIDED (rev 5) as far as this document can decide it — with the residual question logged elsewhere rather than left sitting here.** Two parts: (a) **implement a real `config get/set/list/edit/path`** over the YAML config file (§5.3), plus `config secrets *` (§5.5.2) — that is a legitimate gap regardless of what `github` was for, and §14 R2's second artifact closes with it; (b) **drop `config github` from the rewrite's command surface and help text.** Shipping a subcommand nobody can explain is worse than removing one nobody uses. |
| **Q12** | Does anything script against aap-demo's stdout? | **DECIDED: no.** Maintainer confirmed nothing scripts against it, so human-readable output is free to be redesigned and R12's compatibility risk is closed. `--output json\|yaml` still ships day one — for the GUI's API and future automation, not as a compatibility shim (§5.4). |
| **Q13** | What is the day-2 playbooks repo called? (§4.8.2) | **DECIDED (rev 5): `aap-demo-playbooks`.** The maintainer asked for a proposal rather than a silent pick; rev 2 proposed `aap-demo-ops` and that is now superseded by the maintainer's answer. The CLI noun follows the repo name throughout: `aap-demo playbooks run`/`list`/`info`/`create`/`update`, `playbooks.repo_url` in config, `/api/playbooks` in the API, `<cache>/playbooks-repo/` on disk, and a Playbooks view in the GUI (§9.2a). What the name gives up, recorded so it is not re-opened: it says *what* the repo holds but not *when* you run its contents — handled by the manifest's `tags` and the GUI's Operations nav section, not by the name. `aap-demo-common` remains explicitly rejected: naming it "common" is how it becomes a junk drawer. |
| **Q15** | Does the GUI server bind localhost-only, or is remote access an intended use case? (§9.7) | **DECIDED (rev 5): localhost-only, permanently — a product principle, not a security default.** The maintainer: *"aap-demo is not made for shared access or hosted access. it is a LOCAL demo tool."* This is stronger than rev 2's lean ("localhost by default; `--host` allowed with a loud warning; treat remote access as a feature request to scope separately"), and the difference matters: **there is no `--host` flag, `gui.host` is fixed rather than defaulted, and remote/shared access is out of scope by design rather than deferred.** A test asserts the app cannot be constructed with a non-loopback bind. Anyone determined to expose it can run a reverse proxy — their decision, made outside the tool, not one we make look sanctioned by shipping a flag. This also retires most of §14 R18 (see its rewritten text) and is what makes §9.5.1's server-side clipboard coherent rather than absurd. |
| **Q16** | Does the GUI need authentication at all? | **DECIDED (rev 5): no authentication, ever — combined with a real answer to the exposure it leaves.** Given Q15's permanent loopback bind, a login page would protect nothing: anyone who can reach `127.0.0.1:8720` is already this user and can already run `aap-demo status`. No login page, no startup token, no session. **But "no auth" is only half the answer**, and rev 2's version stopped there. The maintainer's actual requirement was *"it should also not have anything sensitive exposed in it"*, which is a different problem from access control and is answered by **§5.5** (credentials in the OS keyring rather than in files or env vars) and **§9.5.1** (no secret in any API payload; copy-to-clipboard server-side rather than reveal-in-DOM). Cross-referenced rather than restated. One acknowledged limit, unchanged: a shared machine with several local accounts is a real if uncommon counterexample to "loopback is private" — though §5.5 narrows it, since another local user would find a server they can talk to and a keyring they cannot read. |
| **Q17** | What PatternFly 6 minor version is targeted, and who owns frontend dependency updates? (§9.2, §9.6) | **DECIDED (rev 5): pin an exact PF6 minor in `package.json`; automate updates with Dependabot or Renovate on `frontend/` at a monthly cadence; name one owner for the bundle build.** This is rev 2's own lean, formally closed rather than changed — it was never really contested, and leaving it in Still-open implied a debate that did not exist. The mechanism that makes it safe is already built: §9.6's CI freshness check means a bot PR that bumps a dependency without rebuilding the committed bundle fails visibly rather than merging a skew (§14 R14). |
| **Q19** | Is a Linux desktop installer in scope for v1? (§10.1, §10.11) | **DECIDED (rev 5), and refined from a scope question into a sequencing one.** Three parts: (a) **build the macOS native installer first** — it is the primary dev platform and the primary target-audience platform, and doing one signing/notarization pipeline well before starting the second is what keeps §10.4 from becoming two half-finished pipelines; (b) **a Windows native installer follows**, not as a deprioritization of Windows but as a build order — Windows has full CLI, GUI, and tray parity through the PyPI channel from day one, which is the thing that actually matters and which §6.3 delivers in phase 4; (c) **a Linux native installer stays out of scope**, on rev 2's own unchanged reasoning: Linux users are exactly the population for whom `pip install aap-demo` already works, `aap-demo desktop` is a fully working tray app there from a pip install, and the Podman Desktop channel (§11.11) additionally gives Linux the full GUI. Revisit only if a real Linux-desktop user appears; an AppImage would be the cheapest first answer. §12.4's phase 7c reflects the macOS-first ordering. |
| **Q20** | Should the desktop installer bundle or chain-install a container runtime (and `ansible-navigator`) so day-2 playbooks work in that channel? (§10.9) | **DECIDED (rev 5): deferred for the initial release** — rev 2's own lean, formally closed. Detect-and-link only, consistent with Q6 (which now means *offer to install*, but that offer does not extend to a several-hundred-megabyte third-party application with its own VM, admin prompts, and update cadence). The governing reason remains §4.5's tier rule rather than the packaging difficulty: the desktop audience is not the operator. Revisit only when there is a **named** user who needs day-2 in the desktop channel; the cheap intermediate answer at that point is bundling `ansible-navigator` (pure Python, one Briefcase line) while still only *detecting* Podman — not the reverse. |
| **Q24** | Does the desktop app get its own version number and release cadence? | **DECIDED (rev 5): no — one version, one tag, all artifacts every release** (§10.11). Rev 2's own lean, formally closed. `[tool.briefcase].version` is bound to `cz bump` through `version_files`, as is the Podman Desktop extension's `package.json` version (§11.9, Q29) — which is what makes §11.4's backend pin work at all. Two version lines for one codebase is ADR-010's drift in a new coat. If signing runs turn out to be genuinely expensive, **skip publishing an installer for a given tag rather than forking the version line.** |

### 13.2 Still open

| # | Question | Why it matters | My lean |
|---|---|---|---|
| **Q14** | **Do the AAP CR and OLM manifest edits need a comment-preserving YAML round-trip, or can they be expressed as `kubectl patch`?** (§5.4, §14 R6) | **Narrowed in rev 5.** Rev 2 asked two things: which YAML library, and whether the base wheel needs a YAML parser at all. The second half is answered — §5.1 makes YAML the config format, so `pyyaml` is a base dependency and the wheel has a parser regardless. What remains is only about *fidelity*: `yaml.safe_load`/`safe_dump` round-trips the data correctly but discards comments and key order, which §14 R6 warns may change the emitted CR document in ways that trip the operator or a user's diff. `ruamel.yaml` preserves both; `kubectl patch` against the applied object avoids the question entirely and is more consistent with Q4's "use `oc` like an operator would". | Spike it during phase 3: try `kubectl patch` for the `route_host` injection and the OLM manifest substitutions. If it works, drop `ruamel.yaml`. If not, keep it — and note that §5.1 can then also use its round-trip loader for the config file's comment preservation, which would retire the header-regeneration approach. |
| **Q18** | **Is `devspaces` deleted, ported, or neither?** (§4.5 tier 2b, §4.7) | Rev 2 framed this as delete-vs-port on the grounds that `devspaces` only makes sense on a full OpenShift preset that ADR-020 declined. **Both halves of that framing are now wrong**: full OpenShift is back in scope (rev 5), so the deletion argument has lost its basis — and nobody has asked for the addon either, so the porting argument has no advocate. | **Deliberately deferred — not decided in either direction.** The maintainer's words: *"defer for the initial version."* Recorded here as a deferral rather than defaulted to "delete", because a default is a decision and this one was explicitly declined. Concretely: `devspaces` **is not ported in v1**, and that is **not** to be read as a deletion decision — the directory stays in the repo until the retirement phase decides otherwise (§12.4 phase 8), the release notes say "not yet ported" rather than "removed", and **it does not block the v1 migration**: §12.4's combined phase 5+6 exit criterion is "every other addon is ported", explicitly excluding this one. Revisit post-v1, when there is a full-OpenShift user to ask. |
| **Q21** | **Briefcase, or PyInstaller + WiX/productbuild?** (§10.2) | The §10.2 recommendation is Briefcase and the reasoning is sound, but it rests on a claim about packaging behavior that should be *verified* rather than argued: that a Briefcase bundle resolves `importlib.metadata` entry points for addon distributions installed into it (§4.1), on both target OSes. If that fails, the tray, the installer generation, and the signing integration all still work but the addon system does not — and discovering that at phase 7c is expensive. This is the one recommendation in this document I would not lock without touching it. | **Timebox a spike to a few days, during phase 0.** Acceptance criterion: a packaged app that starts uvicorn on a thread, renders one page in a webview, shows a status icon, and lists a tier-2 addon discovered by entry point — on macOS and on Windows. If it passes, lock Briefcase in ADR-030. If it fails, fall back to PyInstaller + WiX/`productbuild`, budget the extra maintenance explicitly, and solve entry points with `copy_metadata()` plus the §14 R24 packaged-app CI test. |
| **Q22** | **Which code-signing identities does Red Hat already hold, who owns them, and what is the lead time?** (§10.4) | This is a cross-team dependency with weeks of latency and it gates the entire desktop channel — an unsigned installer is worse than no installer for a credibility-driven tool (§14 R20). It also has a shape that surprises people: post-2023 CA/B rules mean there is no `.pfx` to drop in a CI secret, so the *pipeline* design depends on the answer (cloud HSM signing service vs. attached token). | **Ask at kickoff, not at release.** Name the four things needed: Developer ID Application cert, Developer ID Installer cert, an App Store Connect API key for notarization, and an EV-grade (or Azure Trusted Signing) Windows identity. Track availability as a release gate on phase 7c. Until it lands, ship ad-hoc-signed internal builds only. |
| **Q23** | **Embedded webview or plain browser launch?** (§10.3) | §10.3 recommends the embedded webview for the "official tool" fidelity §9.0 exists to serve, with automatic browser fallback. The residual unknown is empirical, not architectural: what fraction of the target fleet's Windows machines lack the WebView2 runtime, and does the chained Evergreen Bootstrapper install cleanly on a corporate-managed laptop where the user is not an administrator? | Ship the webview with the fallback as designed — the fallback means a wrong answer here degrades to the browser model rather than to a broken app. But **test the `.msi` on one real, corporate-managed target laptop** before the claim "double-click and it works" goes in any deck. This overlaps §14 R25. |
| **Q25** | **Can a Podman Desktop webview frame the backend's own loopback server (§11.2 Option B), or must the SPA bundle be shipped inside the extension image (Option A)?** | Option B is the recommendation and it is what removes the cross-channel version skew (§14 R14) and the permissive CORS rule (§14 R18) that Option A forces. The mechanics look right from the source — Podman Desktop serves the webview over plain HTTP from a loopback origin, sets no `X-Frame-Options` or CSP response header, and `asWebviewUri()` passes HTTP URIs through untouched — but "no reason it should fail" is not an observation. The second-order unknown is `postMessage` into a cross-origin iframe, which would need a relay in the shell document. | **Timebox a spike, same shape as Q21**, and run it before any extension code is written — it is half a day. Acceptance criterion: a hello-world extension whose webview frames a locally-served page, renders it, and round-trips one message to the extension host. If it passes, lock Option B. If it fails, fall back to Option A, ship the SPA in the extension image, pin the CORS allowlist to the `^http://[0-9a-f-]{36}\.webview\.localhost:\d+$` origin pattern, and add the bundle to the §9.6 freshness check so the copy cannot drift. |
| **Q26** | **Should the extension bundle an embedded Python runtime instead of building a managed venv?** (§11.4) | §11.4 chooses a managed venv built from a host Python, with a python-build-standalone download as the fallback. Bundling instead would make the extension fully self-contained and remove the "no suitable Python" branch entirely, at the cost of ~75 MB per platform in a normally tiny artifact and of moving every backend fix onto the catalog's release path rather than PyPI's. | **Defer, and instrument the decision rather than re-arguing it.** Ship the venv approach with telemetry (opt-in, §11.8) on which resolution branch fires and how often installation fails. If the standalone-runtime fallback turns out to be the common path on Windows rather than the exception, bundling is the right answer and the data will say so. |
| **Q27** | **Is the Red Hat Account extension worth integrating for `registry.redhat.io` auth, or is consuming CRC's pull secret enough?** (§11.7) | ADR-005's CatalogSource pulls from `registry.redhat.io`, so this is on the critical deploy path. The account extension mints a **registry service account**, not an OpenShift pull secret — different artifacts. Composing one into the other is plausible but is a credential-synthesis path that would need its own review. | **Consume CRC's pull secret for v1** — it is a few lines, it reuses something the user necessarily already has, and it deletes the paste-box step in this channel. Revisit only if users appear who have signed in to Red Hat SSO in Podman Desktop but have no CRC pull secret configured, which by construction should be nobody, since CRC cannot start without one. |
| **Q28** | **Who owns the `redhat` publisher name and the `redhat-developer`/`crc-org` repository this extension would need in order to be adopted?** (§11.8) | This is the actual gating question for "adopted officially by Red Hat". Every member of the Red Hat extension pack is a repo in a Red Hat org, published to a Red Hat registry namespace, with an internal maintenance owner. The catalog listing is mechanical and effectively unreviewed; **pack membership is the real bar**, and there is no published process for it. Publishing under `publisher: "redhat"` from a repo Red Hat does not control would be the wrong opening move with exactly the team whose adoption is the goal. | **Ask early, and ask in the same conversation as Q22's signing identities** — it is the same organization. Until it is granted, publish under a neutral publisher and plan the rename at donation time; a rename is a catalog PR before anyone has installed it and a migration headache afterwards. Confirm, do not assume, that catalog listing carries no code review and that pack membership requires org ownership. |
| **Q29** | **Does the extension channel need its own version line?** | Same shape as Q24, and the answer is the same, but it is worth asking separately because the extension has a *third-party* release path (a PR to someone else's catalog repo) that can stall for reasons unrelated to us. | **No — one version, one tag.** The extension version and the wheel version it pins are the same number (§11.9), which is the mechanism that makes §11.4's pin work at all. If a catalog PR stalls, the consequence is that the catalog lists an older version, not that the numbering forks. |
| **Q30** | **On headless Linux with no Secret Service backend, does aap-demo hard-fail, or does a supported encrypted-file mode have to exist?** (§5.5.3) | §5.5 recommends hard-requiring an OS keyring and failing loudly, on the grounds that an encrypted-file fallback keyed by anything the local filesystem also holds is obfuscation rather than encryption — and that it is exactly the mechanism that silently degrades back into "secrets in a file" the first time someone makes the passphrase optional for CI. But RHEL 9 is a primary target (§8.1) and plenty of that usage is over SSH with no desktop session, where `keyring` resolves to `fail.Keyring` and every credential operation raises. Whether hard-requiring is acceptable depends entirely on **how many headless users actually need a credential-storing feature** — `setup-pah`, `apme-eap`, `portal`, and the credential-display paths are the only ones that do — and nobody currently knows that number. | **Ship the hard-require**, with §5.5.3's two narrow escapes: an explicit `KEYRING_BACKEND` for a user who has installed something like `keyrings.cryptfile` and understood the tradeoff (we do not ship it, recommend it, or test it), and **lazy keyring resolution** so that `create`, `deploy`, `status`, `diagnose`, and `playbooks run` never touch it and keep working on a bare headless box. Then **instrument it**: if the loud failure turns out to be a common experience for headless RHEL users rather than a rare one, that is the signal to design a supported encrypted mode properly — with a real user-supplied passphrase and an agent — rather than to bolt on the version that rots. This is the same "ship the simple thing and let data decide" shape as Q26. |

---

## 14. Risks

**R1 — Ordering dependencies in `crc-create.sh` are load-bearing and mostly undocumented.** The 602-line script is a straight-line sequence whose order encodes hard-won workarounds. At minimum: CoreDNS configuration is *deliberately deferred to the very end* because "MicroShift's DNS controller overwrites the configmap during startup" (`crc-create.sh:421–423`, `509–514`); `configure_coredns` itself has a re-patch retry when the DNS operator clobbers it (`crc-create.sh:129–141`); the nip.io baseDomain step *wipes MicroShift data* because CRC starts with `crc.testing` before the dropin can be written (`crc-create.sh:391–396`); the SSH key must be re-detected after `crc start` because the key type differs by preset (`crc-create.sh:345–353`, `infra-crc.sh:22–31`); NFS provisioner needs the NFS **ClusterIP substituted at apply time** because kubelet cannot resolve cluster DNS for NFS mounts (`crc-create.sh:478–480`, per `.claude/CLAUDE.md`). **Mitigation:** port `crc-create.sh` as an explicit ordered list of named `Step` objects with the *reason* for each position in a docstring, and add a unit test asserting the step order. Do not "clean up" the sequence.

**R2 — The current arg parser accepts things a real parser will reject.** It is order-independent, accepts flags after commands, exports arbitrary `KEY=VALUE`, and silently ignores unknown-but-whitelisted tokens. Users and internal scripts will have invocations that a strict `argparse` parser rejects. **Three** known artifacts, all now resolved rather than merely flagged: `--branch` is parsed and never read (dropped, §3.2); `config` accepts `github` and does nothing (dropped, §13 Q11); and `AAP_DEMO_ANSIBLE` is documented and read by nothing (deleted, §13 Q10). **Mitigation:** phase-1 compatibility layer that accepts bare `KEY=VALUE` with a deprecation warning; keep `deploy-all`/`rh-status` aliases; audit `SKILL.md`, `README.md`, `docs/FULL-README.md`, and `.github/workflows/*` for invocation forms before tightening.

**R3 — SCC grant timing (explicitly flagged in ADR-010's *Negative* section).** `setup_namespace` (`aap-demo.sh:2281`) creates the namespace, prepends CRC's `oc` to PATH if `oc` is missing (`aap-demo.sh:2294–2298`), grants SCCs, then labels PSA, then creates the pull secret and patches the default SA — and `_grant_sccs` has two implementations (`oc adm policy` and a `kubectl create clusterrolebinding` fallback) that produce *different* binding names, which `cmd_diagnose` then has to detect two different ways (`aap-demo.sh:2249–2278` vs `1106–1113`). Getting the order or the fallback wrong produces the single most common failure mode in this tool. **Mitigation:** `tests/unit/test_scc.py` asserts exact call order via `FakeRunner`, both branches, plus a diagnose test that recognizes bindings created by either path.

**R4 — `read -t 10` timed prompts have no clean cross-platform Python equivalent.** They appear in the destructive guards (`aap-demo.sh:745`, `1932`), the auto-update nag (`2836`, reading from `/dev/tty`), the cluster auto-create prompt (`698`), and `local-cache` confirmation. Behavior to preserve: prompt, wait N seconds, on timeout take the documented default, and **skip entirely when `QUIET=true` or stdin is not a TTY**. **Mitigation:** one `core/prompts.py::timed_confirm()` with a POSIX `select` path and a Windows `msvcrt`/thread path, plus a `--yes`/`--no-input` flag so automation never needs the timeout at all. Note `_check_for_updates` reads from `/dev/tty` specifically, not stdin — that nuance does not port to Windows and the feature is being replaced anyway (§12.3).

**R5 — Long waits with silent failure modes.** `wait_for_catalog_ready` can run 10+ minutes on a multi-GB index pull; the CSV wait is 60 × 10 s; `watch_aap` runs up to 60 minutes; `_patch_gateway_capability` polls 60 × 5 s for the gateway deployment. Several use `kubectl wait … || true`, so a timeout looks like success. **Mitigation:** every wait becomes a `wait_for(predicate, timeout, interval, description)` helper with injectable clock, explicit timeout handling (never `|| true` silently), and progress output; unit-testable in milliseconds.

**R6 — Text munging that the rewrite must reproduce exactly, not "improve".** `create_aap_instance` injects `route_host` into the CR with an **awk line-insertion after `storage_type: file`** (`aap-demo.sh:2444–2447`); OLM manifests are patched with `sed` on substrings (`namespace: aap` → namespace, `redhat-operator-index:v[0-9.]*` → version, `channel: stable-2.6` → channel — note the sed pattern says `2.6` while the default channel is now `stable-2.7`, so that substitution is currently a **no-op**: `aap-demo.sh:2181–2183` vs `config/olm/subscription.yaml:15`). Re-implementing with a YAML round-trip is *more correct* but changes the emitted document (key order, comments, anchors) and may trip the operator or user diffs. **Mitigation:** switch to real YAML manipulation (it is the right call) — or, better, to `kubectl patch`, which §13 Q14 now spikes during phase 3 and which would avoid the re-emission problem entirely — but either way golden-file test the rendered output against what bash produces today for each CR in `config/crs/` and each OLM manifest, and fix the dead `stable-2.6` sed deliberately rather than by accident.

**R7 — `check_mkcert_ca` (`aap-demo.sh:328–386`) sits outside the ADR-015 trust design.** It is gated by `AAP_DEMO_MKCERT` (default true) and predates the ingress-CA work. It is unclear whether it is still needed or is dead weight overlapping `trust/`. **Mitigation:** determine intent before porting; if it is vestigial, drop it and note it in the release notes rather than carrying an unexplained mkcert dependency into a new codebase.

**R8 — Addon scripts reach into core internals.** `addons/registry/deploy.sh:18` sources `includes/infra-crc.sh` and then uses `$CRC_SSH_KEY`/`${CRC_SSH_OPTS[@]}` directly; `addons/local-cache/deploy.sh:24` does the same and calls the private `_detect_crc_preset`; `addons/setup-pah/deploy.sh:15` sources `includes/galaxy-auth.sh`; `product-demo-*` scripts detect their dependency by `grep`ping `~/.aap-demo/config`. The new `AddonContext` must expose equivalents (`ctx.infra`, `ctx.config`, `depends_on`) as *public* API on day one, or ports will reach into private modules and recreate the coupling.

**R9 — `disable` and `--delete` are not symmetric.** `cmd_disable` (`aap-demo.sh:2757`) runs `deploy.sh --delete` with `|| true` — failures are swallowed — and several addons' `--delete` handlers merely *print instructions* rather than deleting anything (`product-demo-linux/deploy.sh:39–49` tells the user to delete templates in the AAP UI). Users likely believe `disable` cleans up. **Mitigation:** the `AddonStatus`/disable result type should distinguish `REMOVED` / `PARTIAL` / `MANUAL_STEPS_REQUIRED`, and the CLI must print manual steps prominently. Do not swallow disable errors silently.

**R10 — Interactive `exec ssh` and terminal handoff.** `cmd_ssh` replaces the process (`aap-demo.sh:1604`). Any Python wrapper that captures output breaks the interactive session. **Mitigation:** `exec/ssh.py::interactive_shell()` must bypass the `CommandRunner` capture path entirely (`os.execvp` on POSIX, inherit-stdio `subprocess.run` on Windows) and be excluded from the "all subprocess goes through the runner" rule — with a comment saying why.

**R11 — Windows has never actually run the create path in CI.** ADR-010's parity table shows Windows delegating `test` and `watch` to Git Bash, and `enable portal` as "Limited". Nobody currently has a green signal that Windows create→deploy works unattended. The rewrite will surface Windows bugs that were previously masked by Git Bash delegation (path separators in `crc` output parsing, `ssh` availability, `certutil` behavior under different locales, CRLF in kubeconfig files). **Mitigation:** make phase 4 explicitly include a manual Windows create→deploy→enable→destroy acceptance run before declaring parity, and treat `windows-latest` unit CI as necessary-but-not-sufficient.

**R12 — Output-format coupling. ~~Risk~~ — closed by Q12.** Rev 1 flagged that the bash tests, the `aap-demo` Claude skill (`SKILL.md`), and `docs/` might parse human-readable output. The maintainer has confirmed **nothing scripts against stdout**, so restructuring `status`/`diagnose` output carries no compatibility risk. Retained as a decision record. One residual, much smaller item: `SKILL.md` and `.claude/CLAUDE.md` do document specific commands and their expected output shape, so they need updating alongside the rewrite — a docs task, not a risk. `--output json|yaml` ships anyway for the reasons in §5.4.

**R13 — `_check_for_updates` runs `git fetch` on every `status`** (throttled 4 h). On a pip install there is no git tree; on a dev checkout it mutates nothing but does network I/O in the middle of a status command and prompts on a TTY. Under Python this becomes an index query. Ensure it stays non-fatal, non-blocking, and fully skipped under `CI=true` and non-TTY, exactly as today (`aap-demo.sh:2798–2799`).

**R14 — Frontend/backend version skew.** The SPA bundle in `gui/static/` and the Python package version can drift: a contributor edits `frontend/src/` and merges without rebuilding, a release is cut from a tree whose bundle predates a schema change, or someone installs from a git ref whose committed bundle is stale. The failure is quiet and nasty — a form silently missing a field, or an SPA calling an API route that no longer exists, both of which look like product bugs rather than build problems. **Mitigation:** (a) `static/build.json` stamps the bundle with `{bundle_version, schema_hash, built_at}`; the server compares `schema_hash` against the live schema at startup, logs loudly on mismatch, and the SPA renders a persistent warning banner; (b) `GET /api/version` returns all three versions and the SPA checks them on load; (c) a CI job runs `make schema frontend-build` and fails on `git diff --exit-code`, so a frontend source change without a rebuilt bundle cannot merge; (d) the release job builds the bundle from scratch rather than trusting the working tree (§8.3, §9.6).

**R15 — SSE connections across refresh, sleep, and network interruption.** A deploy runs 15+ minutes. In that window a laptop will sleep, wifi will drop, a proxy will time out an idle connection, and someone will refresh the tab. If any of those loses output — or worse, appears to lose the *deploy* — the "official Red Hat tool" credibility this GUI exists to establish is gone in one demo. **Mitigation:** designed into §9.4 rather than patched later — jobs live in the server process and are unaffected by client state; every event carries a monotonic `seq` emitted as the SSE `id:`, so `EventSource`'s automatic `Last-Event-ID` reconnect backfills exactly the missed range; a 15 s heartbeat comment frame keeps intermediaries from idling the connection out during silent image pulls; the full log is on disk so a gap beyond the ring buffer degrades to "some output was skipped" with a link to the complete log rather than to a silent lie; and disconnect explicitly does **not** cancel the job. Test coverage is the layer-2 and layer-3 tests in §9.4 — specifically a reconnect-with-`Last-Event-ID` case, which is the one nobody writes by default.

**R16 — GUI job state is in-process and dies with the server. — Substantially resolved by §10.8; residual risk narrowed.** The original statement: unlike the CLI, where the deploy dies with the terminal the user is watching, the GUI creates the expectation that a job is durable. Stopping `aap-demo gui` (or the process crashing) kills a running deploy mid-flight, potentially leaving a half-configured cluster — and the user's mental model says the deploy "was running on the server."

The desktop app (§10) changes the calculus, because the backend is now a long-lived tray application rather than a foreground server the user is expected to keep a terminal open for. **Resolution, designed in §10.8, not restated here:** a job started from the wizard survives the browser tab closing, the webview window closing, laptop sleep, and network loss — the tray icon shows live state throughout, and reopening the dashboard reconnects via §9.4's `Last-Event-ID` backfill. That covers every case that actually happens.

**Residual risk and its mitigation**, for the cases that remain — quitting the app, a crash, a reboot: job subprocesses are **killed, not orphaned** (§10.8, a deliberate scope cut — orphaning would leave a headless `ansible-navigator` mutating a cluster with nothing watching it). So the mitigations from the original risk still stand and are what §10.8 builds on: persist job metadata, the resolved plan, and logs under `<state>/gui-jobs/`; require a confirmation naming the in-flight job before quitting; and keep every core operation idempotent enough to converge on a re-run (which the addon contract already requires, §7.5, and which `repair` exists for). On next launch the app reconciles the persisted job against the real cluster state and offers a **resume card** that re-submits the saved plan — an honest "this was interrupted, here is where things actually stand" rather than a silent lie. Still do **not** solve this by adding a daemon: §1's amended non-goal is that the CLI stays short-lived and the desktop app stays a user-quittable foreground application.

**R17 — The schema-driven parity mechanism silently degrades.** The entire CLI/GUI parity guarantee rests on every user-settable field living in `core/schema.py`'s JSON Schema documents. It takes one contributor writing a plain `parser.add_argument()` — because it was faster, or because the schema path was unfamiliar — for parity to start rotting exactly the way ADR-010's bash/PowerShell parity table did, and it rots invisibly because both surfaces still work, just differently. **The rev 5 framework change (§3.1) does not change this risk, and if anything makes the tripwire easier to build**: an `argparse` parser's `_actions` are introspectable at runtime with no framework knowledge, and each action carries the `dest` a test can match against a schema key. **Mitigation:** the check must be mechanical and it must fail the build, not appear in a review checklist: `tests/unit/test_schema_parity.py` walks every subparser's actions and fails on any argument that is neither schema-derived nor on the short explicit allowlist (`--output`, `--quiet`, `--yes`, `--config`, `--verbose`, plus `argparse`'s own `-h`); the same test asserts every schema property is reachable as a flag, that its `x-config` path round-trips through `config.yaml`, and that each document passes `Draft202012Validator.check_schema` — a check a hand-written schema needs and rev 2's generated one did not; and a frontend test fails if `FormRenderer` hits its unsupported-widget fallback for any property in the committed schema. Adding to the allowlist requires a reviewer to see the diff — which is the entire point. §2's module-boundary rules state this as a hard rule so it is discoverable before someone writes the argument.

**R18 — Credential exposure through the GUI. — Largely designed out in rev 5; what remains is a different and smaller risk than the original.** The original statement: `GET /api/status` returns the AAP admin password (it is what the status page displays) and `POST` routes start destructive operations with no authentication, so a bind to `0.0.0.0` — via `--host`, a copied command from a blog post, or someone trying to present from another machine — offers the whole cluster to conference wifi unauthenticated.

**Both halves of that are now structurally removed rather than mitigated.** §13 Q15 makes the loopback bind permanent and unconfigurable: there is no `--host`, `gui.host` is fixed, and a test asserts the app cannot be constructed otherwise — so the "someone binds `0.0.0.0`" scenario has no mechanism. And §9.5.1 removes the password from `GET /api/status` entirely: the payload carries credential *references*, and the value reaches the OS clipboard server-side without ever entering the response body, the DOM, or devtools.

**What remains, and it is worth naming precisely because it is easy to declare victory here:** (a) a **shared machine with multiple local user accounts** — another local user can reach the port; §5.5 narrows this to "they get a server they can talk to and a keyring they cannot read", which is a real reduction but not zero, and it is the one case where "loopback is private" is false; (b) **a reverse proxy someone puts in front of the port themselves** — out of our control and explicitly their decision (§9.7), but the startup banner should still echo the bind address so an unexpected exposure is at least visible; (c) **secrets leaking into logs rather than payloads** — unchanged and still the discipline that matters: never log the admin password into a job log or the SSE stream, apply the same rule to playbook `type: secret` vars (§4.8.3), and pass secret values on stdin or a mode-0600 file, never in argv where they land in `ps`.

**R19 — The `image-store` spike may return "not feasible", late.** §4.8.5's preferred redesign depends on CRC supporting a host-directory mount that CRI-O can use, which is unconfirmed and may differ per hypervisor. If the spike runs late and comes back negative, phase 6b has no design and the fallback (ADR-021's skopeo/SSH mechanism) has to be built under time pressure — the exact circumstance in which people port bugs verbatim. **Mitigation:** run the spike **early** — it is four questions with a measurable answer (§4.8.5) and depends on nothing else in the plan, so it can happen during phase 0; the manifest's `mode` choice var means either outcome is a config value rather than a redesign; and the fallback is a known-working 211-line script, so the worst case is "no improvement", not "no feature". Record the answer in an ADR either way — a negative result that nobody wrote down will be re-investigated in a year.

**R20 — An unsigned or unnotarized installer triggers OS security warnings, destroying the credibility the tool exists to project.** This is the highest-severity risk in §10 because the failure is maximally visible and lands on the first interaction. On macOS, an unnotarized app is not warned about — it is **blocked**, with a dialog implying malware. On Windows, an installer signed with a fresh OV certificate (or none) shows *"Windows protected your PC"* and requires the user to click through "More info → Run anyway", which is a thing IT departments train people never to do. A manager who hits either of those does not file a bug; they close the window and conclude the tool is not real. That is the precise inverse of the §9.0 goal. **Mitigation:** treat signing identities as a **release gate on phase 7c**, not a release-week task — request them at project kickoff (§13 Q22), and specifically request an **EV-grade or Azure Trusted Signing** Windows identity, because a standard OV certificate does not clear SmartScreen for a low-volume installer and may never accumulate the reputation to. Use Briefcase's integrated notarization path rather than a hand-rolled `codesign` sweep (§10.2 reason 3) — a Python bundle contains dozens of Mach-O binaries and missing one fails notarization in a way that is tedious to diagnose. Add a **release-blocking acceptance test**: install each artifact on a clean, never-before-used VM of each OS and confirm **zero** security prompts; do not rely on a developer machine, which has already trusted things. Until identities exist, ad-hoc-signed builds circulate internally only (§10.4) and are never given to the target audience.

**R21 — The tray app and the CLI both manage the same cluster and the same config, concurrently.** The two channels are the same package, so nothing stops a technical user from having the tray app running while typing `aap-demo destroy` in a terminal — or from having the GUI's Settings form open with values read five minutes ago while `aap-demo config set` rewrites the file underneath it. Three concrete failure shapes: a `destroy` from the CLI while a GUI deploy job is mid-flight, leaving the job writing to a cluster that is being torn down; a `PUT /api/config` clobbering CLI-written keys with stale form values; and the tray poller reporting "error" for a state change the user themselves caused from a terminal. **Mitigation:** (a) `desktop/server.py` writes `<state>/desktop/runtime.json` (`{pid, port, started_at}`); mutating CLI commands check it and, if a live desktop session is detected, print "A desktop session is running (pid N) and may be managing this cluster" and require confirmation — **a warning, never a hard lock**, because locking a user out of their own CLI is a worse product than the race it prevents. (b) Config writes are **compare-and-swap**: both `PUT /api/config` and `config set` carry the mtime+hash of the file they read, and a mismatch returns a conflict the GUI surfaces as "the configuration changed on disk — reload". (c) One genuine advisory lock, `<state>/cluster.lock` (`{pid, op, started_at}`, stale-detected by PID liveness), guards only the whole-cluster destructive operations — `create`, `deploy`, `destroy` — and a second attempt from either surface refuses and names the holder. This is the one place a real lock earns its complexity. (d) The tray poller reads the *cluster*, so a CLI-caused change is simply observed as truth, not flagged as an error; the state machine must have no "unexpected transition" branch.

**R22 — The auto-update mechanism is itself an attack surface.** An update channel is a supply-chain path straight onto the machine of every user, and hand-rolled ones are a well-worn source of CVEs. Specific ways this goes wrong: the manifest fetched over plain HTTP or following an HTTP redirect; the app treating its own SHA-256 check as a security boundary when the hash and the artifact come from the same origin; a downgrade attack serving an older build with a known flaw; the app auto-executing the downloaded installer; the update running with elevated privileges. **There is also a specific interaction bug waiting in this codebase**: §6.2's trust module sets `CURL_CA_BUNDLE` and `SSL_CERT_FILE` to a bundle containing the CRC ingress CA. If `updater.py` inherits those, the update check validates against a CA store that includes a certificate the *tool itself* installed — which is not the trust anchor an update channel should be using. **Mitigation:** `updater.py` builds its own `ssl.create_default_context()` explicitly against the system store and **ignores** the environment §6.2 sets — with a comment saying why, because this looks like redundant code to anyone who does not know the history. HTTPS only, no plain-HTTP redirect ever followed. Manifest and artifacts on the same origin, so no cross-origin trust downgrade. The SHA-256 is documented **in code and in §10.5** as an integrity check, not a security boundary; the actual boundary is OS signature verification at install time, which is why §10.4 is a hard prerequisite for shipping §10.5 at all (R20 and this risk are coupled: shipping updates without signing would be worse than shipping neither). Never auto-execute the downloaded file. Never run the check or the download elevated. Reject version downgrades unless explicitly chosen from the release page.

**R23 — Installer size and bandwidth are real friction in exactly the scenario this tool is for.** §10.2 estimates a 70–110 MB compressed download. The scenario is a sales laptop on hotel or conference-venue wifi, twenty minutes before a customer meeting — and the auto-update flow (§10.5) re-downloads the **entire** installer, so a user who updates on demo morning pays it twice. A stalled 100 MB download at that moment is a lost demo, and the tool gets blamed for it. **Mitigation:** a hard **150 MB compressed budget enforced by a CI check** that fails the build at the commit that exceeds it, so growth is caught by its author rather than by a user (§10.11). Delta and patch updates are explicitly out of scope — they add an update-format trust problem (R22) for a saving that does not change the order of magnitude. The update banner **shows the download size before the user commits**, and offers "Remind me later". The update check never fires while a job is running. The app is **fully functional without updating** — there is no forced-update wall, so a failed download on bad wifi is never a blocker. And the release page carries direct download links so a user can pre-fetch on good wifi. Keep the number in perspective internally without using it as an excuse: the tool goes on to pull multiple gigabytes of container images, so the installer is never the bandwidth bottleneck — it is only the bottleneck at the moment the user is deciding whether this thing is real.

**R24 — Freezing breaks the entry-point addon model, silently.** The addon system (§4.1) and the day-2 catalog resolve things at runtime through `importlib.metadata` and `importlib.resources`, both of which need genuine `.dist-info` metadata and package data present on disk. A freezer that static-analyzes imports (PyInstaller, Nuitka) does not preserve that unless told to, distribution by distribution — and the failure mode is not a crash, it is `aap-demo addon list` returning nothing in a signed release that nobody can reproduce from a source checkout. There is also a second, permanent consequence that no freezer fixes: **the frozen app's addon set is fixed at build time.** A desktop user cannot `pip install aap-demo-grafana`. **Mitigation:** the §10.2 recommendation of Briefcase is largely *about* this — it pip-installs into the bundle, so metadata and data files are present by construction — and §13 Q21's spike has "resolves a tier-2 addon by entry point in a packaged app on both OSes" as its explicit acceptance criterion. If the fallback (PyInstaller) is taken instead, `copy_metadata()` per tier-2 distribution plus a `datas` entry per data directory becomes a maintained list, and every new addon distribution must update it. Either way, **the tripwire is a packaged-app smoke test in CI** (§10.11): install the built artifact on a clean runner and assert `GET /api/addons` lists the full tier-2 set — so a metadata regression fails the release rather than a user. For the fixed-set consequence: the desktop bundle ships `aap-demo[gui,desktop,demos]` so all first-party addons are present; `AAP_DEMO_ADDON_PATH` (§4.1) remains the sideload path and the desktop app surfaces it as a Settings field defaulting to `<config>/addons/`; and third-party addon *installation* is documented plainly as a **pip-channel capability**, which is honest — that audience has a terminal.

**R25 — "Zero terminal" is true of aap-demo and not yet true of the user's first run.** A signed installer gets the tool onto the laptop. It does not get the user OpenShift Local (a separate multi-hundred-megabyte signed installer with its own administrator prompt), a Red Hat pull secret (a login to console.redhat.com and a file download), or the hardware headroom the deploy needs. If the roadmap or a deck promises a zero-terminal experience end to end, the gap surfaces at the customer site rather than in review. **The sharpest version of this**: if the target audience's laptops are corporate-managed without local administrator rights, **CRC cannot be installed at all**, and no amount of aap-demo packaging fixes that — the entire desktop channel would be moot for those users. **Mitigation:** §10.10 does the work that can be done — deep-linked download buttons, a **pull-secret paste box** that writes `<state>/pull-secret.json` (replacing the file-placement step most likely to be got wrong), and a hardware check that fails in the first thirty seconds with the actual numbers rather than forty minutes into a deploy. Beyond that, the mitigation is not code: **validate the full flow on one real, corporate-managed target laptop before committing the desktop roadmap** (this overlaps §13 Q23's WebView2 question, so do both in one sitting), and do not make the zero-terminal claim in marketing copy until CRC's own install is verified as double-click on both OSes for a non-administrator. If it is not, that is a finding worth having early — it would redirect effort toward a hosted or preinstalled-image story instead, which is a different project.

**R26 — The CRC extension and `aap-demo create` disagree about the cluster's identity.** `crc-org/crc-extension` registers its Kubernetes provider connection with a **hardcoded** `apiURL = 'https://api.crc.testing:6443'`, while `includes/crc-create.sh` deliberately reconfigures the VM's base domain to `nip.io` — and per R1 that step *wipes MicroShift data*, because CRC starts on `crc.testing` before the dropin can be written. A user who installs both extensions and runs `create` therefore gets: Podman Desktop showing a stale API URL; routes that no longer match what the CRC extension believes; and a data-wiping reconfiguration of a VM they may consider the CRC extension's property. It is also the first thing a `crc-org` reviewer would notice (§11.8). **Mitigation:** (a) before running `create` in this channel, detect an existing CRC-extension-managed cluster and require an explicit confirmation naming exactly what will be reconfigured and that the VM's data will be reinitialized — the ADR-001 "fail with fixes" rule applied to a destructive surprise; (b) treat "does aap-demo still need the nip.io base domain, or can it use `apps-crc.testing` as the CRC extension expects?" as a real question for the implementer, because if the answer is that it can, this risk disappears entirely and one of the most fragile steps in `crc-create.sh` (§14 R1) goes with it; (c) if the reconfiguration must stay, say so in the extension's README rather than letting users discover it.

**Deferred to phase 4b (rev 6).** This risk only exists on the OpenShift preset — MicroShift's `nip.io` reconfiguration doesn't collide with the CRC extension the same way, since the extension's hardcoded `apps.crc.testing` assumption is specifically an OpenShift-preset default. With full OpenShift support resequenced to phase 4b rather than shipping alongside MicroShift in v1, resolving R26 is not a v1 gate — the maintainer's framing: "let's not worry about it until we get to full openshift mode." Two candidates to investigate first, in this order, when phase 4b starts: (1) reconfigure the OpenShift preset onto `nip.io` the same way MicroShift already is — if that works, R26 is eliminated rather than mitigated, and mitigation (a)/(c) above become unnecessary; (2) failing that, a longer-term option the maintainer is considering independently of this project — acquiring a dedicated domain (candidate: `aap-demo.io`) to host a self-owned wildcard DNS zone, replacing `nip.io` for both presets and sidestepping the CRC extension's `apps.crc.testing` assumption entirely. Neither is pursued now; this paragraph is the starting point for whoever picks up phase 4b.

**R27 — Depending on `redhat.openshift-local` inherits its bugs as our support burden.** The §11.6 decision buys ecosystem citizenship and pays for it with three known upstream defects that surface to our users as our failures: preset-switch-after-creation ([podman-desktop#4617](https://github.com/podman-desktop/podman-desktop/issues/4617)), extension self-update failures ([crc-extension#176](https://github.com/crc-org/crc-extension/issues/176)), and missing `crc`/`microshift` binaries not being auto-downloaded ([podman-desktop#2659](https://github.com/podman-desktop/podman-desktop/issues/2659)). A user does not know which extension failed; they know aap-demo did not work. There is also a structural aggravator: **`crc-extension` exports no public API** (`activate()` returns `void`), so we cannot query it directly — interop runs through Podman Desktop's provider/kubernetes API and through `crc` itself, which means our detections are inferences about someone else's state. **Mitigation:** the three detections and their specific messages in §11.6's table are **required v1 scope, not polish** — each names the condition, the fix, and the upstream issue so the user can see it is not our bug; the version-range banner is non-blocking so their release cadence cannot block ours; and the preset check lands in `POST /api/deploy/plan`'s warnings so the CLI and the desktop channel get it too rather than it being extension-only knowledge. Additionally: subscribe to those three issues, and re-test the interop path on every CRC-extension minor — the §11.9 packaged-extension smoke test is where that regression would be caught.

**R28 — The managed-venv bootstrap fails on exactly the machines that matter most.** §11.4's install step runs `python -m venv` and `pip install aap-demo==X.Y.Z` on a laptop that may have no Python, a corporate TLS-intercepting proxy that breaks PyPI, an EDR agent that blocks a freshly-written interpreter, or a policy against user-site installs. The failure lands during onboarding, before the user has seen anything work, which is the worst moment for it — and unlike §10's installer channel, there is no signed artifact to fall back on. **Mitigation:** stream the full `pip` output into the onboarding log rather than swallowing it, because a proxy/TLS failure is diagnosable from that text and from nothing else; honor the host's proxy configuration explicitly rather than relying on inheritance; verify the python-build-standalone fallback download against a SHA-256 pinned in the extension image (an unpinned interpreter download would be R22's supply-chain problem with none of R22's mitigations); make `aapDemo.backend.path` a first-class, documented escape hatch so a user with a working `pipx install aap-demo` is never blocked by our installer; and treat repeated bootstrap failure as the trigger for §13 Q26 (bundle the runtime) rather than as something to iterate on indefinitely. The §11.9 packaged-extension smoke test must exercise the venv build on a clean runner, not a developer machine that already has a warm pip cache.

**R29 — "Officially adopted by Red Hat" is an organizational outcome that no amount of design quality guarantees, and building for it can quietly distort the product.** The catalog listing is a mechanical PR with no published review criteria; the thing that would actually constitute adoption — membership in `redhat-developer/podman-desktop-redhat-pack-ext`'s `extensionPack` array — has **no published process at all**, and every current member is a repo inside a Red Hat GitHub org with an internal maintenance owner. So the outcome depends on securing org ownership, a registry namespace, and a named maintainer (§13 Q28), none of which are engineering decisions, and any of which can simply not happen. The specific way this becomes a *technical* risk: designing for adoption pulls toward conventions and dependencies (the `extensionDependencies` edge on `redhat.openshift-local`, publisher `redhat`, matching another team's structure) whose cost — R26 and R27 — is paid immediately by users, while the benefit is contingent on someone else's decision. **Mitigation:** ask the ownership question at kickoff alongside §13 Q22, and be willing to hear no; until it is answered, publish under a neutral publisher so nothing has to be un-published; and sanity-check every adoption-motivated decision against the question *"would we still do this if adoption never happened?"* — for the `crc-extension` dependency the answer is yes (it is genuinely better behavior for a Podman Desktop user regardless of who owns the repo), which is why §11.6 stands; for anything where the answer is no, do not do it. Finally, keep this channel's *scope* small enough (§11.11) that its value does not depend on adoption: even unadopted and installed by hand from an OCI image, it is a working GUI for SEs on all three OSes, including the Linux desktop §13 Q19 declines to serve.

**R30 — The credential store silently degrades into "credentials in a file".** §5.5 moves the admin password, the Galaxy/PAH tokens, the portal OAuth tokens, and the `apme-eap` GitHub credential out of files and into the OS keyring. The failure this creates is not a crash — it is the *fix* for a crash. On a headless Linux box `keyring` resolves to `keyring.backends.fail.Keyring` and every credential operation raises; the obvious-looking repair, under time pressure, is "fall back to a file if there is no backend", and the obvious-looking second repair is "make the fallback's passphrase optional so CI works". Two commits and the design is back where it started, except now it *claims* to use OS-native storage, which is worse than never having claimed it. The same shape threatens from the other direction: a migration (§12.2) that imports credentials into the keyring but leaves the plaintext source files behind has produced a second copy, not a move.

**Mitigation, and all of it is mechanical rather than a rule someone has to remember:** (a) **fail loudly and exit 3 with a platform-specific message** when no backend resolves — never warn-and-continue, never an automatic file fallback; the escape hatch is an explicit `KEYRING_BACKEND` the user sets themselves (§5.5.3), which keeps the decision with the person who understands their threat model. (b) **`tests/unit/test_secrets.py` asserts the no-backend path raises rather than writes**, and asserts `SecretStore` has no filesystem write path at all — the module cannot fall back to a file because there is no code in it that opens one. (c) **Resolve the keyring lazily**, never at startup, so the failure only reaches users of the four features that actually need a credential; getting this wrong turns a keyring-less machine into one where `aap-demo status` fails, which would be a self-inflicted regression that *invites* the file fallback. (d) **The migration deletes the source file after a verified import** and, when no backend is available, skips the credential import with a message naming exactly which files it did not touch — a half-migration that says nothing is how a plaintext token survives for a year. (e) §2's module-boundary rule — only `core/secrets.py` touches the keyring, and no credential enters the config file, an env var, a log line, a job event, or an API body — makes a violation a reviewable diff in one file rather than a needle anywhere in the tree. **Open question**: whether hard-requiring is sustainable for headless RHEL, or whether a properly-designed encrypted mode must exist — §13 Q30, which is exactly the decision that must not be made in a hurry by a contributor unblocking themselves.

---

## Appendix A — Files read for this design

`aap-demo.sh` (full dispatch, all `cmd_*` functions); `includes/{aap-demo-paths,aap-demo-version,aap-demo-notice,infra-api,infra-crc,crc-create,ingress-ca-trust,olm-catalog-signature,galaxy-auth}.sh`; `addons/{ao,ao-eap,product-demo-linux,product-demo-cloud,product-demos-base,registry,olm,mcp-server,local-cache,setup-pah,apme-eap}/deploy.sh` and `addons/product-demos-base/lib.sh`; `config/crs/aap-minimal.yaml`, `config/olm/{subscription,catalogsource,operatorgroup}.yaml`, `config/manifests/nfs-provisioner.yaml`; `docs/adr/{001,003,008,010,012,014,015}`; `test/README.md`, `test/test-core-commands.sh`; `install.sh`; `pyproject.toml`; `VERSION`; `powershell/native/Private/Commands.ps1` (function inventory); `.github/workflows/` (listing); git tag list (empty).

**Added for revision 2** (2026-09-02): `docs/adr/005-olm-on-microshift.md` (confirming OLM is mandatory on MicroShift — tier 1); `docs/adr/013-in-cluster-registry.md` (confirming `registry` is dev tooling off the deploy path — tier 3); `docs/adr/021-local-cache-addon.md` in full (the skopeo/SSH/md5 mechanism, its ~30 GB and 10–15-minute costs, and its own "Alternatives Considered" section — which does **not** consider host-directory mounting, the gap §4.8.5 targets); `docs/adr/020-full-openshift-support.md` (**Declined** — the basis for treating MicroShift as the only preset); GitHub issue **#92** ("Implement dedicated Execution Environment and migrate to ansible-navigator", open, author BBGrimmett2) — §4.8 implements it; `requirements.yml`; `ansible/` (listing); `aap-demo.sh:1685–1884` (`cmd_status` output inventory, re-read section by section for §9.5) and `aap-demo.sh:1815–1859` (credential display, for the mask/reveal design); `docs/adr/` full listing; `addons/` full listing (18 directories).

**Added for revision 3** (2026-09-02): no new repository files were read. §10 is a design pass over this document itself — the desktop channel derives entirely from decisions already recorded here (the entry-point addon model in §4.1, the tier rule in §4.5, the event/job architecture in §9.4, the packaging shape in §8.1/§9.6) plus the maintainer's audience disclosure. Two claims in §10 are asserted from general platform knowledge rather than verified against this environment and are flagged as spike-gated rather than settled: Briefcase's preservation of `.dist-info` entry points in a packaged bundle (§13 Q21) and WebView2 availability on the target Windows fleet (§13 Q23).

**Added for revision 4** (2026-09-02): no new repository files were read; §11 is researched against upstream sources rather than this repo. Read directly: `podman-desktop/podman-desktop` — `packages/extension-api/src/extension-api.d.ts` (the `Webview`/`WebviewOptions`/`WebviewPanel` interfaces, `window.createWebviewPanel`, the `extensions` namespace and its `extensionDependencies` contract, `SecretStorage`, `authentication`, `process.exec`, `cli`, `kubernetes.getKubeconfig`, `provider.*`), `packages/main/src/plugin/webview/webview-registry.ts` and `webview-impl.ts` (the express server on 127.0.0.1, the `<uuid>.webview.localhost:<port>` origin, `cspSource`, and `asWebviewUri`'s HTTP passthrough), `packages/renderer/src/lib/webview/Webview.svelte` (the Electron `<webview>` element and its `src`), and `website/docs/extensions/publish/index.md` (OCI packaging, the `io.podman-desktop.api.version` label, per-platform manifests, the catalog PR). `podman-desktop/extension-template-webview` `src/extension.ts` and `podman-desktop/extension-template-full` `packages/backend/src/extension.ts` (the two webview-hosting patterns — HTML string, and built-`index.html`-plus-`asWebviewUri`). `podman-desktop/podman-desktop-catalog` `static/api/extensions.json` (the entry schema and the full 23-extension listing; the repo has no README or CONTRIBUTING, hence §11.8's "no published review criteria"). `crc-org/crc-extension` `package.json` (publisher/engines/`contributes.configuration`, the `crc.factory.*` preset and pull-secret settings, `extensionDependencies: ["redhat.redhat-authentication"]`, and the vitest/Playwright/ESLint tooling conventions) and `src/extension.ts` (`activate()` returning `void` — no exported API; `registerKubernetesProviderConnection` with the hardcoded `https://api.crc.testing:6443`; the unsupported `podman` preset). `redhat-developer/podman-desktop-redhat-account-ext` `package.json` (the onboarding contribution shape) and `src/extension.ts` (the `redhat.authentication-provider` id and the `registry.redhat.io` registry service account). `redhat-developer/podman-desktop-redhat-pack-ext` `package.json` (the `extensionPack` array that concretely defines "in the Red Hat extension pack"). Upstream issues taken as given from the requester and cited but not independently reproduced: podman-desktop#4617, crc-org/crc-extension#176, podman-desktop#2659.

**Added for revision 5** (2026-09-02): two external verifications and one repository investigation, all done directly rather than recalled.

**External, and decisive for §3.1, §5.1, and §9.3:** the published dependency metadata and CLI entry points of **`ansible-navigator`** and **`ansible-creator`**. Findings taken as given below: `ansible-navigator` declares `pyyaml` and `jsonschema` as hard dependencies and declares no `click`, `typer`, or `pydantic`; `ansible-creator` declares `pyyaml`, declares none of the three, and its `cli.py` drives a hand-rolled `arg_parser.Parser` wrapping stdlib `argparse`. Neither project uses TOML for anything but its own `pyproject.toml`. These two facts are what re-decided Q9 (config format) and Q2 (CLI framework + schema mechanism).

**Repository, and decisive for §13 Q10:** a `find` over the repo root for an `ansible/` directory — **it does not exist**, which retires rev 2's hope that it might seed the playbooks repo. `requirements.yml` at the repo root, read in full: it declares `kubernetes.core` and `community.general` and nothing in the tree consumes them, confirming it orphaned and making it the natural seed for `aap-demo-playbooks`'s EE requirements instead. `aap-demo.sh:485` re-read to confirm `AAP_DEMO_ANSIBLE` is documented in help text and read by no code path.

**Not re-read, and not needed:** no other repository file. §5.5's credential design is a design pass over §5.2's existing inventory of what lives in `~/.aap-demo/` today plus the maintainer's requirement; §9.3's rework replaces a mechanism this document defined rather than one the repo contains. Two claims in this revision are asserted from general platform knowledge rather than verified here and should be treated as spike-shaped if they turn out to matter: that `keyring` resolves to `fail.Keyring` (rather than something subtler) on a headless Linux session with no D-Bus — the branch §5.5.3 and R30 hang on — and that a local FastAPI process can set the host clipboard on all three OSes through the small-binary path §9.5.1 recommends over `pyperclip`. Neither is load-bearing for the architecture; both are load-bearing for one feature each.
