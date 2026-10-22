# APME Playbook Addon

Deploy Ansible Portal with Ansible Quality (APME) on OpenShift Local (MicroShift) using
**official APME EAP welcome pack Ansible playbooks** executed locally in an isolated Python
virtual environment.

> **Preview:** APME is prototype software for the Early Access Program.
> Confidential — Red Hat associate and NDA partner use only.

## Overview

This addon uses the **official APME EAP welcome pack playbooks** executed
locally via `ansible-playbook`. This implementation:

- **Local execution**: Playbooks run in isolated Python venv (no AAP API dependency)
- **KUBECONFIG authentication**: Uses standard kubeconfig for cluster access
- Uses structured Ansible roles from the official APME welcome pack
- Auto-discovers aap-demo environment (no manual configuration)
- Maintains alignment with upstream APME deployment patterns

**Architecture:** Bash wrapper (`deploy.sh`) handles environment discovery and generates vars
file, then invokes official APME playbooks via `ansible-playbook` with KUBECONFIG-based
authentication.

## Quick Start

### Prerequisites

**System requirements:**

- `kubectl` or `oc`
- `python3` (3.8+)
- Podman (running) and Skopeo for portal image builds or validation
- AAP execution environment with network access to `get.helm.sh` (the playbook bootstraps a pinned Helm client)
- AAP deployed (`aap-demo deploy`)

By default the deploy bootstraps the local registry, publishes the bundled plugin archive,
and builds a custom RHDH 1.9 image with all six APME plugins using Podman. Podman must be
running (start `podman machine` on macOS). The chart's standard dynamic-plugin installer
loads those plugins from the image. A published Quay image can replace this local build.

**Ansible installation** (auto-installed in venv):

- A venv is created at `~/.aap-demo/apme-eap-venv` with full Ansible suite + collections
- Includes kubernetes.core, community.okd, and other required collections
- The playbooks run locally using KUBECONFIG authentication (~150 MB venv)

### No Manual Configuration Required! 🎉

The addon **automatically discovers** your aap-demo environment (KUBECONFIG, cluster domain,
AAP credentials). No manual setup needed!

### Automation Hub (setup-pah)

For certified collection access and the repositories **catalog** view, configure hub credentials
**before** or **alongside** apme-eap deploy:

```bash
# console.redhat.com offline token → ~/.aap-demo/galaxy-token
aap-demo enable setup-pah

# optional external PAH → ~/.aap-demo/pah-config.yml
aap-demo enable apme-eap
```

When credential files exist, apme-eap automatically:

- Runs `setup-pah` to configure rh-certified / validated remotes on AAP
- Enables portal `pahCollections` catalog sync
- Seeds APME `/settings/galaxy-servers` with AAP Automation Hub (`{AAP}/api/galaxy/`) + community Galaxy
- Writes literal AAP URLs into portal app-config (fixes `/undefined` navigation from unset `${AAP_HOST_URL}`)

See [collection authentication](../../docs/collection-authentication.md).

### Deploy

```bash
aap-demo enable apme-eap
```

This will:

1. Check system prerequisites (kubectl, python3, helm — installs helm if missing)
2. Create venv with full Ansible + collections (if not exists)
3. Auto-discover your aap-demo environment (KUBECONFIG, cluster domain, AAP route/credentials)
4. Run **setup-pah** when `~/.aap-demo/galaxy-token` or `pah-config.yml` exists (configures AAP hub remotes)
5. Generate playbook vars at `~/.aap-demo/apme-eap-vars.yml`
6. Push the bundled archive and build the portal image locally, or validate the configured prebuilt image
7. Seed APME galaxy servers from AAP (+ external PAH when configured) and enable PAH catalog sync

**Authentication:** The playbooks use KUBECONFIG (client certificate auth) to interact with
the cluster. The `K8S_AUTH_KUBECONFIG` environment variable is set automatically by the
wrapper script.

**First run** takes longer (~2-3 minutes) to set up the virtual environment and install
Ansible collections. Subsequent runs reuse the existing venv and are faster.

### Use a published Quay portal image

Use the immutable manifest tag or `quay.io/aapdemo/apme-eap@sha256:...` reference from
the publishing workflow summary. Replace the example tag with the published value:

```bash
APME_PRELOADED_IMAGE_REF='quay.io/aapdemo/apme-eap:apme-<source-sha>-<12-hex-pack-digest>' \
  aap-demo enable apme-eap
```

Or edit `~/.aap-demo/apme-eap-vars.yml` before running enable again:

