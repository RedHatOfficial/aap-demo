# ADR-040: Shared Addon Framework and Bash Fallback for the Python Command

**Status**: Accepted

**Date**: 2026-11-09 (updated 2026-11-10, after #329 merged; updated 2026-11-12, AO on the fallback)

**Authors**: aap-demo maintainers

**Extends**: [ADR-039](039-product-demos-on-v2-enable.md)

## Context

The bash command lists 15 addons in `AVAILABLE_ADDONS`. The Python command (2.0.0rc1)
runs three of them:

- `fleet`, in Python. Only the in-cluster (kube-native) backend, not the QEMU one.
- `product-demos` and `product-demo-satellite`, through the bash installers that
  ADR-039 (#329) bundles into the wheel.

These 11 still stop with `unknown addon '<name>'`: mcp-server, portal, portal-operator,
setup-pah, ao, ao-pr-testing, apme-eap, local-cache, opa, ollama and keycloak. Their
`deploy.sh` files alone come to about 8,000 lines of bash. The error now links
[the older command](../guides/older-command.md), which is still the only way to run them.

The first Python release was meant to break nothing. Issue #328 showed that it did,
and #329 fixed it for product-demos alone. It added `addons/shell.py` with a
`ShellAddon` that runs `addons/<name>/deploy.sh` with the Python command's kubeconfig,
namespace and enabled-addon list. It bundles the product-demos directories into the
wheel under `aap_demo/bundled_addons/`, records the addon in `addons.enabled`, and
handles product-demos needs: credential wiring, the Galaxy token file, and a result
file that marks a partial install.

That leaves two addon patterns, and neither is shared:

- **No addon abstraction.** `addons/__init__.py` holds `_REGISTRY = {"fleet": FleetAddon()}`
  and a separate `SHELL_ADDONS` set. `get()` returns `Union[FleetAddon, ShellAddon]`.
- **Fleet's reusable parts live inside `fleet/`.** The Job that runs a playbook in the
  cluster (`fleet/job.py:run_playbook`, in an 846-line module), EE discovery
  (`fleet/ee.py`), the gateway URL and credentials (`fleet/gateway.py`) and the
  saved addon options (`fleet/state.py`) are all fleet-specific today. In the same
  files sit pieces that really are fleet's own: node RBAC, the fleet SCC and the
  namespace it owns.
- **`shell.py` is product-demos-shaped.** Its bundled list, wiring script, Galaxy
  token and partial-install marker are all specific to product-demos.

Done the same way for the other 11 addons, it would mean 11 more special cases.

Constraints:

- Nothing may break: every addon that works on the bash command has to keep working
  through `aap-demo enable <name>` until it is ported.
- No second config system. The Python `config.yaml` is the record of what is enabled.
- The bash scripts read `~/.aap-demo/` paths by default (`includes/aap-demo-paths.sh`).
  The Python command keeps its kubeconfig at
  `$XDG_STATE_HOME/aap-demo/kubeconfig.microshift`.
- Bash-only features are not being fixed on the bash side. Changes to the bash scripts
  are limited to what lets Python run them.

## Decision

### 1. One addon interface and a registry table

Add an `Addon` protocol in `aap_demo/addons/base.py`:

- `name`, `summary`
- `enable(ctx, args)`, `disable(ctx, args)`, `destroy(ctx, args)`, `status(ctx, args)`
- `needs_cluster` (bool) and `required_tools` (for example `("bash", "curl", "jq")`)
- `kind`: `"native"` or `"legacy"`, shown in `aap-demo addon list` and `status`

The registry becomes one table of `Addon` instances, replacing `_REGISTRY` plus
`SHELL_ADDONS`. `get()` and `registry()` return `Addon`. The CLI reads `needs_cluster`
and `required_tools` to run its checks before calling the addon. No addon repeats
those checks itself. `kind` comes from the registry and is not stored in config.

### 2. Move the shared parts out of `fleet/`

Create `aap_demo/addons/common/`:

| Module | Moves from | Purpose |
|--------|------------|---------|
| `playbook_job.py` | the general part of `fleet/job.py` | Run a playbook in a Job inside the cluster, with the cluster's EE: runner account, ConfigMap, extra vars in a Secret, pull secret, wait, clean up |
| `ee.py` | `fleet/ee.py` | Find the EE image already in the cluster |
| `gateway.py` | `fleet/gateway.py` | Gateway URL, CA, admin credentials |
| `state.py` | the general part of `fleet/state.py`, and `_enabled`/`_save_enabled` from `shell.py` | Read and write `addons.enabled` and `addons.options.<name>` in `config.yaml` |

The fleet-specific pieces stay in `fleet/`: node RBAC, the fleet SCC, node images,
SSH keys and the inventory import. Callers pass the Job a namespace, a name prefix
and the RBAC it needs, rather than the Job assuming fleet.

This step ships as its own PR and changes no behavior. Fleet's and product-demos'
existing unit tests pass unchanged, apart from import paths.

### 3. Extend the bash fallback to every unported addon

Generalize `ShellAddon` from ADR-039 into the fallback for all 11 remaining addons,
registered from a single list.

- **Packaging:** the wheel force-includes every addon directory that has a
  `deploy.sh`, plus the `includes/` files those scripts load, under
  `aap_demo/bundled_addons/` (the path ADR-039 already uses). The scripts load
  `addon-wire.sh`, `aap-demo-paths.sh`, `galaxy-auth.sh`, `infra-crc.sh`,
  `aap-readiness.sh` and `olm-catalog-signature.sh`, plus their own `lib/`. A test
  fails the build if a bundled script loads a file that isn't in the bundle.
- **Script location:** unchanged from ADR-039. A source checkout's `addons/` is used
  first, otherwise the bundled copy.
- **Environment:** Python sets everything the scripts would otherwise guess:
  `KUBECONFIG` and `AAP_DEMO_KUBECONFIG` (the Python path), `AAP_DEMO_DIR`,
  `NAMESPACE`, and `AAP_DEMO_ENABLED_ADDONS` (from `config.yaml`). Secrets the
  scripts need are passed in environment variables. When a script needs a file,
  Python creates it with mode 0600 from the start (`tempfile.mkstemp`, as `shell.py`
  does for the Galaxy token) and deletes it afterwards.
- **Per-addon hooks:** what ADR-039 hard-codes for product-demos becomes optional hooks
  on the shell addon entry: a post-install step (product-demos credential wiring),
  extra secret files (the Galaxy token), and the result-file marker for a partial
  install. Addons that need none of them use the plain runner.
- **Wiring:** once `addon-wire.sh` is bundled, ADR-023 auto-wiring runs inside the
  installers again. ADR-039's `AAP_DEMO_WIRE_AFTER_DEPLOY=0` workaround is dropped at
  that point, and the product-demos post-install step is kept only if it still adds
  something.
- **State:** a legacy addon is recorded in `addons.enabled`, as ADR-039 does for
  product-demos. The scripts read `AAP_DEMO_ENABLED_ADDONS` instead of grepping
  `~/.aap-demo/config`. That is the `lib.sh` change ADR-039 made, applied to every addon.
- **Windows:** the fallback needs bash. On Windows that means Git Bash (ADR-031).
  If bash is missing, the error says so and names the addon. It doesn't fall
  through to a confusing script error.
- **Errors:** a name that is neither native nor legacy is an error that lists
  both groups. When a script fails, the error gives its exit code and the path of
  the script that ran.

#### Progress: AO, mcp-server and ollama (2026-11-12)

AO, with the two add-ons it needs, is the first group on this fallback:

- **Layout:** the wheel carries the bundled files under `aap_demo/bundled/`, in the
  repository's own layout (`bundled/addons/<name>`, `bundled/includes`,
  `bundled/config/olm`). It replaces ADR-039's `aap_demo/bundled_addons/`, so the
  scripts' `../../includes` and `REPO_ROOT` paths resolve unchanged. `includes/` is
  bundled whole. `addons/subscription-attach` is bundled because `addon-wire.sh` runs it.
- **Wiring:** a `self_wire` option sets `AAP_DEMO_WIRE_AFTER_DEPLOY=1` for these three,
  because AO wires itself to AAP before it imports its workflows. Product demos keep the
  post-install step.
- **What `aap-demo.sh` did before `deploy.sh`:** a `prepare` hook covers it. mcp-server and,
  with the default `AO_LLM_PROVIDER=ollama`, ollama are enabled first and recorded in
  `addons.enabled`. The LLM provider comes from `AO_LLM_PROVIDER`, with no prompt, so
  nothing is saved to `~/.aap-demo/config`. The product-demos question became a note.
  The pull secret this command found is passed as `PULL_SECRET_PATH`.
- **Not yet:** `AAP_DEMO_DIR` is not set, so AO's saved admin password stays in
  `~/.aap-demo/ao/`, where an existing install already has it.

### 4. Porting an addon later

To port an addon, replace its shell entry with a native class built on
`addons/common/`. Its bash directory leaves the bundle in that same PR, so each
addon has exactly one implementation per release. Each port has its own ADR when it
changes behavior. Product-demos is planned as the first one: it runs upstream
`install-apd.yml` through `playbook_job` and follows upstream `main` by default,
with a `--ref` override. That gets its own ADR.

### Order

1. The addon interface, the registry, and the move to `addons/common/`. No behavior change.
2. The bash fallback for the remaining 11 addons, built from ADR-039's `ShellAddon`. Targets rc2.
3. Native product-demos.
4. The other addons, one PR each, in whatever order they are needed.

## Consequences

### Positive

- `aap-demo enable <name>` works for every addon the bash command has, as the
  2.0 compatibility promise requires.
- A second native addon reuses the Job runner, EE discovery, gateway access and
  state, rather than copying them out of fleet.
- The CLI runs the cluster and tool checks once for every addon.
- `aap-demo addon list` shows which addons are native and which are legacy, so
  porting progress is visible to users.
- What #328 fixed for product-demos is fixed for the 11 addons nobody has reported yet.

### Negative

- The wheel grows. The full bundle size has not been measured, and `apme-eap` may
  contain large files. Put a size check in the build.
- Legacy addons need bash, curl and jq (and whatever else each script uses) on the
  user's computer. macOS doesn't ship jq.
- Every bundled script is code the Python release now ships and supports. A bash
  bug shows up as a Python command bug. #329's live test found one: zero async
  retries made the Windows product-demos domain fail every time.
- Moving code out of `fleet/job.py` risks regressions in fleet's cleanup of the
  namespace and RBAC it owns. That is the reason step 1 has to change no behavior.
- Users who ran addons from the bash command have their state in `~/.aap-demo/config`.
  The Python `status` command doesn't see those addons until someone enables them
  again through the Python command, or a migration step reads them.

### Neutral

- The bash command and `aap-demo-v1` keep working, as they do today.
- Fleet's and product-demos' behavior and user-facing commands don't change.
- Bash-only commands that aren't addons (`trust-ca`, `wire`, `configure`,
  `github`, `load`) are not affected by this ADR.

