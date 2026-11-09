<!-- markdownlint-disable MD013 -->

# Task 2 report: EDA Playground OAuth deployment

## Status and commit

Implemented on `feature/eda-playground-addon` and committed as `b7408da235b460a3f995b622716f7af4b654b831` (`feat: configure EDA Playground with AAP OAuth`). The commit has an embedded SSH `gpgsig` and Signed-off-by trailer. `git log -1 --show-signature` reports a good ED25519 signature; local principal verification also warns that the configured allowed-signers file at `/private/tmp/aap-demo-pr247-signers` is absent.

## Changed files

- `test/test-eda-playground-deploy.sh`: executable mocked deploy tests for first organization/application creation, credential reuse, missing-secret recreation, ingress domain, MicroShift host alias and HTTP AAP URL, callback URI, secret redaction, and tracing redaction.
- `addons/eda-playground/deploy.sh`: prerequisite and Gateway checks, exact-name OAuth reconciliation, private credential state, repeatable Kubernetes Secret apply, manifest rendering, host alias patch, rollout wait, final callback patch, and non-secret output.
- `addons/eda-playground/deployment.yaml`: application-specific AAP URL, redirect URI, client ID, and client secret environment variables, with credentials sourced from the Secret.

`addons/eda-playground/route.yaml` already contained the host placeholder required by the brief, so it did not need an edit. Task 3 cleanup remains out of scope.

## Red–green evidence

1. Initial mocked suite: `bash test/test-eda-playground-deploy.sh` failed with `FAIL: first should create organization` against the Task 1 deployer.
2. After OAuth implementation, the suite passed.
3. Repeatable Secret assertion failed with `FAIL: first deploy` when the stub rejected a plain `kubectl create -f -`; client-side dry run piped to apply made it pass.
4. Application environment assertion failed with `FAIL: AAP base URL not rendered`; Deployment rendering made it pass.
5. A `bash -x` run failed with `FAIL: tracing exposed fixture-admin-password`; disabling xtrace at script entry made it pass.

## Verification

- `bash test/test-eda-playground-deploy.sh` — PASS.
- `bash test/test-eda-playground-addon.sh` — PASS.
- `shellcheck addons/eda-playground/deploy.sh test/test-eda-playground-deploy.sh` — PASS.
- `shfmt -d -i 2 -ci -bn addons/eda-playground/deploy.sh test/test-eda-playground-deploy.sh` — PASS after formatting.
- `ANSIBLE_HOME=/private/tmp/aap-demo-ansible-home ANSIBLE_LOCAL_TEMP=/private/tmp/aap-demo-ansible-local .venv-lint/bin/pre-commit run --files addons/eda-playground/deploy.sh addons/eda-playground/deployment.yaml test/test-eda-playground-deploy.sh` — PASS. The commit's pre-commit and commit-msg hooks also passed.
- `git diff --check` — PASS.

The first pre-commit attempt could not write Ansible Lint's default cache under `~/.ansible`; relocating it to `/private/tmp` resolved that environment issue. Commit hooks initially caught a missing executable bit on the new test and an accidentally staged executable bit on the YAML file; both modes were corrected before the successful commit.

## Concerns

- No live AAP or OpenShift deployment was run; Gateway responses, Kubernetes resource creation, OAuth login, and image behavior remain unverified against a cluster.
- The local allowed-signers file is missing, so Git cannot map the good SSH signature to a principal, although the signature and `gpgsig` are present.
- Four pre-existing unrelated untracked files were left untouched.

## Focused hardening review

Signed follow-up commit: `017fab7ca33f3689cfdab45f28f6edbd7b8553dd` (`fix: harden EDA Playground OAuth deployment`). The review changed only `addons/eda-playground/deploy.sh` and `test/test-eda-playground-deploy.sh`.

### Changes

- OAuth reconciliation now prefers the saved application ID among exact-name results. Multiple exact-name results without a unique saved match fail before DELETE.
- The `anyuid` grant occurs after namespace and Secret setup and before Deployment apply. Rollout waits at most 180 seconds and gives an inspect-and-retry recovery path on failure.
- Ingress capability is checked even when `EDA_PLAYGROUND_DOMAIN` overrides the rendered host; MicroShift still uses HTTP for in-cluster AAP and patches its host alias.
- Gateway credentials pass to curl through stdin configuration. Client and session values pass to jq through temporary files under the private state directory, never as command arguments. Temporary inputs are removed at exit.
- Failed AAP Route and admin Secret reads emit specific diagnostics. The test's file-mode helper uses GNU `stat -c` with BSD `stat -f` fallback.

### Red–green evidence

The new fixture run first failed on `FAIL: first exposed fixture-admin-password in argv` against the pre-hardening deployer. After the implementation, `bash test/test-eda-playground-deploy.sh` passed with later-saved-ID selection, ambiguous-match no-delete, SCC ordering, rollout timeout, domain override on MicroShift, argv redaction, and prerequisite failure cases.

### Final verification

- `bash test/test-eda-playground-deploy.sh` — PASS.
- `bash test/test-eda-playground-addon.sh` — PASS.
- `shellcheck addons/eda-playground/deploy.sh test/test-eda-playground-deploy.sh` — PASS.
- `shfmt -d -i 2 -ci -bn addons/eda-playground/deploy.sh test/test-eda-playground-deploy.sh` — PASS.
- `ANSIBLE_HOME=/private/tmp/aap-demo-ansible-home ANSIBLE_LOCAL_TEMP=/private/tmp/aap-demo-ansible-local .venv-lint/bin/pre-commit run --files addons/eda-playground/deploy.sh test/test-eda-playground-deploy.sh` — PASS. Commit pre-commit and commit-msg hooks also passed.
- `git diff --check` — PASS.

Concerns remain unchanged: no live cluster test, and local SSH principal verification lacks its configured allowed-signers file. The four unrelated pre-existing untracked files were not touched.

## Namespace override follow-up

Added a custom namespace fixture and fixed the renderer in the deploy script. With `NAMESPACE=custom-demo`, the Namespace resource and all namespaced resources use `custom-demo`, while the ServiceAccount remains `eda-playground` in `namespace.yaml`, the Deployment `serviceAccountName`, and the SCC grant. The rollout wait also targets `custom-demo`.

Red–green evidence: the new fixture first failed with `FAIL: fixed service account name missing` against the previous global `name: eda-playground` substitution. After changing Namespace rendering to alter only the Namespace object's name and namespace fields, the fixture passed.

Verification for this follow-up:

- `bash test/test-eda-playground-deploy.sh` — PASS.
- `bash test/test-eda-playground-addon.sh` — PASS.
- `shellcheck addons/eda-playground/deploy.sh test/test-eda-playground-deploy.sh` — PASS.
- `shfmt -d -i 2 -ci -bn addons/eda-playground/deploy.sh test/test-eda-playground-deploy.sh` — PASS.
- `git diff --check` — PASS.