```yaml
apme_preloaded_image_ref: quay.io/aapdemo/apme-eap:apme-<source-sha>-<12-hex-pack-digest>
# Replace the example with the published immutable tag or @sha256:... digest.
apme_preloaded_image_pull_secret: ""
apme_preloaded_image_auth_file: ""
apme_preloaded_image_verify: true
```

Fully qualified `registry/repository:tag` and `registry/repository@sha256:<64-hex>`
references are supported, including registry ports. Skopeo verifies availability and pins
the resolved digest for validation and Helm. Podman pulls that image and checks all six
plugin package identities in a read-only container with networking disabled; it does not
build an image in prebuilt mode. The cluster selects its architecture from the published
manifest; deploy from a host matching the cluster architecture because local validation
runs the image with Podman. Set `apme_preloaded_image_verify: false` only to skip the
Skopeo availability/digest lookup; six-plugin validation still runs. Check mode parses
references and plans the deployment without fetching or validating a remote image.

The prebuilt path does not require the bundled archive or bootstrap the local registry.
Its six plugin entries become local `./dynamic-plugins/dist/...` paths, so the portal does
not download the APME plugins at startup. With no pull secret, the cluster must be able to
read the repository anonymously, or have credentials already configured for its service
account. Local Podman/Skopeo credentials do not automatically authorize cluster pulls.
For a private Quay repository, use a pull-only robot account to create a local auth file:

```bash
mkdir -p ~/.aap-demo
skopeo login --authfile ~/.aap-demo/apme-quay-auth.json quay.io
chmod 600 ~/.aap-demo/apme-quay-auth.json
```

Then set `apme_preloaded_image_pull_secret: apme-quay-pull` and
`apme_preloaded_image_auth_file` to the **absolute** path of that file in the generated vars.
The role uses it for Skopeo/Podman and creates or updates the named docker-registry Secret
in the portal namespace. Only the selected registry credentials are copied, and secret
tasks suppress their output. The file must contain an inline `auths.quay.io.auth` entry;
a credential-helper-only configuration cannot be copied into the cluster Secret. The
Secret name is rendered into the portal image's `pullSecrets`. Leave the name empty for
public pulls or when cluster pull credentials are managed separately. Do not commit the
auth file or reuse the CI push token for cluster pulls. The wrapper preserves these
settings when regenerating vars. `latest` is a moving convenience alias; prefer the
immutable tag or a digest for repeatable deployments.

Keep `apme_preloaded_image_ref: ""` (the default) to use the local fallback. It retains the
`apme_oci_push` then `apme_image_build` sequence and requires `apme_oci_tar_resolved`.
A cached local-registry image is reused only after its six plugin identities validate;
an invalid cache triggers a rebuild, and a failed rebuild stops deployment. Use
`apme_image_build_force: true` when a rebuild is required even with a valid cache.
The portal image uses the node-supported external `oci_registry` route and the
registry digest captured from inspection or Podman push. Its Helm tag is empty,
so forced or repair rebuilds deploy the new bytes even with `IfNotPresent`.
The internal service endpoint remains available to the plugin OCI delivery path.
For a custom `apme_oci_tar`, also set its independently verified digest in
`apme_image_build_pack_sha256`; the container build rejects mismatches or missing plugins.

The wrapper regenerates `~/.aap-demo/apme-eap-vars.yml` on each enable and does **not**
preserve `apme_image_build_force`, `apme_oci_tar`, or `apme_image_build_pack_sha256`.
After the wrapper has initialized its venv, collections, and generated vars, run the
playbook directly from the repository root for these overrides. Select the deployment's
kubeconfig and replace the archive path and digest below with your verified values:

```bash
source ~/.aap-demo/apme-eap-venv/bin/activate
export KUBECONFIG=/absolute/path/to/deployment-kubeconfig
export K8S_AUTH_KUBECONFIG="$KUBECONFIG"
export ANSIBLE_ROLES_PATH="$PWD/addons/apme-eap/playbooks/roles"
ansible-playbook addons/apme-eap/playbooks/deploy_apme_portal.yml \
  -e @addons/apme-eap/defaults.yml \
  -e @"$HOME/.aap-demo/apme-eap-vars.yml" \
  -e '{"apme_preloaded_image_ref":"","skip_plugin_push":false,"apme_image_build_force":true}' \
  -e '{"apme_oci_tar":"/absolute/path/to/plugin-pack.tar","apme_image_build_pack_sha256":"sha256:<64-hex-digest>"}'
```

Later `-e` arguments take precedence over the generated vars. To force a rebuild of the
bundled pack, omit the last `-e` argument. These overrides apply to this direct invocation;
rerunning the wrapper does not retain them. The preloaded-image settings described above
are preserved by the wrapper.

