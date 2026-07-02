# Fleet Nodes — Implementation Handoff

## What it does

Spins up QEMU-based RHEL VMs on the host machine as managed nodes for AAP demos. VMs are SSH-reachable from the AAP controller inside the CRC cluster, and auto-registered in AAP's inventory with credentials ready to use.

```
aap-demo deploy --fleet 3 --image ~/rhel9.qcow2   # deploy AAP + 3 VMs
aap-demo fleet add 2 --image ~/rhel9.qcow2        # add VMs to existing AAP
aap-demo fleet list                                 # show running VMs
aap-demo fleet remove 1                            # remove last VM
aap-demo fleet destroy                             # remove all VMs + AAP resources
```

## Files added

- `includes/fleet.sh` — VM lifecycle (QEMU launch, cloud-init ISO, create/delete/list)
- `includes/fleet-aap.sh` — AAP API registration (credential, inventory, hosts, ad-hoc ping)
- `config/cloud-init/user-data.template` — cloud-init user config (creates `ansible` user with SSH key)
- `config/cloud-init/meta-data.template` — cloud-init instance metadata

## Files modified

- `aap-demo.sh` — `fleet` command + subcommands, `--fleet`/`--image` flags, hooks into `deploy`/`destroy`/`stop`/`status`

## How VMs are created

1. Base QCOW2 image is copied once to `~/.aap-demo/fleet/base.qcow2`
2. Each VM gets a thin QCOW2 overlay (~200KB initial, copy-on-write)
3. An ed25519 SSH keypair is generated at `~/.aap-demo/fleet/ssh_key`
4. A cloud-init ISO is built per VM (injects `ansible` user + SSH public key)
5. QEMU launches daemonized with user-mode networking and a host port forward for SSH

QEMU invocation adapts per platform:
- **Apple Silicon**: `qemu-system-aarch64 -accel hvf -M virt -bios edk2-aarch64-code.fd`
- **Intel Mac**: `qemu-system-x86_64 -accel hvf -M q35`
- **Linux**: `qemu-system-x86_64 -accel kvm -M q35`

The QCOW2 image must match the host architecture.

## Networking

This is the critical path and where we hit the most issues during implementation.

### The network path

```
AAP controller pod
  → CRC VM (192.168.127.2)
    → host real network IP (e.g., 10.x.x.x)
      → QEMU port forward (0.0.0.0:220N)
        → VM SSH (:22)
```

### Key findings

1. **CRC's virtual gateway (192.168.127.1) does NOT expose host ports.** vfkit's virtio-net provides the CRC VM with outbound internet but the 192.168.127.1 gateway address is not a real interface on the host. Binding QEMU to `0.0.0.0` doesn't help because that address isn't routable from the CRC VM.

2. **The CRC VM CAN reach the host via its real network IP** (e.g., en0/en5 interface IP). This is how the port forwards become accessible.

3. **Host IP detection** uses the IP on the default route interface (`route -n get default` → interface → `ifconfig <iface> inet`). This is cached at `~/.aap-demo/fleet/host_gateway_ip`. The cache must be cleared if the host IP changes (VPN, network switch, etc.).

4. **QEMU port forwards bind to `0.0.0.0`** (`hostfwd=tcp:0.0.0.0:220N-:22`), not localhost, so they're reachable from the CRC VM.

5. **macOS firewall must allow QEMU.** On managed Macs, this must be done through System Settings → Network → Firewall (CLI `socketfilterfw` commands require sudo which may be blocked). Without this, connections from the CRC VM to host ports are silently dropped.

### AAP registration

Hosts are registered with:
```yaml
ansible_host: <host-real-ip>    # e.g., 10.17.161.219
ansible_port: 220N              # per-VM port forward
ansible_user: ansible
```

A "Fleet SSH Key" Machine credential is created with the generated private key. A "Fleet" inventory is created in the Default org. An ad-hoc ping verifies end-to-end connectivity.

**Important:** Job templates must select the "Fleet SSH Key" credential to authenticate. The ad-hoc ping run during registration uses it automatically, but user-created job templates need it assigned manually.

## Lifecycle hooks

- `aap-demo stop` — kills all fleet node VMs (they're ephemeral)
- `aap-demo destroy` — destroys all fleet nodes + cleans `~/.aap-demo/fleet/` before deleting the CRC cluster
- `aap-demo status` — shows a "Fleet" section with running VMs

VMs are not recreated on `aap-demo start`. After a stop/start cycle, the user re-runs `aap-demo fleet add`.

## Runtime state

```
~/.aap-demo/fleet/
  ssh_key / ssh_key.pub          # generated SSH keypair
  base.qcow2                    # shared base image (copied once)
  host_gateway_ip               # cached host IP (clear if network changes)
  node-1/
    disk.qcow2                  # thin overlay
    cloud-init.iso              # generated cloud-init
    qemu.pid                    # QEMU process ID
    console.log                 # serial console output
    meta                        # INDEX, PORT, PID, HOSTNAME, STATUS
  node-2/
    ...
```

Image path is saved to `~/.aap-demo/config` as `FLEET_IMAGE=<path>` so subsequent `fleet add` commands don't need `--image`.

## Prerequisites

- `qemu-system-aarch64` (or `x86_64`) — `brew install qemu`
- `mkisofs` — `brew install cdrtools` (macOS) / `genisoimage` (Linux)
- A RHEL/CentOS QCOW2 cloud image matching host architecture
- QEMU allowed through macOS firewall (System Settings → Network → Firewall)

## Known limitations

- Host IP detection assumes the default route interface is reachable from the CRC VM. If on VPN, the detected IP may change and the cached `host_gateway_ip` needs to be cleared.
- VMs are ephemeral — `aap-demo stop` kills them. This is by design (no state to corrupt).
- The QCOW2 image must support cloud-init (standard RHEL/CentOS cloud images do, custom images may not).
- Phase 2 (in-cluster Gitea + sample playbooks/job templates) is not yet implemented.
