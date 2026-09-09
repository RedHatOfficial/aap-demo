# aap-demo helper scripts

Utility scripts used during development and local deployment. These are not invoked
automatically by `aap-demo` unless noted below.

## Host preparation (Linux + macOS + CRC)

### Interactive temp swap (`aap-demo create`)

On **Linux (Fedora/RHEL)** and **macOS**, the first interactive cluster create prompts
for temporary swap before CPU and RAM allocation.

```text
Resource allocation for CRC VM:
  Host: 16 CPUs, 30GB RAM (8GB swap)

  Create temp swap for deploy? [Y/n]:
  Temp swap size in GB [16]:
  CPUs [8]:
  Memory in GB [16]:
```

| Platform | What it does | Default path |
|----------|--------------|--------------|
| Fedora/RHEL (Linux) | `mkswap` + `swapon` file-backed swap | `/swapfile-aap-demo` |
| macOS | Reserves disk for `dynamic_pager` kernel swap | `~/.aap-demo/aap-swap-reserve` |

**Linux filesystem notes**

- **btrfs** (Fedora default): uses `chattr +C` + `dd` (not `fallocate`)
- **xfs/ext4** (common on RHEL): uses `fallocate`, falls back to `dd`
- **SELinux** (RHEL): applies `swapfile_t` context when enforcing

**macOS notes**

macOS does not expose Linux-style `swapon`. The script reserves disk space so the
kernel can grow swap files under memory pressure during deploy. Remove the reserve
file after deploy to reclaim space.

Non-interactive create (CI or scripted):

```bash
AAP_ENABLE_TEMP_SWAP=true AAP_SWAP_SIZE_GB=24 QUIET=true aap-demo create
SKIP_TEMP_SWAP=true aap-demo create   # never enable swap
```

| Variable | Default | Description |
|----------|---------|-------------|
| `AAP_SWAP_SIZE_GB` | `16` | Swap/reserve size when enabled |
| `AAP_SWAP_FILE` | platform default (see table) | Override swap/reserve path |
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
