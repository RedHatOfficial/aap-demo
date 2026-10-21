# APME CI Artifact-to-Quay Image Publishing Implementation Plan

<!-- markdownlint-disable MD013 -->

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the APME preloaded RHDH image from the newest valid upstream APME plugin artifact and publish it as `quay.io/aapdemo/apme-eap`, with immutable provenance tags and an opt-in deployment path.

**Architecture:** A reusable artifact resolver will select an exact successful upstream GitHub Actions run, download its artifact ZIP, extract the actual plugin pack, verify its SHA256, and emit metadata. A GitHub Actions workflow will build architecture-specific images, publish them to Quay, and assemble a multi-architecture manifest; local builds will use the same resolver. The addon will accept a prebuilt image reference, while the existing workstation build/push flow remains the fallback.

**Tech Stack:** GitHub Actions, `gh`/GitHub Actions artifacts, Bash, `jq`, `unzip`, Podman/Buildah, Skopeo, Python standard library, Ansible, Quay.io.

**Spec:** This plan is based on the user request and the current `origin/feature/apmecontainer` tree, especially `addons/apme-eap/Containerfile.ci`, `Containerfile`, `playbooks/roles/apme_image_build`, and the portal Helm values template.

## Global Constraints

- Publish only to `quay.io/aapdemo/apme-eap`; do not commit Quay, GitHub, or registry credentials.
- Resolve a concrete upstream run, artifact ID, commit SHA, and artifact digest; never build from an unverified moving download.
- The image build must fail closed unless all six plugins referenced by the APME Helm values are present.
- Keep the current checked-in OCI-pack/local-build deployment path working when no prebuilt image is configured.
- Publish immutable artifact-derived tags on every successful release build; update `latest` only for a main-branch publish or an explicitly enabled manual run.
- Do not use `latest` for the RHDH base image; retain the existing architecture-specific 1.9 defaults unless a separate version change is requested.
- The upstream source repository is configurable. The initial default must match the repository named by the branch’s CI example (`ansible/ansible-rhdh-plugins`); the resolver must also support `ansible/apme` when that repository is the owner of the complete six-plugin artifact.

---

### Task 1: Add deterministic upstream artifact resolution

**Files:**

- Create: `addons/apme-eap/ci/fetch-plugin-artifact.sh`
- Create: `test/test-apme-artifact-resolver.sh`
- Create: `test/fixtures/apme-artifact-runs.json`
- Create: `test/fixtures/apme-artifacts.json`

**Interfaces:**

- Consumes: `APME_SOURCE_REPO`, `APME_SOURCE_REF`, optional `APME_ARTIFACT_NAME`, `GH_TOKEN`, and a writable output directory.
- Produces: `<output>/plugin-pack.tar.gz`, `<output>/artifact.env`, and a nonzero exit when the run, artifact, archive, digest, or required plugin set is invalid.
- `artifact.env` must export `APME_SOURCE_REPO`, `APME_SOURCE_SHA`, `APME_RUN_ID`, `APME_ARTIFACT_ID`, `APME_ARTIFACT_NAME`, `APME_PACK_FILENAME`, `APME_PACK_FORMAT`, and `APME_PACK_SHA256`.

- [ ] **Step 1: Define the resolver selection contract.**

  Use `APME_SOURCE_REF=latest` to select the newest non-expired artifact from the newest successful run on the upstream repository’s default branch. For an explicit commit SHA, select the newest successful run whose `head_sha` exactly matches that SHA. When `APME_ARTIFACT_NAME` is set, require that exact artifact name; otherwise select exactly one non-expired artifact whose name contains `apme` or `plugin`, failing with the candidate names if the match is zero or ambiguous.

- [ ] **Step 2: Write fixture-driven failing tests.**

  Stub the GitHub API command and archive extraction command so tests do not require network access. Cover: latest-run selection, exact-SHA selection, expired-artifact rejection, ambiguous-artifact rejection, extraction of one `.oci.tar.gz` or `.tar.gz`, checksum emission, and failure when the extracted pack does not contain all six required plugin names:

  ```text
  ansible-plugin-scaffolder-backend-module-backstage-rhaap
  ansible-backstage-plugin-catalog-backend-module-rhaap
  ansible-plugin-backstage-self-service
  ansible-backstage-plugin-auth-backend-module-rhaap-provider
  ansible-plugin-backstage-apme
  ansible-backstage-plugin-catalog-backend-module-apme
  ```

  Run: `bash test/test-apme-artifact-resolver.sh`

  Expected: the tests initially fail because the resolver and fixtures do not exist.

