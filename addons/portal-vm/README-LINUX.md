# Portal VM Testing on Linux (Native KVM)

Replicate portal appliance boot issue on Linux x86 with native KVM (no emulation).

## Purpose

Test if portal plugin install lock issue is:

- **Emulation-specific** (macOS ARM x86 emulation)
- **Platform-agnostic** (portal appliance image bug)

## Prerequisites

### RHEL/CentOS/Fedora

```bash
# Install KVM and tools
sudo dnf install qemu-kvm libvirt genisoimage

# Enable KVM module
sudo modprobe kvm_intel  # or kvm_amd
lsmod | grep kvm

# Add user to kvm group (optional, avoids sudo)
sudo usermod -aG kvm $USER
# Re-login for group to take effect

# Verify KVM access
ls -l /dev/kvm
```

### Download Portal QCOW2

1. Login to Red Hat Customer Portal
2. Navigate to: https://access.redhat.com/downloads/content/480/ver=2.7/rhel---9/2.7/x86_64/product-software
3. Download "Ansible automation portal QCOW2" for AAP 2.7
4. Save to: `~/Downloads/ansible-automation-portal-2.2.1-x86_64.qcow2`

### AAP Deployed

```bash
# Verify AAP running
kubectl get route aap -n aap-operator
kubectl get secret aap-admin-password -n aap-operator
```

## Usage

```bash
cd addons/portal-vm

# Deploy portal VM (native KVM, no emulation)
./deploy-linux.sh

# Monitor boot progress
tail -f ~/.aap-demo/portal-vm/serial.log

# Check for lock issue
ssh -i ~/.aap-demo/portal-vm/id_ed25519 -p 2223 admin@localhost \
  'sudo podman logs portal | grep -A5 "Waiting for lock"'

# Stop and cleanup
./deploy-linux.sh --delete
```

## Key Differences from macOS Version

| Aspect | macOS (`deploy.sh`) | Linux (`deploy-linux.sh`) |
|--------|---------------------|---------------------------|
| **Acceleration** | TCG emulation (slow) | KVM native (fast) |
| **CPU** | `-cpu Nehalem` (x86 compat) | `-cpu host` (native) |
| **Networking** | socket_vmnet bridged | QEMU user-mode + port forward |
| **Port 8443** | Via bridged IP | `localhost:8443` (hostfwd) |
| **SSH** | Port 2223 via bridged IP | `localhost:2223` (hostfwd) |
| **Boot Time** | 3-10 minutes | 1-3 minutes |
| **Cert Trust** | macOS login keychain | System CA trust (`/etc/pki/ca-trust`) |

## Expected Behavior

### If Issue is Emulation-Specific

Portal should:

1. Boot in 1-3 minutes (fast)
2. Install plugins successfully
3. Start listening on port 8443
4. Respond to `https://localhost:8443`

### If Issue is Platform-Agnostic

Portal will show same symptoms as macOS:

```
podman logs portal
# Output:
# ======= Waiting for lock release (file: /opt/app-root/src/dynamic-plugins-root/install-dynamic-plugins.lock)...
```

Container stuck indefinitely, port 8443 never opens.

## Diagnostics

### Check Portal Container Status

```bash
ssh -i ~/.aap-demo/portal-vm/id_ed25519 -p 2223 admin@localhost

# Inside VM:
sudo systemctl status portal
sudo podman ps -a
sudo podman logs portal | tail -50

# Check port listening
sudo ss -tlnp | grep 8443
```

### Check Plugin Directory

```bash
ssh -i ~/.aap-demo/portal-vm/id_ed25519 -p 2223 admin@localhost \
  'sudo podman exec portal ls -la /opt/app-root/src/dynamic-plugins-root/'
```

Look for:

- Lock file existence
- Directory permissions
- Partial plugin installs

## Reporting Results

Update `PORTAL-BUG-REPORT.md` with findings:

```markdown
## Linux Native KVM Testing

**Platform**: RHEL 9 / CentOS Stream 9 / Fedora XX
**KVM**: Enabled
**Boot Time**: X minutes
**Result**: [PASSED | FAILED - same lock issue]

### Logs
[attach podman logs portal output]
```

## Cleanup

```bash
# Stop VM
./deploy-linux.sh --delete

# Remove all portal files
rm -rf ~/.aap-demo/portal-vm

# Remove system cert trust (if added)
sudo rm /etc/pki/ca-trust/source/anchors/portal-vm.pem
sudo update-ca-trust
```

## Notes

- Uses user-mode networking (no bridging) - simpler setup
- Portal can still reach AAP via host IP + nip.io routes
- Faster testing cycle than macOS emulation
- Confirms if issue is appliance bug vs platform-specific
