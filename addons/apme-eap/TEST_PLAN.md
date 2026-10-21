# APME Playbook Addon - Test Plan

## Overview

This plan covers artifact-to-Quay publishing, prebuilt portal images, and the local
bundled-pack fallback. The current addon runs deployment playbooks locally in an isolated
venv. The older AAP-native cases below describe historical/manual scenarios; their expected
results are not evidence of a current successful deployment. Only the dated execution
record reports checks actually run for this change.

## Test Environment

### Prerequisites

- OpenShift Local (CRC) or MicroShift cluster running
- AAP 2.7+ deployed (`aap-demo deploy`)
- `kubectl` CLI available
- `python3` (3.8+) installed
- No manual token setup required (auto-created)

### Test Data

- **AAP Route**: Retrieved from `kubectl get route -n aap-operator`
- **Admin Password**: Retrieved from `kubectl get secret aap-admin-password -n aap-operator`
- **Test Namespace**: `apme`

---

## Test Cases

### TC-001: Clean Installation (First-Time Deploy)

**Objective**: Verify full deployment flow with no existing resources

**Prerequisites**:

- Fresh AAP deployment (no prior APME addon runs)
- No `aap-api-token` secret exists
- No APME resources in AAP

**Steps**:

1. Run: `./aap-demo.sh enable apme-eap`
2. Observe console output
3. Check AAP Web UI for job

**Expected Results**:

- ✅ Venv created at `~/.aap-demo/apme-eap-venv/` with ansible-core
- ✅ API token auto-created and stored in `aap-api-token` secret
- ✅ AAP resources created:
  - Organization: Default (existing)
  - Project: `aap-demo-apme` (manual type)
  - Inventory: `localhost` with host `localhost`
  - Job Template: `Deploy APME`
- ✅ Job launched in AAP
- ✅ Console displays AAP Web UI link
- ✅ APME namespace created with pods running

**Validation Commands**:

```bash
# Check token secret
kubectl get secret aap-api-token -n aap-operator

# Check venv
ls ~/.aap-demo/apme-eap-venv/

# Check APME deployment
kubectl get pods -n apme
kubectl get route -n apme
```

**Pass Criteria**: All resources created, job completes successfully, APME portal accessible

---

### TC-002: Idempotent Re-Run

**Objective**: Verify addon can run multiple times without errors

**Prerequisites**:

- TC-001 completed successfully
- All AAP resources exist
- Token secret exists

**Steps**:

1. Run: `./aap-demo.sh enable apme-eap` (second time)
2. Observe console output

**Expected Results**:

- ✅ Existing token reused (no new token created)
- ✅ Existing venv reused
- ✅ Project check finds existing project OR creates new one with unique timestamp path
- ✅ Inventory reused (not recreated)
- ✅ Job template updated (if needed) or reused
- ✅ New job launched successfully

**Validation**:

```bash
# Check token ID hasn't changed
kubectl get secret aap-api-token -n aap-operator -o jsonpath='{.data.token}' | base64 -d

# Check AAP for multiple projects (timestamp-based paths)
# Via AAP UI: Resources → Projects
```

**Pass Criteria**: No errors, job launches successfully, existing resources reused where appropriate

---

### TC-003: Token Auto-Creation

**Objective**: Verify automatic OAuth2 token creation via basic auth

**Prerequisites**:

- AAP deployed
- No `aap-api-token` secret exists

**Steps**:

1. Delete token secret: `kubectl delete secret aap-api-token -n aap-operator`
2. Run: `./aap-demo.sh enable apme-eap`
3. Check token creation output

**Expected Results**:

- ✅ Console shows: "API token not found. Creating new token..."
- ✅ `create_aap_token.yml` playbook runs
- ✅ Token created via `/api/gateway/v1/tokens/` endpoint
- ✅ Token stored in Kubernetes secret
- ✅ Console shows: "✓ API token created successfully"

**Validation**:

```bash
# Verify token secret exists
kubectl get secret aap-api-token -n aap-operator -o yaml

# Check token works
export AAP_HOST="https://$(kubectl get route -n aap-operator -o jsonpath='{.items[0].spec.host}')"
export AAP_TOKEN="$(kubectl get secret aap-api-token -n aap-operator -o jsonpath='{.data.token}' | base64 -d)"
curl -k -H "Authorization: Bearer $AAP_TOKEN" "$AAP_HOST/api/controller/v2/me/" | jq .
```

