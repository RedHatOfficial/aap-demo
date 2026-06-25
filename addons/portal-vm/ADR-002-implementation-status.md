# ADR-002 Implementation Status

**Date:** 2026-06-24
**Status:** Partial (2/3 improvements implemented)

## What Works

### ✅ 1. Port configuration simplified

- **Before:** macOS:8443 → VM:8443 → container:7007
- **After:** macOS:8443 → VM:443 → container:7007
- Systemd override locks at port 443 (default) instead of 8443
- Cleaner QEMU hostfwd config

### ✅ 2. Cloud-init simplified

- **Removed:** `runcmd` section (no manual daemon-reload needed)
- **Removed:** /etc/hosts DNS injection (rely on standard DNS resolution)
- **Kept:** Systemd drop-in (bootc requirement per ADR-001)
- `network.base_url` correctly sets OAuth redirect URL

## What Doesn't Work

### ❌ 3. QEMU guestfwd (AAP connectivity)

**Attempted:**

```bash
-netdev user,id=net0,...,guestfwd=tcp:10.0.2.2:443-tcp:127.0.0.1:443
```

**Error:**

```
Conflicting/invalid host:port in guest forwarding rule 'tcp:10.0.2.2:443-tcp:127.0.0.1:443'
```

**Root cause:**

- Homebrew QEMU (macOS) uses different guestfwd syntax vs Linux QEMU
- Tried alternative: `guestfwd=tcp:10.0.2.2:443-cmd:nc 127.0.0.1 443`
- Requires external `nc` command, more fragile than socat

**Fallback:** Keep socat proxy (requires sudo) for AAP connectivity.

## Net Improvements vs ADR-001

| Improvement | ADR-001 | ADR-002 Implemented | Blocked |
|-------------|---------|---------------------|---------|
| Simpler port config | macOS:8443 → VM:8443 | ✅ macOS:8443 → VM:443 | - |
| Eliminate runcmd | 3-step runcmd | ✅ No runcmd | - |
| Eliminate /etc/hosts hack | Manual DNS injection | ✅ Standard DNS | - |
| Eliminate socat (no sudo) | Socat required | ❌ Socat still required | QEMU guestfwd syntax |
| Processes | 2 (QEMU + socat) | ❌ Still 2 | QEMU guestfwd syntax |

**Score:** 3/5 improvements (60%)

## Recommendations

### Short term: Keep current hybrid

- Port 443 on VM ✅
- Simplified cloud-init ✅
- Socat for AAP (known working) ✅

### Long term: Revisit guestfwd

Options to eliminate socat:

1. **Test Linux QEMU syntax** (if deploying on Linux host)
2. **Use QEMU socket forwarding** instead of guestfwd (different approach)
3. **Port forwarding via iptables/pf** on macOS (no privileged socat)
4. **Wait for ARM64 portal appliance** (native macOS Virtualization.framework)

### Alternative: Port AAP to non-privileged port

Instead of fighting port 443 binding, run socat on high port + update AAP route:

```bash
# Socat: VM 10.0.2.2:8443 → macOS 127.0.0.1:443
socat TCP-LISTEN:8443,bind=0.0.0.0 TCP:127.0.0.1:443 &  # No sudo

# Cloud-init: Portal connects to 10.0.2.2:8443
aap:
  host_url: "https://10.0.2.2:8443"
```

**Tradeoff:** Non-standard AAP URL in portal config vs eliminating sudo.

## Conclusion

ADR-002 partial success. Simplified cloud-init and port config worth keeping.
Socat elimination blocked by QEMU guestfwd syntax incompatibility on macOS.

**Recommendation:** Accept current state (3/5 improvements) or test alternative socat port approach.
