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

5. **socket_vmnet** (required):

   ```bash
   brew install socket_vmnet

   # Post-install setup (one-time)
   sudo brew services start socket_vmnet
   ```

   Portal requires socket_vmnet for bridged networking to reach AAP routes.

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
5. Waits for SSH (up to 10 minutes)
6. Extracts portal cert and adds to login keychain (no sudo)
7. Adds 'portal' vanity URL to /etc/hosts (requires sudo)
8. Portal accessible at `https://portal:8443` (trusted cert in Chrome/Safari)

### Access Portal

After 3-10 minute boot:

```bash
# Portal UI (primary access - vanity URL)
open https://portal:8443

# Or via localhost
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

## Architecture

```
┌───────────────────────────────────────────────────┐
│         macOS Host (192.168.68.81)                │
│                                                   │
│  ┌─────────────────────────────────────────────┐ │
│  │  socket_vmnet (bridge to en0)               │ │
│  └─────────────────────────────────────────────┘ │
│                │                                  │
│  ┌─────────────┴─────────────┐  ┌──────────────┐ │
│  │  QEMU VM (x86 emulation)  │  │  CRC         │ │
│  │  192.168.68.x (DHCP)      │  │  127.0.0.1   │ │
│  │                           │  │              │ │
│  │  - portal.service         │  │  AAP routes: │ │
│  │  - postgres.service       │  │  - aap...    │ │
│  │  - devtools.service       │  │    .apps.    │ │
│  └───────────────────────────┘  │    192...    │ │
│         │                        │    .nip.io   │ │
│         └────────────────────────>              │ │
│           Reaches AAP via        └──────────────┘ │
│           192.168.68.81.nip.io                    │
└───────────────────────────────────────────────────┘
```

**Key Points:**

- VM gets real IP on host network (192.168.68.0/22)
- AAP routes use `<host-ip>.nip.io` instead of `127.0.0.1.nip.io`
- Portal resolves AAP routes via `/etc/hosts` → host IP
- No port forwarding needed - direct L2 connectivity

**Known Limitation:**

Portal configuration hardcodes host LAN IP in `/etc/hosts`. Breaks if host network changes (WiFi → Ethernet, different network).

**Planned Fix:**

Modify CRC haproxy to bind `0.0.0.0` (not `127.0.0.1`) so routes accessible from socket_vmnet gateway IP (`192.168.105.1`). Then portal can use dnsmasq wildcard `*.apps.*.nip.io` → gateway — fully network-portable.

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
  host_url: "https://aap-aap-operator.apps.192.168.68.81.nip.io"
  token: "<generated-from-aap-admin-password-secret>"
  check_ssl: false
  oauth:
    client_id: "portal-vm"
    client_secret: "<generated-oauth-secret>"

database:
  type: builtin

# /etc/hosts entries for AAP route resolution
write_files:
  - path: /etc/hosts
    append: true
    content: |
      192.168.68.81 aap-aap-operator.apps.192.168.68.81.nip.io
      192.168.68.81 aap-mcp-aap-operator.apps.192.168.68.81.nip.io

runcmd:
  - systemctl restart systemd-resolved
```

## Troubleshooting

### socket_vmnet not found or not running

**Install:**

```bash
brew install socket_vmnet
```

**Start service:**

```bash
sudo brew services start socket_vmnet
```

**Verify running:**

```bash
pgrep -x socket_vmnet && echo "✓ Running" || echo "✗ Not running"
```

Deploy script will fail without socket_vmnet running.

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

### Certificate errors in browser

Portal generates self-signed cert with VM IP in SAN on first boot. If cert doesn't match:

```bash
# Check current cert
ssh -i ~/.aap-demo/portal-vm/id_ed25519 admin@<vm-ip> \
  'openssl x509 -in /etc/portal/ssl/cert.pem -noout -text | grep -A1 "Subject Alternative"'

# Regenerate cert if VM IP changed
ssh -i ~/.aap-demo/portal-vm/id_ed25519 admin@<vm-ip> 'sudo /root/generate-portal-cert.sh'
```

Browser will show self-signed warning - accept once to proceed.

### Can't connect to AAP

From portal VM SSH:

```bash
# Check /etc/hosts entries
cat /etc/hosts | grep aap

# Resolve AAP route (should return host IP)
dig +short aap-aap-operator.apps.<host-ip>.nip.io

# Test connectivity
curl -k https://aap-aap-operator.apps.<host-ip>.nip.io/api/v2/ping/

# Check VM can reach host
ping <host-ip>
```

Check socket_vmnet running on host:

```bash
pgrep -x socket_vmnet && echo "✓ Running" || echo "✗ Not running"
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
