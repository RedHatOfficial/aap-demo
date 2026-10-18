# ADR-032: Fleet v2 addon

**Status**: Accepted

**Date**: 2026-10-15

**Authors**: Adam Knochowski

## Context

Issue #196 asked whether fleet nodes would be writable. The bash addon under `addons/fleet/` builds QEMU VMs. v2 needs a first Python addon without taking that path.

## Decision

v2 fleet nodes are pods in namespace `fleet`, one per distro, SSH as user `ansible`.
The namespace is the Ansible variable `namespace` (default `fleet`).
Extra-vars or `addons.options.fleet.namespace` override it.

Each node has a PersistentVolumeClaim.
An init container copies `/usr` and `/var` onto that disk once.
The pod then mounts those paths, so a package update survives a new pod.
`disk_size` defaults to `2Gi`.
`storage_class` is empty unless set.
An empty value leaves `storageClassName` off the claim so the cluster default is used.
Both are extra-vars, and both can be set under `addons.options.fleet`.
`/etc` stays on the image so the pod keeps cluster DNS.

Deployment replicas are kept as YAML integer literals. The AAP execution
environment serializes a Jinja-templated numeric value as a string, which
Kubernetes rejects for `Deployment.spec.replicas`. The `disable` path does
not apply that Deployment again. It scales the existing Deployments to zero
with `kubernetes.core.k8s_scale`.

KubeVirt and QEMU are out of v2.
The bash addon under `addons/fleet/` is untouched and is not the implementation.
AAP objects are created by `import.yml` using `ansible.controller` against the gateway,
with `ansible.platform` installed beside it.
Those playbooks run as a Kubernetes Job using the `ee-supported` image already
running in the cluster. The laptop does not install ansible-core or collections.
The Job's service account can manage the fleet namespace and bind anyuid
to the fleet-node account. It is not cluster-admin.
Certificate checks stay on unless addons.options.fleet.validate_certs is false.
The fleet SSH key is a Secret in the AAP namespace, not a keychain item.
The packaged playbooks ship inside `aap_demo.addons.fleet`, not in `aap-demo-playbooks`.

## Consequences

### Positive

- One variable moves the namespace, the DNS name, and the SCC subject together.
- Package files under `/usr` and `/var` survive `disable` and `enable`.
- `disk_size` and `storage_class` change the claim without editing the playbook.
- Enable creates schema-valid Deployments, and disable preserves the pods' disks while scaling them to zero.

### Negative

- `aap-demo disable fleet` stops the pods by setting replicas to 0.
  The namespace, the disks, and the AAP inventory stay.
- `aap-demo fleet destroy` deletes Controller objects first, then the namespace.
  Deleting the namespace deletes the disks.
- `/etc` is rebuilt on each start (sudoers, host keys). Cluster DNS stays intact.
- The default disk is 2Gi. A large update needs a larger `disk_size` before the first create.
- ADR-026 still describes the bash QEMU fleet. This record does not replace it.

### Neutral

- Controller inventory, credential, and project stay named `aap-demo-fleet`.

### Validation

- Fleet unit tests cover the literal replica field and scale-to-zero task.
- The three-node Fleet deployment was exercised on MicroShift/CRC; all node pods became Ready.

## Alternatives Considered

- Namespace `aap-demo-fleet`, hardcoded in the playbooks. Rejected so the name can change without editing templates.
- KubeVirt or QEMU. Out of v2.

## References

- Issue #196
- ADR-026 (bash fleet)