`skip_plugin_push: true` retains the existing chart/runtime OCI path and assumes the
plugin archive has already been published; it skips both local push and image build.
This fallback uses the bundled OCI pack, not a fresh GitHub artifact. Live Quay and
x86/ARM cluster smoke tests remain pending in [TEST_PLAN.md](TEST_PLAN.md).

### Check Status

```bash
aap-demo status        # Shows APME in addons section
kubectl get pods -n apme
kubectl get route -n apme
```

### Undeploy

```bash
aap-demo disable apme-eap
```

This removes the APME namespace and generated vars file but preserves GitHub credentials
and the virtual environment for future use.

**Clean re-test cycle** (remove saved GitHub creds and private key):

```bash
aap-demo disable apme-eap --purge-creds
# or non-interactive:
APME_PURGE_CREDS=true aap-demo disable apme-eap
```

When run interactively, disable also prompts to remove saved credentials.

**To completely remove everything** (including venv):

```bash
aap-demo disable apme-eap --purge-creds
rm -rf ~/.aap-demo/apme-eap-venv
```

## Architecture

### Welcome Pack Roles

The addon uses these roles from the official APME welcome pack:

1. **openshift_apme_setup** - Creates namespace and scaffolder ConfigMap
2. **apme_pah_integration** - setup-pah remotes, PAH catalog sync flags, APME galaxy seeding
3. **aap_apme_prerequisites** - Creates AAP OAuth app, generates API token
4. **apme_oci_push** - Publishes the bundled APME plugin archive to the local registry
5. **apme_image_build / apme_preloaded_image** - Builds the local image or validates an external image
6. **apme_helm_values** - Generates Helm values for chart-native dynamic plugin installation
7. **apme_scm_secrets** - Creates GitHub OAuth/App secrets (optional)
8. **portal_helm_install** - Installs Red Hat Developer Hub Helm chart
9. **apme_gateway_helm** - Installs APME gateway Helm chart

### Deployment Flow

```
deploy.sh (bash wrapper)
    ↓
Environment auto-discovery:
  - KUBECONFIG from CRC
  - OpenShift API URL
  - AAP route and credentials
  - Cluster architecture (x86/ARM)
    ↓
Generate vars file:
  ~/.aap-demo/apme-eap-vars.yml
    ↓
ansible-playbook playbooks/deploy_apme_portal.yml
    ↓
Roles execute in sequence:
  1. openshift_apme_setup
  2. apme_pah_integration (setup-pah + galaxy facts)
  3. aap_apme_prerequisites
  4. apme_preloaded_image, or apme_oci_push → apme_image_build
  5. apme_helm_values (selected portal image + local plugin paths + PAH sync)
  6. apme_scm_secrets (if enabled)
  7. portal_helm_install
  8. apme_gateway_helm
  9. post_tasks: seed APME galaxy servers + portal rollout
```

## Configuration

### CI publishing to Quay

The [APME EAP image workflow](../../.github/workflows/apme-eap-image.yaml) resolves one
upstream pack, builds it on native AMD64 and ARM64 runners, pushes to
`quay.io/aapdemo/apme-eap`, and assembles a verified two-platform manifest. It runs on
manual dispatch or matching addon/workflow changes pushed to `main`; pull requests
never publish. Publishing is serialized across branches. There is no upstream webhook
or scheduled rebuild: each triggered build resolves its inputs anew.

Configure these **Actions repository secrets** on `RedHatOfficial/aap-demo`:

| Secret | Purpose |
| --- | --- |
| `APME_ARTIFACT_TOKEN` | Read access to Actions runs/artifacts in the selected upstream repository (Actions read permission, including private-repository access when needed). Passed as `GH_TOKEN` to the resolver. |
| `QUAY_USERNAME` | Quay user or robot account authorized for `aapdemo/apme-eap`. |
| `QUAY_TOKEN` | That account's token with push/pull access to the target repository. |
| `REGISTRY_REDHAT_USERNAME` / `REGISTRY_REDHAT_PASSWORD` | Base-image pull credentials for the AMD64 Red Hat registry image when authentication is required. Set both. |

The workflow has only `contents: read` for its own `GITHUB_TOKEN`; that token does not
replace the upstream artifact token or Quay credentials. Secrets are passed through
environment variables and password-stdin/credential-helper pipes; never commit them.
The native `ubuntu-24.04-arm` runner must also be available to the repository.

