# ADR-043: One PostgreSQL StatefulSet for Automation Orchestrator

**Status**: Proposed

**Date**: 2026-11-12

**Authors**: aap-demo maintainers

**Updates**: [ADR-017](017-ao-addon.md)

## Context

The `ao` addon (ADR-017) gives Automation Orchestrator a PostgreSQL database by installing the
upstream CloudNativePG (CNPG) operator from GitHub into `cnpg-system`, then creating a CNPG
`Cluster` and three `Database` resources. For one database pod on a laptop cluster that is heavy:

- **A second operator, cluster-wide.** CNPG brings its own CRDs, controller and webhooks, plus SCC
  grants for its service account. Disabling AO leaves all of it behind.
- **Not Red Hat software.** The manifest and the `ghcr.io/cloudnative-pg/postgresql:15` image come from
  upstream, outside the registry the rest of the demo uses.
- **An extra image pull** of a PostgreSQL image, when AAP already runs `rhel9/postgresql-15` on the
  same node.

The checked-in manifests were also generated once with `aapctl install ao --dry-run`. `aapctl` is
Technology Preview. The supported CLI install is an OLM Subscription, which `deploy.sh` already uses.
`aapctl` remained only in a maintainer script (`scripts/generate-manifests.sh`) and an optional
`aapctl uninstall` on disable.

What AO needs from the database is fixed by its CR: the host `orchestrator-postgres-rw`, port 5432,
`sslMode: verify-ca` with the CA in the `orchestrator-postgres-ca` Secret, and the databases
`orchestrator`, `temporal` and `temporal_visibility`, owned by one user.

## Decision

Replace CNPG with one StatefulSet of the Red Hat `rhel9/postgresql-15` image
([`addons/ao/manifests/postgres.yaml`](../../addons/ao/manifests/postgres.yaml)), and drop `aapctl`.

- **Same names.** The Service is `orchestrator-postgres-rw` and the credential Secrets keep their
  names. The CR's `postgres.host` becomes the full name, `orchestrator-postgres-rw.<namespace>.svc`:
  Temporal checks the host name against the certificate even with `verify-ca`, and the service-ca
  certificate names only the `.svc` and `.svc.cluster.local` forms.
- **Image.** `deploy.sh` reads the `rhel9/postgresql-15` image from AAP's own StatefulSet in the AAP
  namespace. That image is already on the node, so nothing new is pulled. When it can't be read, the
  addon uses `registry.redhat.io/rhel9/postgresql-15`. `AO_POSTGRES_IMAGE` overrides both.
- **TLS.** MicroShift's service-ca signs a serving certificate for the Service and injects its CA into
  a ConfigMap. `deploy.sh` copies that CA into `orchestrator-postgres-ca` as `ca.crt`, so
  `verify-ca` holds. A pre-start hook copies the key to a 0600 file, which PostgreSQL requires.
  The addon's own `pg_hba.conf` replaces the image's, which accepts plain TCP from any host: only
  the local socket is trusted, and every TCP connection, loopback included, needs TLS and a password.
- **Rotation.** service-ca renews the certificate and its CA in place. The postgres container's
  liveness probe copies a renewed certificate and key into place and runs `pg_reload_conf()` over the
  local socket, so no other container needs database access. A rotated CA reaches AO on the next
  `aap-demo enable ao`, which copies it into `orchestrator-postgres-ca` and restarts AO's workloads,
  because they read that Secret only at start.
- **Databases.** The image creates `orchestrator` and its user from the Secret. `deploy.sh` creates
  `temporal` and `temporal_visibility` with `psql`, as it already did when CNPG's were late.
- **Storage.** The PostgreSQL volume uses `topolvm-provisioner` (block storage) when it exists, not
  the NFS class AO's other volumes use. Without it, the cluster's default class is used unless that is
  `nfs-local-rwx`, and enable stops if neither exists. `AO_POSTGRES_STORAGE_CLASS` overrides it.
- **No aapctl.** `scripts/generate-manifests.sh` and the `aapctl uninstall` call on disable are removed.
  The CR is maintained against the CRD (`kubectl explain automationorchestrator.spec`).
- **Existing installs.** A running AO on a CNPG `Cluster` is left as it is, and `enable ao` prints a
  note. One that is not running stops `enable ao` with a message. `enable ao --force` deletes the CNPG
  cluster and creates the new database, which loses AO's data, as `--force` already did. CNPG itself
  is left installed and disable says so.
- **Windows.** The PowerShell native AO path (ADR-030) applies the same `postgres.yaml`.

## Consequences

### Positive

- One pod and one PVC instead of an operator, its CRDs and webhooks, and a database pod.
- Everything AO runs comes from registry.redhat.io, and normally nothing new is pulled.
- Disable leaves nothing cluster-wide behind for new installs.

### Negative

- Upgrading from a CNPG install needs `--force`, which deletes AO's database. aap-demo is a demo tool,
  so a dump and restore was not built.
- aap-demo now owns the PostgreSQL configuration (TLS, probes, extra databases) that CNPG handled.
- The TLS setup depends on service-ca, which MicroShift runs. A cluster without it stops with a
  message after two minutes.
- A rotated service-ca CA is not copied until the next `aap-demo enable ao`. Doing it inside the
  cluster would need a controller with write access to Secrets and Deployments.

### Neutral

- The Secret names are unchanged. The CR changes only `postgres.host`.
- The Python port of the addon can apply the same manifest later.

## Alternatives Considered

### Keep CloudNativePG

It works. Rejected because it is a cluster-wide operator for one demo database, from outside Red Hat's
registry, and it stays behind after disable.

### CNPG from certified-operators

Not available: MicroShift has no `certified-operators` catalog.

### Share AAP's PostgreSQL instance

AO's databases would live inside AAP's. Rejected: the AAP operator owns that instance and its
credentials, and deleting AAP would take AO's data with it.

### Generate a CA in deploy.sh

`openssl` on the host would sign the server certificate. Rejected: service-ca already does it on the
cluster, rotates it, and needs no host tool.

## References

- [ADR-017: Automation Orchestrator Addon](017-ao-addon.md)
- [ADR-030: Windows Native Addon Execution](030-windows-native-addon-execution.md)
- [ADR-040: Shared Addon Framework and Bash Fallback](040-addon-framework-and-bash-fallback.md)
- `registry.redhat.io/rhel9/postgresql-15`, the image AAP 2.7 also runs for its database
- [Install the operator from the OpenShift CLI](https://docs.redhat.com/en/documentation/automation_orchestrator/2026.8/install-install_the_operator_from_the_openshift_cli)
