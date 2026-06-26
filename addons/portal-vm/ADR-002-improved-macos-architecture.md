# ADR-002: Improved Portal VM Architecture for macOS

**Status:** Rejected (guestfwd implementation failed) **Date:** 2026-06-24 **Updated:** 2026-06-26 **Author:** Backend
Architect Agent **Supersedes:** ADR-001 (partial) **Superseded by:** Hybrid approach (see Implementation Outcome)

## Context

Current portal-vm implementation (ADR-001) works but has architectural issues:

1. **Three-layer port translation:** macOS 8443 → QEMU → VM 8443 → container 7007
1. **Fighting appliance defaults:** Systemd drop-in required to override port
1. **Requires sudo:** Socat proxy for AAP connectivity needs privileged port binding
1. **Manual DNS hacks:** /etc/hosts entry for AAP route resolution
1. **Slow emulation:** x86-64 emulation on ARM Mac (3-10min boot)
1. **Complex debugging:** Multiple moving parts (QEMU, socat, systemd overrides)

**Root cause:** Current design fights portal appliance defaults instead of working with them.

### Bootc Compatibility Constraint

Portal appliance runs on **bootc** (Red Hat's container-native OS):

- `/usr` is **read-only** (includes `/usr/local/bin/detect-and-set-base-url.sh`)
- `/etc` is **writable** (systemd drop-ins work)
- Cloud-init `network.port` field **ignored by appliance** (per ADR-001 investigation)
- `detect-and-set-base-url.sh` runs as `ExecStartPre` and **dynamically modifies** Quadlet `PublishPort`

**Implication:** Cannot rely on cloud-init `network.port` to control container port. Must lock port via systemd drop-in
to prevent script overwrites.

## Decision

**Redesign networking to align with appliance defaults and eliminate workarounds.**

### Key Changes

#### 1. Port Configuration: Lock at default, prevent drift

**Before (ADR-001):**

```
macOS:8443 → QEMU → VM:8443 → systemd override PublishPort=8443:7007 → container:7007
```

**After (ADR-002):**

```
macOS:8443 → QEMU → VM:443 → systemd override PublishPort=443:7007 → container:7007
```

- Portal container **remains on internal port 7007** (hardcoded in appliance)
- VM host publishes on **port 443** (locked via systemd drop-in)
- QEMU forwards **macOS 8443 → VM 443** (aligns with default expectation)
- OAuth redirect stays `https://localhost:8443/...` (macOS access URL unchanged)

**Why systemd drop-in still needed:**

Per ADR-001, `/usr/local/bin/detect-and-set-base-url.sh` dynamically modifies Quadlet port. Cloud-init `network.port`
field is **not implemented** by appliance. Must lock via systemd:

```yaml
write_files:
  - path: /etc/containers/systemd/portal.container.d/10-port-override.conf
    owner: root:root
    permissions: '0644'
    content: |
      [Container]
      PublishPort=443:7007  # Lock at default, prevent detect script drift
```

**Benefit vs ADR-001:** Port locked at **443** (appliance default) not **8443** (arbitrary). Simpler QEMU forwarding
(8443→443, not 8443→8443).

#### 2. AAP Connectivity: Eliminate socat, use QEMU networking

**Before (ADR-001):**

```
Portal VM → 10.0.2.2:443 → sudo socat → 127.0.0.1:443 → OpenShift Local
```

**After (ADR-002):**

```
Portal VM → 10.0.2.2:443 → QEMU hostfwd → 127.0.0.1:443 → OpenShift Local
```

QEMU user-mode networking already provides host reachability via `10.0.2.2`. For AAP on port 443, add reverse port
forwarding:

```bash
-netdev user,id=net0,\
  hostfwd=tcp::8443-:443,\           # Portal UI: macOS → VM
  hostfwd=tcp::8080-:80,\             # HTTP redirect
  hostfwd=tcp::2223-:22,\             # SSH
  guestfwd=tcp:10.0.2.2:443-tcp:127.0.0.1:443  # AAP: VM → macOS
```

**Benefit:** No sudo required. One process instead of two.

**Implementation note:** QEMU's `guestfwd` requires `slirp` backend (default on macOS Homebrew QEMU). Fallback for older
QEMU: keep socat but run without sudo on high port + iptables/pf redirect.

#### 3. DNS Resolution: Use cloud-init network config

**Before (ADR-001):**

```yaml
runcmd:
  - echo "10.0.2.2 $aap_route" >> /etc/hosts
```

**After (ADR-002):**

```yaml
network:
  base_url: "https://localhost:8443"  # User-facing URL

# No /etc/hosts hack needed
```

Portal container resolves AAP route via:

1. VM DNS → QEMU DNS (10.0.2.3) → macOS resolver
1. OpenShift Local `nip.io` routes resolve to 127.0.0.1 via public DNS
1. Portal reaches AAP via 10.0.2.2:443 → guestfwd → 127.0.0.1:443

**Benefit:** No manual DNS injection. Standard resolution path.

#### 4. Cloud-init: Reduced but not eliminated

**Before (ADR-001):**

```yaml
write_files:
  - path: /etc/containers/systemd/portal.container.d/10-port-override.conf
    content: |
      [Container]
      PublishPort=8443:7007

runcmd:
  - echo "10.0.2.2 $aap_route" >> /etc/hosts
  - systemctl daemon-reload
  - systemctl restart portal.service
```

**After (ADR-002):**

```yaml
network:
  base_url: "https://localhost:8443" # User access URL (OAuth redirect)

write_files:
  - path: /etc/containers/systemd/portal.container.d/10-port-override.conf
    content: |
      [Container]
      PublishPort=443:7007  # Lock at default port

# runcmd eliminated (no /etc/hosts hack, systemd auto-reloads)
```

**Benefit vs ADR-001:** Eliminates `runcmd` section (no manual DNS injection, no daemon-reload). Still need port lock
due to bootc constraint.

### Architecture Comparison

| Component | ADR-001 (Current) | ADR-002 (Proposed) | |-----------|-------------------|-------------------| | Portal
container port | 7007 (internal) | 7007 (internal) | | VM host port | 8443 (systemd override) | 443 (systemd override,
matches default) | | macOS access port | 8443 | 8443 (unchanged) | | AAP connectivity | socat (requires sudo) | QEMU
guestfwd (no sudo) | | DNS resolution | /etc/hosts hack in runcmd | Standard DNS via QEMU | | Cloud-init complexity |
write_files + runcmd (3 steps) | write_files only (1 step) | | Processes | 2 (QEMU + socat) | 1 (QEMU) | | Systemd
override | Required (port 8443) | Required (port 443, aligns with default) |

## Implementation

### Updated deploy.sh

```bash
# QEMU networking (simplified)
qemu-system-x86_64 \
  $accel_arg \
  -machine q35 \
  -cpu "$cpu_arg" \
  -m 8192 \
  -smp cpus=4 \
  -nographic \
  -serial file:"$PORTAL_DIR/serial.log" \
  -device virtio-blk-pci,drive=disk0 \
  -drive id=disk0,if=none,format=qcow2,file="$PORTAL_DIR/portal.qcow2" \
  -drive file="$PORTAL_DIR/cloud-init.iso",media=cdrom,readonly=on \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0,\
hostfwd=tcp::8443-:443,\
hostfwd=tcp::8080-:80,\
hostfwd=tcp::2223-:22,\
guestfwd=tcp:10.0.2.2:443-tcp:127.0.0.1:443,\
dns=10.0.2.3 \
  >"$PORTAL_DIR/qemu.log" 2>&1 &
```

### Updated cloud-init user-data

```yaml
#cloud-config

users:
  - name: admin
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $ssh_pub

aap:
  host_url: "https://$aap_route"
  token: "$aap_token"
  check_ssl: false
  oauth:
    client_id: "$client_id"
    client_secret: "$client_secret"

database:
  type: builtin
  builtin:
    password: "auto"
    admin_password: "auto"

security:
  backend_secret: "auto"  # Auto-generated

network:
  base_url: "https://localhost:8443" # User-facing URL (OAuth redirect target)

write_files:
  - path: /etc/containers/systemd/portal.container.d/10-port-override.conf
    owner: root:root
    permissions: '0644'
    content: |
      [Container]
      PublishPort=443:7007  # Lock at default port, prevent detect-and-set-base-url.sh drift

# No runcmd needed (systemd auto-reloads drop-ins)
```

## Rationale

### Why keep systemd drop-in but change port to 443?

Portal appliance is a **black box** (bootc, read-only /usr). Cloud-init `network.port` **ignored** by appliance per
ADR-001 investigation.

**Systemd drop-in unavoidable** because:

1. `/usr/local/bin/detect-and-set-base-url.sh` dynamically modifies Quadlet port
1. Cloud-init `network.port` not implemented in appliance code
1. Must lock port to prevent drift across service restarts

**ADR-002 improvement:** Lock at **443** (appliance default) instead of **8443** (arbitrary):

- Aligns with expected portal behavior (standard HTTPS port on VM)
- Simpler QEMU config (macOS 8443 → VM 443, not 8443 → 8443)
- If Red Hat fixes port detection logic, we're already at default

### Why eliminate socat?

1. **Security:** Avoids `sudo` requirement for port 443 binding
1. **Simplicity:** One process (QEMU) instead of two (QEMU + socat)
1. **Reliability:** No separate PID tracking, no cleanup race conditions
1. **Logging:** All networking in one QEMU log

### Why use guestfwd over socat?

QEMU's `guestfwd` redirects **guest-initiated** connections from VM to macOS.

```
Portal container → 10.0.2.2:443 → guestfwd → 127.0.0.1:443 (AAP on macOS)
```

- No privileged ports on macOS side (QEMU runs as user)
- Transparent to portal (sees 10.0.2.2:443 as AAP)
- Standard QEMU feature (no external deps)

### Why keep port 8443 on macOS?

Non-privileged port (\<1024 requires root). macOS users expect browser access without sudo.

## Consequences

### Positive

1. **Simpler:** One process (QEMU), reduced cloud-init (no runcmd)
1. **No sudo:** Entire portal-vm runs as user (guestfwd replaces socat)
1. **Less fragile:** Eliminates /etc/hosts injection (DNS works normally)
1. **Debuggable:** All networking in QEMU, standard tools work
1. **Portable:** Same approach works on Intel/ARM Macs
1. **Aligns with defaults:** Port 443 on VM (not arbitrary 8443)

### Related Issues

**Portal appliance lock file bug:** See ADR-003 for workaround. Not related to ADR-002 architecture, but required in
`runcmd` for portal to function on reboots.

### Negative

1. **Systemd drop-in still required**

   - **Why:** Bootc appliance ignores cloud-init `network.port`, must lock via systemd
   - **Mitigation:** Use default port 443 (not arbitrary), clearer intent

1. **QEMU dependency:** Requires `guestfwd` support (slirp backend)

   - **Mitigation:** Homebrew QEMU includes slirp by default
   - **Fallback:** Keep socat path for old QEMU versions

1. **DNS resolution depends on macOS resolver**

   - **Mitigation:** OpenShift Local routes already use `nip.io` (public DNS)
   - **Fallback:** If AAP uses custom DNS, add `--dns-search` to QEMU

1. **Still slow (x86 emulation on ARM)**

   - **No fix:** Portal appliance is x86-64 only (per Red Hat docs)
   - **Future:** If Red Hat ships ARM64 appliance, use native macOS virtualization (Tart/Lima)

### Migration Path (ADR-001 → ADR-002)

**Breaking change:** Cloud-init format changes.

For existing deployments:

```bash
# Clean slate (preserve qcow2 if customized)
aap-demo disable portal-vm

# Redeploy with new script
aap-demo enable portal-vm
```

## Alternatives Considered

### 1. Eliminate systemd override entirely, rely on cloud-init network.port

**Rejected:** Bootc appliance **ignores** cloud-init `network.port` field. Detect script overwrites Quadlet config. Must
lock via systemd.

### 2. Extract container, run via Podman Desktop

**Rejected:** Portal may depend on bootc features (ostree, systemd-sysext). Risky.

### 3. Use UTM.app instead of CLI QEMU

**Rejected:** Adds GUI dependency. Harder to automate. CLI QEMU is standard.

### 4. Wait for ARM64 portal appliance

**Rejected:** No timeline from Red Hat. Need working solution now.

## References

- AAP Extend 2.7 docs, pages 207-225: Portal appliance deployment
- QEMU networking docs: `guestfwd`, `hostfwd`, slirp backend
- Cloud-init docs: `network` section (AAP-specific fields)
- ADR-001: Original port configuration approach
- OpenShift Local: Uses `nip.io` for DNS (`<ip>.nip.io` resolves to `<ip>`)

## Implementation Outcome (2026-06-25, revised 2026-06-26)

**guestfwd approach FAILED.** QEMU guestfwd syntax accepted but no traffic forwarded to macOS host.

### Actual Implementation: Hybrid ADR-001 + ADR-002

Deployed version uses:

1. **Port config:** ADR-002 approach (VM port 443, systemd lock)

   ```yaml
   write_files:
     - path: /etc/containers/systemd/portal.container.d/10-port-override.conf
       content: |
         [Container]
         PublishPort=443:7007  # Lock at default
   ```

1. **Environment variable fix:** Cloud-init→env conversion bug workaround (ADR-004)

   ```yaml
   write_files:
     - path: /etc/containers/systemd/portal.container.d/20-aap-env.conf
       content: |
         [Container]
         Environment=AAP_HOST_URL=https://<aap-route>
         Environment=AAP_OAUTH_CLIENT_ID=<oauth-client-id>
   ```

1. **AAP route resolution:** `/etc/hosts` in both `bootcmd` and `runcmd`

   Portal starts before cloud-init `runcmd` completes on first boot. Mapping the AAP route to `10.0.2.2` in `bootcmd`
   ensures the VM can reach AAP before the portal container initializes.

   ```yaml
   bootcmd:
     - grep -q "<aap-route>" /etc/hosts || echo "10.0.2.2 <aap-route>" >> /etc/hosts

   runcmd:
     - grep -q "<aap-route>" /etc/hosts || echo "10.0.2.2 <aap-route>" >> /etc/hosts
     - sudo rm -f /var/lib/portal/dynamic-plugins-root/install-dynamic-plugins.lock
     - systemctl restart portal.service
   ```

1. **RHAAP-only sign-in:** Disable SCM auth plugins and force RHAAP sign-in page

   The bundled portal ships GitHub/GitLab auth plugins enabled by default. Disabling them requires package paths that
   match `dynamic-plugins.override.yaml` (not npm-style `@backstage/...` names). A separate app-config override forces
   `signInPage: rhaap` on both `auth` and `app`.

   ```yaml
   write_files:
     - path: /etc/portal/configs/dynamic-plugins/zz-disable-scm-auth.yaml
       content: |
         plugins:
           - package: ./ansible-plugins/backstage-plugin-auth-backend-module-github-provider
             disabled: true
           - package: ./ansible-plugins/backstage-plugin-auth-backend-module-gitlab-provider
             disabled: true
     - path: /etc/portal/configs/app-config/zz-auth-rhaap-only.yaml
       content: |
         auth:
           signInPage: rhaap
         app:
           signInPage: rhaap
   ```

1. **QEMU networking:** hostfwd only (no guestfwd)

   ```bash
   -netdev user,id=net0,hostfwd=tcp::8443-:443,hostfwd=tcp::8080-:80,hostfwd=tcp::2223-:22,dns=10.0.2.3
   ```

1. **AAP connectivity on macOS host:** socat fallback restored

   QEMU slirp forwards VM connections to `10.0.2.2:443` on the macOS host. When CRC/OpenShift Local binds AAP on
   `*:443`, this works without socat. When the router only binds `127.0.0.1:443`, the VM cannot reach AAP and the
   portal login page falls back to GitHub (RHAAP provider fails to initialize).

   ```bash
   socat TCP-LISTEN:443,bind=0.0.0.0,fork,reuseaddr TCP:127.0.0.1:443
   ```

   `deploy.sh` starts socat if not already running. Requires `brew install socat`. Does not require sudo on macOS when
   CRC already owns port 443 — socat is skipped if an existing listener is present.

### Why It Works

**Primary path (CRC binds `*:443`):**

```
Portal container → aap-aap-operator.apps.127.0.0.1.nip.io
  ↓ /etc/hosts resolves to 10.0.2.2
Portal VM → 10.0.2.2:443
  ↓ QEMU slirp auto-forwards to macOS
macOS → CRC route (*:443)
  ↓
AAP Gateway
```

**Fallback path (CRC binds `127.0.0.1:443` only):**

```
Portal VM → 10.0.2.2:443
  ↓ QEMU slirp → macOS 0.0.0.0:443
socat → 127.0.0.1:443 → CRC → AAP Gateway
```

Without either `*:443` binding or socat, AAP OAuth does not appear on the login page even when portal UI is reachable.

### Why guestfwd Failed

Attempted syntax:

```bash
-netdev user,id=net0,guestfwd=tcp:10.0.2.2:443-tcp:127.0.0.1:443
```

**Issue:** QEMU accepted syntax but didn't forward traffic. Possible causes:

1. Homebrew QEMU slirp version incompatibility
1. guestfwd conflicts with automatic 10.0.2.2 gateway behavior
1. Incorrect guestfwd syntax (docs unclear on format)

**Decision:** Abandon guestfwd, use proven /etc/hosts approach.

### Lessons Learned

1. **QEMU slirp forwards 10.0.2.2 → macOS host** — but only if something listens on `0.0.0.0:443`; otherwise use socat
1. **ADR-002 port alignment still valuable** — VM on 443 (default) cleaner than 8443
1. **Cloud-init `bootcmd` + `runcmd` both needed** — portal auto-starts before `runcmd`; hosts mapping must exist early
1. **Document actual behavior not aspirational** — a comment claiming "no socat needed" hid regressions when CRC bind
   address differed
1. **Portal appliance cloud-init conversion bug** — `aap.host_url` and `aap.oauth.client_id` fields don't convert to env
   vars. Must inject via systemd `Environment=` directives. See ADR-004.
1. **AAP API requires Bearer tokens not passwords** — Portal backend catalog auth needs API token from
   `/api/gateway/v1/tokens/`, not admin password. See ADR-004.
1. **GitHub login ≠ working OAuth** — bundled GitHub auth plugins must be disabled with `./ansible-plugins/...` package
   paths; wrong disable config leaves a broken GitHub button instead of RHAAP sign-in
1. **Symptom: GitHub-only login** — usually AAP unreachable from VM (network) or SCM plugins not disabled (config), not
   missing OAuth app credentials

## Next Steps

1. ~~Update `deploy.sh` with new QEMU netdev config~~ DONE (partial: no guestfwd)
1. ~~Update cloud-init generator (remove write_files, runcmd)~~ BLOCKED (need /etc/hosts + auth overrides)
1. ✅ Test on Intel Mac (hvf acceleration)
1. ✅ Test on ARM Mac (tcg emulation)
1. ✅ Restore socat fallback for localhost-only CRC bind
1. ✅ Fix RHAAP sign-in (dynamic-plugin disable + signInPage override)
1. ~~Add fallback for QEMU without guestfwd support~~ N/A (not using guestfwd)
1. ✅ Update README with new architecture
1. ✅ Document hybrid approach in ADR-002
1. ✅ Fix cloud-init env conversion bug (ADR-004) — added systemd env override
