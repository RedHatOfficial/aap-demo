# Linux quickstart (RHEL and Fedora)

aap-demo is for local development only, not production. Run the CLI as your
ordinary user; use sudo only for host preparation and service installation.

## 1. Prepare the host

- Use a CRC-supported, hardware-virtualization-enabled Linux workstation.
  The automatic CRC downloader currently targets **x86_64** only.
- Reserve at least 8 CPUs and 16 GiB for CRC; **24 GiB for CRC and 32+ GiB
  host RAM** is a better starting point for AAP plus addons. Fleet needs extra.
- Keep space for the VM, bundle cache, and backups. Each full retained checkpoint
  is additional host storage, not space inside the CRC guest.
- On RHEL, register the host and enable the repositories needed for these
  packages. Do not bypass SELinux or disable your firewall globally.

```bash
sudo dnf install -y git curl jq python3 python3-pip ansible-core \
  libvirt qemu-kvm qemu-img rsync libxml2 policycoreutils nss-tools
git clone https://github.com/ShaddGallegos/aap-demo.git
cd aap-demo
./install.sh
source ~/.bashrc
```

The installer adds an idempotent `~/.local/bin` PATH block and Bash completion
loader to `~/.bashrc`. New Bash sessions load both automatically.

Download your personal [Red Hat pull secret](https://console.redhat.com/openshift/install/pull-secret)
to `~/Downloads/pull-secret.txt`. It is a credential: do not commit or share it.

## 2. Install and deploy

For the bootstrap including MCP Server, APME, Product Demos and Automation
Orchestrator:

```bash
CRC_MEMORY=24576 CRC_DISK=200 ./scripts/local-prereq.sh --full \
  --pull-secret "$HOME/Downloads/pull-secret.txt"
```

The bootstrap installs missing clients and CRC, prepares libvirt/group access,
and runs `crc setup`. Follow any relogin instructions. Keep the repository at
its installed location.

For a smaller/manual installation, install the matching Linux
[OpenShift Local release](https://console.redhat.com/openshift/create/local),
put `crc` on PATH, and run:

```bash
./install.sh
./scripts/local-prereq.sh --pull-secret "$HOME/Downloads/pull-secret.txt"
CRC_MEMORY=24576 CRC_DISK=200 aap-demo deploy
```

`deploy` creates the cluster if necessary. `create` alone does not install AAP.
Use the MicroShift preset unless an addon needs full OpenShift.

## 3. Configure and use

Settings are stored in `~/.aap-demo/config`. Command environment variables take
precedence; use `aap-demo config` and `aap-demo help` to inspect options.

```bash
aap-demo status
aap-demo diagnose
aap-demo status --show-secrets  # Interactive terminal only
aap-demo kubeconfig
export KUBECONFIG="$HOME/.aap-demo/kubeconfig.microshift"
kubectl get pods -n aap-operator
aap-demo enable                # Show available addons
aap-demo enable mcp-server
aap-demo wire                  # Restore addon integrations
```

Open the route printed by `status`. Browser trust may need `nss-tools`, a
successful CA import, and a complete browser restart.

## 4. Stop, restart, and recover

```bash
aap-demo stop
aap-demo start
aap-demo restart
```

`start` restores DNS/integrations, resumes idle AAP, waits for workloads, and
starts preserved Fleet VMs. Set `AAP_START_TIMEOUT=900` for longer readiness
phases. It does not redeploy or forcibly restart healthy pods.

At startup, CRC filesystem usage of **90% or more** triggers **20% growth of
the actual VM disk**, rounded up to GiB, through a graceful stop/start.
Host free space and guest expansion are checked. This is not continuous
monitoring and does not resize PVCs or separate image-store disks.

Optional, after deployment finishes and no other mutating command is running:

```bash
aap-demo service install         # Default: keep one completed cold backup
aap-demo service retention 3     # Optional: keep three instead
aap-demo service backup
aap-demo service backups
aap-demo service status
sudo journalctl -u aap-demo.service --no-pager
```

This Linux/systemd/libvirt service saves on graceful host shutdown and restores
and starts at boot. With it enabled, `stop` saves a checkpoint and `start` /
`restart` use the managed recovery workflow. Backups contain secrets, are
root-only, and are **not independently encrypted**. Sudden power loss uses the
last completed checkpoint. Read [recovery semantics](docs/state-service.md)
before enabling intentional rollback.

Disable recovery before rebuilding or deleting the demo:

```bash
aap-demo service disable
```

## Troubleshooting and limits

- `localhost:8080 refused`: export the demo kubeconfig shown above.
- Pending pods: inspect `kubectl describe pod -n aap-operator <pod>`; check
  memory requests, PVCs, image pulls and `aap-demo diagnose`.
- `crc setup` / libvirt errors: finish host setup and group relogin first.
- Architecture-specific addon images are not made portable by the CLI.
  The full bootstrap is not a supported WSL VM installation.
- `destroy`, `clean`, and `redeploy-all` remove state; read their warnings.

See also [macOS](MAC_Quickstart.md), [Windows](Windows_Quickstart.md), and
[WSL](WSL_Quickstart.md).
