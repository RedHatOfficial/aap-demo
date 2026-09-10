# aap-demo helper scripts

Utility scripts used during development and local deployment. These are not invoked
automatically by `aap-demo` unless noted below.

## Host preparation (Linux + CRC)

### Interactive temp swap (`aap-demo create`)

On **Linux (Fedora/RHEL)**, the first interactive cluster create prompts for a
temporary swap file before CPU and RAM allocation.

```text
Resource allocation for CRC VM:
  Host: 16 CPUs, 30GB RAM (8GB swap)

  Create temp swap for deploy? [Y/n]:
  Temp swap size in GB [16]:
  CPUs [8]:
  Memory in GB [16]:
```

Default swap file: `/swapfile-aap-demo` via `mkswap` + `swapon`.

**Filesystem notes**

- **btrfs** (Fedora): uses `chattr +C` + `dd` (not `fallocate`)
- **xfs/ext4** (RHEL): uses `fallocate`, falls back to `dd`
- **SELinux** (RHEL): applies `swapfile_t` context when enforcing

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

Temp swap is handled by `aap-demo create` on Linux (see above), not this script.

### `enable-temp-swap.sh`

Manual swap management on Linux when you are not running interactive create:

```bash
./scripts/enable-temp-swap.sh
AAP_SWAP_SIZE_GB=24 ./scripts/enable-temp-swap.sh
./scripts/enable-temp-swap.sh status
./scripts/enable-temp-swap.sh disable
```

`aap-demo destroy` also removes temp swap on Linux (requires sudo for `swapoff`).

### `test-temp-swap-flow.sh`

End-to-end host test (requires sudo): disable → enable → `aap-demo create` with
`AAP_ENABLE_TEMP_SWAP`. Run in an interactive terminal:

```bash
./scripts/test-temp-swap-flow.sh
```

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
