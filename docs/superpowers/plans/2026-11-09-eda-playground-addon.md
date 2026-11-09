# EDA Playground Addon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the closed EDA Playground addon into the current
Bash/macOS/Linux workflow with AAP OAuth authentication, safe cleanup, catalog
integration, and automated coverage.

**Architecture:** Add a self-contained `addons/eda-playground` Bash deployer
that owns its Kubernetes namespace, OAuth application, credentials, and SCC
binding. Register it in the existing legacy Bash CLI and dashboard catalog,
while deliberately leaving the Python CLI and native Windows addon paths
unchanged.

**Tech Stack:** Bash, `kubectl`, optional `oc`, `curl`, `jq`, OpenShift Route,
Kubernetes YAML, Python dashboard tests, shell tests, pre-commit hooks.

**Spec:**
[docs/superpowers/specs/2026-11-09-eda-playground-addon-design.md](../specs/2026-11-09-eda-playground-addon-design.md)

## Global Constraints

- Support the existing legacy Bash addon workflow on macOS and Linux only.
- Do not merge `origin/feature/eda-playground` wholesale; port only the addon and required registrations.
- Keep Python CLI support and native Windows support out of this release.
- Only mutate the owned OAuth application, dedicated SCC binding, and configured `eda-playground` namespace.
- Never print AAP passwords, OAuth client secrets, or session secrets.
- Store OAuth state in a `0700` directory with a `0600` credentials file.
- Make the image reference configurable and explicit; document the personal GHCR image as experimental.
- Use the current branch’s route, secret, addon catalog, and test conventions.

## Review Focus

- Existing OAuth application with no recoverable client secret: recreate only
  the owned application and update local state; test in Task 2.
- Cluster domain other than `127.0.0.1.nip.io`: render the route and redirect
  URI from discovered domain; test in Task 2.
- MicroShift/CRC in-cluster AAP access: add the AAP service host alias only when needed; test in Task 2.
- Repeated or partial cleanup: tolerate missing resources without deleting
  unrelated namespaces or OAuth applications; test in Task 3.
- Secret-bearing command output: redact or omit credentials from success and failure paths; test in Task 3.

---

### Task 1: Add the addon manifests and deployment script skeleton

**Files:**

- Create: `addons/eda-playground/README.md`
- Create: `addons/eda-playground/deploy.sh`
- Create: `addons/eda-playground/namespace.yaml`
- Create: `addons/eda-playground/configmap.yaml`
- Create: `addons/eda-playground/service.yaml`
- Create: `addons/eda-playground/deployment.yaml`
- Create: `addons/eda-playground/route.yaml`
- Test: `test/test-eda-playground-addon.sh`

**Interfaces:**

- Consumes: the seven source files from
  `origin/feature/eda-playground` commit `92d3561` and the current addon
  conventions in `addons/keycloak/`.
- Produces: executable `addons/eda-playground/deploy.sh` accepting no argument
  for deploy and `--delete`/`delete` for cleanup, plus valid Kubernetes YAML
  templates.

- [ ] **Step 1: Write the failing static checks.**

  Create `test/test-eda-playground-addon.sh` with checks for the addon
  directory, executable deployer, all seven manifests/docs, `apiVersion`/`kind`
  declarations, the dedicated `eda-playground` namespace, the dedicated service
  account, the OAuth Secret reference, readiness/liveness probes, resource
  requests/limits, and Route host templating.

- [ ] **Step 2: Run the new test to verify it fails.**

  Run:

  ```bash
  bash test/test-eda-playground-addon.sh
  ```

  Expected: FAIL because the addon files do not yet exist.

