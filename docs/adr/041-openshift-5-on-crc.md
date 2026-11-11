# ADR-041: OpenShift 5 on CRC

**Status**: Proposed

**Date**: 2026-11-11

**Authors**: aap-demo maintainers

## Context

OpenShift 5.0 went GA on 2026-11-09. aap-demo builds MicroShift clusters with CRC, and the Python
command pins CRC 2.64.0, which bundles MicroShift 4.22. There is no CRC release with a 5.0 bundle yet.
crc-org/crc#5456, which moves CRC to 5.0.0, merged on 2026-11-10 but is not in a release.

What we found on a test Mac (arm64), 2026-11-10 and 2026-11-11:

- Signed MicroShift 5.0.0 bundles are on the mirror for every host type:
  `mirror.openshift.com/pub/openshift-v4/clients/crc/bundles/microshift/5.0.0/`
  (vfkit arm64/amd64, libvirt arm64/amd64, hyperv amd64), with `sha256sum.txt`, a clearsigned
  `sha256sum.txt.sig` and a binary `sha256sum.txt.gpg`. The signer is Red Hat release key 2
  (`199E2F91FD431D51`), an RSA key. The signature is a v4 SHA-256 text signature.
- CRC 2.64 starts that bundle with `crc start -b <file>` and only warns "expected 4.22.13". The node
  is MicroShift 5.0.0 on RHEL 10.2 with Kubernetes 1.36.5.
- An unmodified 2.0.0rc1 `deploy --auto-license` worked on that cluster in 13 minutes. The
  `redhat-operator-index:v5.0` CatalogSource was picked from the cluster version, the AAP 2.7
  operator installed, and the subscription was applied.
- CRC checks the signature only on its own default bundle. A bundle passed as a URL or a file is
  used without a signature or checksum check.
- The v5.0 operator index at GA has the AAP operator on `stable-2.7` and `stable-2.7-cluster-scoped`
  only. It has no Automation Orchestrator operator and no Automation Portal operator.
- The 5.0 bundle does not include the `microshift-olm` RPM, and the VM has no package repositories.
  Upstream OLM from `operator-sdk olm install` stays.
- The first test VM filled its root disk. CRC gives the persistent-volume pool its size out of
  `disk-size`, so the defaults (120 GB disk, 100 GB pool) leave about 20 GB for the root filesystem,
  where images live.

Constraints:

- OpenShift 4 stays the default until 5 has had live runs on every host type we support. The
  default is always the newest supported stable version.
- One CRC binary for both. Installing a second CRC next to the pinned one would double the setup
  path and the `crc setup` sudo step.
- Python command only. The bash command stays on 4.
- No new runtime dependencies, and no host `gpg`. macOS doesn't ship one.

## Decision

### 1. One setting: `--ocp-version`

Add `crc.ocp_version`, with `--ocp-version` on `create` and `deploy` and `CRC_OCP_VERSION` in the
environment. It comes from the schema like the other `crc.*` settings. The name keeps `ocp` because
aap-demo already has several versions (CRC, AAP). The preset stays `microshift`: this picks which
OpenShift release the MicroShift bundle comes from, not full OpenShift.

Unset, it resolves to the newest supported stable version: the highest `stable` among profiles
marked `supported`. Today that is 4.22.13. When the 5 profile is marked `supported` after live runs,
the same unset setting gives 5.0.0 with no code change.

A value can be as broad or as exact as the user wants:

| Value | Resolves to | Today |
|-------|-------------|-------|
| `4`, `5` | The stable version aap-demo pins for that major version | `4` → 4.22.13, `5` → 5.0.0 |
| `4.22`, `5.0` | The stable version for that minor, the same as the major when it is the newest minor | `4.22` → 4.22.13 |
| `4.21` (an older minor) | The newest patch for that minor on the mirror, looked up at create | `4.21` → 4.21.7 |
| `4.22.0`, `5.0.0` | Exactly that bundle | as given |

- The stable versions are pinned in the profiles (below), so `4` and `4.22` give the same tested
  cluster for everyone, and a new mirror upload doesn't change what `create` builds.