- [ ] **Step 3: Implement the resolver.**

  Use `gh api` with `GH_TOKEN` to query workflow runs and artifacts, `jq` to select the run/artifact, `gh api .../actions/artifacts/<id>/zip` to download the GitHub artifact ZIP, and `unzip` into a temporary directory. Locate exactly one plugin pack, copy it to `plugin-pack.tar.gz`, calculate `sha256:<hex>`, inspect its contents, and write `artifact.env` with shell-safe quoted values. Inject the API command and archive tools through variables in the test path so the same script is testable without network access.

- [ ] **Step 4: Run the resolver tests.**

  Run: `bash test/test-apme-artifact-resolver.sh`

  Expected: PASS, including a clear error for a four-plugin artifact. This prevents the current `Containerfile.ci` behavior of warning about missing APME-specific plugins and producing an unusable `apme-eap` image.

- [ ] **Step 5: Commit the resolver.**

  ```bash
  git add addons/apme-eap/ci/fetch-plugin-artifact.sh test/test-apme-artifact-resolver.sh test/fixtures
  git commit -m "ci(apme-eap): resolve verified upstream plugin artifacts"
  ```

### Task 2: Make both container build paths consume verified packs

**Files:**

- Create: `addons/apme-eap/ci/extract-plugin-pack.py`
- Modify: `addons/apme-eap/Containerfile`
- Modify: `addons/apme-eap/Containerfile.ci`
- Create: `test/test-apme-plugin-pack.sh`

**Interfaces:**

- Consumes: `/tmp/plugin-pack.tar.gz`, `PLUGIN_PACK_SHA256`, and `PLUGIN_PACK_FORMAT` (`oci` or `npm`).
- Produces: the six validated plugin directories under `/opt/app-root/src/dynamic-plugins/dist/`.

- [ ] **Step 1: Write extractor tests for OCI and npm formats.**

  Add fixture archives generated in a temporary directory during the test. Assert that the extractor copies all six plugin directories, rejects a checksum mismatch, rejects a missing plugin, rejects path traversal entries, and rejects an unsupported archive format.

  Run: `bash test/test-apme-plugin-pack.sh`

  Expected: FAIL until the extractor exists.

- [ ] **Step 2: Implement `extract-plugin-pack.py`.**

  Use only Python standard-library modules. Verify `sha256:<hex>` before extraction, normalize the Docker/OCI archive layer contents or npm `package/` prefixes, allow only regular files and directories beneath the expected plugin roots, and fail if any of the six required plugin directories is absent. Exit with a concise missing-plugin list so CI diagnostics identify the incompatible upstream artifact.

- [ ] **Step 3: Refactor `Containerfile` to call the extractor.**

  Preserve the existing bundled OCI archive build context and architecture base-image argument. Copy `ci/extract-plugin-pack.py` into the image, invoke it with `PLUGIN_PACK_FORMAT=oci`, and remove the duplicated inline extraction implementation. Keep the final runtime user at `1001`.

- [ ] **Step 4: Refactor `Containerfile.ci` to use a normalized artifact.**

  Replace the hard-coded artifact ID and digest comments/defaults with runtime build arguments. Copy exactly `plugin-pack.tar.gz`, require a nonempty `PLUGIN_PACK_SHA256`, pass `PLUGIN_PACK_FORMAT`, and call the shared extractor. Remove the invalid example that saves a GitHub artifact ZIP directly as a tarball. The CI containerfile must no longer warn and continue when the two APME-specific plugins are missing.

- [ ] **Step 5: Run archive and syntax checks.**

  Run: `bash test/test-apme-plugin-pack.sh`

  Run: `python3 -m py_compile addons/apme-eap/ci/extract-plugin-pack.py`

  Expected: PASS. A real `podman build` is run in Task 4 after the upstream pack is resolved.

- [ ] **Step 6: Commit the container build changes.**

  ```bash
  git add addons/apme-eap/ci/extract-plugin-pack.py addons/apme-eap/Containerfile addons/apme-eap/Containerfile.ci test/test-apme-plugin-pack.sh
  git commit -m "build(apme-eap): validate and extract complete plugin packs"
  ```