- [ ] **Step 3: Port the source manifests and documentation.**

  Copy the seven files from the source branch as a starting point, then make
  these current-branch edits before staging them:

  - retain the dedicated namespace and service account;
  - use a configurable image repository/tag or digest in `deploy.sh` when rendering `deployment.yaml`;
  - retain non-secret environment variables in the Deployment and reference
    OAuth values only through the Kubernetes Secret;
  - preserve probes and bounded CPU/memory requests and limits;
  - leave the Route host as a known template value for deploy-time replacement;
  - document the legacy Bash-only support boundary and the experimental personal GHCR image.

- [ ] **Step 4: Run the static test and YAML checks.**

  Run:

  ```bash
  bash test/test-eda-playground-addon.sh
  pre-commit run --files addons/eda-playground/*.yaml addons/eda-playground/deploy.sh test/test-eda-playground-addon.sh
  ```

  Expected: PASS for the static checks and all applicable pre-commit hooks.

- [ ] **Step 5: Commit the self-contained addon package.**

  ```bash
  git add addons/eda-playground test/test-eda-playground-addon.sh
  git commit -S -m "feat: add EDA Playground addon manifests"
  ```

### Task 2: Implement safe OAuth-aware deployment and route handling

**Files:**

- Modify: `addons/eda-playground/deploy.sh`
- Modify: `addons/eda-playground/deployment.yaml`
- Modify: `addons/eda-playground/route.yaml`
- Test: `test/test-eda-playground-deploy.sh`

**Interfaces:**

- Consumes: `kubectl`, `jq`, `curl`, optional `oc`, the current AAP route and
  admin-password Secret, plus `NAMESPACE`, `AAP_NAMESPACE`, `OAUTH_APP_NAME`,
  image settings, and OAuth state directory overrides.
- Produces: an idempotent deploy flow that creates the Kubernetes Secret and
  owned resources, writes OAuth state with safe permissions, and reports the
  final route without secrets.

- [ ] **Step 1: Write mocked deploy tests for the required decision points.**

  Create `test/test-eda-playground-deploy.sh` using a temporary `PATH`
  containing command stubs for `kubectl`, `oc`, `curl`, `jq`, `openssl`, and
  `base64`. Have the stubs record arguments and return fixture JSON for these
  cases:

  1. first deployment creates an organization and OAuth application;
  2. existing application plus matching saved client secret reuses credentials;
  3. existing application without a matching saved secret deletes and recreates only that application;
  4. a non-default cluster domain is rendered into Route and redirect URI;
  5. MicroShift mode patches the AAP host alias after the Deployment exists;
  6. output contains no fixture password, client secret, or session secret.

- [ ] **Step 2: Run the mocked tests to verify they fail.**

  Run:

  ```bash
  bash test/test-eda-playground-deploy.sh
  ```

  Expected: FAIL because the deployer does not yet satisfy the current test fixtures and configuration contract.

- [ ] **Step 3: Implement prerequisite and discovery helpers.**

  In `deploy.sh`, add or adapt helpers so deploy validates `kubectl
  cluster-info`, AAP route availability, the admin Secret, `jq`, and the
  Gateway ping endpoint before making changes. Resolve the route and
  credentials without echoing their values. Derive the cluster domain from
  `ingresses.config/cluster` and fall back to the AAP route suffix for
  MicroShift/CRC.

- [ ] **Step 4: Implement owned OAuth application reconciliation.**

  Query the Gateway organizations endpoint; create `Default` only when none
  exists. Query applications by the exact configured name. Persist
  `oauth_app_id`, `client_id`, and `client_secret` under the `0700` state
  directory. Reuse the saved secret only when its stored application ID
  matches the discovered application ID; otherwise delete and recreate the
  named application before continuing.

- [ ] **Step 5: Implement Secret creation and manifest rendering.**

  Generate the session secret with `openssl rand -hex 16`, create/update the
  Kubernetes Secret using `kubectl create -f -`, apply
  namespace/ConfigMap/Service/Deployment, and render the Route host from
  `CLUSTER_DOMAIN`. Ensure the credentials file is written with mode `0600`
  and that shell tracing is not enabled around secret-bearing commands.