Dispatch inputs are `source_repo` (default `ansible/ansible-rhdh-plugins`), `source_ref`
(default `latest`), `pack_format` (`oci` by default, or `npm`), and boolean
`publish_latest` (default `false`). Choose
`source_repo=ansible/apme` when that repository publishes the complete six-plugin pack;
the resolver does not switch repositories automatically. `source_ref=latest` means the
newest completed successful Actions run on the upstream repository's default branch.
A full lowercase 40-character commit SHA selects the newest successful run at that exact
commit. Branch names and shortened SHAs are not accepted. Selection spans all workflows;
an unusable newest run fails rather than falling back to an older run.

Within that run, automatic selection requires a non-expired name containing `apme` or
`plugin` (case-insensitive), with an `oci` token for OCI packs, or an `npm` token/plain
`.tar.gz` suffix without an `oci` token for npm packs. Docker/build/image records are
excluded. Set `APME_PACK_FORMAT=oci|npm` for the standalone resolver/build command.
Zero/ambiguous matches report candidate names and the exact-name override:
`APME_ARTIFACT_NAME` bypasses automatic format/name filtering, but never expiry or
content validation. The workflow exposes format selection, not an artifact-name input.
The downloaded artifact may be a ZIP containing exactly one `.oci.tar.gz`/`.tar.gz`
pack, or a raw gzip pack from upstream `archive: false` uploads. The resolver verifies
the downloaded payload digest when supplied by GitHub, computes the normalized pack's
SHA256, and validates all six package identities. The extractor validates the pack again
before both architecture builds. A four-plugin pack fails; these six directories are
required under `dynamic-plugins/dist/`:

```text
ansible-plugin-scaffolder-backend-module-backstage-rhaap
ansible-backstage-plugin-catalog-backend-module-rhaap
ansible-plugin-backstage-self-service
ansible-backstage-plugin-auth-backend-module-rhaap-provider
ansible-plugin-backstage-apme
ansible-backstage-plugin-catalog-backend-module-apme
```

Both jobs consume the same `plugin-pack.tar.gz` and `artifact.env`, retained as the
`apme-resolved-pack` Actions artifact for one day. Save them with the run URL and publishing
summary for longer retention. The metadata records source repository/SHA, upstream run ID,
artifact ID/name, pack filename/format, and full pack SHA256. The summary includes provenance
and the registry manifest digest; extractor logs identify the six validated plugins.

Let `T = apme-<full-upstream-source-sha>-<first-12-hex-of-pack-sha256>`. The CI tags are:

| Reference in `quay.io/aapdemo/apme-eap` | Contents |
| --- | --- |
| `T-amd64` | `linux/amd64`, based on `registry.redhat.io/rhdh/rhdh-hub-rhel9:1.9` |
| `T-arm64` | `linux/arm64`, based on `quay.io/rhdh-community/rhdh:1.9` |
| `T` | Manifest containing exactly those two platforms, published after both builds succeed |
| `latest` | Optional alias of the verified manifest, subject to the gate below |

Architecture tags and the manifest tag are write-once through these publishing commands:
immediately before each push, a remote inspection must confirm the tag is missing.
The workflow explicitly reuses existing architecture images only after verifying their
platform, source repository/revision, pack checksum, and registry digest. It reuses an
existing manifest only when the resolved source/pack tag matches and the manifest contains
exactly `linux/amd64` and `linux/arm64`; its digest is captured for deployment and promotion.
Existing immutable references are never pushed again. An authentication failure, transport
failure, unknown response, or invalid existing release stops the workflow. Standalone
publishing refuses existing tags. Mutable bases and build timestamps can change rebuilt
bytes, so a rebuild cannot replace an existing artifact-derived tag. Retain and deploy its
published digest.
These checks do not configure Quay tag immutability or make check-and-push atomic across
independent publishers; use registry tag protection to enforce that boundary for all clients.

Leave the **repository variable** `APME_QUAY_PUBLISH_ENABLED` unset until the first live
validation. Dispatch `publish_latest=false`, verify both architecture tags and the manifest,
then validate prebuilt deployment on x86 and ARM64 using [TEST_PLAN.md](TEST_PLAN.md).
After validation, set the variable to the literal `true`. With that gate open, matching
`main` pushes also update `latest`, and a manual run updates it only with
`publish_latest=true`. A manual request for `latest` with the gate closed fails before
resolution. Manual non-latest publishing remains available with the gate closed.
To promote the validated bootstrap release, dispatch again with the same source/pack inputs
and `publish_latest=true` after opening the gate. Use the recorded full source SHA and pack
format to select the same upstream release; `source_ref=latest` may resolve newer inputs.
The workflow verifies and reuses the existing architecture tags and manifest, then copies
the verified manifest digest to `latest` without rebuilding or overwriting release tags.

