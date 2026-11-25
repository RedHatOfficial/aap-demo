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

Add-ons are optional extras on top of AAP: monitoring, a self-service portal, demo job
templates, a local model, and practice machines.

## Monitoring

The Python command can install a small, AAP-focused Prometheus and Grafana stack:

```bash
aap-demo enable monitoring
aap-demo status monitoring
aap-demo disable monitoring
```

See the [monitoring guide](../monitoring.md) for dashboards, resource cost, and the
credential-file location. `prometheus` is accepted as an alias for `monitoring` by the
Python command.

## OPA Policy as Code

The Python v2 command can install Open Policy Agent and configure AAP Policy as Code:

```bash
aap-demo enable opa
aap-demo disable opa
```

Enable creates the OPA Deployment, Service, and Route, configures AAP's policy settings, and creates these job
templates: **OPA | Load Example Policies**, **OPA | Test Policies**, **OPA | Clear Policies**, and
**OPA | Demo Policy**. Launch **OPA | Load Example Policies** in AAP to load the upstream example policies.

The native command continues to accept `OPA_VERSION`, `OPA_REPO`, and `OPA_MANIFEST_REF`. It records the addon in
the Python `addons.enabled` setting only after enable finishes. To use the older shell implementation explicitly,
run `aap-demo-v1 enable opa`.

`aap-demo status` reports MCP Server as enabled when it is recorded in settings or when
its custom resource or deployment is detected in the AAP namespace. The label identifies
the source; it does not indicate readiness. Check the namespace's pod counts or run
`kubectl get deployment aap-mcp-server -n aap-operator` to check the deployment. If the
resource check fails, status reports MCP as unknown rather than disabled.
When enabling AO, the command reuses an existing MCP Server and records it in settings.
If it cannot check for an existing server, it stops and asks you to resolve access first.

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

Open the Route and finish AAP OAuth login manually. Set
`EDA_PLAYGROUND_IMAGE` to a reviewed immutable digest before enabling the addon;
mutable tags require the explicit `EDA_PLAYGROUND_ALLOW_UNPINNED_IMAGE=true`
override for disposable testing. This addon is not supported for production use.
The live smoke test waits for the browser check by default; use
`AAP_DEMO_LIVE_NONINTERACTIVE=true` for unattended validation, which reports
OAuth as unverified.

When the manual check is complete, remove the addon:

```bash
aap-demo disable eda-playground
```

## Automation Orchestrator

`aap-demo enable ao` installs Automation Orchestrator next to AAP and wires the two together. It is part
of the new command and needs only `kubectl`, so it does not need Bash ([ADR-045](../adr/045-ao-on-python-command.md)).
AO is not in the OpenShift 5 catalog yet, so it needs the default OpenShift 4 cluster.

An AO that the older command installed is adopted as it is, with its database and admin password. If its
database is still in CloudNativePG, AO keeps running on it; moving it to the new PostgreSQL needs
`aap-demo enable ao --force`, which deletes AO's data.

```bash
aap-demo enable product-demos   # optional, before AO
aap-demo enable ao
```

AO needs the `mcp-server` add-on, the MCP server for AAP, and `enable ao` installs it first when it is
missing.

AO links its workflows to the product demos' job templates when it installs. When no product demos are
enabled, `enable ao` says so and carries on. Enable them and run `aap-demo enable ao` again to link them later.

Set `AO_LLM_PROVIDER` to choose the model AO's agentic demos use:

| `AO_LLM_PROVIDER` | Model |
|---|---|
| `ollama` (default) | Ollama running on this machine (see below) |
| `external` | An OpenAI-compatible service (see below) |
| `none` | No model. The agentic demos are unavailable |

For `external`, set `AO_LLM_BASE_URL` and `AO_LLM_MODEL`, and set `AO_LLM_API_KEY` once. The key is kept in
the new command's state directory for later runs. A key or settings the older command saved are picked up.
An `http://` URL is allowed, and the URL's host is added to AO's integration allow-list.

### Ollama on this machine

AO uses Ollama running on the host, not in the cluster, so it can use the Mac's GPU and keep the VM small
([ADR-046](../adr/046-ao-host-ollama.md)). aap-demo does not install Ollama or download models. You choose
a model and accept its license.

1. Install Ollama from [ollama.com](https://ollama.com/download), or `brew install ollama` on macOS, and
   start it.
2. Pull a model that supports tools, which AO's agents call. Some choices:

   | Model | License |
   |---|---|
   | `granite3.3:8b` | Apache 2.0 |
   | `qwen3:8b` | Apache 2.0 |
   | `llama3.1:8b` | Llama 3.1 Community License |

   ```bash
   ollama pull granite3.3:8b
   ```

3. Run `aap-demo enable ao`.

`enable ao` checks that Ollama answers on `127.0.0.1:11434` and that the cluster reaches it before it
installs anything. With one model pulled, it uses that one. With several, it asks in a terminal, or set
`OLLAMA_MODEL`. The choice is saved for later runs; set `OLLAMA_MODEL` again to change it. It warns when the
model does not list tool support.

Pods reach the host through CRC's `host-network-access`, which `aap-demo create` turns on for a new VM on
macOS and Windows. A VM created before this needs `aap-demo destroy`, then `aap-demo create`. With it on,
pods in the VM can reach any service that listens on the host's `127.0.0.1`, not only Ollama. To create
the VM without it, run `AAP_DEMO_HOST_NETWORK_ACCESS=false aap-demo create`; the `ollama` provider then
cannot reach the host, so use `external`. On Linux, CRC
has no such setting: make Ollama listen on the libvirt bridge (`OLLAMA_HOST`) and set `AO_LLM_BASE_URL` to
that address with `/v1`, or use `external`.

Earlier releases ran Ollama in the cluster. `aap-demo disable ollama` removes that install.

To reinstall AO, run `aap-demo enable ao --force`. To remove it:

```bash
aap-demo disable ao
AO_PURGE_DATA=1 aap-demo disable ao   # also remove its database and saved admin password
```

`disable ao` leaves `mcp-server` installed. Disable it by name.

## Local image cache

The native command can save and reload CRC's OCI image cache. Save and load need a running cluster;
`validate`, `clear`, and `disable` are host-only and still work after the cluster is removed.

```bash
aap-demo enable local-cache          # save images from the running cluster
aap-demo enable local-cache load     # load the cache into a fresh cluster
aap-demo enable local-cache validate
aap-demo enable local-cache clear   # one-shot clear; keeps the enabled setting
aap-demo disable local-cache        # clear and remove the enabled setting
```

The cache is stored per configured CRC preset under `~/.aap-demo/local-cache/`. See the
[local-cache README](../../addons/local-cache/README.md) and [ADR-021](../adr/021-local-cache-addon.md)
for the cache format, catalog pinning, and rewrite behavior.

## Everything else

Portal and the other extras are not in the new command yet.
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

The image is experimental and hosted in a maintainer's personal GHCR namespace.
Set `EDA_PLAYGROUND_IMAGE` to a reviewed immutable digest; mutable tags require
the explicit `EDA_PLAYGROUND_ALLOW_UNPINNED_IMAGE=true` override for disposable
testing. This addon is not supported for production use. See the
[addon README](../../addons/eda-playground/README.md) for configuration and
limitations.