- [ ] **Step 6: Implement MicroShift host aliasing and redirect update.**

  When the cluster is MicroShift/CRC, resolve the AAP Service ClusterIP and
  patch only the `eda-playground` Deployment’s pod-template host aliases. Wait
  for rollout. After the Route exists, PATCH the owned Gateway OAuth
  application with exactly `https://<eda-route>/auth/callback`; fail with a
  recovery message if this update fails.

- [ ] **Step 7: Run the mocked tests and shell lint.**

  Run:

  ```bash
  bash test/test-eda-playground-deploy.sh
  shellcheck addons/eda-playground/deploy.sh
  ```

  Expected: PASS, including the reuse, recreate, domain, host-alias, and redaction cases.

- [ ] **Step 8: Commit the deployment behavior.**

  ```bash
  git add addons/eda-playground/deploy.sh addons/eda-playground/deployment.yaml \
    addons/eda-playground/route.yaml test/test-eda-playground-deploy.sh
  git commit -S -m "feat: configure EDA Playground with AAP OAuth"
  ```

### Task 3: Implement idempotent cleanup and safety tests

**Files:**

- Modify: `addons/eda-playground/deploy.sh`
- Test: `test/test-eda-playground-delete.sh`
- Modify: `test/test-eda-playground-deploy.sh`

**Interfaces:**

- Consumes: the OAuth metadata and namespace settings from Task 2.
- Produces: `deploy.sh --delete` and `deploy.sh delete` that remove only owned
  resources and succeed when cleanup is repeated.

- [ ] **Step 1: Write cleanup tests.**

  Create `test/test-eda-playground-delete.sh` with command stubs that record DELETE operations. Assert that cleanup:

  - uses the saved OAuth application ID when available;
  - falls back to an exact-name Gateway lookup when metadata is absent;
  - never deletes an application with a different name or ID;
  - removes the dedicated `anyuid` binding when `oc` is present;
  - deletes only the configured `eda-playground` namespace;
  - removes local OAuth state after the cleanup attempt;
  - exits successfully when AAP, OAuth, SCC, or namespace resources are already absent.

- [ ] **Step 2: Run cleanup tests to verify they fail.**

  Run:

  ```bash
  bash test/test-eda-playground-delete.sh
  ```

  Expected: FAIL until cleanup is adapted to the current ownership and repeatability requirements.

- [ ] **Step 3: Implement guarded cleanup.**

  Refactor cleanup into explicit steps. Initialize lookup variables before
  conditional branches, treat missing resources as non-fatal, use exact
  application IDs for DELETE calls, remove the SCC binding before namespace
  deletion, and delete the configured namespace only. Do not use a broad
  application or namespace selector.

- [ ] **Step 4: Add output redaction assertions.**

  Extend the deploy and delete tests so captured stdout/stderr does not contain
  the fixture AAP password, OAuth client secret, session secret, or raw API
  response containing those values. Keep actionable endpoint names and
  resource identifiers that are not credentials.

- [ ] **Step 5: Run the safety suite.**

  Run:

  ```bash
  bash test/test-eda-playground-delete.sh
  bash test/test-eda-playground-deploy.sh
  shellcheck addons/eda-playground/deploy.sh
  ```

  Expected: PASS for first cleanup, repeated cleanup, partial cleanup, and redaction.

- [ ] **Step 6: Commit cleanup behavior.**

  ```bash
  git add addons/eda-playground/deploy.sh test/test-eda-playground-delete.sh test/test-eda-playground-deploy.sh
  git commit -S -m "fix: make EDA Playground cleanup safe and repeatable"
  ```

### Task 4: Register the addon in the Bash CLI and dashboard catalog

**Files:**

- Modify: `aap-demo.sh:359,702-748,3012`
- Modify: `scripts/aap-demo-completion.bash`
- Modify: `config/addons-dashboard.json`
- Modify: `includes/cmd-status.sh`
- Test: `test/test-eda-playground-addon.sh`
- Test: `test/test-bash-completion.sh`
- Test: `test/test-dashboard.py`

