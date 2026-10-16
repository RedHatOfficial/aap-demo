# ADR-032: Fleet v2 addon

**Status**: Accepted

**Date**: 2026-10-15

**Authors**: Adam Knochowski

## Context

Issue #196 asked whether fleet nodes would be writable. The bash addon under `addons/fleet/` builds QEMU VMs. v2 needs a first Python addon without taking that path.

## Decision

v2 fleet nodes are pods in namespace `fleet`, one per distro, SSH as user `ansible`. The namespace is the Ansible variable `namespace` (default `fleet`, overridable in extra-vars or `addons.options.fleet.namespace`). Writable means the container root filesystem, for the life of the pod. KubeVirt and QEMU are out of v2. The bash addon under `addons/fleet/` is untouched and is not the implementation. AAP objects are created by `import.yml` using `ansible.controller` against the gateway, with `ansible.platform` installed beside it. The packaged playbooks ship inside `aap_demo.addons.fleet`, not in `aap-demo-playbooks`.

## Consequences

### Positive

- One variable moves the namespace, the DNS name, and the SCC subject together.
- The root filesystem is writable without a PVC.

### Negative

- Deleting the pod discards the writable layer.
- ADR-026 still describes the bash QEMU fleet. This record does not replace it.

### Neutral

- Controller inventory, credential, and project stay named `aap-demo-fleet`.

## Alternatives Considered

- Namespace `aap-demo-fleet`, hardcoded in the playbooks. Rejected so the name can change without editing templates.
- KubeVirt or QEMU. Out of v2.

## References

- Issue #196
- ADR-026 (bash fleet)
