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

## Comparison Matrix

| Aspect | Current (nip.io) | Proposed (crc.testing + manual DNS) | Future (automated DNS) |
|--------|------------------|-------------------------------------|------------------------|
| **Setup complexity** | High (SSH timing, domain switching) | Low (use CRC defaults) | Medium (platform detection) |
| **User DNS config** | None | Manual (one-time per platform) | Automated (requires sudo) |
| **Cluster creation time** | +30-60s (MicroShift wipe/restart) | Baseline (no extra steps) | Baseline + DNS check |
| **SSH during create** | ✅ Required | ❌ Not needed | ❌ Not needed |
| **Timing bugs** | ❌ Fragile (key detection race) | ✅ None | ✅ None |
| **Failure modes** | Many (SSH, key types, restart) | Few (CRC, DNS misconfiguration) | Medium (privilege, conflicts) |
| **Maintenance burden** | High (SSH timing, edge cases) | Low (standard CRC workflow) | Medium (platform-specific code) |
| **Works out-of-box** | ✅ Yes (after cluster starts) | ❌ No (DNS setup required) | ⚠️ Yes (if automation succeeds) |
| **Platform support** | All (same code) | All (different docs) | Varies (platform-specific) |
| **Debugging** | Hard (SSH, domain, timing) | Easy (DNS or CRC issue) | Medium (DNS automation state) |
| **Rollback on destroy** | Automatic (VM deleted) | None needed (DNS persists) | Required (undo DNS changes) |
| **Risk to host system** | None | None | Medium (modify system DNS) |
| **Code complexity** | High (150+ lines SSH logic) | Low (~20 lines removed) | High (platform-specific sudo) |

**Key takeaway**: Proposed approach trades one-time manual DNS setup for significantly simpler, faster, more reliable cluster creation. Automated DNS is possible future work but adds new complexity.

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

### Alternative 3: /etc/hosts File Entries

**Description**: Add static entries to `/etc/hosts` for known AAP routes instead of configuring DNS resolver.

**Why rejected**:

- `/etc/hosts` doesn't support wildcards — must list every route individually
- AAP creates 5+ routes dynamically (controller, hub, eda, gateway, automation-job-*...)
- Additional services or test deployments require manual `/etc/hosts` updates
- Routes change between AAP versions or deployment configurations
- Windows has 4KB `/etc/hosts` file size limit (can hit with many entries)
- Brittle: forgot one route = broken functionality, hard to debug

**Example of the problem**:

```bash
# Would need ALL of these (and more as AAP adds services):
127.0.0.1 aap-aap-operator.apps.crc.testing
127.0.0.1 controller-aap-operator.apps.crc.testing
127.0.0.1 hub-aap-operator.apps.crc.testing
127.0.0.1 eda-aap-operator.apps.crc.testing
127.0.0.1 gateway-aap-operator.apps.crc.testing
# ... plus any job execution routes, webhooks, etc.
```

DNS resolver with wildcard (`*.apps.crc.testing`) handles all current and future routes automatically.

### Alternative 4: Defer nip.io Change to Deploy

**Description**: Keep nip.io approach but move domain change from `aap-demo create` to `aap-demo deploy`.

```bash
# aap-demo create - fast, no domain change
crc start  # defaults to crc.testing

# aap-demo deploy - change domain before deploying AAP
if [ "$(current_domain)" = "crc.testing" ]; then
  ssh ... write nip.io config
  ssh ... wipe /var/lib/microshift, restart
  wait for API ready
fi
# deploy AAP operator
```

**Why rejected**:

- Still requires MicroShift wipe/restart (same 30-60s penalty, just later)
- Still fragile SSH operations (timing bugs just moved to deploy)
- Deploy becomes stateful (must detect if already converted)
- Partial failure state (domain changed but AAP not deployed)
- User re-running deploy triggers domain detection logic every time
- Doesn't eliminate complexity, just relocates it

### Alternative 5: Managed DNS Daemon (dnsmasq/CoreDNS)

**Description**: Bundle and manage a local DNS daemon (dnsmasq or CoreDNS) as part of aap-demo. Start/stop it with the cluster.

```bash
# aap-demo create
crc start
aap-demo-dns start  # launch local DNS daemon on port 5353
configure host to query 127.0.0.1:5353 for .testing domain
```

**Why rejected**:

- Adds persistent daemon management (start, stop, restart, monitor)
- Still requires host DNS config (point to local daemon)
- Cross-platform daemon binaries (dnsmasq not on macOS by default)
- Process lifecycle: what if daemon crashes? Port conflicts?
- Cleanup complexity: must ensure daemon stops on destroy
- Overkill: full DNS server to resolve one wildcard domain
- Most complexity of automated DNS without the "works everywhere" benefit

### Alternative 6: HTTP Proxy on Host

**Description**: Run nginx/haproxy on host port 80/443, proxy `*.apps.127.0.0.1.nip.io` to cluster ingress.

```bash
# nginx config
server {
  listen 80;
  server_name *.apps.127.0.0.1.nip.io;
  location / {
    proxy_pass http://router-internal-default.openshift-ingress.svc.cluster.local;
  }
}
```

**Why rejected**:

- Requires nginx/haproxy installation
- Conflicts with other services on port 80/443
- TLS complexity (certificates, SNI routing)
- Can't access routes from inside cluster (only from host)
- Adds infrastructure layer that can fail independently
- Doesn't solve DNS (nip.io still needs to resolve to 127.0.0.1)

### Alternative 7: Automated DNS Setup

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