Incomplete/expired/ambiguous artifacts, bad checksums, unsafe archives, and wrong package
identities fail before architecture publishing. A failed build or registry push fails its
job; one architecture tag may already exist, but manifest assembly waits for both builds.
A manifest verification failure blocks `latest` promotion. Rerunning the workflow reuses
verified existing architecture images and publishes only missing tags. A complete existing
manifest can be promoted again after a failed `latest` copy. An incomplete existing manifest
fails validation and is never repaired by overwriting its tag; publish new source/pack inputs
instead. Never enable the gate to bypass validation.
Live Quay publication and x86/ARM64
deployment results have not yet been verified; the execution record is in the test plan.

### Build and publish a preloaded portal image locally

From the repository root, use Bash, Podman, GitHub CLI (`gh`), `jq`, `unzip`,
`tar`, and `sha256sum` (or `shasum`). Podman must be running. Supply `GH_TOKEN`
through your environment with permission to read upstream Actions artifacts.
For publishing, install Skopeo and supply `QUAY_USERNAME` and `QUAY_TOKEN` with push/pull access
to `quay.io/aapdemo/apme-eap`. Do not put tokens in command arguments or files.

```bash
# Build only (no Quay login or publication)
addons/apme-eap/ci/build-image.sh --source-ref latest

# Build and publish
addons/apme-eap/ci/build-image.sh --source-ref latest --push
```

The branch's existing CI example points at `ansible/ansible-rhdh-plugins`, which
is also this command's default source. Select `ansible/apme` when that repository
publishes the complete six-plugin pack, using `--source-repo ansible/apme`
or `APME_SOURCE_REPO=ansible/apme`. The command does not read Ansible defaults.

The resolver requires all six plugins and records the exact source SHA, artifact
ID, pack format, and artifact digest (`APME_PACK_SHA256`, the downloaded pack's
SHA256) in `artifact.env`. It also checks GitHub's downloaded payload digest when available.
The build uses the normalized `plugin-pack.tar.gz` with `Containerfile.ci`,
passing `PLUGIN_PACK_SHA256` and `PLUGIN_PACK_FORMAT`; extraction verifies the
pack again during the image build. OCI labels record the upstream repository,
source SHA, artifact ID, pack SHA256, and UTC build timestamp.

For `--push`, the immutable tag is
`apme-<upstream-source-sha>-<pack-sha256-prefix>-<architecture>` (12 hex digest
characters). Without `--architecture`, host `x86_64`/`amd64` maps to `amd64` and
`aarch64`/`arm64` maps to `arm64`; other hosts require an explicit supported architecture.
Build-only runs may use an unsuffixed local tag. Unsuffixed release tags are reserved
for CI manifest assembly. `--tag <tag>` accepts only
`[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}` and adds that tag as a Quay alias; the
immutable tag is always built and published first. Artifact-derived release tags cannot
be used as aliases, and `--push --tag latest` is rejected before fetching, building, or login.
Existing immutable tags stop the push, including alias publication;
retry only while the target tag is absent, or reuse the existing digest. Publication is always to
`quay.io/aapdemo/apme-eap`; only `--push` publishes. Output includes the local
image config digest, the pushed registry manifest digest when publishing,
and the path to `artifact.env`. This command builds one architecture and does not assemble
a multi-architecture manifest. `--architecture amd64|arm64` selects the architecture
explicitly and disallows `--tag`, as used by CI; select the matching `BASE_IMAGE`.
`latest` is reserved for the workflow's gated, verified multi-architecture promotion.
The workflow alone supplies `--reuse-existing` with `--push`, `--pack-dir`, and an explicit
`--architecture`; ordinary standalone publishing remains write-once.
Preserve the metadata file and the pack for provenance.
The default output directory is printed; set `--output-dir` to retain them at
a chosen location. Build and authentication scratch directories are removed.

To repeat a build, source only your trusted, locally generated metadata and
pass its recorded values back to the command:

```bash
source /path/to/previous-build/artifact.env
addons/apme-eap/ci/build-image.sh \
  --source-repo "$APME_SOURCE_REPO" --source-ref "$APME_SOURCE_SHA" \
  --pack-sha256 "$APME_PACK_SHA256" --output-dir /path/to/repeat-build
```

Sourced `APME_SOURCE_SHA` and `APME_PACK_SHA256` also serve as defaults when
not overridden (`APME_SOURCE_REF` takes precedence over `APME_SOURCE_SHA`).
The resolver downloads and validates a fresh artifact for that commit rather
than relying on a fixed artifact ID. A changed pack digest or an expired or
missing artifact fails the build. Retrying does not bypass verification.
This pins plugin inputs; a mutable base tag and build timestamp mean image
bytes can differ. Set `BASE_IMAGE` to a digest reference for a pinned base
(default: `registry.redhat.io/rhdh/rhdh-hub-rhel9:1.9`).

