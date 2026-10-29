# AAP Demo Quick Start

**Python beta, `2.0.0.dev1`.** This is the line in the `v2` → `main` cutover. It is not stable `2.0.0`. The bash release on today's `main` stays until that cutover, and `aap-demo.sh` stays in the tree until Phase 8.

Deploy Ansible Automation Platform 2.7 to a local MicroShift cluster.

## SECURITY NOTICE — DEVELOPMENT ENVIRONMENT ONLY

**aap-demo is a local development tool and must never be used in production.**

Install paths for both lines are in [docs/v2-to-main.md](docs/v2-to-main.md).

## Install the Python beta

Python 3.9 or newer. [pipx](https://pipx.pypa.io/) keeps the command isolated:

```bash
pipx install aap-demo
aap-demo update
aap-demo version
```

`pip install aap-demo` and `uv tool install aap-demo` install the same published beta. `pip` does not select a `.dev` release on every configuration. If it reports no matching version:

```bash
pip install 'aap-demo==2.0.0.dev1'
```

State lives under `~/.local/state/aap-demo`, not `~/.aap-demo`. A checkout is only for changing the code. `./install.sh` still links `~/.local/bin/aap-demo` to `aap-demo.sh`, so move that bash command before pipx or the bash launcher wins:

```bash
mv ~/.local/bin/aap-demo ~/.local/bin/aap-demo-v1
pipx install aap-demo
```

If a bash `aap-demo` is still earlier on `PATH`, the first Python command asks whether to uninstall it or rename it to `aap-demo-v1`. `AAP_DEMO_KEEP_BASH=1` skips that prompt.

### Bash release, until Phase 8

Today's `main` installs from a checkout:

```bash
git clone https://github.com/RedHatOfficial/aap-demo.git
cd aap-demo
./install.sh
mkdir -p ~/.aap-demo
cp ~/Downloads/pull-secret.txt ~/.aap-demo/pull-secret.txt
```

That kubeconfig is `~/.aap-demo/kubeconfig.microshift` and is not merged into `~/.kube/config`. `aap-demo update` on that line is `git pull` plus `./install.sh`. Bash `enable fleet` is the QEMU addon. Details and the Phase 8 boundary are in [docs/v2-to-main.md](docs/v2-to-main.md).

## Pull secret and kubeconfig

Download a pull secret from the [Red Hat console](https://console.redhat.com/openshift/install/pull-secret).

```bash
mkdir -p ~/.local/state/aap-demo
cp ~/Downloads/pull-secret.txt ~/.local/state/aap-demo/pull-secret.txt
```

`pull-secret.json` in that directory is accepted second. `~/.aap-demo` is not searched. `aap-demo config set pull-secret ~/path/to/pull-secret.txt` stores another path.

`aap-demo create` saves the cluster kubeconfig at `~/.local/state/aap-demo/kubeconfig.microshift` and installs an `aap-demo` context into `~/.kube/config`. That context becomes current. Other contexts stay. `aap-demo kubeconfig` refreshes both files.

```bash
aap-demo oc get nodes
export KUBECONFIG=~/.local/state/aap-demo/kubeconfig.microshift
```

## Prerequisites

- **OpenShift Local (`crc`)** — [Download](https://console.redhat.com/openshift/create/local)
- **kubectl**
- **Linux:** `libvirt-daemon`, `libvirt-daemon-driver-storage`, `qemu-kvm`. Start `crc daemon` when `~/.crc/crc-http.sock` is missing.

The Python schema defaults are 8 vCPUs, 24576 MB of memory, a 120 GB disk, and a 100 GB PV pool. `create` warns when the host has fewer than 4 CPUs or 10 GB of RAM. Override before the VM exists:

```bash
aap-demo create --cpus 8 --memory 24576 --disk 120 --pv-size 100
```

`--preset openshift` is refused. This beta provisions MicroShift only.

## Create and deploy

```bash
aap-demo create     # MicroShift VM only
aap-demo deploy     # OLM and the AAP operator. Default channel is stable-2.7.
aap-demo status     # Routes and the admin password
```

`--channel` selects the OLM subscription channel. Use it to try another AAP release:

```bash
aap-demo deploy --channel stable-2.6
```

The value is any channel string the operator catalog publishes. The default is `stable-2.7`. Save one so later deploys keep it:

```bash
aap-demo config set deploy.channel stable-2.6
```

`deploy` does not install addons and does not load a saved image cache.

## Fleet

`fleet` is the only addon the Python command implements. It runs Kubernetes-native pods in the `fleet` namespace. The default nodes are `fleet-ubi9` and `fleet-ubi10`.

```bash
aap-demo enable              # prints: fleet
aap-demo enable fleet        # --no-import skips AAP registration
aap-demo fleet list
aap-demo fleet add --os ubi9
aap-demo fleet remove fleet-ubi9
aap-demo disable fleet       # scales the pods to 0
aap-demo fleet destroy
```

Any other name, including `portal`, `ao`, `mcp-server`, and `local-cache`, raises `unknown addon '...'; only fleet is implemented`.

Those addons still install from the bash command (`aap-demo-v1` or `aap-demo.sh`). Bash `enable fleet` stays the QEMU addon unless the command passes `--backend kube-native`.

## Commands

```bash
aap-demo start
aap-demo stop
aap-demo idle true           # scale AAP down; the VM keeps running
aap-demo idle false
aap-demo ssh
aap-demo watch
aap-demo diagnose            # exit 1 only when the API cannot be reached
aap-demo diagnose --ai       # requires the claude CLI
aap-demo must-gather
aap-demo repair
aap-demo clean               # remove AAP, keep the VM
aap-demo destroy             # delete the VM. --reset also clears config.yaml
aap-demo redeploy            # clean, then deploy
aap-demo update              # pipx upgrade aap-demo
aap-demo version             # 2.0.0.dev1
```

`redeploy-all`, `addon`, `playbooks`, `gui`, and `completion` are accepted and exit not implemented. Use the bash command for those until they are ported. Removing the bash tree is Phase 8, not this cutover.

## Environment

```bash
CRC_CPUS=8                   # default 8
CRC_MEMORY=24576             # MiB, default 24576
CRC_DISK=120                 # GiB, default 120
CRC_PV_SIZE=100              # GiB, default 100
NAMESPACE=aap-operator       # legacy name of AAP_DEMO_NAMESPACE
QUIET=true
```

Config file: `~/.config/aap-demo/config.yaml`. `AAP_DEMO_DIR` collapses config, state, and cache under one directory. That is the escape hatch for CI, not the path for a normal install.

## Clean up

```bash
aap-demo clean
aap-demo destroy
pipx uninstall aap-demo
```

## Documentation

- **[v2 to main](docs/v2-to-main.md)** — bash `main` and Python beta install paths for the cutover
- **[Architecture decision records](docs/adr/)** — design history
- **[Contributing](docs/CONTRIBUTING.md)**