**Interfaces:**

- Consumes: the executable `addons/eda-playground/deploy.sh` from Tasks 1–3.
- Produces: `aap-demo enable eda-playground`, `aap-demo disable
  eda-playground`, help output, completion, status visibility, and dashboard
  health metadata.

- [ ] **Step 1: Add failing registration assertions.**

  Extend `test/test-eda-playground-addon.sh` to require `eda-playground` in
  the enable/disable parser and `AVAILABLE_ADDONS`, a help summary, and the
  addon deploy path. Extend the completion test to expect the addon for
  `enable` and `disable`. Extend the dashboard test fixture/catalog assertion
  to require the addon ID and namespace health entry.

- [ ] **Step 2: Run the registration tests to verify they fail.**

  Run:

  ```bash
  bash test/test-eda-playground-addon.sh
  bash test/test-bash-completion.sh
  pytest -q test/test-dashboard.py -k 'catalog or addon'
  ```

  Expected: FAIL because the current CLI and catalog do not list `eda-playground`.

- [ ] **Step 3: Register the Bash command surface.**

  Add `eda-playground` to the parser case in `aap-demo.sh`, add a help summary
  such as `EDA Playground for testing event-driven integrations`, and append it
  to `AVAILABLE_ADDONS`. Do not add it to
  `src/aap_demo/cluster/status.py` or
  `powershell/native/Private/Addons.ps1` because those interfaces are
  explicitly out of scope.

- [ ] **Step 4: Register completion, legacy status, and dashboard health.**

  Add the addon to `scripts/aap-demo-completion.bash`. Add its
  namespace/resource health metadata to `config/addons-dashboard.json` using
  the existing namespace or pod-prefix health schema. Update legacy status
  only where it consumes `AVAILABLE_ADDONS`; do not alter the Python status
  addon tuple. Ensure the dashboard catalog and Bash `AVAILABLE_ADDONS` remain
  equal.

- [ ] **Step 5: Run registration tests.**

  Run:

  ```bash
  bash test/test-eda-playground-addon.sh
  bash test/test-bash-completion.sh
  pytest -q test/test-dashboard.py -k 'catalog or addon'
  ```

  Expected: PASS with the addon listed exactly once in each Bash/catalog
  surface and absent from Python/PowerShell addon lists.

- [ ] **Step 6: Commit CLI integration.**

  ```bash
  git add aap-demo.sh scripts/aap-demo-completion.bash \
    config/addons-dashboard.json includes/cmd-status.sh \
    test/test-eda-playground-addon.sh test/test-bash-completion.sh \
    test/test-dashboard.py
  git commit -S -m "feat: register EDA Playground in addon CLI"
  ```

### Task 5: Complete documentation and validation coverage

**Files:**

- Modify: `addons/eda-playground/README.md`
- Modify: `docs/guides/addons.md`
- Modify: `docs/CHANGELOG.md`
- Modify: `test/test-eda-playground-addon.sh`
- Create: `test/test-eda-playground-live.sh`

**Interfaces:**

- Consumes: the completed addon and CLI registration from Tasks 1–4.
- Produces: user-facing Bash-only documentation, explicit image/security
  limitations, and a disposable-cluster live smoke test.

- [ ] **Step 1: Add documentation assertions.**

  Extend the static addon test to require the README to document
  `aap-demo enable eda-playground`, `aap-demo disable eda-playground`, legacy
  Bash/macOS/Linux support, the personal GHCR image limitation, configurable
  image reference, OAuth behavior, and the no-production-support warning.

- [ ] **Step 2: Update the addon guide and changelog.**

  Add the addon to `docs/guides/addons.md` under the legacy Bash add-ons
  section, including prerequisites, access, cleanup, and the explicit
  Python/Windows deferral. Add a concise `docs/CHANGELOG.md` entry naming the
  new experimental addon and its image limitation; do not claim official
  product support.

