# ADR-045: Persistent CRC Startup and Guest Kubeconfig Refresh

## Status

Accepted

## Context

The CRC MicroShift backend starts `vfkit` as part of `crc start`. When that
command is launched by a transient agent command runner, the runner can reap
the vfkit child after the command returns. CRC then reports a running or
partially started VM while SSH and the Kubernetes API become unavailable.

Separately, the kubeconfig under `~/.crc/machines/crc/kubeconfig` can retain
stale external-signer certificate data after a MicroShift reset or restart.
Using it for normal aap-demo operations produces an unknown-authority error
even when the guest API is healthy.

## Decision

The `aap-demo start` command starts CRC through a persistent tmux session when
tmux is available. The session remains alive after `crc start` returns so the
vfkit process is not owned by a transient agent command. `aap-demo stop` and
`aap-demo destroy` release that session after stopping CRC.

The aap-demo command path refreshes the kubeconfig from the running guest and
uses `~/.aap-demo/kubeconfig.microshift` as the authoritative local
kubeconfig. The CRC machine kubeconfig is retained only for low-level CRC
diagnostics and is not treated as authoritative after a reset or restart.

The workflow verifies both API readiness and node readiness before declaring
the local cluster usable:

```bash
kubectl get --raw=/readyz
kubectl get nodes
```

## Consequences

### Positive

- `aap-demo start` survives transient agent command cleanup.
- Kubeconfig certificate rotation is handled through the supported guest
  kubeconfig rather than by destructive VM resets.
- Stop and destroy clean up the persistent session.

### Negative

- macOS and Linux hosts with tmux keep one named session while CRC is running.
- Startup logs are written to the temporary directory for troubleshooting.
- Hosts without tmux use the existing direct-start fallback and should launch
  CRC from a persistent terminal or equivalent service manager.

## Alternatives Considered

### Raw `crc start` from the agent command runner

Rejected because the transient runner can terminate vfkit when the command
returns.

### Treating the CRC machine kubeconfig as authoritative

Rejected because it can contain stale external-signer CA data after a
MicroShift restart.

### Resetting the VM whenever the API reports unknown authority

Rejected because refreshing the guest-issued kubeconfig resolves the problem
without destroying cluster state.