## Alternatives Considered

### Stop at product-demos (ADR-039)

Rejected as the long-term shape. It leaves 11 addons failing and two addon patterns
side by side. Its code (`ShellAddon`, finding the scripts, the environment handling,
the 0600 secret files) is the starting point for the generic fallback here.

### Document `aap-demo-v1` and wait for native ports

Rejected. It breaks the non-breaking promise, needs a checkout and a renamed symlink,
and splits state between two config systems for months.

### Hand any unknown name to `aap-demo.sh`

Run the whole bash CLI (`aap-demo.sh enable <name>`) instead of each addon's
`deploy.sh`. Rejected: it brings the bash command's config file, kubeconfig guessing
and prompts back into the Python command. It also needs the whole bash tree in the
wheel, and nothing then records which addons are legacy.

### Port all 11 addons to Python before 2.0 final

Rejected for the timeline: about 8,000 lines, several with their own operators,
Helm charts and OLM flows. Ports happen one at a time on top of the shared layer.

### Turn `fleet/` into the framework in place

Rejected. Other addons would import from `fleet`, and fleet-only RBAC and SCC code
would sit in their path.

## References

- [Issue #328](https://github.com/RedHatOfficial/aap-demo/issues/328): `enable product-demos` failed on the Python command
- [PR #329](https://github.com/RedHatOfficial/aap-demo/pull/329) and
  [ADR-039](039-product-demos-on-v2-enable.md): the product-demos fallback this extends
- [ADR-001](001-project-cli-architecture.md): project CLI architecture
- [ADR-008](008-addon-system.md): addon system
- [ADR-018](018-product-demos-addon.md): product-demos addon
- [ADR-023](023-addon-auto-wiring.md): addon auto-wiring
- [ADR-026](026-fleet-addon.md): fleet addon
- [ADR-031](031-windows-git-bash-wrapper.md): Git Bash on Windows
- [The older command](../guides/older-command.md)
