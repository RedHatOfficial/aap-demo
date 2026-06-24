# ADR-002: Portal VM Addon for macOS QEMU Deployment

**Status**: Accepted

**Date**: 2026-06-22

**Authors**: Chad Ferman

## Context

The AAP Self-Service Portal was initially implemented as a Helm-based addon (`addons/portal/`) using the Red Hat Developer Hub (RHDH) with a Portal plugin. While functional on x86_64 OpenShift environments, this approach had critical limitations for macOS development:

### Architecture Mismatch Issues

1. **RHDH Image Limitations**: RHDH container images only support x86_64 architecture (not ARM64)
2. **quay.io Plugin Failures**: On ARM Macs (Apple Silicon M1/M2/M3), the quay.io OCI plugin for RHDH fails when pulling x86 images
3. **No Native ARM Support**: AAP 2.7 Portal appliance not available as ARM-native qcow2 or container
4. **Development Friction**: Developers using macOS (especially ARM Macs) could not deploy portal locally for testing

### Business Impact

- Portal developers needed functional local test environments
- ARM Mac adoption increasing (now majority of Red Hat field laptops)
- Integration testing between AAP and Portal components blocked
- Customer demos requiring Portal features limited to x86 environments

### Constraints

- Must work on both ARM and Intel Macs
- Should leverage existing Portal appliance qcow2 from Red Hat Customer Portal
- Cannot require x86 hardware or cloud infrastructure for simple dev/test
- Must integrate with existing OpenShift Local (CRC) AAP deployment
- Performance limitations acceptable for dev/test use case (not production)

## Decision

Create a standalone `portal-vm` addon that deploys the Portal appliance qcow2 using QEMU x86-64 emulation on macOS, with automated AAP OAuth integration and cloud-init configuration.

### Technical Approach

**Deployment Architecture:**

```
macOS Host (ARM or Intel)
  ├── OpenShift Local (CRC) - AAP deployment
  │   └── AAP Gateway - OAuth provider
  └── QEMU x86-64 VM - Portal appliance
      ├── TCG emulation (not HVF on ARM)
      ├── User networking: 443→8443, 22→2223
      └── Cloud-init: AAP credentials, SSH keys
```

**Key Implementation Details:**

1. **QEMU Emulation Layer**
   - Uses `qemu-system-x86_64` for cross-architecture support
   - TCG (Tiny Code Generator) emulation on ARM Macs (5-10x slower than native)
   - 8GB RAM, 4 vCPU allocation for acceptable performance
   - tmux session for console access, background daemon mode

2. **Network Configuration**
   - QEMU user networking (no TAP/bridge complexity)
   - Port forwarding: HTTPS (443→8443), HTTP (80→8080), SSH (22→2223)
   - Portal VM uses port 2223 for SSH (CRC uses 2222, avoiding conflicts)
   - AAP access via nip.io route: `https://aap-aap-operator.apps.127.0.0.1.nip.io`

3. **Security Hardening**
   - SSH password authentication disabled (`ssh_pwauth: false`)
   - Key-only authentication with auto-generated Ed25519 keypair
   - Sudo NOPASSWD for admin user (VM appliance model, not multi-user)
   - OAuth client credentials auto-generated per deployment

4. **Cloud-Init Automation**
   - ISO image generated with `mkisofs` (cdrtools)
   - AAP credentials extracted from cluster secrets
   - OAuth application auto-created in AAP Gateway
   - Builtin PostgreSQL (no external DB dependency)
   - SSL verification disabled (`check_ssl: false`) for nip.io self-signed certs

5. **Integration with aap-demo CLI**
   - Unified addon lifecycle: `aap-demo enable portal-vm`, `aap-demo disable portal-vm`
   - Auto-discovery of qcow2 in `~/Downloads/ansible-automation-portal-*-x86_64.qcow2`
   - Prerequisite checks: macOS, QEMU, cdrtools, AAP deployment
   - Status reporting: VM running state, access URLs, SSH instructions

### Why This Approach

**Alternatives Considered and Rejected:**

1. **Remote x86 VM (AWS/GCP)**
   - Rejected: requires cloud account, network connectivity, cost
   - Better for CI/CD, but adds friction for local dev

2. **Docker x86 emulation**
   - Rejected: Portal appliance is qcow2-based, no official container
   - Would require custom containerization effort

3. **Wait for ARM Portal image**
   - Rejected: no ARM support planned in AAP 2.7 roadmap
   - Blocks current development needs

4. **Use Intel Mac only**
   - Rejected: most field team on ARM Macs, limits developer pool
   - Doesn't solve long-term ARM adoption

**Why QEMU VM Won:**

- Leverages official Portal appliance qcow2 (no custom builds)
- Works on both ARM and Intel Macs (single solution)
- Full VM isolation matches production deployment model
- Cloud-init support built into Portal appliance
- Acceptable performance tradeoff for dev/test use case

## Consequences

### Positive

1. **ARM Mac Developer Enablement**
   - Portal development now possible on Apple Silicon
   - Removes architecture as blocker for local testing

2. **Unified Developer Experience**
   - Single addon command: `aap-demo enable portal-vm`
   - Automatic AAP integration (OAuth, credentials)
   - Consistent with other aap-demo addon patterns

3. **Production Fidelity**
   - Uses same qcow2 appliance as production deployments
   - Cloud-init configuration matches appliance best practices
   - Full VM isolation (not containerized shortcuts)

4. **Maintainability**
   - Official Red Hat appliance (no custom builds to maintain)
   - Cloud-init is standard appliance interface
   - QEMU is stable, well-documented hypervisor

### Negative

