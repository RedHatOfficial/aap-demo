# macOS quickstart

aap-demo is for local development only. Use the Bash CLI from Terminal, not the
Windows PowerShell implementation.

## 1. Install prerequisites

Use a macOS version and Intel/Apple Silicon architecture supported by your
[OpenShift Local release](https://console.redhat.com/openshift/create/local).
Download CRC for your actual CPU architecture; do not mix ARM and Intel bundles.
AAP/addon images must also support that architecture.

Allow at least 8 CPUs and 16 GiB for CRC; prefer 24 GiB for CRC and 32+ GiB host
RAM for an addon-heavy demo. Keep ample host disk space for bundles and copies
of the VM disk.

Install [Homebrew](https://brew.sh/), then:

```bash
brew install git jq python ansible rsync
git clone https://github.com/ShaddGallegos/aap-demo.git
cd aap-demo
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
./install.sh
```

Keep the PATH export in `~/.zshrc` (or your chosen shell's profile) for new
terminals. Homebrew's own setup instructions also configure its executable path.

The installer downloads architecture-matched `oc` and `kubectl` when needed and
verifies their archive checksum. It installs shell completions and a launcher
pointing at this repository. Keep the repository in place.

Install CRC from the Red Hat download and verify `crc version`. Download your
[pull secret](https://console.redhat.com/openshift/install/pull-secret), then:

```bash
mkdir -p "$HOME/.aap-demo"
install -m 600 "$HOME/Downloads/pull-secret.txt" "$HOME/.aap-demo/pull-secret.txt"
crc config set preset microshift
crc setup
```

Follow CRC's host permission prompts. **Do not use
`scripts/local-prereq.sh --full` on macOS**: that is the native Linux/libvirt
bootstrap.

## 2. Configure and deploy

```bash
CRC_MEMORY=24576 CRC_DISK=200 aap-demo deploy
aap-demo status
aap-demo diagnose
aap-demo status --show-secrets
aap-demo kubeconfig
export KUBECONFIG="$HOME/.aap-demo/kubeconfig.microshift"
kubectl get pods -n aap-operator
```

Configuration lives in `~/.aap-demo/config`; command environment variables take
precedence. `deploy` can create the cluster; `create` alone only provisions CRC.
Open the route shown by `status`. Complete any Keychain CA trust prompt, then
fully restart your browser if necessary.

```bash
aap-demo enable             # List addons
aap-demo enable mcp-server
aap-demo enable ao
aap-demo wire
aap-demo stop
aap-demo start
aap-demo restart
```

Bash startup restores DNS, resumes idle AAP, waits for installed workloads and
enabled addons, and starts preserved Fleet nodes. Set `AAP_START_TIMEOUT=900`
for slower hardware. The 90%-used / 20%-growth CRC disk check runs at startup;
host space and guest growth must verify before success.

## 3. Optional checkpoint and login recovery

For a standard **vfkit/raw-disk** CRC installation:

```bash
aap-demo service install          # Initial verified checkpoint; keep one state
aap-demo service retention 3      # Optional history
aap-demo service backup           # Save, restore, and resume
aap-demo service backups
aap-demo service status
aap-demo stop                     # Save and stop BEFORE logging out/rebooting
```

The LaunchAgent is installed for the **next graphical user login**. It restores
the latest completed checkpoint and starts the demo. This is **not pre-login
boot startup or a guaranteed host-shutdown hook**. Run `stop` or `service backup`
before restarting the Mac; otherwise changes since the last checkpoint may be
lost. macOS can terminate jobs during logout/shutdown.

While enabled, `start` / `restart` checkpoint a running demo before restore/start.
Starting from stopped disks intentionally restores the latest checkpoint.
Failed same-boot checkpoints block rollback until an explicit checkpoint retry.
Partial restores must be retried before another checkpoint can be saved.

Files and logs live under `~/Library/Application Support/aap-demo/`; the
LaunchAgent is `~/Library/LaunchAgents/com.aap-demo.recovery.plist`.
Backups include CRC state/cache, raw disk, managed Fleet overlays, demo settings,
keys and the standard Vault/password files. They are private to your account,
**contain credentials and are not separately encrypted**. Use FileVault and keep
space for full copies. Same-account, same-path recovery only; keep CRC versions
consistent. External shared directories and old hyperkit layouts are refused.

```bash
aap-demo service disable          # Checkpoint, stop, remove login agent
```

Read [native recovery details](docs/state-service.md#macos-and-windows-login-recovery).

## Feature limits and troubleshooting

- The separate persistent CRI-O image disk is **Linux/libvirt only**. Use
  the local OCI cache workflow on macOS instead.
- Fleet requires native QEMU and an architecture-compatible RHEL image:
  `brew install qemu cdrtools`. Do not assume x86 guests run with ARM acceleration.
- Some operators/images, including portal-operator, are AMD64-only. Check addon
  documentation before enabling them on Apple Silicon.
- If `kubectl` tries `localhost:8080`, set the kubeconfig export above.
- Use `aap-demo diagnose` for image pulls, resource shortages and DNS.
- Native macOS VM/launchd recovery still needs a real Mac lifecycle validation;
  isolated tests are not proof of end-to-end VM recovery.

See also [Linux](Linux_Quickstart.md), [Windows](Windows_Quickstart.md), and
[WSL](WSL_Quickstart.md).