### Task 3: Add a reusable local build and publish command

**Files:**

- Create: `addons/apme-eap/ci/build-image.sh`
- Modify: `addons/apme-eap/README.md`
- Modify: `addons/apme-eap/defaults.yml`

**Interfaces:**

- Consumes: `--source-ref latest|<commit-sha>`, `--source-repo owner/repo`, `--tag <tag>`, `--push`, `QUAY_USERNAME`, `QUAY_TOKEN`, and optional `REGISTRY_REDHAT_USERNAME`/`REGISTRY_REDHAT_PASSWORD`.
- Produces: a local image and, with `--push`, `quay.io/aapdemo/apme-eap:<tag>` plus its digest.

- [ ] **Step 1: Define image naming and metadata.**

  Use `quay.io/aapdemo/apme-eap` as the fixed repository. Default the immutable tag to `apme-<upstream-source-sha>-<pack-sha256-prefix>`; accept an explicit tag only after validating it against `[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}`. Add OCI labels for the upstream repository, source SHA, artifact ID, pack SHA256, and build timestamp.

- [ ] **Step 2: Implement build/push flow.**

  Resolve the pack with `fetch-plugin-artifact.sh`, select `Containerfile.ci` for normalized CI packs, build with Podman using `BASE_IMAGE`, `PLUGIN_PACK_SHA256`, and `PLUGIN_PACK_FORMAT`, and push with `skopeo` or Podman only when `--push` is supplied. Use `--password-stdin` for Quay login and never echo credentials. Print the final image digest and the generated `artifact.env` path.

- [ ] **Step 3: Add deployment defaults without changing the fallback.**

  Add empty-by-default variables to `defaults.yml`: `apme_preloaded_image_ref`, `apme_preloaded_image_pull_secret`, `apme_source_repo`, and `apme_source_ref`. An empty `apme_preloaded_image_ref` must continue to select the existing local/in-cluster `apme_image_build` role.

- [ ] **Step 4: Document local usage and the source distinction.**

  Document that the branch’s existing CI example points at `ansible/ansible-rhdh-plugins`, while `apme_source_repo` can be set to `ansible/apme` when that repository publishes the complete six-plugin pack. Include exact commands:

  ```bash
  addons/apme-eap/ci/build-image.sh --source-ref latest --push
  ```

  Explain that the resolver records the exact source SHA and artifact digest in `artifact.env`; a repeat build must accept those recorded values as inputs and still verify the downloaded artifact, rather than relying on a fixed artifact ID.

- [ ] **Step 5: Run local shell validation.**

  Run: `bash -n addons/apme-eap/ci/fetch-plugin-artifact.sh addons/apme-eap/ci/build-image.sh`

  Run: `shellcheck addons/apme-eap/ci/fetch-plugin-artifact.sh addons/apme-eap/ci/build-image.sh`

- [ ] **Step 6: Commit the local workflow.**

  ```bash
  git add addons/apme-eap/ci/build-image.sh addons/apme-eap/README.md addons/apme-eap/defaults.yml
  git commit -m "feat(apme-eap): add reproducible local image publishing"
  ```

### Task 4: Add the GitHub Actions Quay publishing workflow

**Files:**

- Create: `.github/workflows/apme-eap-image.yaml`
- Modify: `.github/workflows/lint.yaml`
- Modify: `.github/workflows/test.yaml`

**Interfaces:**

- Consumes: repository secrets `APME_ARTIFACT_TOKEN`, `QUAY_USERNAME`, `QUAY_TOKEN`, and `REGISTRY_REDHAT_USERNAME`/`REGISTRY_REDHAT_PASSWORD` when the RHEL base image requires authentication.
- Produces: architecture tags, a multi-architecture manifest at the immutable tag, and `latest` for the permitted publish events.

- [ ] **Step 1: Define workflow triggers and permissions.**

  Trigger on `push` to `main` when `addons/apme-eap/**`, `addons/apme-eap/ci/**`, or the workflow changes, plus `workflow_dispatch` inputs `source_ref`, `source_repo`, and `publish_latest`. Do not push from pull requests. Use minimal `contents: read`; Quay authentication comes from secrets rather than `GITHUB_TOKEN`.

