---
type: Guide
title: Choose an OpenShift version
description: Build the cluster on the usual OpenShift 4 release, a specific 4.x version, or OpenShift 5.
tags: [create, openshift, microshift, version]
status: draft
stale_after: 2027-01-28
resource: https://github.com/RedHatOfficial/aap-demo
---

# Choose an OpenShift version

`aap-demo create` builds a MicroShift cluster on the newest OpenShift version aap-demo supports. Today that
is 4.22.13, the version CRC 2.64.0 ships, so nothing extra is downloaded. Most people never need this page.

## See the choices

```bash
aap-demo ocp-version-list
```

```text
VERSION   STATUS                      SOURCE
5.0.0     stable, not default yet     download
4.22.13   stable, default             CRC 2.64.0 (built in)
4.22.0    untested                    download
4.21.7    untested                    download
4.21.0    untested                    download
```

- **stable** versions are the ones aap-demo is tested with. The default is marked.
- **untested** versions are older patches that should work but are not tested.
- **download** means `create` fetches the bundle from mirror.openshift.com first.
- **no bundle for this host** means Red Hat publishes none for your operating system and processor.

`aap-demo ocp-version-list --all` also shows versions older than aap-demo supports. Without a network
connection, the list shows the stable versions and marks them `(not checked)`.

## Build another version

Pass a major version, a minor version, or an exact version:

```bash
aap-demo create --ocp-version 5        # newest stable 5.x
aap-demo create --ocp-version 4.21     # newest 4.21 patch on the mirror
aap-demo create --ocp-version 4.22.0   # exactly 4.22.0
```

`4` and `4.22` both give the same version as the default.

To keep the choice for later runs:

```bash
aap-demo config set crc.ocp_version 5
```

The environment variable is `CRC_OCP_VERSION`.

## Downloaded bundles are checked

When CRC doesn't ship the version, `create` downloads its bundle from mirror.openshift.com. The OpenShift 5.0
bundle is about 1.4 GB. Before CRC starts the bundle, aap-demo checks it:

1. It verifies the mirror's signed checksum file against Red Hat's release key.
2. It compares the bundle's SHA-256 with the signed checksum.

A file that fails either check is deleted, and `create` stops. A verified bundle is kept in `~/.crc/cache`,
so the next `create` reuses it.

CRC then prints a warning that it expected its own bundle version. That warning is expected.

## An existing cluster keeps its version

`create` and `deploy` stop before changing anything when the cluster runs a different version than
`--ocp-version` asks for. To switch versions:

```bash
aap-demo destroy
aap-demo create --ocp-version 5
```

## OpenShift 5

OpenShift 5 is supported but is not the default yet:

- AAP comes only from the 2.7 channels, `stable-2.7` and `stable-2.7-cluster-scoped`. `deploy --channel
  stable-2.6` stops on OpenShift 5.
- The Automation Orchestrator and Automation Portal operators are not in the OpenShift 5 catalog yet.

## CRC_VERSION

`CRC_VERSION` (`--crc-version`, `crc.version`) is deprecated. It still lowers the version floor for the CRC
already on your PATH, so `create` keeps an older CRC instead of installing 2.64.0, and builds the bundle that
CRC ships. Use `--ocp-version` to choose the cluster version. When both are set, `--ocp-version` decides the
version.