Optional `REGISTRY_REDHAT_USERNAME` and `REGISTRY_REDHAT_PASSWORD` authenticate
the base-image pull; otherwise Podman uses its existing authentication. Logins
use `--password-stdin`. A temporary credential helper reads credentials from
the environment over pipes and discards credential stores, so its configuration
and script contain no secrets and no registry password is written to disk.

`apme_preloaded_image_ref`, `apme_preloaded_image_pull_secret`, `apme_source_repo`,
and `apme_source_ref` are empty by default. The preloaded image settings select the
implemented deployment path described above. `apme_source_repo` and `apme_source_ref`
are not consumed by the deploy playbook or this standalone command: use CLI flags or
uppercase `APME_SOURCE_REPO` / `APME_SOURCE_REF` to fetch fresh artifacts, publish the
image, then select that image with `apme_preloaded_image_ref`. Leaving the image reference
empty preserves bundled-pack local builds; it does not request the latest upstream pack.

### Auto-Discovered Values

The deploy.sh wrapper automatically discovers:

- **openshift_api_url** - From kubeconfig
- **openshift_cluster_domain** - From console route or AAP route
- **aap_host** - From AAP route in aap-operator namespace
- **aap_username** - Fixed: `admin`
- **aap_password** - From AAP secret
- **openshift_project_name** - Fixed: `apme`

These are written to `~/.aap-demo/apme-eap-vars.yml` (regenerated on each deploy).

### GitHub Integration (Manual Configuration)

To enable repository quality scanning, edit the generated vars file:

```bash
vim ~/.aap-demo/apme-eap-vars.yml
```

Uncomment and fill in the GitHub section:

```yaml
configure_github_secrets: true
github_oauth_client_id: "YOUR_OAUTH_CLIENT_ID"
github_oauth_client_secret: "YOUR_OAUTH_CLIENT_SECRET"
github_app_id: "YOUR_APP_ID"
github_app_client_id: "YOUR_APP_CLIENT_ID"
github_app_client_secret: "YOUR_APP_CLIENT_SECRET"
github_app_private_key_path: "/path/to/private-key.pem"
github_token: "YOUR_PERSONAL_ACCESS_TOKEN"
```

Then re-run:

```bash
aap-demo enable apme-eap
```

