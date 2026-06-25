# Portal VM Addon (QEMU x86 Emulation)

Deploy AAP Portal via QEMU x86 emulation on macOS.

## Overview

Runs portal appliance qcow2 using `qemu-system-x86_64` on macOS (ARM or Intel).
Uses x86 emulation on ARM Macs - slow but functional for dev/testing.

**⚠️ Performance Warning:**

- x86 emulation on ARM Mac = 5-10x slower than native
- Boot time: 3-10 minutes (vs 1-3 native)
- UI latency noticeable
- **Dev/testing only - not production**

## Prerequisites

### Required

1. **macOS** (ARM or Intel)
2. **AAP deployed** in `aap-operator` namespace
3. **Portal qcow2 downloaded** from Red Hat Customer Portal
4. **QEMU and cdrtools** installed:

   ```bash
   brew install qemu cdrtools
   ```

### Download Portal QCOW2

1. Login to Red Hat Customer Portal (requires AAP subscription)
2. Navigate to: https://access.redhat.com/downloads/content/480/ver=2.7/rhel---9/2.7/x86_64/product-software
3. Download "Ansible automation portal QCOW2" for AAP 2.7
4. Save to: `~/Downloads/portal-appliance-2.7.qcow2`

**Note:** Pull secret (`~/Downloads/pull-secret.txt`) is for container registries only,
not appliance downloads. Manual download required.

## Usage

### Deploy Portal VM

```bash
./deploy.sh
```

**What it does:**

1. Checks prerequisites (qemu, qcow2, AAP)
2. Gets AAP credentials from cluster
3. Generates cloud-init configuration with SSH keys
4. Starts QEMU VM in background
5. Portal accessible at `https://localhost:8443`

### Access Portal

After 3-10 minute boot:

```bash
# Portal UI (primary access)
open https://localhost:8443

# Console access (for debugging/config)
tmux attach -t portal-vm
# Login: admin / admin
# Detach: Ctrl-b d

# Check services (from console)
sudo systemctl status portal postgres devtools
```

**SSH Access:**

```bash
# SSH using generated key (key-only auth)
ssh -i ~/.aap-demo/portal-vm/id_ed25519 -p 2223 admin@localhost
```

**Note:** Portal VM uses port 2223 for SSH (CRC uses 2222). Password auth disabled for security.

### Optional: Import SSL Certificate

Eliminate browser SSL warnings by importing portal's self-signed certificate to macOS keychain:

```bash
# After portal finishes booting
cd addons/portal-vm
./import-cert.sh
```

Requires sudo to add cert to macOS System keychain. Restart browser after import to clear warnings.

### Monitor Boot Progress

```bash
tail -f ~/.aap-demo/portal-vm/serial.log
```

### Stop Portal VM

```bash
./deploy.sh --delete
```

Stops QEMU process. Optionally removes portal directory (keeps qcow2 copy for restart).

## Configuration

### Environment Variables

```bash
# Custom qcow2 location
QCOW2_PATH=/path/to/portal.qcow2 ./deploy.sh

# Custom portal directory (default: ~/.aap-demo/portal-vm)
PORTAL_DIR=/custom/path ./deploy.sh

# Custom AAP namespace (default: aap-operator)
NAMESPACE=my-aap ./deploy.sh

# Custom VM name (default: automation-portal)
PORTAL_VM_NAME=my-portal ./deploy.sh
```

### Files Created

```
~/.aap-demo/portal-vm/
├── portal.qcow2        # Copy of portal appliance (don't modify original)
├── cloud-init.iso      # Cloud-init configuration disk
├── user-data           # Cloud-init config (AAP creds, SSH keys)
├── meta-data           # Instance metadata
├── id_ed25519          # SSH private key
├── id_ed25519.pub      # SSH public key
├── qemu.pid            # QEMU process PID
├── qemu.log            # QEMU stdout/stderr
└── serial.log          # VM serial console output
```

## Architecture (ADR-002)

**Port flow (no socat, no sudo required):**

```
macOS Browser
  ↓ https://localhost:8443
QEMU hostfwd tcp::8443-:443
  ↓
Portal VM :443
  ↓ systemd override PublishPort=443:7007
Portal Container :7007 (internal)
```

**AAP connectivity (QEMU guestfwd):**

```
Portal Container → AAP route
  ↓ DNS resolves to 10.0.2.2 (QEMU host gateway)
Portal VM → 10.0.2.2:443
  ↓ QEMU guestfwd=tcp:10.0.2.2:443-tcp:127.0.0.1:443
macOS 127.0.0.1:443 → OpenShift Local
```

**Component diagram:**

