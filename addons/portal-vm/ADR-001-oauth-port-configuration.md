# ADR-001: Portal OAuth Port Configuration via Systemd Drop-in

**Status:** Accepted **Date:** 2026-06-25 **Author:** Chad Ferman

## Context

Portal VM addon deploys AAP Portal appliance (QCOW2) via QEMU x86 emulation on macOS. OAuth integration with AAP Gateway
failed due to port mismatch between QEMU port forwarding and portal container configuration.

### Problem Chain

1. **Portal appliance defaults:** Container listens on internal port 7007, published to VM host port **8443** (default
   in `/etc/containers/systemd/portal.container`)
1. **QEMU forwarding:** Initially forwarded macOS port 8443 → VM port **443** (wrong)
1. **OAuth redirect:** AAP OAuth app configured with
   `redirect_uris: "https://localhost:8443/api/auth/rhaap/handler/frame"`
1. **Result:** macOS → 8443 → VM 443 → **nothing listening** → OAuth fails

### Investigation Findings

Portal appliance uses `/usr/local/bin/detect-and-set-base-url.sh` (ExecStartPre) to:

- Read `PublishPort` from Quadlet file to determine default port (line 26: `DEFAULT_PORT=$(grep "^PublishPort=" ...)`)
- Falls back to 443 if missing
- **Ignores cloud-init `network.port` field** (not implemented in appliance)
- Dynamically updates Quadlet `PublishPort` based on detected IP/environment

Attempted fixes that **failed**:

1. ❌ Set `network.port: 443` in cloud-init → appliance ignores it
1. ❌ Patch Quadlet via `sed` in `runcmd` → `detect-and-set-base-url.sh` runs **before** runcmd, reverts changes
1. ❌ Copy + patch detect script to `/etc` → `/usr/local/bin` read-only on bootc, complex override chain
1. ❌ Remove `network` section, patch Quadlet manually → script still overwrites on every restart

## Decision

**Use systemd drop-in configuration to override Quadlet port.**

Cloud-init `write_files` creates `/etc/containers/systemd/portal.container.d/10-port-override.conf`:

```ini
[Container]
PublishPort=8443:7007
```

Combined with QEMU port forwarding `hostfwd=tcp::8443-:8443`:

```
macOS localhost:8443 → QEMU → VM host 0.0.0.0:8443 → portal container 7007
```

OAuth redirect `https://localhost:8443/...` now reaches portal correctly.

## Rationale

### Why systemd drop-in over alternatives?

| Approach | Result | |----------|--------| | Modify cloud-init `network.port` | Appliance ignores field | | Patch
Quadlet via `runcmd` | Script overwrites before runcmd runs | | Modify detect script in `/usr` | Read-only filesystem
(bootc) | | Copy script to `/etc`, override | Complex, fragile, multi-step | | **Systemd drop-in (chosen)** | ✅ Clean,
standard, survives script overwrites |

**Systemd drop-in wins because:**

- Standard systemd mechanism (`.d/` override directories)
- Applied **before** ExecStartPre runs
- Survives `detect-and-set-base-url.sh` updates to base Quadlet
- Single file, applied via cloud-init `write_files` (runs early in boot)
- `/etc` writable on bootc (unlike `/usr`)

### Why port 8443 instead of 443?

Portal appliance defaults to 8443. Fighting defaults = complexity. Simpler to:

- Let portal use 8443 (appliance default)
- Forward QEMU macOS 8443 → VM 8443 (not 443)
- Match OAuth redirect to actual access URL

## Consequences

### Positive

- OAuth works: AAP → Portal SSO functional
- No appliance script hacks required
- Standard systemd configuration pattern
- Survives portal service restarts
- Clean cloud-init config (one `write_files` entry)

### Negative

- Non-standard port (8443 vs 443) for HTTPS
  - **Mitigation:** Only affects local dev/test, documented in README
- Requires systemd drop-in knowledge for troubleshooting
  - **Mitigation:** Documented in this ADR

### Required Components

1. **Cloud-init:** `write_files` creates drop-in before portal starts
1. **QEMU:** Forward macOS 8443 → VM 8443 (match portal container port)
1. **OAuth app:** `redirect_uris` uses `https://localhost:8443` (matches access URL)
1. **Full config files:** See AAP Extend docs page 214 (`database.builtin`, `security.backend_secret`)

## References

- AAP Extend 2.7 docs, pages 207-225: Portal appliance deployment
- Cloud-init docs: `write_files` directive
- Systemd docs: Drop-in configuration (`systemd.unit(5)`)
- Portal appliance: `/usr/local/bin/detect-and-set-base-url.sh` (read-only)
- Related: `addons/portal-vm/deploy.sh`, `addons/portal-vm/README.md`

## Alternatives Considered

### 1. Modify portal appliance image

**Rejected:** Requires rebuilding QCOW2, not maintainable across AAP versions.

### 2. Use `network.base_url` cloud-init field

**Rejected:** Field exists but doesn't control container port, only sets backend URLs in config.

### 3. Disable `detect-and-set-base-url.sh`

**Rejected:** Script handles AWS/cloud IP detection, SSL cert generation, legitimate functionality.

### 4. Run portal on native port 443

**Rejected:**

- Requires root for port \<1024 binding (Podman rootless won't work)
- QEMU user-mode networking can't forward privileged ports on macOS
- Appliance defaults to 8443 for this reason