- [ ] **Step 3: Add the live smoke-test harness.**

  Create `test/test-eda-playground-live.sh` that exits with a clear skip
  message unless `AAP_DEMO_RUN_LIVE_TESTS=true`. When enabled, run these exact
  checks in order: `aap-demo enable eda-playground`, wait for the namespace
  Deployment, verify a Route exists, print only the route host, run
  `aap-demo disable eda-playground`, run disable again, and assert the
  namespace is absent. Keep OAuth browser login as a documented manual step
  because the harness cannot complete interactive authentication safely.

- [ ] **Step 4: Run the complete local validation suite.**

  Run:

  ```bash
  bash test/test-eda-playground-addon.sh
  bash test/test-eda-playground-deploy.sh
  bash test/test-eda-playground-delete.sh
  bash test/test-bash-completion.sh
  pytest -q test/test-dashboard.py tests/unit/test_cluster_status.py
  pre-commit run --files addons/eda-playground aap-demo.sh \
    scripts/aap-demo-completion.bash config/addons-dashboard.json \
    includes/cmd-status.sh docs/guides/addons.md docs/CHANGELOG.md \
    test/test-eda-playground-addon.sh test/test-eda-playground-deploy.sh \
    test/test-eda-playground-delete.sh test/test-eda-playground-live.sh
  ```

  Expected: all addon tests, dashboard tests, status tests, and applicable
  hooks pass; the live test skips unless explicitly enabled.

- [ ] **Step 5: Run the disposable-cluster verification.**

  On a disposable current AAP demo cluster, run:

  ```bash
  AAP_DEMO_RUN_LIVE_TESTS=true bash test/test-eda-playground-live.sh
  kubectl get pods,route -n eda-playground
  ```

  Manually open the printed Route, complete AAP OAuth login, and confirm the
  playground loads. Verify the second disable leaves no `eda-playground`
  namespace and does not remove unrelated Gateway applications.

- [ ] **Step 6: Review the final diff and commit documentation/tests.**

  ```bash
  git diff --check HEAD~4..HEAD
  git status --short
  git add addons/eda-playground/README.md docs/guides/addons.md \
    docs/CHANGELOG.md test/test-eda-playground-addon.sh \
    test/test-eda-playground-live.sh
  git commit -S -m "docs: document EDA Playground addon"
  ```

### Task 6: Final review and handoff

**Files:**

- Review: all files changed by Tasks 1–5
- Test: all addon, dashboard, completion, and unit test commands from Task 5

**Interfaces:**

- Consumes: the complete implementation and verification evidence from Tasks 1–5.
- Produces: a merge-ready feature branch with no Python or Windows registration drift and a concise handoff report.

- [ ] **Step 1: Inspect the final diff against the branch base.**

  Run:

  ```bash
  git diff --stat main...HEAD
  git diff --check main...HEAD
  git status --short --branch
  ```

  Confirm that changes are limited to the EDA addon, Bash/catalog integration,
  focused tests, and documentation; the pre-existing untracked
  `docs/superpowers/2026-11-04-automation-orchestrator-kubernetes-test-design.md`
  and `.DS_Store` must remain untouched.

- [ ] **Step 2: Verify out-of-scope surfaces did not change.**

  Run:

  ```bash
  git diff main...HEAD -- src/aap_demo/cluster/status.py powershell/native/Private/Addons.ps1
  ```

  Expected: no output.

- [ ] **Step 3: Run the final verification commands.**

  Repeat the complete local suite from Task 5 and record the
  disposable-cluster result, including whether manual OAuth login succeeded.

- [ ] **Step 4: Prepare the handoff.**

  Report the implementation commits, test commands and results, live route
  verification result, experimental image limitation, and the explicit future
  work for Python CLI and Windows support. Do not include credentials, tokens,
  or raw API responses.