```
┌─────────────────────────────────────────────────┐
│         macOS Host                              │
│                                                 │
│  ┌─────────────────────────────────────────┐   │
│  │  QEMU (x86 emulation) - ADR-002         │   │
│  │                                         │   │
│  │  ┌───────────────────────────────────┐ │   │
│  │  │ Portal VM (RHEL 9 bootc x86)     │ │   │
│  │  │                                   │ │   │
│  │  │ Container: portal:7007            │ │   │
│  │  │ VM host: 0.0.0.0:443 (override)   │ │   │
│  │  │                                   │ │   │
│  │  │ Services:                         │ │   │
│  │  │ - portal.service                  │ │   │
│  │  │ - postgres.service                │ │   │
│  │  │ - devtools.service                │ │   │
│  │  └───────────────────────────────────┘ │   │
│  │                                         │   │
│  │  QEMU networking (user mode, slirp):   │   │
│  │  hostfwd: macOS:8443 → VM:443          │   │
│  │  hostfwd: macOS:8080 → VM:80           │   │
│  │  hostfwd: macOS:2223 → VM:22           │   │
│  │  guestfwd: VM:10.0.2.2:443 → macOS:443 │   │
│  └─────────────────────────────────────────┘   │
│                                                 │
│  ┌─────────────────────────────────────────┐   │
│  │  OpenShift Local (127.0.0.1:443)        │   │
│  │                                         │   │
│  │  - AAP Gateway (OAuth provider)         │   │
│  │  - AAP Controller                       │   │
│  │  - Hub                                  │   │
│  └─────────────────────────────────────────┘   │
└─────────────────────────────────────────────────┘

Key improvements vs ADR-001:
- No socat proxy (QEMU guestfwd handles AAP connectivity)
- No sudo required (guestfwd runs in user QEMU process)
- No /etc/hosts DNS hacks (standard resolution via QEMU DNS)
- Port 443 on VM (matches appliance default, cleaner override)
```

## Cloud-Init Configuration

Portal VM auto-configures on first boot via cloud-init:

```yaml
ssh_pwauth: false
users:
  - name: admin
    groups: sudo
    ssh_authorized_keys:
      - <generated-ssh-key>

aap:
  host_url: "https://aap-aap-operator.apps.127.0.0.1.nip.io"
  token: "<generated-from-aap-admin-password-secret>"
  check_ssl: false
  oauth:
    client_id: "portal-vm"
    client_secret: "<generated-oauth-secret>"

database:
  type: builtin
  builtin:
    password: "auto"
    admin_password: "auto"

security:
  backend_secret: "auto"  # Auto-generated

network:
  base_url: "https://localhost:8443"

write_files:
  - path: /etc/containers/systemd/portal.container.d/10-port-override.conf
    content: |
      [Container]
      PublishPort=443:7007
```

## Troubleshooting

### QEMU not found

```bash
brew install qemu
```

Verify: `qemu-system-x86_64 --version`

### mkisofs not found

```bash
brew install cdrtools
```

Verify: `mkisofs --version`

### Portal qcow2 not found

Download from Customer Portal:
https://access.redhat.com/downloads/content/480/ver=2.7/rhel---9/2.7/x86_64/product-software

Save to: `~/Downloads/portal-appliance-2.7.qcow2`

### VM won't boot

Check serial log:

```bash
tail -f ~/.aap-demo/portal-vm/serial.log
```

Common issues:

- Insufficient RAM (need 24GB free)
- Corrupted qcow2 (re-download)
- Cloud-init errors (check user-data syntax)

### SSH access issues

**SSH Working on Port 2223:**

```bash
# Key-based auth (only option - password auth disabled)
ssh -i ~/.aap-demo/portal-vm/id_ed25519 -p 2223 admin@localhost
```

**Console Access (Alternative):**

```bash
# Attach to VM console
tmux attach -t portal-vm

# Login credentials:
# Username: admin
# Password: admin

# Detach from console: Ctrl-b d
```

**Port Notes:**

- Portal SSH: 2223 (this addon)
- CRC SSH: 2222 (OpenShift Local)
- Separated to avoid conflicts

### Portal services not starting

Check logs via serial console:

```bash
tail -f ~/.aap-demo/portal-vm/qemu.log | grep -E "(portal|postgres|devtools)"
```

### Can't connect to AAP

**ADR-002:** Portal reaches AAP via QEMU guestfwd (no socat):

```
Portal → 10.0.2.2:443 → guestfwd → macOS 127.0.0.1:443 → OpenShift Local
```

Test from portal VM SSH:

```bash
# Should reach AAP Gateway
curl -k https://10.0.2.2:443/api/v2/ping/
```

If fails, check macOS:

```bash
# AAP should respond on 127.0.0.1:443
curl -k https://127.0.0.1:443/api/v2/ping/

# Check CRC routes
oc get route aap -n aap-operator
```

Verify QEMU guestfwd enabled:

```bash
# Check qemu.log for guestfwd line
grep guestfwd ~/.aap-demo/portal-vm/qemu.log
```

### Performance too slow

x86 emulation on ARM inherently slow. Options:

1. **Reduce resources** (slower but less RAM):

   ```bash
   # Edit deploy.sh line 185:
   -m 16G \  # Instead of 24G
   -smp 4 \  # Instead of 6
   ```

2. **Use remote x86 host** (AWS/GCP/local x86 server with native KVM)

3. **Wait for ARM portal image** (not available as of AAP 2.7)

## Comparison: Portal VM vs Portal Helm Chart

| Aspect | Portal VM (this addon) | Portal Helm Chart |
|--------|------------------------|-------------------|
| Platform | macOS (QEMU) | OpenShift/Kubernetes |
| Architecture | Standalone VM | Containerized |
| macOS ARM support | ✅ (slow emulation) | ❌ (broken quay plugin) |
| Boot time | 3-10 min | 1-2 min (when working) |
| Resource usage | 24GB RAM, 6 vCPU | 16GB RAM typical |
| Production ready | ❌ Dev/testing only | ✅ (when chart fixed) |
| Isolation | Full VM isolation | Kubernetes namespace |
| Persistence | VM disk persists | Kubernetes PVCs |

## References

- AAP Extend Docs (pages 207-225): Portal appliance deployment
- Red Hat Customer Portal: https://access.redhat.com/downloads/content/480
- QEMU Documentation: https://www.qemu.org/docs/master/
- Cloud-init: https://cloudinit.readthedocs.io/
