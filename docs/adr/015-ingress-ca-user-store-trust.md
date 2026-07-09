# ADR-015: Ingress CA Trust via User Certificate Stores

**Status**: Accepted

**Date**: 2026-06-22

**Authors**: aap-demo maintainers

## Context

MicroShift generates a self-signed **ingress CA** for OpenShift Routes (e.g.
`https://aap-aap-operator.apps.127.0.0.1.nip.io`). Without trusting that CA,
browsers show certificate warnings and CLI tools fail TLS validation.

Requirements:

- Trust must be **automatic** during normal workflow (`create`, `deploy`, `status`)
- Import should **not require Administrator** when possible — corporate laptops often
  block UAC elevation
- **Chrome and Edge on Windows** read the **Local Machine** root store, not only
  Current User — both stores may be needed
- **Chrome and Firefox on Linux** use **NSS databases** in the user home directory,
  not the system `ca-trust` store
- The CA PEM must be **saved locally** so curl and other tools can use
  `CURL_CA_BUNDLE` / `SSL_CERT_FILE` without re-fetching from the cluster
- Cluster recreate issues a **new CA** — stale certificates must be removed before re-import

ADR-010 documents cross-platform CLI parity at a high level. This ADR records the
**user-store trust strategy** and how it differs by platform.

## Decision

Implement a **tiered trust model**: import the ingress CA into **user-scoped
certificate stores first**, then attempt **system-scoped stores** when admin
access is available. Always persist the CA to `~/.aap-demo/crc-ingress-ca.crt`.

### CA source and persistence

1. SSH to the CRC VM (`core@127.0.0.1:2222`) and read
   `/var/lib/microshift/certs/ingress-ca/ca.crt`
