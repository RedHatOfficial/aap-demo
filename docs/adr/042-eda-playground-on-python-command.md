# ADR-041: EDA Playground on the Python Command

**Status**: Accepted

**Date**: 2026-11-10

**Authors**: aap-demo maintainers

**Extends**: [ADR-040](040-addon-framework-and-bash-fallback.md)

## Context

The EDA Playground addon was developed against the legacy Bash dispatcher in
PR 333. ADR-040 defines one registry and a shared shell fallback for addons
that have not yet been ported natively.

EDA Playground has addon-specific OAuth ownership state and cleanup behavior.
It must not use product-demos credential wiring or the legacy config file.

## Decision

Register EDA Playground as a public `legacy` `ShellAddon`. The existing
`addons/eda-playground/deploy.sh` remains the deployment backend.

The Python adapter passes the Python command's kubeconfig and AAP namespace,
stores OAuth state below the Python state directory, records the addon in
`config.yaml` under `addons.enabled`, runs no product-demos wiring, and checks
the tools needed by both enable and cleanup before invoking Bash.

The legacy Bash command continues to expose the addon for compatibility. The
Python and Bash commands share the deployment script but not config files.

## Consequences

EDA Playground works through `aap-demo enable/disable` without duplicating its
Kubernetes and OAuth implementation in Python. The Python release still
requires Bash, curl, jq, kubectl, and base64 for this legacy addon. A future
native port can replace the registry entry while retaining the same name and
state contract.

## Alternatives Considered

### Rewrite the deployment script in Python now

Rejected for this change. The existing script contains substantial OAuth
ownership and failure-recovery behavior covered by focused shell tests. The
shared legacy boundary allows the CLI migration without forking that behavior.

### Keep EDA Playground on `aap-demo-v1`

Rejected because it leaves the addon outside the Python registry and requires
two command names and state systems.