- [ ] **Step 2: Add a resolve job.**

  Install `gh`, `jq`, `unzip`, Podman, and Skopeo; run the resolver once; upload the normalized pack and `artifact.env` as a short-lived workflow artifact; expose the immutable tag and upstream metadata through job outputs. The job must fail before any registry push if the six-plugin check fails.

- [ ] **Step 3: Add architecture build jobs.**

  Use a matrix for `amd64` and `arm64`, with the existing base-image choices: `registry.redhat.io/rhdh/rhdh-hub-rhel9:1.9` for amd64 and `quay.io/rhdh-community/rhdh:1.9` for arm64. Build and push `quay.io/aapdemo/apme-eap:<immutable-tag>-amd64` and `...-arm64`, logging into Quay only through the configured token. Keep the upstream metadata in OCI labels.

- [ ] **Step 4: Assemble and publish the manifest.**

  After both matrix jobs pass, create `quay.io/aapdemo/apme-eap:<immutable-tag>` from the two architecture tags, verify it with `skopeo inspect --raw`, and publish `latest` only when the event is a main push or `publish_latest=true` on a manual run. Add the image digest and upstream artifact metadata to `$GITHUB_STEP_SUMMARY`.

- [ ] **Step 5: Add CI checks for the new files.**

  Include the new workflow and CI scripts in existing YAML, shell, and Markdown lint coverage. Add a workflow syntax check using `actionlint` if it is available in the repository’s established CI tooling; otherwise validate the YAML with the existing yamllint job and run the resolver/extractor fixture tests in `test.yaml`.

- [ ] **Step 6: Validate the workflow without publishing.**

  Run: `yamllint .github/workflows/apme-eap-image.yaml`

  Run: `bash test/test-apme-artifact-resolver.sh && bash test/test-apme-plugin-pack.sh`

  For the first live run, use `workflow_dispatch` with `publish_latest=false`, confirm both architecture tags and the manifest digest, then enable the main-branch publish path.

- [ ] **Step 7: Commit the GitHub Actions workflow.**

  ```bash
  git add .github/workflows/apme-eap-image.yaml .github/workflows/lint.yaml .github/workflows/test.yaml
  git commit -m "ci(apme-eap): publish preloaded image to Quay"
  ```

### Task 5: Allow the addon to consume the published Quay image

**Files:**

- Create: `addons/apme-eap/playbooks/roles/apme_preloaded_image/defaults/main.yml`
- Create: `addons/apme-eap/playbooks/roles/apme_preloaded_image/meta/main.yml`
- Create: `addons/apme-eap/playbooks/roles/apme_preloaded_image/tasks/main.yml`
- Modify: `addons/apme-eap/playbooks/deploy_apme_portal.yml`
- Modify: `addons/apme-eap/playbooks/tasks/resolve_plugin_pack.yml`
- Modify: `addons/apme-eap/playbooks/roles/apme_helm_values/tasks/main.yml`
- Modify: `addons/apme-eap/playbooks/roles/apme_helm_values/files/portal-apme-values.yaml.template`
- Modify: `addons/apme-eap/deploy.sh`
- Modify: `addons/apme-eap/README.md`

**Interfaces:**

- Consumes: `apme_preloaded_image_ref`, optional `apme_preloaded_image_pull_secret`, and `apme_preloaded_image_verify`.
- Produces: `apme_preloaded_registry`, `apme_preloaded_repository`, and `apme_preloaded_tag` facts consumed by the Helm values renderer.

- [ ] **Step 1: Add explicit image-reference parsing and verification.**

  Parse `registry/repository:tag` or `registry/repository@sha256:digest` without accepting an unqualified image. When verification is enabled, run Skopeo inspect and fail with the exact reference if it is unavailable. Set facts for the template; preserve a digest as a digest rather than silently converting it to `latest`.

- [ ] **Step 2: Make deployment role selection conditional.**

  When `apme_preloaded_image_ref` is nonempty, run `apme_preloaded_image`, skip local `apme_image_build`, and skip the plugin OCI push if the prebuilt image has passed the six-plugin validation. When it is empty, retain the current `apme_oci_push` → `apme_image_build` sequence unchanged.

- [ ] **Step 3: Support optional Quay pull credentials.**

  If `apme_preloaded_image_pull_secret` is configured, create/update the corresponding Kubernetes docker-registry secret in the `apme` namespace and render it into the portal image `pullSecrets`. If it is empty, render no pull secret and document that the Quay repository must be readable by the cluster.

