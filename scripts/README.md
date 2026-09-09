# aap-demo helper scripts

Utility scripts used during development and local deployment. These are not invoked
automatically by `aap-demo` unless noted below.

## Host preparation (Linux + CRC)

### Interactive temp swap (`aap-demo create`)

On Linux, the first interactive cluster create prompts for a temporary swap file
before CPU and RAM allocation. This helps memory-constrained hosts (32 GB RAM or less)
survive CRC image pulls and AAP operator reconciliation.

```text
Resource allocation for CRC VM:
  Host: 16 CPUs, 30GB RAM (8GB swap)

  Create temp swap file for deploy? [Y/n]:
  Temp swap size in GB [16]:
  CPUs [8]:
  Memory in GB [16]:
```

Non-interactive create (CI or scripted):

```bash
AAP_ENABLE_TEMP_SWAP=true AAP_SWAP_SIZE_GB=24 QUIET=true aap-demo create
SKIP_TEMP_SWAP=true aap-demo create   # never enable swap
```

| Variable | Default | Description |
|----------|---------|-------------|
| `AAP_SWAP_SIZE_GB` | `16` | Swap file size when enabled |
| `AAP_SWAP_FILE` | `/swapfile-aap-demo` | Path to the swap file |
| `AAP_ENABLE_TEMP_SWAP` | `false` | Enable swap during non-interactive create |
| `SKIP_TEMP_SWAP` | `false` | Skip swap prompt and enable |

### `local-prereq.sh`

One-time workstation setup before the first `aap-demo deploy` on Fedora or other
Linux distributions using CRC (OpenShift Local):

```bash
./scripts/local-prereq.sh
```

Steps performed:

1. Verify `~/.aap-demo/pull-secret.txt` exists
2. Add the current user to the `libvirt` group (if needed)
3. Run `crc setup` with the MicroShift preset

Temp swap is handled by `aap-demo create` (see above), not this script.

### `enable-temp-swap.sh`

Manual swap management when you are not running interactive create, or to remove
swap after deploy:

```bash
./scripts/enable-temp-swap.sh
AAP_SWAP_SIZE_GB=24 ./scripts/enable-temp-swap.sh
./scripts/enable-temp-swap.sh status
./scripts/enable-temp-swap.sh disable
```

**btrfs hosts:** Fedora's default btrfs root with compression cannot use `fallocate`
for swap files. The shared logic in `includes/temp-swap.sh` disables copy-on-write
(`chattr +C`) and writes the file with `dd` instead.

## Deployment checks

### `preflight-checks.sh`

Validates CLI dependencies (`kubectl`, `ansible-playbook`, `jq`, etc.) before
operator deployment. Called internally by deploy flows; can also be run directly.

## Development

### `setup-linting.sh`

Installs pre-commit hooks and lint tooling for contributors.

### `require-tool.sh`

Pre-commit helper that verifies a tool exists before executing it.

### `check-version-bump.sh`

CI helper that enforces `VERSION` bumps on pull requests.