- A version that isn't a profile's stable version prints a warning that it is untested. A version
  below 4.21, or one with no bundle on the mirror for this host, is refused with the list of
  supported values.
- `crc.ocp_version` keeps what the user gave (`4`, `5.0.0`, or nothing), so an unset setting keeps
  following the newest supported version on the next create. aap-demo doesn't store the version
  it built: CRC already reports it (`crc status`, and the bundle name in the VM's config while it
  is stopped). `create` on an existing VM of another version, and `deploy` on a running one, stop
  before any change: `4` matches any 4.x, `4.22` any 4.22.z, an exact value only itself, and an
  unset setting keeps whatever cluster is there. The message names the fix: "run aap-demo destroy,
  then create --ocp-version 5".
- `crc.version` / `CRC_VERSION` keeps its current meaning (a MicroShift floor that keeps an older
  CRC already on PATH, which avoids the sudo step in `crc setup`) and prints a deprecation note
  that points at `--ocp-version`. Reading it as `--ocp-version` would have quietly removed that
  escape hatch.
- `AAP_OCP_VERSION` keeps overriding the operator index tag (`v5.0`). A value whose major version
  differs from the cluster's is refused.

### 2. One profile file per major version

`src/aap_demo/data/openshift/4.yaml` and `5.yaml`. Code reads the profile. It does not branch on
`major == 5`. Each profile lists:

- `stable`: the full version `4`/`5` and its newest minor resolve to (`4.22.13`, `5.0.0`).
- `supported`: whether an unset `--ocp-version` may resolve to this profile (`4` true, `5` false
  until live runs pass).
- `minimum`: the oldest version accepted (`4.21`, `5.0`).
- `crc_bundle`: the version the pinned CRC binary ships, if any. When the resolved version equals
  it, CRC's own bundle is used and nothing is downloaded. Otherwise the bundle comes from the mirror
  (section 3).
- `aap_channels`: channels `deploy --channel` accepts.
- `operators`: which optional operators the index has (`automation-orchestrator`,
  `automation-portal`). The addons that use them (`ao`, `ao-eap`, `ao-pr-testing`,
  `portal-operator`) only run through the bash command today (ADR-040). When they are ported, their
  enable checks this list and refuses before touching the cluster. The Helm `portal` addon needs
  no operator.

`DEFAULT_OCP_VERSION = "4.20"` in `catalog_signature.py` goes away. The fallback comes from the
profile.

### 3. Download and verify bundles CRC doesn't ship

When the resolved version isn't the pinned CRC's own bundle (5.0.0 today, or an exact 4.x),
`create` downloads the bundle for the host from
`mirror.openshift.com/.../crc/bundles/microshift/<version>/`, verifies it, caches it under `~/.crc/cache`, and runs
`crc start -b <file>`.

Verification, in order, stopping on the first failure:

1. Download `sha256sum.txt.sig` over HTTPS.
2. Verify its clearsigned OpenPGP signature against Red Hat release key 2, shipped in the package as
   `data/openshift/redhat-release-key-2.asc`, with its fingerprint pinned in code. The check is pure
   Python with the standard library: parse the v4 signature packet, hash the canonical text with
   SHA-256, and verify RSA PKCS#1 v1.5. This is the same check CRC runs on its own bundles.
3. Read the bundle's sha256 from the verified text, never from an unsigned file.
4. Download the bundle, or reuse the cached file, and compare its sha256.

A bad signature or checksum refuses to start and deletes the downloaded file. The cache is kept when
the checksum matches, so a second create doesn't download it again.

### 4. Moving to CRC's own 5.0 bundle

A CRC binary ships one MicroShift bundle (CRC 2.64.0 ships 4.22.13). When a CRC release ships 5.0,
aap-demo pins that release, the 5 profile's `crc_bundle` names its version, and the 4 profile's
`crc_bundle` is cleared, so `--ocp-version 4` downloads and verifies 4.22.13 the same way 5.0.0 is
handled today.

### 5. `aap-demo ocp-version-list`

A read-only command that lists what `--ocp-version` can build on this host, listed in
`aap-demo help` next to `version`. It needs no cluster.