- [ ] **Step 4: Update Helm rendering for external image references.**

  Stop deriving the preloaded image registry by stripping `/apme` from the cluster registry when a prebuilt reference is active. Render the parsed registry, repository, and tag/digest facts into the existing placeholders, and assert that no placeholder or unqualified image remains.

- [ ] **Step 5: Add playbook checks.**

  Add a check-mode test covering both modes: prebuilt mode must not invoke Podman build, and fallback mode must still require `apme_oci_tar_resolved`. Validate the rendered image fields with `ansible-playbook --syntax-check` and the existing Ansible lint job.

- [ ] **Step 6: Document opt-in deployment.**

  Add an example to `README.md` and `deploy.sh` generated variables:

  ```yaml
  apme_preloaded_image_ref: quay.io/aapdemo/apme-eap:latest
  # Use an immutable tag or digest for repeatable deployments.
  apme_preloaded_image_pull_secret: ""
  ```

  Keep the default empty so existing welcome-pack deployments do not begin depending on Quay unexpectedly.

- [ ] **Step 7: Commit the deployment integration.**

  ```bash
  git add addons/apme-eap/playbooks addons/apme-eap/deploy.sh addons/apme-eap/README.md
  git commit -m "feat(apme-eap): support prebuilt Quay images"
  ```

### Task 6: End-to-end verification and operational handoff

**Files:**

- Modify: `addons/apme-eap/TEST_PLAN.md`
- Modify: `addons/apme-eap/README.md`
- Modify: `docs/adr/019b-apme-aap-native-execution.md`

- [ ] **Step 1: Run repository checks.**

  Run:

  ```bash
  bash test/test-apme-artifact-resolver.sh
  bash test/test-apme-plugin-pack.sh
  bash -n addons/apme-eap/ci/*.sh
  shellcheck addons/apme-eap/ci/*.sh
  yamllint addons/apme-eap .github/workflows/apme-eap-image.yaml
  ansible-playbook --syntax-check addons/apme-eap/playbooks/deploy_apme_portal.yml
  ```

  Expected: all checks pass without requiring Quay credentials or a live cluster.

- [ ] **Step 2: Execute a non-latest live publish.**

  Dispatch the workflow with the upstream default source and `publish_latest=false`. Verify the resolver summary contains the upstream run ID, source SHA, artifact ID, pack SHA256, and all six plugin names. Verify both architecture tags and the multi-architecture manifest in Quay.

- [ ] **Step 3: Execute a prebuilt deployment smoke test.**

  Set `apme_preloaded_image_ref` to the immutable manifest tag, deploy on an x86 cluster and an ARM64 cluster, and verify that the RHDH pod starts without downloading the six APME plugins from the plugin registry. Confirm the rendered Helm values contain the Quay image reference and correct architecture image.

- [ ] **Step 4: Verify fallback and failure behavior.**

  Run once with `apme_preloaded_image_ref` empty to confirm the existing local build path still works. Run the resolver against a four-plugin artifact and a mismatched checksum to confirm both fail before any Quay push.

- [ ] **Step 5: Update the test plan and ADR.**

  Record the new CI publish flow, required repository secrets, tag conventions, source-repository configuration, public/private Quay behavior, and fallback behavior. State that `latest` is a convenience tag and immutable tags/digests are the deployment recommendation.

- [ ] **Step 6: Commit the verification documentation.**

  ```bash
  git add addons/apme-eap/TEST_PLAN.md addons/apme-eap/README.md docs/adr/019b-apme-aap-native-execution.md
  git commit -m "docs(apme-eap): document Quay image publishing and consumption"
  ```

## Self-review checklist

- The existing hard-coded artifact ID and digest are removed from the build path.
- GitHub’s outer artifact ZIP is not passed directly to a tar extractor.
- The current four-plugin CI artifact cannot silently produce an incomplete six-plugin APME image.
- The exact Quay repository, credentials boundary, tag policy, and multi-architecture behavior are defined.
- Local builds, CI builds, prebuilt deployments, and fallback deployments have separate test paths.
- No task relies on a placeholder such as “later”, “TBD”, or an unspecified artifact name; ambiguous upstream artifact selection fails with actionable diagnostics.
