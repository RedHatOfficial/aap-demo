# ADR-032: Fleet v2 addon

**Status**: Accepted

**Date**: 2026-10-15

**Authors**: Adam Knochowski

## Context

Issue #196 asked whether fleet nodes would be writable. The Bash addon under
`addons/fleet/` builds QEMU VMs, while v2 needs a first Python addon without
taking that path. During the transition, both command implementations must be
available without making the lifecycle verb ambiguous.

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
The Bash addon under `addons/fleet/` remains the v1 QEMU implementation and is
not the v2 implementation. The Python addon is the canonical v2 implementation.

Fleet follows the addon lifecycle: `enable fleet` deploys or enables the Fleet
resources, and `fleet list|add|remove|destroy` performs day-two operations.
`deploy` remains the AAP platform deployment command; it is not the Fleet v2
entrypoint.

The canonical Python v2 commands are:

```text
aap-demo enable fleet
aap-demo fleet list
```

The Bash wrapper exposes the same lifecycle in two explicit forms:

```text
aap-demo.sh v2 enable fleet
aap-demo.sh enable fleet --backend kube-native
```

`aap-demo.sh enable fleet --backend qemu` (and the existing default without a
backend) continues to use the Bash v1 implementation. The `v2` wrapper is a
runtime bridge, not a separate addon. `--backend all` is supported only for
read-only Fleet listing and is not valid for `enable`.

AAP objects are created by `import.yml` using `ansible.controller` against the gateway,
with `ansible.platform` installed beside it.
Those playbooks run as a Kubernetes Job using the `ee-supported-rhel` image
from the `aap-controller-ee` container already running in the cluster.
The laptop does not install ansible-core or collections.
The Job runs in `<namespace>-runner`, a second namespace this install creates.
Its service account lives there, away from the node pods, and can manage
only the fleet namespace. It is not cluster-admin and it cannot bind SCCs.
The operator kubeconfig creates an addon-owned `aap-demo-fleet` SCC and the
matching `system:openshift:scc:aap-demo-fleet` ClusterRole. A RoleBinding in
the Fleet namespace grants that role only to the `fleet-node` service account.
The SCC permits the `SYS_CHROOT` and `AUDIT_WRITE` capabilities required by
OpenSSH privilege separation and audit logging in the container, while
keeping privileged containers, host networking, host PID, host IPC, and host
ports disabled. It does not grant `anyuid` or any broad cluster role. The
runner Job itself never receives cluster-scoped rights.
Destroy removes the addon-owned SCC, ClusterRole, and namespace RoleBinding;
removing one node leaves them in place for the remaining nodes.
A token on each namespace is required before Fleet will use or delete it.
The gateway host is a route whose endpoints are pods of the AAP-owned
gateway deployment. A ReplicaSet outside that chain is ignored.
Certificate checks stay on unless addons.options.fleet.validate_certs is false.
The fleet SSH key is a Secret in the AAP namespace, not a keychain item.
Fleet generates RSA keys for compatibility with the UBI/OpenSSH crypto
policy and rotates addon-owned legacy Ed25519 keys. A public-key hash on the
node pod template forces a rollout when the key changes.
The packaged playbooks ship inside `aap_demo.addons.fleet`, not in `aap-demo-playbooks`.

## Consequences

### Positive

- One variable moves the namespace, the DNS name, and the SCC subject together.
- Package files under `/usr` and `/var` survive `disable` and `enable`.
- `disk_size` and `storage_class` change the claim without editing the playbook.
- Enable creates schema-valid Deployments, and disable preserves the pods' disks while scaling them to zero.
- The v2 lifecycle is available from the installed Python CLI and from the Bash
  wrapper, allowing gradual migration without renaming the addon.

### Negative

- `aap-demo disable fleet` stops the pods by setting replicas to 0.
  The namespace, the disks, and the AAP inventory stay.
- `aap-demo fleet destroy` deletes Controller objects first, then the namespace.
  Deleting the namespace deletes the disks.
- `/etc` is rebuilt on each start (sudoers, host keys). Cluster DNS stays intact.
- The default disk is 2Gi. A large update needs a larger `disk_size` before the first create.
- Users must choose the Python v2 or Bash v1 backend when both are available.
- ADR-026 describes the Bash QEMU fleet. This record does not replace it.

### Neutral

- Controller inventory, credential, and project stay named `aap-demo-fleet`.

### Validation

- Fleet unit tests cover the literal replica field and scale-to-zero task.
- The three-node Fleet deployment was exercised on MicroShift/CRC; all node pods became Ready.
- CLI tests cover the Python v2 lifecycle and the Bash backend bridge for both
  `v2 enable fleet` and `enable fleet --backend kube-native`.

## Alternatives Considered

- Namespace `aap-demo-fleet`, hardcoded in the playbooks. Rejected so the name can change without editing templates.
- KubeVirt or QEMU. Out of v2.

## References

- Issue #196
- ADR-026 (bash fleet)