For detailed GitHub setup instructions, see the
[APME EAP welcome pack documentation](https://drive.google.com/drive/folders/146Yc3TDKgX0l7k1etdJVXZ2NqhBvPuqr).

### Advanced Configuration

Edit `~/.aap-demo/apme-eap-vars.yml` to customize:

- **skip_plugin_push** - Skip the runtime OCI plugin push (default: `false`)
- **apme_oci_push_force** - Re-push the bundled plugin archive (default: `false`)
- **apme_pah_run_setup_pah** - Run `setup-pah` when `~/.aap-demo/galaxy-token` exists (default: `true`)
- **apme_pah_seed_apme_galaxy_servers** - POST AAP/community galaxy servers to APME gateway (default: `true`)
- **apme_pah_collections_enabled** - `auto` | `true` | `false` for portal PAH catalog sync (default: `auto`)
- **portal_helm_chart_version** - Override RHDH chart version
- **apme_helm_chart_version** - Override APME gateway chart version
- **devspaces_base_url** - Enable "Open in DevSpaces" actions

### Local Registry and Plugin Archives

The addon publishes the bundled APME dynamic-plugin archive to the in-cluster registry before
installing the portal Helm release. On OpenShift Local, that registry is exposed through an
OpenShift Route, so the registry API can return redirects during blob and manifest operations.
The publisher follows those redirects automatically.

The archive is stored under the repository path expected by the portal's runtime installer:

```text
registry.apps.127.0.0.1.nip.io/apme/apme-prototype-plugins:<version>
```

This path is part of the deployment contract. If the archive is pushed to only `apme:<version>`,
the portal can start successfully but its dynamic-plugin init container will fail with a
`manifest unknown` error because it requests `apme/apme-prototype-plugins:<version>`.

When troubleshooting a failed enablement, check the APME deployment report for the first
registry or portal error, then verify the archive and portal rollout:

```bash
kubectl get pods -n apme
kubectl rollout status deployment/redhat-rhaap-portal -n apme
```

The addon also uses explicit boolean comparisons for standalone Ansible `when` expressions and
`kubectl exec` for gateway seeding. These choices keep the playbooks compatible with the strict
conditional handling in newer Ansible releases and avoid the unavailable `kubernetes.core.k8s_exec`
client path in the APME execution environment.

For detailed registry troubleshooting, set `APME_OCI_PUSH_DEBUG=1` before enabling the addon. The
publisher then writes redirect chains, contacted endpoints, and progress for large blob uploads to
stderr without changing the normal output or registry behavior.

## Differences from Bash Addon

| Feature | Bash Addon | Playbook Addon |
|---------|------------|----------------|
| Implementation | Pure bash (~1,180 lines) | Ansible playbooks + bash wrapper (~300 lines) |
| Upstream alignment | Custom logic | Official APME welcome pack roles |
| Configuration | Hardcoded in script | Ansible vars file (editable) |
| Maintainability | Single script | Structured roles |
| Prerequisites | kubectl, helm, gh | ansible-playbook + kubectl, helm |
| Plugin delivery | Pre-built portal hub image | Same |

## File Structure

```
addons/apme-eap/
├── deploy.sh                     # Bash wrapper (addon contract)
├── defaults.yml                  # Default configuration
├── requirements.yml              # Ansible collection dependencies
├── README.md                     # This file
├── playbooks/
│   ├── deploy_apme_portal.yml    # Main deployment playbook
│   ├── tasks/
│   └── templates/
├── roles/
│   ├── openshift_apme_setup/
│   ├── aap_apme_prerequisites/
│   ├── apme_preloaded_image/
│   ├── apme_image_build/
│   ├── apme_helm_values/
│   ├── apme_scm_secrets/
│   ├── portal_helm_install/
│   └── apme_gateway_helm/
└── plugin_packs/                 # Bundled OCI plugin archive and manifest
```

## Runtime plugin architecture

The chart's `install-dynamic-plugins` loads the six plugins from the custom local or Quay
portal image. With `skip_plugin_push: true` and no prebuilt reference it uses runtime OCI
delivery from the existing local registry. The fallback archive is under `plugin_packs/`.

## Troubleshooting

Quick fixes below; root causes and anti-patterns are documented in the deployment history.

### Git Repositories catalog: blank page or `scrollWidth` TypeError

**Symptom**: `/self-service/repositories/catalog` shows
`Cannot read properties of null (reading 'scrollWidth')` or a blank table.

**Cause**: Two issues can affect Git Repositories:

1. **Init copied `/pre-installed/` then ran `install-dynamic-plugins`**, which removed APME
   plugins during cleanup (GitHub sign-in fallback). Init must only run
   `install-dynamic-plugins` — do not copy `/pre-installed/dynamic-plugins-root/` first.
2. **Catalog table (`@material-table/core` + React 18)**: `scrollWidth` TypeError on
   `/self-service/repositories/catalog`. Init patches served `dist-scalprum` bundles after
   install (not the full plugin source tree).

**Runtime plugin locations**:

| Path | Role |
| ---- | ---- |
| `registry.aap-demo-registry.svc.cluster.local:5000/apme` | In-cluster OCI registry |
| `/opt/app-root/src/dynamic-plugins-root/` | Writable volume populated by the chart init container |

**Solution**: Redeploy with current `apme-eap` playbooks so the chart init container reruns
`install-dynamic-plugins`. Hard-refresh the browser after redeploy so cached chunks are not reused.

### Git Repositories: `NotImplementedError: apiRef{plugin.apme.api}`

**Symptom**: Git Repositories or Self Service pages throw `No implementation available for apiRef{plugin.apme.api}`.

**Cause**: `ansible.plugin-backstage-apme` exports two API factories. Config must register both
`apmeApiFactory` (core APME client API) and `gitRepositoriesExtensionsApiFactory` (catalog UI
extensions). Registering only the extensions factory leaves `plugin.apme.api` unbound.

**Solution**: Redeploy with current `apme-eap` playbooks (values template includes both
factories). Hard-refresh the browser after redeploy.

### Python venv creation fails

**Symptom**: `python3 not found` or venv module errors

**Solution**:

```bash
# macOS
brew install python3

# Verify
python3 --version  # Should be 3.8 or later
```

### Ansible collection missing

**Symptom**: `ERROR! couldn't resolve module/action 'kubernetes.core.k8s'`

**Cause**: Virtual environment was corrupted or collections install failed

**Solution**:

```bash
# Remove and recreate venv
rm -rf ~/.aap-demo/apme-eap-venv
aap-demo enable apme-eap  # Will recreate venv
```

### Playbook fails with "AAP route not found"

**Symptom**: `AAP route not found. Deploy AAP first`

**Solution**: Deploy AAP before enabling this addon:

```bash
aap-demo deploy
aap-demo status  # Verify AAP is running
aap-demo enable apme-eap
```

### OAuth app creation fails

**Symptom**: Playbook fails during `aap_apme_prerequisites` role

**Solution**: Check AAP credentials:

```bash
kubectl get secret -n aap-operator <aap-cr-name> -o jsonpath='{.data.admin_password}' | base64 -d
# Verify password works by logging into AAP web UI
```

### OAuth login fails on CRC or MicroShift

The portal uses the external HTTPS AAP route for browser access. On CRC, its
backend uses `http://<aap-route>` for the in-cluster token exchange and
receives a `hostAliases` entry for the AAP Service. On MicroShift, `nip.io`
routes continue to use HTTPS through the router and receive router aliases for
the AAP and registry routes. This applies to the default `apps.crc.testing`
domain and `nip.io` routes respectively.

If login still fails, check the generated values and portal environment:

```bash
grep -E '^aap_(host|host_url):' ~/.aap-demo/apme-eap-vars.yml
kubectl exec deploy/redhat-rhaap-portal -n apme -- \
  printenv AAP_HOST_URL
kubectl get deploy redhat-rhaap-portal -n apme \
  -o jsonpath='{.spec.template.spec.hostAliases}'
```

### Portal image or plugin pull fails

**Symptom**: Portal pod stays in `ImagePullBackOff`

**Solution**:

1. Verify the local registry is running: `kubectl get pods -n aap-demo-registry`
2. Re-push the bundled OCI archive by setting `apme_oci_push_force: true`
3. Re-deploy: `aap-demo enable apme-eap`

### Helm bootstrap

**Symptom**: Playbook fails with `Failed to find required executable 'helm'` or `helm: command not found`

**Solution**: Re-run enable. The AAP job downloads the pinned Helm client
into its writable `/tmp` area; no Windows or host Helm installation is
required.

```bash
aap-demo enable apme-eap
```

The selected AAP execution environment must be able to reach `https://get.helm.sh`.

### Helm timeout

**Symptom**: Helm install times out waiting for pods

**Solution**:

```bash
# Check pod status
kubectl get pods -n apme

# Check events
kubectl get events -n apme --sort-by='.lastTimestamp'

# Common fix: resource constraints
kubectl describe pod -n apme <pod-name>
```

### GitHub secrets not working

**Symptom**: Repository registration fails or Quality tab missing

**Solution**:

1. Verify secrets-scm exists: `kubectl get secret secrets-scm -n apme`
2. Check secret keys: `kubectl get secret secrets-scm -n apme -o jsonpath='{.data}' | jq 'keys'`
3. Re-enable with `configure_github_secrets: true` in vars file
4. Redeploy: `aap-demo enable apme-eap`

## Post-Deployment Steps

### 1. Verify Deployment

**ARM (RHDH portal)**:

```bash
kubectl get route -n apme
# Open the route URL in browser
```

**x86 (APME gateway)**:

```bash
kubectl port-forward -n apme deploy/apme-gateway 8080:8080
# Open http://localhost:8080
```

### 2. Sign In

Use AAP admin credentials (same as AAP web UI).

### 3. Register Repository

1. Navigate to **Self-service** → **Register Git repository**
2. Select owner/org and repository
3. Confirm default branch
4. Verify repository appears in catalog

### 4. Run Quality Scan

1. Open registered repository
2. Select **Quality** tab
3. Start scan → Generate fixes → Push branch → Create PR

## Advanced Topics

### Using a Different Plugin Pack

Replace the bundled OCI archive and update `plugin-pack.manifest.yml`, then set
`apme_oci_push_force: true` for the next deployment.

### Debugging Playbook Execution

Run the playbook with verbose output:

```bash
cd addons/apme-eap
ansible-playbook playbooks/deploy_apme_portal.yml \
  -e @~/.aap-demo/apme-eap-vars.yml \
  -vvv
```

### Manual Playbook Execution

You can run the playbook directly without the wrapper:

```bash
cd addons/apme-eap

# Edit vars file manually
vim ~/.aap-demo/apme-eap-vars.yml

# Run playbook
ansible-playbook playbooks/deploy_apme_portal.yml \
  -e @~/.aap-demo/apme-eap-vars.yml \
  -e @defaults.yml
```

## References

- [APME EAP Welcome Pack](https://drive.google.com/drive/folders/146Yc3TDKgX0l7k1etdJVXZ2NqhBvPuqr) -
  Official APME deployment documentation
- [aap-demo Documentation](../../docs/FULL-README.md) - Main aap-demo documentation
- [APME GitHub Repository](https://github.com/ansible/apme) - APME source code
- [APME Plugins Repository](https://github.com/ansible/ansible-rhdh-plugins) - RHDH plugins for APME
<!-- markdownlint-disable MD013 -->
