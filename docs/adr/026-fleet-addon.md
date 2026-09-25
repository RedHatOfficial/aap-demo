# ADR-016: Fleet Addon — Local QEMU VMs as Managed Nodes

**Status**: Accepted

**Date**: 2026-07-09

**Authors**: aap-demo maintainers

## Context

AAP demos often need managed hosts to target with playbooks, job templates, and EDA
rulebooks. Spinning up external VMs or cloud instances adds setup friction and
infrastructure cost.

Fleet was initially implemented as core functionality (`includes/fleet.sh`,
`includes/fleet-aap.sh`, cloud-init templates, `--fleet`/`--image` flags on deploy,
deep hooks in `cmd_deploy`/`cmd_status`/`cmd_stop`/`cmd_destroy`). This bloated the
main script and coupled VM management tightly to the core lifecycle — even though fleet
is optional demo infrastructure that many users never need.

Per [ADR-008](008-addon-system.md), optional capabilities should be opt-in,
independently deployable/removable, and discoverable via `aap-demo enable`.

## Decision

Move fleet to a self-contained addon under `addons/fleet/`, following the ADR-008
contract, with a thin dispatcher in `aap-demo.sh` for subcommand routing.

### Addon structure

```text
addons/fleet/
├── deploy.sh                  # ADR-008 contract: deploy + --delete
├── fleet.sh                   # VM lifecycle (QEMU, cloud-init, SSH)
├── fleet-aap.sh               # AAP REST API registration (inventory, credential, hosts)
└── cloud-init/
    ├── user-data.template     # Cloud-init user provisioning (ansible user + SSH key)
    └── meta-data.template     # Cloud-init instance metadata
```

### ADR-008 compliance

| Design rule | How fleet satisfies it |
|-------------|----------------------|
| Must not modify core AAP CR | Uses AAP REST API (inventory, credentials, hosts), not the CR |
| Use `NAMESPACE` env var | Fleet-aap.sh discovers AAP route and secrets via `NAMESPACE` |
| Check `kubectl cluster-info` | `deploy.sh --delete` checks before AAP deregistration |
| Idempotent re-enable | Re-running `deploy.sh` validates prereqs; existing VMs untouched |
| `--delete` cleans cluster resources | Deregisters AAP inventory/credential/hosts, destroys all VMs |

### deploy.sh behavior

| Invocation | Behavior |
|------------|----------|
| `./deploy.sh` | Validate prereqs (qemu, qemu-img, mkisofs), print usage |
| `./deploy.sh --delete` | Deregister AAP resources, destroy all VMs, remove `~/.aap-demo/fleet/` |

Deploy does not create VMs — that requires a user-supplied QCOW2 image via
`aap-demo fleet add`. This is intentional: enable makes the capability available,
the user drives VM creation.

### CLI integration

Fleet is more complex than typical addons — it has subcommands (`add`, `remove`,
`list`, `destroy`) and lifecycle hooks. This is handled via a **thin dispatcher
pattern**:

```text
aap-demo fleet add 3 --image ~/rhel9.qcow2   # Create VMs + register in AAP
aap-demo fleet list                            # Show VM status
aap-demo fleet remove 1                        # Remove last N or by name
aap-demo fleet destroy                         # Destroy all VMs + deregister AAP
```

`cmd_fleet()` in `aap-demo.sh` sources `fleet.sh` and `fleet-aap.sh` on demand
(not at startup), then dispatches subcommands. This keeps the main script fast when
fleet is not in use.

### Lifecycle hooks

`cmd_status`, `cmd_stop`, and `cmd_destroy` conditionally source fleet when VMs exist.
The guard checks for both the data directory and the addon script:

```bash
if [ -d "${HOME}/.aap-demo/fleet" ] && [ -f "${SCRIPT_DIR}/addons/fleet/fleet.sh" ]; then
  source "${SCRIPT_DIR}/addons/fleet/fleet.sh"
  fleet_stop_all  # or fleet_list, fleet_destroy_all
fi
```

Checking `~/.aap-demo/fleet` (not addon-enabled state) ensures orphaned VMs get cleaned
up even if the user disabled the addon.

### VM architecture

- **QEMU** with hardware acceleration (HVF on macOS, KVM on Linux)
- **Thin overlays**: single base QCOW2 image, per-node overlay disks
- **Cloud-init**: ISO-based provisioning with `ansible` user and ed25519 SSH key
- **Networking**: SSH port forwarding (host ports 2201+) — no bridge/tap required
- **AAP registration**: inventory + Machine credential + per-host variables
  (`ansible_host`, `ansible_port`, `ansible_user`) via REST API
- **RAM check**: validates available memory before creating nodes

### Self-contained paths

`fleet.sh` resolves cloud-init template paths relative to `BASH_SOURCE[0]` via
`FLEET_ADDON_DIR`, not `SCRIPT_DIR`, making the addon portable.

## Consequences

### Positive

- Main script no longer unconditionally sources 1,100+ lines of fleet code
- Fleet is testable in isolation (`addons/fleet/deploy.sh`)
- `--fleet`/`--image` flags removed from `aap-demo deploy` — cleaner core interface
- Consistent with MCP server and portal addon patterns
- VM data (`~/.aap-demo/fleet/`) persists independently of addon state

### Negative

- `aap-demo deploy --fleet 3 --image ~/rhel9.qcow2` shortcut removed — now requires
  two steps (`enable fleet` + `fleet add 3 --image ...`)
- Lifecycle hooks in `cmd_stop`/`cmd_destroy` still reference fleet — not fully decoupled,
  but guarded by existence checks
- Fleet subcommand dispatching adds complexity beyond the standard `deploy.sh` contract

### Neutral

- `aap-demo fleet *` commands work identically to before
- Migration from `seed-nodes` naming (ADR-era rename) preserved in `fleet.sh`
- FLEET_IMAGE config persistence unchanged (`~/.aap-demo/config`)

## Alternatives Considered

### Keep fleet in core

Rejected: fleet is optional demo infrastructure. Keeping it in core violates ADR-008's
principle that optional capabilities should be addons. It also forces all users to load
fleet code at startup.

### Pure deploy.sh with no subcommands

Rejected: fleet's VM lifecycle (add/remove/list/destroy) doesn't fit the simple
deploy/delete contract. Users need fine-grained control over individual VMs, not just
all-or-nothing.

### Separate CLI binary for fleet

Rejected: adds distribution complexity. The thin dispatcher pattern keeps fleet
accessible via the existing `aap-demo` CLI while isolating the implementation.

## References

- [addons/fleet/deploy.sh](../../addons/fleet/deploy.sh)
- [addons/fleet/fleet.sh](../../addons/fleet/fleet.sh)
- [addons/fleet/fleet-aap.sh](../../addons/fleet/fleet-aap.sh)
- [ADR-008](008-addon-system.md)
