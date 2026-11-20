# ADR-045: Automation Orchestrator on the Python Command

**Status**: Proposed

**Date**: 2026-11-18

**Authors**: aap-demo maintainers

**Extends**: [ADR-040](040-addon-framework-and-bash-fallback.md), [ADR-043](043-ao-postgres-statefulset.md)

## Context

`aap-demo enable ao` runs the bundled `addons/ao/deploy.sh` through a `ShellAddon`
(ADR-040). That script is about 1,900 lines of Bash plus helper libraries, and it
starts three Python scripts of its own for AAP provisioning, demo import and
Fleet workflows. The Python command therefore needs Bash, curl, jq and base64 to
install AO, and AO's behavior is split between two languages that are tested
separately.

The installer has changed shape several times. A cluster can hold an AO from any
of these eras:

1. aapctl-generated manifests with a CloudNativePG (CNPG) database and the old
   `orchestrator-pg-credentials` Secret names.
2. CNPG with the current Secret names.
3. The ADR-043 PostgreSQL StatefulSet with service-ca TLS.

The host may also hold `~/.aap-demo/ao/initial-admin-password`,
`~/.aap-demo/ao-state` or `~/.aap-demo/ao-eap-state`, and `AO_LLM_*` keys in
`~/.aap-demo/config`.

`aap-demo-v1 enable ao` runs the same `deploy.sh` from a checkout.

## Decision

### Native addon

AO becomes a `native` addon. One Python package, `aap_demo.addons.ao`, does the
whole `enable ao`: namespace and SCCs, catalog source, OLM Subscription and
InstallPlan approval, the ADR-043 PostgreSQL (manifest, Secrets, CA copy,
databases, storage size, reset), the AutomationOrchestrator CR, local AAP access,
MCP and LLM wiring, AAP provisioning, demo import and Fleet workflows. The three
scripts in `addons/ao/scripts/` move into the package as modules and are called
directly. The manifests in `addons/ao/manifests/` stay the single source for both
commands.

The switch happens in one release. Python never runs `deploy.sh`, and AO no
longer needs Bash, curl, jq or base64 under the Python command.

### SCCs

AO's namespace grants only `nonroot-v2`, to `default` and the catalog
ServiceAccount. Only two AO pods run outside `restricted-v2`, and both need just a
fixed non-root UID: PostgreSQL as UID 26, which owns its data, and OLM's bundle
unpack and catalog pods as UID 1001. The PostgreSQL manifest pins UID 26, so data
written under the `anyuid` grant of earlier releases stays readable. `enable ao`
grants `nonroot-v2` before it deletes the earlier `anyuid` and `privileged`
bindings, and `disable ao` deletes all of them, since they are cluster-scoped.

### Adopting existing installs

The Python addon must take over any AO the Bash installer left, without
`--force`, unless the data would be lost:

- **StatefulSet era**: adopted as is. Its claim size, Secrets, CA copy and admin
  password are kept.
- **CNPG eras**: a Ready instance is left running and reported, as the Bash
  installer does today. Moving it to the StatefulSet needs `--force`, which deletes
  AO's data. Cleanup deletes only the CNPG objects AO created.
- **Legacy Secret names**: refused without `--force`, as in the Bash installer.
- **Admin password**: the first Python run copies
  `~/.aap-demo/ao/initial-admin-password` into the Python state directory
  (mode 0600) and leaves the original for `aap-demo-v1`. A file, not the OS
  keyring, because the keyring is not available on every host. A retained database is detected by the
  StatefulSet PVC `data-orchestrator-postgres-0` as well as the CNPG names.
- **LLM settings**: `AO_LLM_PROVIDER`, `AO_LLM_BASE_URL` and `AO_LLM_MODEL` are
  read from the environment, then `addons.options.ao` in `config.yaml`, then the
  legacy config. The external provider's API key is copied from
  `~/.aap-demo/ao/llm-api-key` into the Python state directory (mode 0600) the
  same way as the admin password.
- **TLS**: the wiring verifies the AO and AAP routes against the cluster's
  ingress CA instead of the Bash wiring's `curl -k`.
- **State files**: `ao-state` and `ao-eap-state` carry nothing the Python addon
  needs and are left alone.

Each era gets a unit test against recorded cluster state, and the StatefulSet
and CNPG eras get a live adoption check before the release.

### Bash installer lifecycle

`addons/ao/deploy.sh` and its libraries are frozen for `aap-demo-v1`: no new
features, and fixes only for data loss. They are removed in a later release, once
the Python addon has shipped in a release and the adoption checks have passed on
real installs. The removal release notes point `aap-demo-v1` users to
`aap-demo enable ao`, which adopts their install.

## Consequences

### Positive

- One language and one test suite for AO under the Python command.
- AO installs without Bash wherever the Python command runs.
- Upgrading from either command keeps existing AO data unless `--force` is
  given.

### Negative

- A large port, reviewed in one PR. Behavior that only the Bash tests cover has
  to be carried over by hand.
- Until removal, the manifests are shared by a frozen Bash installer and the
  Python addon, so manifest changes must keep working for both.

### Neutral

- `aap-demo-v1 enable ao` behaves as before.
- The native PowerShell AO path (ADR-030) is unchanged.

## Alternatives Considered

### Port in phases behind the Bash wiring

Run the core install in Python and call `deploy.sh` in a wire-only mode until a
later phase. Rejected: it keeps two languages in one install and adds a Bash mode
only to remove it again.

### Delete `deploy.sh` with the port

Rejected for now: `aap-demo-v1 enable ao` would stop working with no warning
release in between.

## References

- [ADR-017: Automation Orchestrator Addon](017-ao-addon.md)
- [ADR-040: Shared Addon Framework and Bash Fallback](040-addon-framework-and-bash-fallback.md)
- [ADR-043: One PostgreSQL StatefulSet for Automation Orchestrator](043-ao-postgres-statefulset.md)
- [PR #338](https://github.com/RedHatOfficial/aap-demo/pull/338): storage size and CNPG cleanup this port carries over
