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

- OpenShift 4 stays the default until 5 has had live runs on every host type we support.
- One CRC binary for both. Installing a second CRC next to the pinned one would double the setup
  path and the `crc setup` sudo step.
- Python command only. The bash command stays on 4.
- No new runtime dependencies, and no host `gpg`. macOS doesn't ship one.

## Decision

### 1. A setting for the OpenShift major version

Add `crc.ocp_version_major`, `4` or `5`, default `4`, with `--ocp-version-major` on `create` and
`deploy` and `CRC_OCP_VERSION_MAJOR` in the environment. It comes from the schema like the other
`crc.*` settings. The name keeps `ocp` because aap-demo already has several versions (CRC, AAP,
the MicroShift floor in `crc.version`), and the preset stays `microshift`: this picks which
OpenShift release the MicroShift bundle comes from, not full OpenShift.

- `create` builds the chosen version and saves it.
- `deploy` on an existing VM compares the setting with the running cluster. A mismatch stops before
  any change, with "this cluster runs OpenShift N; run aap-demo destroy, then
  create --ocp-version-major M".
- `CRC_VERSION` still lowers the minimum minor version. Its default comes from the chosen profile.
- `AAP_OCP_VERSION` keeps overriding the operator index tag (`v5.0`). A value whose major version
  differs from the cluster's is refused.

### 2. One profile file per major version

`src/aap_demo/data/openshift/4.yaml` and `5.yaml`. Code reads the profile. It does not branch on
`major == 5`. Each profile lists:

- `minimum_version`: the lowest MicroShift minor version create and deploy accept (`4.22`, `5.0`).
- `bundle`: `null` when the pinned CRC's own bundle is used (4), or the version, mirror directory and
  file name for each host type (5).
- `aap_channels`: channels `deploy --channel` accepts.
- `operators`: which optional operators the index has (`automation-orchestrator`,
  `automation-portal`). Addons that need a missing one refuse before touching the cluster.
- `root_disk_gb`: the smallest root filesystem create allows, so `disk_gb - pv_size_gb` is checked
  before the VM is built.

`DEFAULT_OCP_VERSION = "4.20"` in `catalog_signature.py` goes away. The fallback comes from the
profile.

### 3. Download and verify the 5.0 bundle in aap-demo

While CRC has no 5.0 release, `create --ocp-version-major 5` downloads the bundle for the host from the
profile's mirror directory, verifies it, caches it under `~/.crc/cache`, and runs
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

When a CRC release ships 5.0, the 5 profile sets `bundle: null` and pins that CRC release. If that
CRC drops 4.22, the 4 profile gets the download path instead. The verification code stays for
whichever version isn't the CRC default.

## Consequences

### Positive

- `create --ocp-version-major 5` works now, without waiting for a CRC release.
- 4 and 5 differ in data, not in code paths. Adding 5.1 is a new profile.
- The bundle is verified more strictly than `crc start -b` does on its own, with no host tools.
- Addons and channels that don't exist on 5 refuse up front instead of failing halfway.

### Negative

- aap-demo carries a small OpenPGP verifier. It has to handle only the signature format Red Hat
  uses (v4, RSA, SHA-256, clearsigned); anything else fails closed.
- The pinned key has to be updated if Red Hat rotates its release key.
- CRC 2.64 warns on every start of a 5.0 bundle ("expected 4.22.13").
- A 5.0 bundle is about 1.4 GB (vfkit arm64), cached next to CRC's own bundle.

### Neutral

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
