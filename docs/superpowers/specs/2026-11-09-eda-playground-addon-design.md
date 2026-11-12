# EDA Playground Addon Design

**Date:** 2026-11-09
**Status:** Design approved for specification
**Scope:** Bash/macOS/Linux addon integration only

## Goal

Port Brian Grimmett’s closed EDA Playground addon PR (#74) into the current
`aap-demo` branch as a focused, tested `eda-playground` addon for interactive
Event-Driven Ansible testing with AAP-backed OAuth authentication.

The first release will support the existing legacy Bash addon workflow on
macOS and Linux. Python CLI support and native Windows support are explicitly
out of scope.

## Context and constraints

The source implementation is available on
`origin/feature/eda-playground` and includes seven addon files, but that branch
is historically divergent from the current branch. The implementation must be
ported selectively rather than merged wholesale.

The addon deploys a web application into the local OpenShift/MicroShift
cluster. It uses the AAP Gateway API to create or reuse an OAuth application,
stores the client secret locally for reuse, and configures the application’s
redirect URI after the route exists.

The addon is experimental. Its current container image is hosted in Brian’s
personal GHCR namespace and is not an official Red Hat image. The image remains
configurable; the maintained default is `:latest` at the user's explicit request
so live testing picks up the newest published image. The deployment therefore
uses `imagePullPolicy: Always`. Operators needing reproducibility should set
`EDA_PLAYGROUND_IMAGE` to a reviewed immutable tag or digest.

## Design

### 1. Addon package

Port these files into `addons/eda-playground/`:

- `README.md` — usage, prerequisites, access URL, limitations, and cleanup.
- `deploy.sh` — idempotent deployment and deletion workflow.
- `namespace.yaml` — dedicated namespace.
- `configmap.yaml` — built-in integration definitions.
- `service.yaml` — internal application service.
- `deployment.yaml` — application deployment and configuration references.
- `route.yaml` — OpenShift route template whose host is rendered at deploy time.

The deployment script remains the addon’s orchestration boundary. It should
not modify unrelated AAP or cluster resources except the OAuth application it
owns and the SCC binding for its dedicated service account.

### 2. Deployment flow

The deploy action will execute the following ordered flow:

1. Validate `kubectl`, cluster connectivity, AAP availability, and `jq`.
2. Discover the AAP route and admin password from the current deployment.
3. Discover or create an AAP organization for the OAuth application.
4. Discover or create the named OAuth application.
5. Reuse the saved client secret when the OAuth application still exists; if
   the secret is unavailable, recreate the owned application rather than
   continuing with unusable credentials.
6. Persist OAuth metadata under the addon state directory with mode `0700` on
   the directory and `0600` on the credentials file.
7. Determine the cluster domain and whether the cluster is MicroShift/CRC or
   OpenShift.
8. Generate a session secret and create the Kubernetes OAuth Secret without
   exposing secret values in normal output.
9. Apply the namespace, ConfigMap, Service, Deployment, and rendered Route.
10. Grant the dedicated service account only the required `anyuid` SCC when
    the `oc` command is available.
11. Wait for the Deployment to become available.
12. On MicroShift/CRC, add the AAP route host alias to the application
    Deployment so in-cluster OAuth traffic reaches the AAP service.
13. Update the owned AAP OAuth application with the final route redirect URI.
14. Print the application URL and non-secret operational next steps.

Failures after OAuth application creation must identify the incomplete step
and provide a safe recovery path without printing client secrets or passwords.

### 3. Configuration

The addon will support environment overrides for:

- addon namespace;
- AAP namespace;
- OAuth application name;
- image repository and tag/digest;
- local OAuth state directory.

The default image reference must be explicit and reviewable. A digest-pinned
reference is preferred once a trusted digest is available; until then, the
README must clearly identify the image as experimental and externally hosted.

Route hosts must be derived from the cluster domain rather than assuming only
the default `127.0.0.1.nip.io` environment.

### 4. Cleanup flow

The delete action will be safe to repeat:

1. Locate the owned OAuth application using saved metadata or an exact name
   lookup.
2. Delete only that OAuth application when it can be identified.
3. Remove the dedicated service account’s SCC binding when `oc` is available.
4. Delete only the `eda-playground` namespace configured for this addon.
5. Remove the local OAuth state directory after the cluster cleanup attempt.

Missing AAP, OAuth, SCC, or namespace resources are non-fatal cleanup cases.
Unexpected API failures must be reported without causing deletion of unrelated
resources.

### 5. CLI and catalog integration

Register `eda-playground` in the current Bash command surface:

- argument parsing for `enable` and `disable`;
- `AVAILABLE_ADDONS`;
- help summaries and examples;
- Bash completion;
- status output where the current legacy CLI exposes addon state;
- `config/addons-dashboard.json` with namespace health metadata.

The addon must not be added to the Python CLI’s supported addon list or the
native PowerShell addon list in this release. Documentation must state that
the addon is available through the legacy Bash workflow only.

### 6. Testing and verification

Automated coverage will include:

- CLI registration/catalog consistency;
- manifest validation for namespace, service account, secret references,
  probes/resources, and route shape;
- shell tests for argument validation and safe delete behavior;
- mocked deploy tests covering first OAuth creation, OAuth reuse, missing
  saved secret, route rendering, and cleanup;
- redaction checks ensuring passwords, client secrets, and session secrets do
  not appear in normal output.

Live verification will be performed on a disposable current AAP demo cluster:

```text
aap-demo enable eda-playground
kubectl get pods,route -n eda-playground
open the route and complete AAP OAuth login
aap-demo disable eda-playground
repeat disable and verify no unrelated OAuth app or namespace was removed
```

The live test is a release gate for the final implementation but is not
required for unit tests to run locally.

## Out of scope

- Merging the historical `feature/eda-playground` branch wholesale.
- Python CLI support.
- Native Windows implementation.
- Moving or maintaining the EDA Playground application source itself.
- Production support or an official Red Hat container image.
- General AAP OAuth framework refactoring.
- Unrelated addon architecture changes.

## Acceptance criteria

The port is complete when:

1. `aap-demo enable eda-playground` deploys the addon on the current Bash
   workflow without changing unrelated resources.
2. The generated route is usable on both the default MicroShift/CRC domain and
   an OpenShift/SNO domain.
3. A user can authenticate through AAP OAuth and reach the playground.
4. Re-running enable reuses or safely repairs owned OAuth state.
5. Disable removes the addon and owned OAuth application idempotently.
6. Automated tests cover registration, manifests, error paths, redaction, and
   cleanup safety.
7. Documentation clearly identifies the experimental image and the Bash-only
   support boundary.
