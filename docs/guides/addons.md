---
type: Guide
title: Add-ons
description: Fleet machines, product demos and Automation Orchestrator in the new command, and where the other extras still live.
tags: [addons, fleet, eda, ao]
status: draft
stale_after: 2027-01-28
resource: https://github.com/RedHatOfficial/aap-demo
---

# Add-ons

Add-ons are optional extras on top of AAP: a self-service portal, demo job templates, a local model, and practice machines.

## Practice machines (Fleet)

The new command can add small Linux machines that show up as hosts in AAP. They run inside the same local cluster.

```bash
aap-demo enable fleet
aap-demo fleet list
aap-demo fleet add --os ubi9
aap-demo fleet remove fleet-ubi9
aap-demo disable fleet
aap-demo fleet destroy
```

`enable fleet` creates two machines by default, `fleet-ubi9` and `fleet-ubi10`, and registers them in AAP.
Registering needs a [subscription](subscription.md) in AAP. Without one, use `aap-demo enable fleet --no-import`.
Add `--no-import` if you want the machines without that registration.

`disable fleet` turns the machines off and leaves the registration in place. `fleet destroy` removes both.

### Reboots and services

Each machine runs systemd, so `sudo reboot`, `systemctl`, and the `service` and `systemd_service` modules work.
A reboot restarts the machine's container, usually within two minutes. Installed packages, `/etc`, and enabled
services are still there afterward.

`ansible.builtin.reboot` needs one extra option. The machines share the cluster's kernel, so the boot ID the module
checks by default never changes, and the module waits until it times out:

```yaml
- name: Reboot a Fleet machine
  ansible.builtin.reboot:
    boot_time_command: cut -d' ' -f22 /proc/1/stat
```

Packages that set file capabilities, such as `httpd`, do not install on these machines.

## Product demos

`aap-demo enable product-demos` installs the Ansible product demos into the AAP you already deployed.
The command needs `bash`, `curl`, and `jq`. On a Mac, `brew install jq` supplies jq when it is missing.

The install clones the demo repository, syncs a project in AAP, and launches one job per domain:
Linux, Windows, network, cloud, and OpenShift. That can take a while. Satellite stays out of this set
until you ask for it:

```bash
aap-demo enable product-demo-satellite
```

A smaller set:

```bash
PRODUCT_DEMOS_DOMAINS="linux cloud" aap-demo enable product-demos
```

One domain uses the same installer under its own name, for example `aap-demo enable product-demo-linux`.

`aap-demo disable product-demos` drops the addon from this computer's settings. The job templates stay
in AAP until you delete them in the UI.

The cluster still wants about 8 processors and 24 GB of memory. Demo jobs add work on top of AAP.

## EDA Playground (experimental)

`aap-demo enable eda-playground` runs the existing Bash deployment backend
through the Python addon framework. It needs `bash`, `curl`, `jq`, `kubectl`,
and a running AAP demo cluster with Gateway and OpenShift Routes.

```bash
aap-demo enable eda-playground
kubectl get route eda-playground -n eda-playground
```

Open the Route and finish AAP OAuth login manually. The default image is an
experimental maintainer-hosted image; set `EDA_PLAYGROUND_IMAGE` to a reviewed
tag or digest when appropriate. This addon is not supported for production use.
The live smoke test waits for the browser check by default; use
`AAP_DEMO_LIVE_NONINTERACTIVE=true` for unattended validation, which reports
OAuth as unverified.

When the manual check is complete, remove the addon:

```bash
aap-demo disable eda-playground
```

## Automation Orchestrator

`aap-demo enable ao` installs Automation Orchestrator next to AAP and wires the two together. It runs the
same Bash installer as the older command, so it needs `bash`, `curl`, `jq`, `kubectl`, `base64`, and `python3`.
AO is not in the OpenShift 5 catalog yet, so it needs the default OpenShift 4 cluster.

```bash
aap-demo enable product-demos   # optional, before AO
aap-demo enable ao
```

AO needs two other add-ons, and `enable ao` installs them first when they are missing:

- `mcp-server`, the MCP server for AAP.
- `ollama`, a local model for AO's agentic demos.

AO links its workflows to the product demos' job templates when it installs. When no product demos are
enabled, `enable ao` says so and carries on. Enable them and run `aap-demo enable ao` again to link them later.

The new command does not ask which model to use. Set `AO_LLM_PROVIDER` instead:

| `AO_LLM_PROVIDER` | Model |
|---|---|
| `ollama` (default) | The local `ollama` add-on |
| `external` | An OpenAI-compatible service (see below) |
| `none` | No model. The agentic demos are unavailable |

For `external`, set `AO_LLM_BASE_URL` and `AO_LLM_MODEL`, and put the API key in `~/.aap-demo/ao/llm-api-key`.

To reinstall AO, run `aap-demo enable ao --force`. To remove it:

```bash
aap-demo disable ao
AO_PURGE_DATA=1 aap-demo disable ao   # also remove its database and saved admin password
```

`disable ao` leaves `mcp-server` and `ollama` installed. Disable them by name.

## Everything else

Portal, a local cache of container images, and the other extras are not in the new command yet.
Asking the new command for one of them stops with a short error, and your cluster is left as it was.

Use [the older command](older-command.md) for those. For example, after you have renamed it:

```bash
aap-demo-v1 enable portal
```

Each of those extras will move to the new command on its own. Until a page says otherwise, the older command
is the way to install them. Nothing you already run with the older command is being removed in this release candidate.

### EDA Playground (experimental)

Use the legacy Bash command on macOS or Linux. You need a running AAP demo
cluster, a working `kubectl` connection, AAP Gateway, and OpenShift Routes.
The Python command and native Windows support are deferred.

```bash
aap-demo-v1 enable eda-playground
kubectl get route eda-playground -n eda-playground
```

If the Bash command still has the `aap-demo` name, use that name instead of
`aap-demo-v1`. Open the Route in a browser and finish AAP OAuth login manually.
When the manual check is complete, remove the addon:

```bash
aap-demo-v1 disable eda-playground
```

The disposable-cluster smoke test waits for this browser check by default:

```bash
AAP_DEMO_RUN_LIVE_TESTS=true bash test/test-eda-playground-live.sh
```

For unattended validation, add `AAP_DEMO_LIVE_NONINTERACTIVE=true`. The harness
then skips the wait and clearly reports OAuth as unverified.

The addon creates the Gateway OAuth application and removes its owned
application and namespace during cleanup. Retry disable if cleanup reports an
error.

The default image is an experimental image in a maintainer's personal GHCR
namespace. Review it or set `EDA_PLAYGROUND_IMAGE` to a reviewed tag or digest.
This addon is not supported for production use. See the
[addon README](../../addons/eda-playground/README.md) for configuration and
limitations.
