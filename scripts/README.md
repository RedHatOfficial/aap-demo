# aap-demo helper scripts

Utility scripts used during development and local deployment. These are not invoked
automatically by `aap-demo` unless noted below.

## Host preparation (Linux + CRC)

### `local-prereq.sh`

One-time workstation setup before the first `aap-demo deploy` on Fedora or other
Linux distributions using CRC (OpenShift Local):

```bash
./scripts/local-prereq.sh
```

Steps performed:

1. Enable temporary file-backed swap (see `enable-temp-swap.sh`)
2. Verify `~/.aap-demo/pull-secret.txt` exists
3. Add the current user to the `libvirt` group (if needed)
4. Run `crc setup` with the MicroShift preset

Skip swap with `SKIP_TEMP_SWAP=true`. Increase swap size with
`AAP_SWAP_SIZE_GB=24`.

### `enable-temp-swap.sh`

Adds a removable swap file for deploy bursts on hosts where CRC memory allocation
plus the OS leaves little headroom (common on 32 GB laptops running a 16–24 GB VM).

Fedora ships with zram swap (typically 8 GB). This script layers a file-backed swap
file on top without modifying `/etc/fstab`. Remove it after deploy completes.

```bash
# Enable 16 GB temp swap (default)
./scripts/enable-temp-swap.sh

# Larger swap when CRC_MEMORY is 20-24 GB
AAP_SWAP_SIZE_GB=24 ./scripts/enable-temp-swap.sh

# Check active swap
./scripts/enable-temp-swap.sh status

# Remove after deploy
./scripts/enable-temp-swap.sh disable
```

| Variable | Default | Description |
|----------|---------|-------------|
| `AAP_SWAP_SIZE_GB` | `16` | Swap file size in gigabytes |
| `AAP_SWAP_FILE` | `/swapfile-aap-demo` | Path to the swap file |
| `SKIP_TEMP_SWAP` | `false` | Set to `true` to skip enable |

**btrfs hosts:** Fedora's default btrfs root with compression cannot use `fallocate`
for swap files. The script disables copy-on-write (`chattr +C`) and writes the file
with `dd` instead.

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
