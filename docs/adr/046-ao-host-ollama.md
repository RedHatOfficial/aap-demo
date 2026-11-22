# ADR-046: AO Uses the Host's Ollama

**Status**: Accepted

**Date**: 2026-11-20 (Updated: 2026-11-22: step 7 dropped, opt-out added, Bash and PowerShell moved)

**Authors**: aap-demo maintainers

**Supersedes**: [ADR-024](024-ollama-addon.md)

**Extends**: [ADR-045](045-ao-on-python-command.md)

## Context

ADR-024 added an `ollama` addon that runs Ollama as a CPU-only pod inside the
OpenShift Local VM, and AO's default LLM provider (`ollama`) installs it. That
design has these costs:

- **No GPU.** The VM has none, so inference runs on a few virtual CPUs. On a Mac,
  Ollama on the host uses the GPU through Metal and runs several times faster.
- **VM resources.** The pod requests 2 GiB of memory and 200m CPU, with limits of
  8 GiB and 4 CPUs, inside the same VM as AAP (#204). The models need a 10 GiB PVC.
- **Downloads on every cluster.** The image comes from `docker.io`, which rate-limits
  anonymous pulls, and the model (about 2 GB) is pulled again on every new cluster.
- **A hidden prompt.** The Bash installer asks for a PVC size when stdin is a
  terminal. The Python command reads the script's output one line at a time, so the
  prompt never shows, and the install appears to hang.
- **Licensing.** AO's default model is `qwen2.5:3b`, which is under the Qwen Research
  License (non-commercial use only). ADR-024 named `phi4-mini`; the code drifted.
  A Red Hat demo tool should not pull a model with commercial-use limits by default.

ADR-024 never considered Ollama on the host. Its alternatives were cloud LLMs,
llama.cpp in a container, larger models and a shared namespace.

A test on macOS (CRC 2.64, MicroShift preset) found:

- With `host-network-access` unset (default `false`), neither the VM nor a pod can
  reach the host. Every address times out.
- With `host-network-access=true`, a pod reaches the host's Ollama at
  `192.168.127.254:11434` (`/api/version`, `/v1/chat/completions`). Ollama listens
  only on `127.0.0.1` and needs no change.
- `host.crc.testing` resolves on the VM node but not inside pods.
- Changing `host-network-access` on an existing VM requires `crc cleanup`, which
  deletes the VM.
- With the URL on AO's integration allow-list and `allow_http` set, AO creates
  the LLM integration, lists the host's models and binds the demo workflows to the
  chosen one. The `external` provider today does neither, so it cannot reach an
  HTTP endpoint or a host outside aap-demo's routes.

## Decision

### Ollama runs on the host

The `ollama` provider means an Ollama server that the user runs on the host. aap-demo
does not install Ollama and does not pull models. The user installs Ollama, chooses
a model, pulls it and accepts its license.

`ollama` stays the default provider. `external` and `none` are unchanged.

### `enable ao` with the `ollama` provider

1. Check `http://127.0.0.1:11434/api/version` on the host. If Ollama is not running,
   stop with instructions: install it from ollama.com (or `brew install ollama` on
   macOS), start it, pull a model, rerun `aap-demo enable ao`, or choose the
   `external` or `none` provider.
2. Choose the model:
   - `OLLAMA_MODEL` sets it. Otherwise the model an earlier run chose, kept in
     `addons.options.ao.ollama_model` (not `llm_model`, which belongs to `external`).
   - If none is set and the host has exactly one model, use it.
   - If it has several, ask in an interactive run. A non-interactive run stops with
     the list and how to set one.
   - If it has none, stop with the `ollama pull` instruction.
   - If the chosen model is not on the host, stop. Do not pull it.
3. Check the model's `capabilities` from `/api/show` and warn if `tools` is missing,
   since AO's agents call tools. Older Ollama releases do not report capabilities; in
   that case warn that the check was skipped.
4. Check from a short-lived pod that the cluster reaches the host's Ollama before
   wiring AO, and stop with the cause if it does not.
5. Wire AO's LLM integration to `http://192.168.127.254:11434/v1`, an IP rather than
   `host.crc.testing` because pods cannot resolve that name. `AO_LLM_BASE_URL`
   overrides it.
6. Add the LLM URL's host to AO's integration allow-list
   (`APP_INTEGRATION_URL_ALLOWED_HOSTS`), and set the integration's `allow_http` from
   the URL's scheme. Both apply to `external` too, which today allows neither.
7. ~~Limit AO's egress to the host with a NetworkPolicy.~~ Dropped during
   implementation. The AO operator already applies a default-deny policy and gives
   its backend and worker pods, the ones that call the LLM, an allow-all egress rule
   (`egress: [{}]`). NetworkPolicies only add allows, so no policy can narrow those
   pods, and a broad one would open egress for the pods the operator restricts.
   MicroShift has no EgressFirewall or AdminNetworkPolicy to deny instead.

### CRC host network access

`aap-demo create` sets `host-network-access=true` before the VM exists, on macOS and
Windows, where CRC uses user-mode networking. `AAP_DEMO_HOST_NETWORK_ACCESS=false`
(or `0`, `no`, `off`) sets it to `false` instead, for users who cannot accept the
host exposure below; the `ollama` provider then cannot reach the host.

For an existing VM without it, `enable ao` explains that the setting needs a new VM
(`aap-demo destroy`, then `aap-demo create`) and stops. aap-demo never runs
`crc cleanup` itself.

On Linux, CRC uses libvirt networking and has no `host-network-access`. The host is
reachable at the libvirt bridge address, and Ollama must listen there
(`OLLAMA_HOST`). This path needs its own test before it is documented. Until then,
Linux users choose `external` with their own URL.

### The `ollama` addon is removed

- `enable ao` no longer installs anything for the LLM.
- The `ollama` addon is removed from the Python command, along with
  `addons/ollama/`'s installer and manifest, its tests and its Bash and PowerShell
  wiring.
- The Bash (`aap-demo-v1`) and PowerShell paths use the host's Ollama too, with the
  same checks: Ollama answers, a pulled model is chosen and saved as `OLLAMA_MODEL`
  in `~/.aap-demo/config`, and a pod reaches the host. Their `create` sets
  `host-network-access` the same way, and `ao-pr-testing` loads the model on the
  host before reviews.
- `aap-demo disable ollama` stays for one release, as cleanup only. It deletes the
  `aap-demo-ollama` namespace and the `aap-demo-ollama-anyuid` ClusterRoleBinding.
  `enable ao` points to it when it finds that namespace.
- `qwen2.5:3b` is removed as a default everywhere. No model is a default.

### Documentation

The AO guide lists a few suggested models with their license names, as suggestions
only, and explains how to pull one.

## Consequences

### Positive

- **Speed.** Host Ollama uses the GPU on Apple silicon instead of CPU in the VM.
- **Smaller VM footprint.** No Ollama pod, PVC or image in the VM. AO competes less
  with AAP for memory and CPU.
- **No `docker.io`.** Nothing pulls the Ollama image.
- **No licensing exposure.** aap-demo never chooses or downloads a model.
- **Models survive clusters.** They live on the host, so `destroy` and `create` do
  not download them again.
- **No hidden prompt.** The Bash installer that hangs is gone.
- **Less code.** The `ollama` addon, its manifest, tests and wiring go away.

### Negative

- **One more prerequisite.** Users must install Ollama and pull a model before the
  default provider works.
- **Existing clusters need a new VM** to get `host-network-access`, unless they
  switch to `external`.
- **Breaking change.** `aap-demo enable ollama` stops working on every path. Users
  with the `ollama` provider install Ollama on the host and pull a model, or move
  to `external`.
- **Linux and Windows are not yet tested** for host access.
- **Host memory.** A large model uses host memory instead of VM memory.
- **Host services are reachable from the VM.** `host-network-access` lets every pod
  in the VM, including AAP job pods that run playbooks, connect to any service on the
  host's `127.0.0.1`, not just Ollama. aap-demo is a local development tool, and the
  user's own playbooks already run with their credentials, but users who run other
  local services should know. `aap-demo create`
  and the AO guide say so, and `AAP_DEMO_HOST_NETWORK_ACCESS=false`
  opts out. aap-demo cannot narrow this with a NetworkPolicy (step 7).

### Neutral

- The `external` and `none` providers are unchanged.
- AO's wiring to an OpenAI-compatible `/v1` endpoint is unchanged; only the URL and
  model source change.

## Alternatives Considered

### 1. Keep the in-cluster addon and port it to Python

A native addon with no prompts, streamed pull progress, preflight checks, an image
built from the Ollama release binary on UBI, and permissively licensed models.

**Why not chosen**: Fixes the reliability problems but keeps the CPU-only inference,
the VM footprint and the per-cluster downloads. Host Ollama removes them.

### 2. Detect host Ollama, and offer to install it when missing

**Why not chosen**: Installing software on the user's machine adds per-OS installer
logic and support load, for a one-line step the user can run. aap-demo prints the
instruction instead.

### 3. A default model with a permissive license (Granite, phi4-mini)

**Why not chosen**: Any default makes aap-demo choose and download a model for the
user. Letting the user choose keeps aap-demo out of model licensing entirely.

### 4. `host.crc.testing` as the URL

**Why not chosen**: Pods cannot resolve it. A CoreDNS entry could fix that, but the
IP works with no DNS change.

### 5. Make Ollama listen on all interfaces

**Why not chosen**: Not needed on macOS with `host-network-access`, and it exposes
Ollama to the local network.

## References

- [ADR-024: Ollama Addon](024-ollama-addon.md) — superseded by this ADR
- [ADR-045: Automation Orchestrator on the Python Command](045-ao-on-python-command.md)
- [ADR-040: Shared Addon Framework and Bash Fallback](040-addon-framework-and-bash-fallback.md)
- [#204](https://github.com/RedHatOfficial/aap-demo/issues/204) — Ollama CPU request kept the pod Pending beside AAP
- [#144](https://github.com/RedHatOfficial/aap-demo/issues/144) — Ollama rollout ProgressDeadlineExceeded
- [Qwen2.5-3B license](https://huggingface.co/Qwen/Qwen2.5-3B/commits/main/LICENSE) — Qwen Research License
- [Ollama API](https://github.com/ollama/ollama/blob/main/docs/api.md) — `/api/version`, `/api/tags`, `/api/show`
