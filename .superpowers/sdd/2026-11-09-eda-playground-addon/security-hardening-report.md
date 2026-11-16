# EDA Playground final security hardening

## Scope

Implemented the three final code findings on `feature/eda-playground-addon`.
Read the approved design, implementation plan, and whole-branch review package
`review-373cb99..d9091bb.diff`. No subagents or reviewers were spawned.
The four pre-existing unrelated untracked files were left untouched.

## Changes

- Deploy and delete share validation of the saved OAuth application ID and
  non-secret ownership marker. Conflicting or invalid records stop recovery.
  Deploy cannot fall back to another application's name when saved ownership
  disagrees. Marker-only state identifies the application to recreate.
- Deploy exhausts validated application pages before selecting an application.
  It refuses foreign endpoints, path traversal, pagination cycles, failed or
  malformed pages, invalid IDs, and ambiguous matches. A uniquely saved ID can
  select its application among same-name results across pages. With no saved
  ownership, the existing unique exact-name fallback remains available.
- Recreation records ownership before DELETE and updates the marker after
  saving replacement credentials, so subsequent recovery uses the new ID.
- The entire Secret construction, dry-run, and apply pipeline suppresses stdout
  and stderr. Pipefail detects failures at every stage and emits only a fixed
  diagnostic with retry guidance. Credentials remain available for retry.
- Only explicit ingress resource/type absence enables MicroShift HTTP and host
  aliases. Forbidden, transport, timeout, unrelated NotFound, and empty-domain
  responses stop before OAuth or Kubernetes mutation, even with a domain
  override.

## Red-green evidence

Before changing production code, ran:

```bash
bash test/test-eda-playground-security.sh
bash test/test-eda-playground-delete.sh
```

The new security suite failed 23 of 27 cases against `d9091bb`. Failures
included saved/marker mismatches and conflicts, invalid saved IDs, stale
marker-only recovery, duplicates and owned IDs on later pages, invalid
pagination, both Secret failure payload leaks, and unexpected ingress errors.
Four positive controls already passed: matching ownership, confirmed absent
owned application, and both confirmed ingress absence forms.

Cleanup independently failed `conflicting_state unexpectedly succeeded`.
Its regression verifies that conflicting records preserve local state and
prevent OAuth deletion, SCC changes, and namespace deletion.

Raw red-run results are in `security-red.log` and `security-delete-red.log`
in this SDD workspace. The new tests use local command fixtures only.

The existing deploy fixtures were corrected to return the newly created
application ID on repeated deployment and an explicit NotFound response for
MicroShift. All existing behavior assertions remain in place.

## Verification

All checks passed on the final code:

- `bash test/test-eda-playground-security.sh`: 27/27 cases passed, including
  all 23 previously failing cases. A run interrupted by formatting the test
  file was discarded; the final stable-file rerun exited 0.
- `bash test/test-eda-playground-delete.sh`: passed, including the new
  conflicting-state regression (RED to GREEN).
- `bash test/test-eda-playground-deploy.sh`: passed.
- `bash test/test-eda-playground-addon.sh`: passed.
- `bash test/test-bash-completion.sh`: passed.
- `bash test/test-eda-playground-cli.sh`: passed.
- `./.venv/bin/pytest`: 1,030 passed, 2 skipped, 18 deselected.
- `./.venv/bin/pytest -q test/test-dashboard.py tests/unit/test_cluster_status.py`:
  16 passed.
- ShellCheck and `shfmt -d -i 2 -ci -bn` on the deployer and all three changed
  shell test files: passed.
- Applicable pre-commit hooks on the five changed files: passed.
- `git diff --check` and staged whitespace checks: passed.

The final test logs are `security-green.log`, `deploy-check.log`,
`delete-check.log`, `security-pytest.log`, and `security-hooks.log` in this
SDD workspace. These logs are local evidence; this report is committed.

## Concerns

No live cluster or browser OAuth verification was performed in this hardening
pass. The approved spec's disposable-cluster/browser release gate remains
outstanding. The addon remains experimental with an externally hosted image.

## Scoped review follow-up: state recovery and ingress diagnostics

The follow-up addresses two findings against signed commit `2cf7d0d`.

### Recoverable OAuth state replacement

Replacement credentials, the new non-secret marker, and exact prior snapshots
are staged in a private directory. An atomic rename publishes this recovery
record before either live state file changes. A marker-write failure restores
the previous credentials (or their absence for marker-only state), preserving
the prior pair while retaining the replacement credentials for recovery.

Both deploy and delete finish a pending transition before reading ownership.
Recovery validates both live records against the recorded before/after
snapshots before writing either. Unrelated changes and genuine ownership
conflicts are rejected. The record also permits recovery if an interruption
or rollback failure leaves one of the recorded intermediate states. Completed
transitions remove the recovery record; state files remain mode 0600.

Tests inject failure specifically when publishing the new application's
marker, after its credentials write succeeds. They verify rollback and then
exercise subsequent deploy, delete, and marker-only recovery against the new
application alongside an unrelated same-name application. Another regression
changes the ownership marker after the failed write and verifies that both
deploy and delete reject it without mutation.

### Ingress stdout and stderr

Ingress lookup captures stdout and stderr separately. A successful lookup
uses only stdout as the domain, tolerating warnings without including them in
Route or Deployment manifests. Nonzero status still uses the narrow confirmed
absence checks; valid-looking stdout cannot conceal a lookup failure.

Discovered and overridden domains are validated before OAuth or Kubernetes
mutation. Validation checks DNS label syntax and length and reserves space for
the addon prefix in the complete Route hostname.

### Follow-up red-green evidence

Before changing production code, the focused run failed seven new cases:
three split-state failures, a valid domain plus warning, an invalid discovered
domain, an oversized DNS label, and an invalid override. A valid-looking domain
returned with an actual lookup error already failed safely as expected. The
additional pending-conflict case also failed at its split-state assertion.
These results are retained locally in `followup-red.log`.

After implementation, all targeted cases passed. The pending-conflict test
initially exposed a Bash 3.2 empty-array limitation in the test harness; its
optional argument handling was corrected before the successful rerun.

### Follow-up verification

All final checks passed:

- Full security suite: 36/36 cases, including all nine follow-up cases.
- Deploy, delete, static addon, CLI, and Bash completion shell suites: passed.
- `./.venv/bin/pytest`: 1,030 passed, 2 skipped, 18 deselected.
- Catalog and cluster-status tests: 16 passed.
- ShellCheck and `shfmt -d -i 2 -ci -bn` on the deployer and security,
  deploy, and delete tests: passed.
- Applicable pre-commit hooks and `git diff --check`: passed.

Final local evidence is in `followup-security.log`, `followup-deploy.log`,
`followup-delete.log`, `followup-pytest.log`, and `followup-hooks.log` in this
SDD workspace. No live cluster or browser verification was performed, and the
four pre-existing unrelated untracked files remain untouched.