1. **Performance Limitations**
   - x86 emulation on ARM: 5-10x slower than native
   - Boot time: 3-10 minutes (vs 1-3 minutes native)
   - UI latency noticeable, not suitable for production
   - Documented clearly as **dev/test only**

2. **Resource Requirements**
   - 8GB RAM dedicated to VM (on top of CRC's 16GB)
   - 24GB+ total RAM recommended for host
   - CPU overhead from TCG emulation

3. **Additional Dependencies**
   - Requires `brew install qemu cdrtools`
   - Manual qcow2 download from Red Hat Customer Portal (subscription required)
   - Cannot automate download (pull-secret is for containers only)

4. **Platform Limitation**
   - macOS only (but that's the target use case)
   - Linux users should use native KVM or portal Helm chart

### Neutral

1. **Maintenance Surface**
   - New addon to maintain alongside portal Helm chart
   - Both approaches needed: Helm for OpenShift, VM for macOS
   - Documentation split across README.md and ARM-DEPLOYMENT.md

2. **SSH Port Convention**
   - Port 2223 for portal-vm, 2222 for CRC
   - Avoids conflicts but adds cognitive load
   - Documented in help text and troubleshooting guides

## Alternatives Considered

### 1. Multi-Arch Container Support

**Description**: Wait for or contribute ARM64 RHDH images

**Pros**:

- Native ARM performance
- Leverages existing Helm chart

**Cons**:

- Upstream RHDH ARM support not planned
- Quay plugin issues independent of image arch
- Blocks current development needs

**Why rejected**: Timeline too long, doesn't solve quay plugin issues

### 2. Rosetta 2 + Docker Desktop

**Description**: Use Docker Desktop with Rosetta 2 x86 emulation

**Pros**:

- Familiar Docker workflow
- Desktop GUI for management

**Cons**:

- Portal is qcow2 appliance, no official container
- Custom containerization breaks production fidelity
- Docker Desktop resource overhead same as QEMU

**Why rejected**: No official container, loses appliance benefits

### 3. Cross-Compilation + Native Binaries

**Description**: Rebuild Portal components for ARM64

**Pros**:

- Native ARM performance

**Cons**:

- Requires deep Portal internals knowledge
- Unsupported configuration (breaks support)
- Ongoing maintenance burden for each release

**Why rejected**: Too much effort, unsupported configuration

## Implementation Details

### File Structure

```
addons/portal-vm/
├── deploy.sh              # Main deployment script (330 lines)
├── README.md              # General documentation
└── ARM-DEPLOYMENT.md      # ARM-specific guide

~/.aap-demo/portal-vm/     # Runtime directory
├── portal.qcow2           # Copy of appliance
├── cloud-init.iso         # Generated config disk
├── user-data              # Cloud-init AAP config
├── meta-data              # Instance metadata
├── id_ed25519             # SSH private key
├── id_ed25519.pub         # SSH public key
├── qemu.pid               # Process ID
├── qemu.log               # QEMU output
└── serial.log             # VM serial console
```

### Cloud-Init Configuration Template

```yaml
ssh_pwauth: false
users:
  - name: admin
    groups: sudo
    ssh_authorized_keys: [<generated-key>]

aap:
  host_url: "https://aap-aap-operator.apps.127.0.0.1.nip.io"
  token: "<from-aap-admin-password-secret>"
  check_ssl: false
  oauth:
    client_id: "portal-vm"
    client_secret: "<auto-generated>"

database:
  type: builtin
  builtin:
    password: "auto"
    admin_password: "auto"

security:
  backend_secret: "auto"
```

### QEMU Command Line

```bash
qemu-system-x86_64 \
  -machine type=q35,accel=tcg \  # TCG emulation (ARM)
  -cpu qemu64 \
  -m 8G \
  -smp 4 \
  -drive file=portal.qcow2,if=virtio,cache=writeback \
  -drive file=cloud-init.iso,if=virtio,readonly=on \
  -netdev user,id=net0,hostfwd=tcp::8443-:443,hostfwd=tcp::2223-:22 \
  -device virtio-net-pci,netdev=net0 \
  -nographic \
  -serial unix:$PORTAL_DIR/serial.sock,server,nowait
```

### Integration Points

1. **AAP OAuth Creation**
   - Extracts admin password from `aap-admin-password` secret
   - Creates OAuth application via AAP Gateway API
   - Stores client_id/secret in cloud-init user-data

2. **Addon Lifecycle Hooks**
   - `ADDON_REQUIRES_AAP=true` in deploy.sh header
   - aap-demo CLI validates AAP deployed before enabling
   - `aap-demo status` shows portal-vm state

3. **User Experience Flow**

   ```bash
   # Enable addon (one-time setup)
   aap-demo enable portal-vm

   # Start VM (idempotent)
   addons/portal-vm/deploy.sh

   # Access portal (after 3-10 min boot)
   open https://localhost:8443

   # Console access for debugging
   tmux attach -t portal-vm

   # Stop VM
   addons/portal-vm/deploy.sh --delete
   ```

## References

- **Commit**: `5889f54` - feat(portal): Add portal-vm addon for macOS QEMU deployment
- **Issue**: #18 (closed)
- **Related ADR**: ADR-001 (Self-Service Portal Integration) - Helm chart approach
- **Documentation**:
  - AAP Extend Docs (pages 207-225): Portal appliance deployment
  - Red Hat Customer Portal: https://access.redhat.com/downloads/content/480
  - QEMU Documentation: https://www.qemu.org/docs/master/
  - Cloud-init: https://cloudinit.readthedocs.io/
- **Related PRs**:
  - `411bace` - fix(portal-vm): Fix shellcheck warnings
  - `15a815e` - fix(portal-vm): Show correct SSH access instructions
  - `2c58d27` - fix: Replace placeholder secrets with generic descriptions