```text
$ aap-demo ocp-version-list
VERSION   STATUS                      SOURCE
5.0.0     stable, not default yet     download
4.22.13   stable, default             CRC 2.64.0 (built in)
4.22.0    untested                    download
4.21.7    untested                    download
4.21.0    untested                    download
```

- It reads the mirror's `crc/bundles/microshift/` directory, then the directory of each version at
  or above the oldest profile `minimum`, and keeps the versions that have a bundle for this host
  (for example `vfkit` and `arm64`). Parsing is limited to the directory listing's links; anything
  that doesn't look like a version is skipped.
- `--all` also lists versions below the minimum, marked "not supported".
- `--output json|yaml` works like the other commands, for scripts.
- With no network it still prints the profile versions, marked "not checked".
- It never downloads a bundle and never checks signatures. `create` does that.

The mirror lists MicroShift bundles only for versions CRC built. OpenShift's `stable-4.22` channel
was at 4.22.22 on 2026-11-11, but the newest MicroShift bundle for 4.22 was 4.22.13, so 4.22.13 is
the newest 4.22 aap-demo can build.

## Consequences

### Positive

- `create --ocp-version 5` works now, without waiting for a CRC release.
- One flag covers both the simple case (`4`, `5`) and a pinned version (`4.22.0`), and
  `ocp-version-list` shows what is available.
- 4 and 5 differ in data, not in code paths. Moving to 5.1 is a change to `stable` in a profile.
- The bundle is verified more strictly than `crc start -b` does on its own, with no host tools.
- AAP channels that don't exist on 5 refuse up front instead of failing halfway.

### Negative

- aap-demo carries a small OpenPGP verifier. It has to handle only the signature format Red Hat
  uses (v4, RSA, SHA-256, clearsigned); anything else fails closed.
- The pinned key has to be updated if Red Hat rotates its release key.
- CRC 2.64 warns on every start of a 5.0 bundle ("expected 4.22.13"). aap-demo prints one note
  that it verified the bundle itself, so the warning isn't mistaken for a failure.
- A 5.0 bundle is about 1.4 GB (vfkit arm64), cached next to CRC's own bundle.

### Neutral

- A user who never sets `--ocp-version` sees no change: CRC's own 4.22.13 bundle, no download.
- The bash command and its CRC path are unchanged.
- The operator index tag already follows the cluster version (`redhat-operator-index:v5.0`).

## Alternatives Considered

### Require host gpg or gpgv

**Why not chosen**: macOS and Windows don't ship it, and the test Mac had none. A missing tool would
make 5.0 unavailable for most users, or tempt a "skip verification" flag.

### Add an OpenPGP library dependency

**Why not chosen**: `pgpy` and `python-gnupg` add a dependency (and, for `python-gnupg`, still need
gpg) to check one signature format. The stdlib check is about 150 lines and is tested against the
real 5.0 signature.

### Trust the checksum file over HTTPS without the signature

**Why not chosen**: it trusts the mirror's TLS endpoint and anything that can write to it. CRC
itself checks the signature for its default bundle; aap-demo should not do less.

### Install a second CRC built from main after crc-org/crc#5456

**Why not chosen**: an unreleased CRC build, a second binary, and a second `crc setup`. The pinned
CRC already starts the 5.0 bundle.

### Wait for a CRC release with 5.0

**Why not chosen**: no date. The profile design means the switch is a data change when it ships.

## References

- [ADR-003: Infrastructure backend selection](003-infrastructure-backend-selection.md)
- [ADR-005: OLM on MicroShift](005-olm-on-microshift.md)
- [ADR-040: Shared addon framework and bash fallback](040-addon-framework-and-bash-fallback.md)
- [crc-org/crc#5456](https://github.com/crc-org/crc/pull/5456): update OCP/MicroShift to 5.0.0 (merged, unreleased)
- [MicroShift 5.0 bundles](https://mirror.openshift.com/pub/openshift-v4/clients/crc/bundles/microshift/5.0.0/)
- RFC 9580, OpenPGP (signature packets, cleartext signature framework)
