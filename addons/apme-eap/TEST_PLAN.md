# APME Addon Test Plan

## Overview

The APME addon runs its bundled Ansible playbook locally from an isolated virtual
environment. The playbook creates AAP OAuth credentials, stores portal credentials in
OpenShift, pushes the plugin OCI archive, and installs the portal and APME gateway with
Helm. It does not create or launch an AAP project, inventory, or job template.

## Prerequisites

- OpenShift Local cluster running
- AAP 2.7 deployed with `aap-demo deploy`
- `kubectl` and Python 3 available
- Red Hat pull secret configured under `~/.aap-demo/`

Optional integrations are enabled when their credentials exist:

- GitHub: environment variables or `~/.aap-demo/apme-eap-vars.yml`
- Automation Hub: encrypted `~/.ansible/conf/env.yml` credentials or `~/.aap-demo/pah-config.yml`

## Automated Checks

Run these before a live deployment:

```bash
bash -n addons/apme-eap/deploy.sh
shellcheck --severity=warning addons/apme-eap/deploy.sh

~/.aap-demo/apme-eap-venv/bin/ansible-playbook \
  addons/apme-eap/playbooks/deploy_apme_portal.yml \
  --syntax-check -i 'localhost,' -c local \
  -e @addons/apme-eap/defaults.yml \
  -e @~/.aap-demo/apme-eap-vars.yml
```

## TC-001: Clean Installation

1. Confirm AAP is healthy with `aap-demo status`.
2. Ensure the `apme` namespace does not exist.
3. Run `aap-demo enable apme-eap`.

Expected results:

- The virtual environment is created at `~/.aap-demo/apme-eap-venv`.
- The local playbook completes without failed or unreachable tasks.
- Namespace `apme` exists.
- Helm releases `redhat-rhaap-portal` and `apme` are deployed.
- Secret `secrets-rhaap-portal` contains OAuth and AAP API credentials.
- Portal and gateway pods become ready.
- The portal route responds successfully.
- A deployment report is written under `~/.aap-demo/reports/`.

Validation:

```bash
kubectl get pods -n apme
kubectl get secret secrets-rhaap-portal -n apme
helm list -n apme
kubectl get route -n apme
curl -kfsS -o /dev/null "https://$(kubectl get route redhat-rhaap-portal -n apme -o jsonpath='{.spec.host}')"
ls -t ~/.aap-demo/reports/apme-portal-deployment-*.md | head -1
```

## TC-002: Idempotent Re-Run

1. Record the current pod names and Helm revisions.
2. Run `QUIET=true aap-demo enable apme-eap` again.
3. Repeat the validation commands from TC-001.

Expected results:

- Existing OAuth and API credentials are reused when valid.
- Helm upgrades complete successfully.
- No duplicate AAP OAuth application is created.
- Galaxy server definitions converge without duplicates.
- All workloads return to ready state.

## TC-003: AAP Credential Recreation

1. Back up `secrets-rhaap-portal` from namespace `apme`.
2. Delete the secret.
3. Run `aap-demo enable apme-eap`.

Expected results:

- A write-scope AAP API token is created through the Gateway API.
- `secrets-rhaap-portal` is recreated without exposing values in output.
- Portal OAuth login works with the AAP admin account.

Do not print decoded token or client-secret values during validation.

## TC-004: MicroShift Compatibility

Verify the addon uses Kubernetes namespace resources and does not depend on the
OpenShift Project API:

```bash
kubectl get namespace apme
grep -R "kind: Namespace" addons/apme-eap/playbooks/roles/openshift_apme_setup/tasks/
if grep -R "ProjectRequest" addons/apme-eap/playbooks/roles/openshift_apme_setup/tasks/; then
  echo "Unexpected ProjectRequest usage" >&2
  exit 1
fi
```

## TC-005: Optional Integration Modes

Validate these configurations independently:

1. No GitHub or PAH credentials: deployment succeeds and skips both integrations.
2. `GITHUB_TOKEN` only: SCM secret is created in token-only mode.
3. Full GitHub App variables and private key: App integration is rendered.
4. Galaxy token or PAH config present: PAH setup and catalog synchronization are enabled.

In every mode, inspect command output for accidental credential disclosure.

## TC-006: Disable and Re-Enable

1. Run `aap-demo disable apme-eap`.
2. Confirm APME workloads and addon state are removed as documented.
3. Run `QUIET=true aap-demo enable apme-eap`.
4. Repeat TC-001 validation.

## TC-007: Missing AAP

On a disposable cluster without AAP, run `aap-demo enable apme-eap`.

Expected results:

- The command exits nonzero with a clear instruction to deploy AAP first.
- No APME Helm release or namespace workload is created.

## Security Checks

- Secret-bearing Ansible tasks use `no_log: true`.
- Local credential files and private keys have owner-only permissions.
- No token, password, signed URL, or client secret appears in console logs or reports.
- The AAP API token uses `write` scope and is associated with the portal OAuth app.
- Generated reports remain under `~/.aap-demo/reports`, outside the checkout.

## Test Record

Record the date, commit, CRC/OpenShift version, AAP version, chart versions, elapsed time,
and result for each applicable test case. Attach `aap-demo diagnose` output for failures,
redacting credentials before sharing it.