2. Save to `~/.aap-demo/crc-ingress-ca.crt` (Windows: `%USERPROFILE%\.aap-demo\`)
3. Export `CURL_CA_BUNDLE` and `SSL_CERT_FILE` pointing at the saved file

If fetch fails but a previously saved PEM exists, import from the saved copy.

Skip all automatic import when `AAP_DEMO_TRUST_CA=false`.

### Windows — Current User root store (primary user store)

`powershell/native/Private/Helpers.ps1` → `Import-AapIngressCaCertificate`:

1. Compute SHA-1 thumbprint; skip if already in **LocalMachine** Root
2. Remove stale `CN=ingress-ca` entries from **CurrentUser** and **LocalMachine** Root
3. Import to **CurrentUser → Trusted Root Certification Authorities**:
   - Primary: .NET `X509Store('Root', 'CurrentUser')` with `ReadWrite` + `Add()`
   - Fallback: `certutil -user -addstore Root <path>`
4. If running as Administrator, import to **LocalMachine** Root via `certutil`
5. If not elevated, prompt UAC via `Start-Process certutil -Verb RunAs` for
   **LocalMachine** import (required for Chrome/Edge)

User-store import **never requires elevation**. System-store import is best-effort
with UAC; failures emit warnings but do not abort `status`.

### Linux — NSS user databases (browser user store)

`includes/ingress-ca-trust.sh` → `_import_ingress_ca_nss`:

Chrome/Chromium and Firefox trust CAs in **NSS databases**, not system
`ca-trust`:

| Path | When used |
|------|-----------|
| `~/.pki/nssdb` | Default; created if missing |
| `~/.local/share/pki/nssdb` | Chromium M146+ when `.pki/nssdb` absent |

Import via `certutil`:

```bash
certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n crc-ingress-ca -i <ca-path>
```

Nickname `crc-ingress-ca` is used for idempotency checks (`certutil -L`).
Existing entries with the same nickname are deleted before re-import.

Requires `nss-tools` package (`certutil`). Without it, system trust may work for
curl but browsers remain untrusted.

### Linux — system trust (requires sudo, not user store)

After user-store NSS import, also attempt system trust for CLI tools:

- RHEL/Fedora: `/etc/pki/ca-trust/source/anchors/crc-ingress-ca.crt` +
  `update-ca-trust`
- Debian/Ubuntu: `/usr/local/share/ca-certificates/crc-ingress-ca.crt` +
  `update-ca-certificates`

### macOS — system keychain (no separate user-store path)

macOS uses a single **System keychain** import via
`security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain`.
This requires `sudo` (admin password), not a user-only store. Stale `ingress-ca`
entries are deleted before re-import.

Fingerprint comparison uses the installed system certificate vs the fetched PEM
to detect cluster recreate.

### Idempotency and trigger points

Trust is considered complete when:

- **Windows**: thumbprint present in LocalMachine Root (preferred) or CurrentUser Root
- **Linux**: fingerprint matches in system anchors **and** NSS nickname present in
  all detected NSS DBs
- **macOS**: matching fingerprint in System keychain

`install_ingress_ca_trust` / `Install-AapIngressCaTrust` runs from:

- `create` (end of cluster setup)
- `deploy`
- `status`

When already trusted, commands stay silent. Import failures are warnings only —
`status` never aborts.

### Implementation map

| Platform | User store | System store | Module |
|----------|------------|--------------|--------|
| Windows | CurrentUser Root | LocalMachine Root (UAC) | `Helpers.ps1` |
| Linux | NSS (`~/.pki/nssdb`, etc.) | ca-trust / ca-certificates (sudo) | `ingress-ca-trust.sh` |
| macOS | — | System keychain (sudo) | `ingress-ca-trust.sh` |

## Consequences

### Positive

- Windows developers get TLS working for PowerShell/.NET without admin rights
  (CurrentUser store)
- Linux Chrome/Firefox trust via NSS without sudo when `nss-tools` is installed
- Saved PEM + env vars give curl/openssl a reliable CA bundle independent of OS stores
- Stale CA cleanup prevents trust mismatches after cluster recreate
- Opt-out via `AAP_DEMO_TRUST_CA=false` for locked-down environments

### Negative

- **Windows Chrome/Edge still need LocalMachine** — user store alone is insufficient;
  UAC prompt is a recurring friction point
- **Dual stores on Linux** — system ca-trust and NSS must both be updated for full coverage
- **macOS always needs sudo** — no user-only path
- NSS/Chromium path changes (e.g. M146 `.local/share/pki/nssdb`) require maintenance
- Corporate policies blocking UAC or cert import leave browsers untrusted despite warnings

### Neutral

- Ingress CA trust is orthogonal to CoreDNS nip.io resolution (ADR-007)
- mkcert for other local certs is separate (`aap-demo.sh` preflight messaging)
- Windows `curl.exe` may still need `--ssl-no-revoke` for Schannel revocation checks

## Alternatives Considered

### System store only (skip user store)

Rejected on Windows: requires Administrator for every developer; blocks locked-down laptops.

### User store only (skip system store)

Rejected on Windows: Chrome and Edge ignore CurrentUser Root for HTTPS validation.

### Browser-specific installers (Chrome policy, Firefox policies.json)

Rejected: too invasive; requires admin or enterprise policy; poor portability.

### Manual trust instructions only

Rejected: highest support burden; TLS is the most common Windows onboarding failure.

### mkcert for ingress CA

Rejected: MicroShift owns ingress certificate lifecycle; replacing it would fight the platform.

## References

- [includes/ingress-ca-trust.sh](../../includes/ingress-ca-trust.sh) — bash/Linux/macOS implementation
- [powershell/native/Private/Helpers.ps1](../../powershell/native/Private/Helpers.ps1) —
  `Import-AapIngressCaCertificate`, `Install-AapIngressCaTrust`
- [powershell/README.md](../../powershell/README.md) — Windows troubleshooting (UAC, Chrome HSTS)
- [ADR-007](007-coredns-route-resolution.md) — route DNS (separate from TLS trust)
- [ADR-010](010-cross-platform-cli.md) — cross-platform CLI parity overview
