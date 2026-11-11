# ADR-038: Satellite CA Trust-on-First-Use and Vault-Backed Admin Password

**Status**: Accepted

**Date**: 2026-11-11

**Authors**: aap-demo maintainers

---

## Context

The Satellite lab VM serves a self-signed certificate from its own internal
Katello CA (`CN=satellite.demo.lab`). Browsers and CLI tools reject it with
`ERR_CERT_AUTHORITY_INVALID` until the CA is trusted. Two security questions
arise in how the lab bootstraps that trust and how it handles the Satellite
admin password:

1. **CA bootstrap is trust-on-first-use (TOFU).** The CA is self-signed by
   definition, so the first fetch of
   `https://satellite.demo.lab/pub/katello-server-ca.crt` cannot validate the
   server's identity — there is no prior trust anchor. Fetching it requires
   `curl -sk` (skip verification), which is a MITM window on first trust.
2. **The admin password was hardcoded** (`RedHat123!`) in the installer, the
   content playbook, the APD credential wiring, the status command, and the
   completion banner — a committed secret reused across every deployment.

## Decision

**CA trust (TOFU, with verification).** `includes/satellite-ca-trust.sh` fetches
the CA over `curl -sk` (unavoidable for a self-signed first fetch) but then
**verifies the fetched cert is a real CA** (`basicConstraints CA:TRUE`) before
importing it into the OS ca-trust store and the Chrome/Firefox NSS stores. This
rejects a leaf or garbage payload even on a MITM'd first fetch. The import is
idempotent (SHA-256 fingerprint match against the installed anchor) and skipped
when `AAP_DEMO_TRUST_CA=false`. The TOFU window is accepted because the lab is a
single-host, host-only VM on a private libvirt network; the CA:TRUE check bounds
the risk to "an attacker on the lab network served a different *valid CA*",
which the fingerprint mismatch on subsequent runs would surface.

**Admin password (Vault-backed, generated).** The Satellite admin password is no
longer hardcoded. A new `aap_demo_satellite_admin_password()` helper in
`includes/credential-vault.sh` generates a random password
(`secrets.token_urlsafe(24)`) on first use and stores it in the encrypted
credential Vault (`~/.ansible/conf/env.yml`, key
`aap_demo.satellite.admin_password`). Every consumer reads from that single
source:

- `satellite-lab/build-and-configure.sh` pulls it and passes it to
  `02-satellite-installer.sh` over the SSH environment (stdin), never on the
  command line or in the repo.
- `02-satellite-installer.sh` reads `SATELLITE_ADMIN_PASSWORD`; the literal
  fallback remains only for a standalone manual run.
- `includes/cmd-status.sh` (`status --show-secrets`) and
  `addons/product-demo-satellite/deploy.sh` (APD credential wiring) read it from
  the Vault, with `SATELLITE_PASSWORD` as an env override for an external
  Satellite.
- The completion banner no longer prints the password; it points at
  `aap-demo status --show-secrets`.

## Consequences

### Positive

- No committed Satellite admin password; each deployment gets a unique one.
- Single source of truth in the encrypted Vault; rotation is a Vault edit.
- The CA bootstrap verifies the payload is a CA before trusting it, and the
  fingerprint check makes a changed CA visible on later runs.
- Passwords and the activation key cross SSH via stdin, not argv, so they stay
  out of the remote process list and shell history (covered by
  `test-fleet-satellite.sh`).

### Negative

- The first CA fetch is still TOFU; a fully offline lab cannot validate the
  server's identity on first contact. Acceptable for a local single-host lab,
  not for a shared network.
- The Vault must be initialized before the Satellite build
  (`aap-demo fleet auth configure` or any Vault-writing step).

### Neutral

- The VM **root** password (kickstart `ROOTPW`) is a separate, VM-local concern
  and is out of scope for this ADR.

## Related

- [ADR-015](015-ingress-ca-user-store-trust.md) — the dual-store (OS + NSS)
  trust pattern this mirrors for the Satellite CA.
- `includes/satellite-ca-trust.sh`, `includes/credential-vault.sh`,
  `satellite-lab/build-and-configure.sh`