**Pass Criteria**: Token auto-created, stored in secret, validates successfully against AAP API

---

### TC-004: AAP Resource Creation via API

**Objective**: Verify all AAP resources created correctly via REST API

**Prerequisites**:

- Clean AAP (no APME resources)
- Token exists

**Steps**:

1. Run: `./aap-demo.sh enable apme-eap`
2. Check AAP Web UI: Resources → Projects/Inventories/Templates

**Expected Results**:

- ✅ **Project**:
  - Name: `aap-demo-apme`
  - Type: Manual
  - Local Path: `aap-demo-apme-<timestamp>`
  - Organization: Default
  - Files exist in controller pod at `/var/lib/awx/projects/aap-demo-apme-<timestamp>/`
- ✅ **Inventory**:
  - Name: `localhost`
  - Organization: Default
  - Hosts: 1 (localhost with `ansible_connection: local`)
- ✅ **Job Template**:
  - Name: `Deploy APME`
  - Project: `aap-demo-apme`
  - Inventory: `localhost`
  - Playbook: `playbooks/deploy_apme_portal.yml`
  - Ask variables on launch: Yes

**Validation**:

```bash
# Check files in controller pod
POD=$(kubectl get pods -n aap-operator -l app.kubernetes.io/name=aap-controller-task -o name | head -1)
kubectl exec -n aap-operator $POD -- ls -la /var/lib/awx/projects/ | grep aap-demo-apme
```

**Pass Criteria**: All resources visible in AAP UI, files present on controller pod

---

### TC-005: Job Launch and Monitoring

**Objective**: Verify job launches correctly and output is streamed

**Prerequisites**:

- AAP resources exist (TC-004)

**Steps**:

1. Run: `./aap-demo.sh enable apme-eap`
2. Watch console output during job execution
3. Click AAP Web UI link from console

**Expected Results**:

- ✅ Console shows: "Launching APME deployment job..."
- ✅ Job ID displayed
- ✅ AAP Web UI link provided
- ✅ Job status polled (waiting message)
- ✅ Job output streamed to console
- ✅ Success/failure status displayed
- ✅ AAP UI shows same job with matching output

**Validation**:

```bash
# Check AAP UI manually
# Resources → Jobs → Recent Jobs → "Deploy APME"
```

**Pass Criteria**: Job launches, output streams, status reported correctly

---

### TC-006: MicroShift Compatibility (Namespace vs Project)

**Objective**: Verify playbooks use Kubernetes Namespace API (not OpenShift Project)

**Prerequisites**:

- MicroShift or OpenShift Local cluster

**Steps**:

1. Run: `./aap-demo.sh enable apme-eap`
2. Check for API errors related to `project.openshift.io`

**Expected Results**:

- ✅ No errors about `ProjectRequest` not found
- ✅ Namespace `apme` created successfully
- ✅ Playbook uses `kind: Namespace` not `kind: Project`

**Validation**:

```bash
# Verify namespace exists
kubectl get namespace apme

# Check playbook code
grep -r "kind: Namespace" addons/apme-eap/roles/openshift_apme_setup/tasks/
grep -r "ProjectRequest" addons/apme-eap/roles/openshift_apme_setup/tasks/ || echo "Good - no ProjectRequest"
```

**Pass Criteria**: Namespace created without Project API errors

---

### TC-007: Tar-Free File Copy

**Objective**: Verify file copy works without `tar` in controller pod

**Prerequisites**:

- AAP controller pod lacks `tar` binary (typical minimal image)

**Steps**:

1. Run: `./aap-demo.sh enable apme-eap`
2. Check file copy output

**Expected Results**:

- ✅ No errors about "tar not found"
- ✅ Files copied using `kubectl exec` + `cat` method
- ✅ All playbook files present in controller pod
- ✅ Directory structure preserved

**Validation**:

