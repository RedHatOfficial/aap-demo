# ADR-007: Use CRC Default Domain Instead of nip.io

**Status**: Proposed

**Date**: 2026-07-08

**Authors**: Chad Ferman, Claude Sonnet 4.5

## Context

Currently, `aap-demo create` reconfigures MicroShift clusters to use `127.0.0.1.nip.io` as the base domain instead of the CRC default `crc.testing`. This requires:

1. SSH access to the CRC VM during cluster creation
2. Writing a MicroShift config drop-in (`/etc/microshift/config.d/99-aap-demo-dns.yaml`)
3. Wiping `/var/lib/microshift` and restarting MicroShift to apply the new domain
4. Complex SSH key detection logic to handle different key types (id_ed25519 for OpenShift preset, id_ecdsa for MicroShift preset)

### Problem Statement

The nip.io domain change introduces significant complexity and fragility:

- **Timing bugs**: SSH key detection must happen after `crc start` completes, not at script initialization. PR #40 failed because the script sourced `infra-crc.sh` (which detects SSH keys) before the cluster VM was running.
- **Key type detection**: Different CRC presets generate different SSH key types. The detection logic (`_detect_crc_ssh_key()`) must be called at the right time and handle both cases.
- **Restart overhead**: Wiping MicroShift data and restarting adds ~30-60 seconds to cluster creation.
- **Maintenance burden**: Every operation touching nip.io config requires understanding SSH key availability timing.

### Current Benefit of nip.io

The nip.io domain was chosen because:

- Routes work immediately without host DNS configuration
- `nip.io` is a public DNS service that resolves `<IP>.nip.io` to `<IP>` automatically
- No need to edit `/etc/resolver/testing` or configure dnsmasq on macOS

### Constraints

- MicroShift defaults to `crc.testing` domain
- Host machines need DNS resolution for `*.apps.crc.testing` → `127.0.0.1`
- macOS requires `/etc/resolver/testing` configuration or dnsmasq
- Linux typically uses NetworkManager dnsmasq or systemd-resolved

## Decision

**Remove the nip.io domain reconfiguration and use CRC's default `crc.testing` domain.**

Changes:

1. Remove nip.io config block from `includes/crc-create.sh` (lines 287-324)
2. Remove `configure_coredns()` SSH-based domain detection (line 42-45)
3. Simplify `configure_coredns()` to assume `apps.crc.testing` for MicroShift
4. Add host DNS setup instructions to documentation
5. Optionally: provide automated DNS setup for macOS/Linux as a separate optional step

SSH access is still needed for other operations (`aap-demo ssh`, registry mirror, ingress CA fetch), but **not during cluster creation**.

## Consequences

### Positive

- **Simpler cluster creation**: No SSH operations during `aap-demo create`, eliminating timing bugs
- **Faster startup**: Skip MicroShift wipe/restart (~30-60s saved)
- **Fewer failure modes**: No SSH key detection timing issues, no SSH authentication failures during creation
- **Easier to maintain**: Less conditional logic, fewer moving parts
- **Consistent with CRC**: Use tool defaults instead of fighting them
- **Better debugging**: When things break, it's CRC's problem or DNS config, not our domain-switching logic

### Negative

- **Manual DNS setup required**: Users must configure host DNS for `*.apps.crc.testing` → `127.0.0.1`
- **Platform-specific setup**: Different instructions for macOS, Linux, Windows
- **Extra setup step**: Not quite "zero config" anymore (though nip.io never truly was either)
- **Documentation burden**: Must document DNS setup clearly for each platform

### Neutral

- CoreDNS configuration still needed (for in-cluster route resolution)
- SSH operations still needed for `aap-demo ssh`, registry mirror, CA fetch
- Overall user experience similar once DNS configured (both approaches require some setup)

## Alternatives Considered

### Alternative 1: Keep nip.io, Fix Timing Bugs (Current PR #40)

**Description**: Continue using nip.io domain but fix SSH key detection timing by re-detecting keys after `crc start` completes.

**Why rejected**:

- Adds complexity (deferred SSH key detection in two places)
- Still requires MicroShift wipe/restart overhead
- Doesn't eliminate the fundamental fragility of SSH operations during creation
- Fixes one bug but doesn't prevent future timing issues as code evolves

### Alternative 2: Hybrid Approach (nip.io Optional)

**Description**: Default to `crc.testing`, add `--nip-io` flag for users who want automatic DNS.

**Why rejected**:

- Doubles maintenance burden (must support both code paths)
- More complex testing matrix
- Users would still encounter timing bugs if they chose nip.io
- Adds CLI complexity for marginal benefit

### Alternative 3: Automated DNS Setup

**Description**: Keep `crc.testing` but auto-configure host DNS during `aap-demo create`.

**Why not chosen now** (but could be future work):

- Platform-specific implementation (macOS vs Linux vs Windows)
- Requires sudo/admin privileges (user prompts)
- Risk of breaking existing DNS config
- Better as optional convenience feature after manual setup proven

**Implementation requirements** (if automated in future):

**macOS**:

```bash
# Create /etc/resolver/testing (requires sudo)
sudo mkdir -p /etc/resolver
sudo tee /etc/resolver/testing > /dev/null <<EOF
nameserver 127.0.0.1
domain testing
search_order 1
EOF

# Verify with: scutil --dns | grep testing
```

**Linux (systemd-resolved)**:

```bash
# Add DNS stub for .testing domain
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/testing.conf > /dev/null <<EOF
[Resolve]
DNS=127.0.0.1
Domains=~testing
EOF

sudo systemctl restart systemd-resolved

# Verify with: resolvectl query aap.apps.crc.testing
```

**Linux (NetworkManager + dnsmasq)**:

```bash
# Add dnsmasq config for .testing domain
sudo tee /etc/NetworkManager/dnsmasq.d/testing.conf > /dev/null <<EOF
server=/testing/127.0.0.1
EOF

sudo systemctl restart NetworkManager

# Verify with: dig aap.apps.crc.testing
```

**Windows (PowerShell as Administrator)**:

```powershell
# Add hosts file entries (wildcard not supported, must add per-route)
# Or configure local DNS server (dnsmasq-for-windows, Acrylic DNS Proxy)

# Example hosts approach (limited):
Add-Content -Path C:\Windows\System32\drivers\etc\hosts -Value "127.0.0.1 aap.apps.crc.testing"

# Better: Install Acrylic DNS Proxy and configure *.testing → 127.0.0.1
```

**Automation challenges**:

- **Privilege escalation**: All platforms require admin/sudo for DNS config
- **Conflict detection**: Must check for existing `.testing` DNS config
- **Rollback on destroy**: Must track what was auto-configured vs manual
- **Platform detection**: Distinguish systemd-resolved vs NetworkManager vs other
- **Verification**: Must test DNS resolution works before proceeding
- **User consent**: Explicit warning before modifying system DNS config

## References

- Issue: [#39 - aap-demo ssh fails on MicroShift preset](https://github.com/RedHatOfficial/aap-demo/issues/39)
- PR: [#40 - fix: detect SSH key type for MicroShift compatibility](https://github.com/RedHatOfficial/aap-demo/pull/40)
- CRC DNS documentation: https://crc.dev/crc/getting_started/getting_started/configuring/
- Related ADR: [003-infrastructure-backend-selection.md](003-infrastructure-backend-selection.md)