```bash
POD=$(kubectl get pods -n aap-operator -l app.kubernetes.io/name=aap-controller-task -o name | head -1)

# Check tar availability
kubectl exec -n aap-operator $POD -- which tar || echo "tar not found (expected)"

# Check files copied
kubectl exec -n aap-operator $POD -- find /var/lib/awx/projects/ -name "aap-demo-apme-*" -type d
kubectl exec -n aap-operator $POD -- ls /var/lib/awx/projects/aap-demo-apme-*/playbooks/
```

**Pass Criteria**: Files copied successfully without tar, all files present

---

### TC-008: Cleanup and Re-Deploy

**Objective**: Verify addon can be disabled and re-enabled cleanly

**Prerequisites**:

- APME addon currently deployed

**Steps**:

1. Run: `./aap-demo.sh disable apme-eap` or `./aap-demo.sh enable apme-eap --delete`
2. Verify cleanup
3. Run: `./aap-demo.sh enable apme-eap` again

**Expected Results**:

- ✅ Namespace deleted
- ✅ Vars file removed
- ✅ Token secret preserved (optional)
- ✅ AAP resources may remain (not critical)
- ✅ Re-deploy works without errors

**Validation**:

```bash
# After disable
kubectl get namespace apme  # Should not exist
ls ~/.aap-demo/apme-eap-vars.yml  # Should not exist

# After re-enable
kubectl get pods -n apme  # Should exist again
```

**Pass Criteria**: Clean disable, successful re-enable

---

### TC-009: Error Handling - AAP Not Deployed

**Objective**: Verify graceful failure when AAP is not available

**Prerequisites**:

- No AAP deployed in cluster

**Steps**:

1. Run: `./aap-demo.sh enable apme-eap`

**Expected Results**:

- ✅ Error message: "AAP not deployed. Run 'aap-demo deploy' first."
- ✅ No resources created
- ✅ Exit code non-zero

**Pass Criteria**: Clear error message, graceful exit

---

### TC-010: Error Handling - Invalid Credentials

**Objective**: Verify error handling when AAP credentials fail

**Prerequisites**:

- AAP deployed
- Corrupt `aap-admin-password` secret

**Steps**:

1. Backup secret: `kubectl get secret aap-admin-password -n aap-operator -o yaml > /tmp/aap-secret.yaml`
2. Corrupt it:
   `kubectl create secret generic aap-admin-password -n aap-operator \
   --from-literal=password=WRONG --dry-run=client -o yaml | kubectl apply -f -`
3. Run: `./aap-demo.sh enable apme-eap`
4. Restore: `kubectl apply -f /tmp/aap-secret.yaml`

**Expected Results**:

- ✅ Error during token creation: "Invalid username/password"
- ✅ Clear error message displayed
- ✅ Deployment stops

**Pass Criteria**: Authentication error caught and reported

---

## Performance Tests

### PT-001: Initial Deployment Time

**Objective**: Measure end-to-end deployment time

**Steps**:

1. Time full deployment: `time ./aap-demo.sh enable apme-eap`

**Acceptance Criteria**:

- First run (venv creation): < 5 minutes
- Subsequent runs (venv exists): < 3 minutes

---

### PT-002: Venv Size

**Objective**: Verify minimal venv footprint

**Steps**:

1. After deployment: `du -sh ~/.aap-demo/apme-eap-venv/`

**Acceptance Criteria**:

- Venv size: < 100 MB (target: ~50 MB)
- Much smaller than full Ansible install (150+ MB)

---

## Security Tests

### ST-001: Token Permissions

**Objective**: Verify token has minimal required scope

**Steps**:

1. Retrieve token: `kubectl get secret aap-api-token -n aap-operator -o jsonpath='{.data.token}' | base64 -d`
2. Check token in AAP UI: Settings → Users → admin → Tokens

**Expected Results**:

- ✅ Scope: `write` (not `admin` or broader)
- ✅ Description: "aap-demo APME addon API access"

---

### ST-002: Secret Storage

**Objective**: Verify sensitive data stored securely

**Steps**:

1. Check token secret: `kubectl get secret aap-api-token -n aap-operator -o yaml`

**Expected Results**:

- ✅ Token stored base64-encoded in Kubernetes secret
- ✅ Not logged to console or files
- ✅ No plaintext tokens in logs

---

## Regression Tests

### RT-001: Portal Addon Pattern Compatibility

**Objective**: Verify similar pattern to portal addon (basic auth token creation)

**Steps**:

1. Compare with portal addon: `grep -A 10 "create_api_token" addons/portal/deploy.sh`
2. Verify APME uses same approach

**Expected Results**:

- ✅ Both use basic auth with `aap-admin-password`
- ✅ Both POST to `/api/gateway/v1/tokens/`
- ✅ Both store in Kubernetes secrets

---

## Image Publishing and Consumption Verification

The [README publishing contract](README.md#ci-publishing-to-quay) defines the required
Actions secrets, source selection, six plugins, tag policy, and rollout gate. Use
`quay.io/aapdemo/apme-eap` for every publishing check. Use immutable tags or digests for
deployment; `latest` is only a convenience alias.

### CI-001: Offline Artifact, Build, and Deployment Checks

Run from the repository root with Bash, Python, `jq`, `unzip`, `tar`, a SHA256 tool,
ShellCheck, yamllint, Ansible, PyYAML, and the `kubernetes.core` collection installed:

```bash
bash test/test-apme-artifact-resolver.sh
bash test/test-apme-plugin-pack.sh
python3 test/test-apme-build-image.py -v
python3 test/test-apme-preloaded-image.py -v
python3 test/test-apme-image-workflow.py -v
bash -n addons/apme-eap/ci/*.sh
for script in addons/apme-eap/ci/*.sh; do bash -n "$script" || exit 1; done
shellcheck addons/apme-eap/ci/*.sh
yamllint addons/apme-eap .github/workflows/apme-eap-image.yaml
yamllint --strict -d "{extends: .yamllint, ignore: ''}" .github/workflows/apme-eap-image.yaml
ansible-playbook --syntax-check addons/apme-eap/playbooks/deploy_apme_portal.yml
markdownlint addons/apme-eap/README.md addons/apme-eap/TEST_PLAN.md docs/adr/019b-apme-aap-native-execution.md
make test
git diff --check
```

The loop checks each script: `bash -n` with multiple filenames only parses the first.
The explicit workflow lint overrides `.yamllint`'s `.github/` exclusion. Do not interpret
the first yamllint command alone as workflow validation. If system Python lacks PyYAML,
use the existing lint venv's Python and record the interpreter used; do not skip the tests.

**Acceptance criteria:** All focused suites pass, including simultaneous OCI/npm/build-record
selection, raw-gzip and ZIP transport, four-plugin npm/OCI rejection,
payload/pack digest mismatch, malformed identity, unsafe archive paths, expired/ambiguous
artifacts, and no fallback to an older successful run. Build-wrapper tests must stop before
push on resolution/checksum/build/login failure, preserve immutable tags with aliases,
reject existing immutable tags and unknown remote status, suffix host-architecture pushes,
and reject tampered matrix inputs. Manifest tests must block overwrites and retain promotion
checks. Deployment tests must cover external-route/digest rendering, all
six local plugin paths, missing private credentials, no build in prebuilt mode, check mode,
fallback pack requirements, cache validation, invalid-cache rebuild, and failed rebuilds
blocking Helm rendering. Container/registry commands in these suites are test doubles;
they do not establish live publishing or cluster results.

### CI-002: First Live Publish Without Updating Latest

**Prerequisites:** Workflow available on the repository default branch, Actions secrets
`APME_ARTIFACT_TOKEN`, `QUAY_USERNAME`, `QUAY_TOKEN`, and the Red Hat registry credential
pair when required. The artifact token must read the chosen upstream repository's Actions
artifacts. Confirm native `ubuntu-24.04` and `ubuntu-24.04-arm` runner access. Leave
`APME_QUAY_PUBLISH_ENABLED` unset or false during bootstrap. Record the current `latest`
digest (or its absence) before dispatch so it can be compared after publication.

1. Dispatch the workflow, initially using its upstream defaults:

   ```bash
   gh workflow run apme-eap-image.yaml --repo RedHatOfficial/aap-demo --ref main \
     -f source_repo=ansible/ansible-rhdh-plugins -f source_ref=latest -f publish_latest=false
   ```

2. Record the workflow run URL. Confirm resolution chose the newest successful upstream
   default-branch run and exactly one non-expired `apme`/`plugin` artifact, not an older
   substitute. For `ansible/apme`, dispatch with that explicit `source_repo`; only a full
   40-character commit SHA or `latest` is accepted for `source_ref`.
3. Record upstream repository/SHA, run ID, artifact ID/name, format, and pack SHA256.
   Save `apme-resolved-pack` before its one-day expiry. Verify extractor logs list all six
   plugin names from the README. The summary contains provenance and final manifest digest;
   `artifact.env` and the pack provide the retained build inputs. An ambiguous artifact
   name must fail; CI has no exact-name input. The standalone resolver supports
   `APME_ARTIFACT_NAME` for deliberate local selection.
4. Confirm both builds use that same pack. Copy the immutable tag and digest from the
   summary into `APME_TAG` and `APME_DIGEST`, then inspect the published results:

   ```bash
   : "${APME_TAG:?Set the immutable tag from the run summary}"
   : "${APME_DIGEST:?Set the sha256 manifest digest from the run summary}"
   APME_IMAGE=quay.io/aapdemo/apme-eap
   skopeo inspect --override-arch amd64 "docker://$APME_IMAGE:$APME_TAG-amd64" | jq '{Architecture, Os, Labels}'
   skopeo inspect --override-arch arm64 "docker://$APME_IMAGE:$APME_TAG-arm64" | jq '{Architecture, Os, Labels}'
   skopeo inspect --raw "docker://$APME_IMAGE@$APME_DIGEST" | \
     jq -e '.schemaVersion == 2 and (.manifests | length == 2) and
       ([.manifests[].platform | .os + "/" + .architecture] | sort == ["linux/amd64", "linux/arm64"])'
   ```

5. Compare the tag's raw manifest digest with the recorded digest using
   `skopeo manifest-digest` on a saved raw manifest. Check the child digests match the two
   architecture tags and OCI labels match the source SHA, artifact ID, and pack digest.
   Inspect anonymously for public Quay; for private Quay use an explicit `REGISTRY_AUTH_FILE`
   with pull access. Publication does not change Quay repository visibility.
6. Verify `latest` is unchanged (or remains absent) by comparing its pre-run and post-run
   digest. A failed architecture job can leave one architecture tag, but must not run the
   manifest job. Manifest verification failure must block `latest` promotion.

**Acceptance criteria:** `T-amd64`, `T-arm64`, and `T` exist with exactly the expected
platforms, where `T=apme-<source-sha>-<12-hex-pack-digest>`. AMD64 uses the Red Hat RHDH 1.9
base and ARM64 uses the community RHDH 1.9 base. No `latest` change occurs. Architecture
and manifest publishers refuse existing tags and unknown registry status before pushing.
Retry only failed jobs whose target tags are absent. If publication preceded a later
failure, reuse its recorded digest or choose new source/pack inputs for a full republish.
Registry tag protection is needed to prevent races with independent publishers.

### CI-003: Prebuilt Deployment on AMD64 and ARM64

Repeat on one x86 (`amd64`) cluster and one ARM64 cluster, using a deployment host whose
Podman architecture matches that cluster. Capture node architecture, namespace, rendered
Helm values, pod image/imageID, rollout result, and dynamic-plugin init logs for each run.

1. Set `apme_preloaded_image_ref` to `quay.io/aapdemo/apme-eap@$APME_DIGEST` (substitute the
   actual digest in YAML) or use the immutable manifest tag. Keep
   `apme_preloaded_image_verify: true` and run `aap-demo enable apme-eap`.
2. In public mode leave `apme_preloaded_image_pull_secret: ""`. Verify the cluster can pull
   anonymously. A local workstation login is not a cluster pull credential.
3. Repeat private mode with a pull-only Quay robot account. Follow the README auth-file
   instructions and set `apme_preloaded_image_auth_file` to its absolute path and
   `apme_preloaded_image_pull_secret: apme-quay-pull`. Verify the namespaced Secret has
   type `kubernetes.io/dockerconfigjson`, contains only the selected registry, and its name
   appears in Helm `image.pullSecrets` and the pod's `imagePullSecrets`. Do not save decoded
   credentials in test evidence. With no explicit Secret, private pulls require separately
   configured cluster credentials.
4. Confirm local Skopeo inspection and isolated Podman six-plugin validation succeed.
   Prebuilt mode must skip bundled-pack resolution, local-registry bootstrap,
   `apme_oci_push`, and `apme_image_build`. Check mode only parses/plans and cannot count as
   remote-image validation; disabling the Skopeo lookup still requires six-plugin validation.
5. Collect deployment evidence:

   ```bash
   kubectl get nodes -L kubernetes.io/arch
   helm get values redhat-rhaap-portal -n apme -o yaml
   kubectl rollout status deployment/redhat-rhaap-portal -n apme
   kubectl get pods -n apme -o wide
   kubectl get pods -n apme -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{.status.containerStatuses[*].imageID}{"\n"}{end}'
   # Choose the portal pod shown above:
   kubectl logs -n apme <portal-pod> -c install-dynamic-plugins
   ```

6. Verify the chart's portal image fields retain `quay.io`, `aapdemo/apme-eap`, and the
   validated digest (a verified tag is pinned). Compare pod imageID with the matching
   architecture child from CI-002. All six APME package entries must be local
   `./dynamic-plugins/dist/...` paths; init logs must not download those six from the OCI
   plugin registry. Other chart plugins may still use their configured sources.

**Acceptance criteria:** Healthy portal rollout on both architectures with the correct
image child, preserved digest, local six-plugin delivery, and working public/private pulls.

### CI-004: Bundled-Pack Fallback and Failure Behavior

1. Clear `apme_preloaded_image_ref` in the saved vars and unset `APME_PRELOADED_IMAGE_REF`.
   Keep `skip_plugin_push: false`, then deploy. Confirm local pack resolution supplies
   `apme_oci_tar_resolved` and deployment runs `apme_oci_push` before `apme_image_build`.
   Publication uses Podman push from its own storage, including on macOS Podman machine.
   The rendered portal image must use the external `oci_registry` route supported by
   the node runtime, retain its repository namespace, and pin the inspected/pushed digest
   with an empty tag. After a forced/repair rebuild, compare the new pod imageID with
   that pushed digest; an old locally cached tag must not determine deployment bytes.
   The fallback does not fetch current GitHub artifacts; source defaults are not a fetch switch.
2. Confirm a valid cached portal image is checked for all six plugin identities before
   reuse. An invalid cache must rebuild; a failed rebuild must stop before Helm renders
   local plugin paths. To force a rebuild or supply a custom OCI pack, use the README's
   [direct playbook invocation](README.md#use-a-published-quay-portal-image) after the
   wrapper has initialized its venv, collections, and generated vars. Load defaults first,
   then `-e @"$HOME/.aap-demo/apme-eap-vars.yml"`, then the extra `-e` overrides: empty
   `apme_preloaded_image_ref`, `skip_plugin_push: false`, and `apme_image_build_force: true`.
   For a custom pack, also supply the absolute `apme_oci_tar` path and independently verified
   `apme_image_build_pack_sha256`. Omit both custom-pack overrides to rebuild the bundled pack.
   Confirm this direct invocation rebuilds even when the cached image validates.
   Do not rely on saving these three fallback overrides in the generated vars: the wrapper
   regenerates that file on enable and does not preserve them. The documented preloaded-image
   settings are preserved; clear the prebuilt reference explicitly for this fallback test.
3. Test the opt-out separately: empty prebuilt reference plus `skip_plugin_push: true`
   skips both local publication and image build. The runtime installer then requires the
   plugin archive to have already been published at its expected registry path.
4. Run the offline suites in CI-001 for deliberate four-plugin and checksum-mismatch
   fixtures. Confirm nonzero exit and no build/push on invalid resolver output. Test invalid
   qualified references, unavailable images, missing private auth, wrong/missing plugins,
   and failed rebuilds; none may reach Helm installation with a falsely validated image.
5. With `APME_QUAY_PUBLISH_ENABLED` unset, manually request `publish_latest=true` and expect
   the gate to fail before resolution. Only after CI-002/CI-003 pass, set the repository
   variable to `true`; verify matching main pushes promote `latest`, manual `false` does
   not, and manual `true` does. Confirm the promoted digest matches the verified manifest.

**Acceptance criteria:** Both local modes remain usable, invalid inputs fail closed, and
promotion follows the gate. A failed remote push may leave already published architecture
tags; it is not a transactional rollback. The standalone build wrapper publishes a single
architecture; its explicit `--tag` aliases are outside the CI gate and must not be mistaken
for CI's multi-architecture promotion.

### Task 6 Execution Record — 2026-10-21

Offline checks target implementation commit `b03dc06` plus this documentation change on
`codex/apme-quay-ci-publishing`, using macOS with an available ARM64 Podman machine.
No live workflow was dispatched, registry image built/pushed, or cluster deployment run.

| Check | Result / evidence |
| --- | --- |
| `bash test/test-apme-artifact-resolver.sh` | PASS: 62 cases, including four-plugin npm/OCI failures and independent GitHub ZIP digest checks. |
| `bash test/test-apme-plugin-pack.sh` | PASS: 17 tests, including checksum mismatch before parsing/writing and the real checked-in six-plugin pack. |
| `python3 test/test-apme-build-image.py -v` | PASS: 15 tests with container/registry doubles, including failed pushes and tampered matrix inputs. |
| `/Users/cferman/Documents/GitHub/aap-demo/.venv-lint/bin/python3 test/test-apme-preloaded-image.py -v` | PASS: 18 tests. System `python3` initially failed with `ModuleNotFoundError: No module named 'yaml'`; the existing lint venv supplies PyYAML and Ansible. |
| Shell syntax / ShellCheck | PASS for `addons/apme-eap/ci/*.sh`; each script also checked individually. |
| Brief's addon/workflow yamllint command | Exit 0, no errors, 53 existing warnings (document-start/line-length); `.github/` excluded by repo config. |
| Explicit strict workflow YAML lint with `ignore: ''` | PASS, no warnings. `actionlint` unavailable; YAML/fixture checks used as specified by the plan. |
| Deployment playbook syntax check | PASS, two implicit-localhost/inventory warnings; initial sandbox temp-directory denial resolved by rerunning with filesystem permission. |
| `make test` | PASS: repository shell syntax and help-command dry run. |
| Markdown lint and `git diff --check` | PASS for the three changed documentation files; no whitespace errors. |
| Secret baseline refresh | The first pre-commit run updated `.secrets.baseline` line numbers for existing documentation findings and its timestamp; no new hashed findings were added. |

Live CI-002/CI-003/CI-004 checks remain **PENDING**. `APME_ARTIFACT_TOKEN`, `QUAY_USERNAME`,
`QUAY_TOKEN`, `REGISTRY_REDHAT_USERNAME`, and `REGISTRY_REDHAT_PASSWORD` were unset in this
process; repository secret configuration was not inspected. Podman reports ARM64, which
does not supply an x86 cluster or prove either cluster smoke test. Do not enable the
publishing gate based on offline results. Pending evidence includes upstream live selection,
base-image access, native ARM runner access, both Quay architecture tags and manifest digest,
public/private pulls, x86/ARM64 prebuilt rollouts, local fallback/Podman-machine publishing,
and live `latest` promotion. Preserve run URLs, provenance, and cluster observations when
these checks are performed.

### Whole-Branch Review Fix Validation — 2026-10-21

The review fixes add format-specific artifact selection, raw gzip transport, host
architecture publication tags, fail-closed write-once checks for architecture images
and manifests, and external-route fallback images pinned to registry digests.
The artifact fixture includes the simultaneous npm/OCI and `.dockerbuild` names observed
in upstream run `35992077617`; checking those names does not validate a live download.
Targeted suites exercise the real resolver, build wrapper, manifest step, Ansible roles,
and Helm rendering with offline registry/container command doubles. Live Quay publication,
both architecture pulls, Podman-machine publication, and cluster rollouts remain **PENDING**.

| Targeted command | Offline result |
| --- | --- |
| `bash test/test-apme-artifact-resolver.sh` | 69/69 passed, including both transport formats and simultaneous upstream pack/record names. |
| `bash test/test-apme-plugin-pack.sh` | 17/17 passed; six-plugin extraction and safety checks preserved. |
| `python3 test/test-apme-build-image.py -v` | 20/20 passed, including architecture suffixes, reserved aliases, existing tags, and unknown registry status. |
| Lint venv `python3 test/test-apme-preloaded-image.py -v` | 19/19 passed; cached, forced, and repaired fallback images use the external route and correct digest. |
| Lint venv `python3 test/test-apme-image-workflow.py -v` | 3/3 passed; first publication, overwrite prevention, and manifest promotion checks execute the real workflow shell. |
| Focused Ansible lint / playbook syntax | Passed: 0 rule failures/warnings; syntax check has the existing implicit-localhost inventory warnings. |
| Shell syntax, ShellCheck, shfmt, Markdown lint, `make test`, `git diff --check` | Passed. |
| Publishing workflow strict YAML lint | Passed; the test workflow and Ansible role retain their existing document-start warnings under the repository YAML config. |

## Test Summary Template

Copy this template for a live run and replace each status only after collecting evidence.
The expected-result checkmarks in the test cases are acceptance criteria, not run results.

```markdown
## Test Execution Summary

**Date**: YYYY-MM-DD
**Tester**: Name
**Environment**: OpenShift Local / MicroShift
**AAP Version**: 2.7.x

### Test Results

| Test ID | Test Name | Status | Notes |
|---------|-----------|--------|-------|
| TC-001 | Clean Installation | NOT RUN | |
| TC-002 | Idempotent Re-Run | NOT RUN | |
| TC-003 | Token Auto-Creation | NOT RUN | |
| TC-004 | AAP Resource Creation | NOT RUN | |
| TC-005 | Job Launch and Monitoring | NOT RUN | |
| TC-006 | MicroShift Compatibility | NOT RUN | |
| TC-007 | Tar-Free File Copy | NOT RUN | |
| TC-008 | Cleanup and Re-Deploy | NOT RUN | |
| TC-009 | AAP Not Deployed Error | NOT RUN | |
| TC-010 | Invalid Credentials Error | NOT RUN | |
| PT-001 | Deployment Time | NOT RUN | |
| PT-002 | Venv Size | NOT RUN | |
| ST-001 | Token Permissions | NOT RUN | |
| ST-002 | Secret Storage | NOT RUN | |
| RT-001 | Portal Addon Compatibility | NOT RUN | |
| CI-001 | Offline image checks | NOT RUN | |
| CI-002 | Non-latest Quay publish | NOT RUN | Run URL, immutable tag, manifest digest |
| CI-003 | x86/ARM64 prebuilt deployment | NOT RUN | Cluster/architecture, public/private pull evidence |
| CI-004 | Fallback, failures, latest gate | NOT RUN | |

### Issues Found

1. [If any issues] Description, severity, workaround

### Recommendations

1. [If applicable] Suggestions for improvements
```

---

## Automated Test Script

```bash
#!/usr/bin/env bash
# Quick smoke test for APME addon

set -e

echo "=== APME Addon Smoke Test ==="

# TC-003: Token creation
echo "TEST: Token auto-creation"
kubectl delete secret aap-api-token -n aap-operator 2>/dev/null || true
./aap-demo.sh enable apme-eap
kubectl get secret aap-api-token -n aap-operator || exit 1
echo "✅ PASS: Token created"

# TC-004: AAP resources
echo "TEST: AAP resources exist"
# Would need API calls to verify - left as manual test

# TC-006: MicroShift compat
echo "TEST: Namespace created"
kubectl get namespace apme || exit 1
echo "✅ PASS: Namespace exists"

# TC-007: Files copied
echo "TEST: Files in controller pod"
POD=$(kubectl get pods -n aap-operator -l app.kubernetes.io/name=aap-controller-task -o name | head -1)
kubectl exec -n aap-operator $POD -- ls /var/lib/awx/projects/ | grep aap-demo-apme || exit 1
echo "✅ PASS: Files copied"

echo ""
echo "=== Smoke Test Complete ==="
echo "Run full test plan manually for comprehensive validation"
```
