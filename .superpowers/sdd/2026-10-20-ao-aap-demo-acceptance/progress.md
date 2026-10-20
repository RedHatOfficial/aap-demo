# SDD ledger — plan: docs/superpowers/plans/2026-10-20-ao-aap-demo-acceptance.md

## Preflight scan

Shared interfaces were checked before Task 1: Task 1 produces RunConfig,
CheckResult, and runner contracts; Task 2 extends them; Task 3 provides AAP/AO
clients; Task 4 consumes those clients for inventory; Task 5 consumes inventory
and CommandRunner; Task 6 consumes inventory and clients; Task 7 consumes
results and diagnostics boundaries; Task 8 documents the shell interface. No
contradiction was found. Global constraints remain binding: live testing is
opt-in, validate is non-mutating, auto requires explicit context, failures are
secret-free, and managed EEs must not be silently skipped.

## Rulings

No controller rulings have been made.

## Task status

- Task 1: complete (commits a9caa82..9197966; review clean after 1 fix round)
- Task 2: complete (commits 9197966..fd8b68c; 1 minor deferred)
- Task 3: complete (commits fd8b68c..6eb59ea; review clean after 2 fix rounds)
- Task 4: complete (commits 6eb59ea..cb31bb7; review clean after 1 fix round)
- Task 5: complete (commits cb31bb7..2c88df2; review clean after 3 fix rounds)
- Task 6: complete (commits 2c88df2..e61638f; review clean after 3 fix rounds)
- Task 7: fix round 1 addressed exit/redaction semantics; re-review found
  post-redaction payload expansion and a pod-log collection regression.
- Task 7: fix round 2 addressed final-output bounds and restored safe pod-log
  invocation; re-review clean. Commits 160a98f..73ff7d2.
- Task 7: complete (commits e61638f..73ff7d2, review clean after 2 fix rounds)
- Task 8: review found Important alias-test, auto token-preflight, and
  discovery-command gaps, plus a Minor documentation command omission. Fix
  round 1 required.
- Whole-branch review: Critical default scenarios cannot pass and diagnostics
  can leak unlabeled API secrets; Important MCP auth/readiness, EE
  representatives, wiring assumptions, preparation ordering/failure handling,
  CI Python coverage, and unsafe-context diagnostics require one comprehensive
  fix wave.

- Task 8: Ruling: the design requires `--skip-provision` as an alias for
  `--mode validate`, but Task 2 did not implement it — added the minimal parser
  mapping in `runner.py` and exercised it through the CLI safeguard — the
  alternative would document a nonexistent option.
- Task 8: Ruling: the brief's `unittest discover` command finds no hyphenated
  filenames and exits nonzero — retained the command as evidence and ran the
  explicit seven-suite 103-test regression set for substantive coverage.
- Task 8: complete (commit 32a1eea, focused CLI safeguard passed; seven-suite
  Task 1-7 regression: 103 tests passed; syntax, whitespace, and commit hooks
  passed)
- Task 8: fix round 1 complete (commit 30067b7; focused CLI safeguard and
  required discovery command: 104 tests passed; explicit Task 1-7 regression:
  104 tests passed; syntax and hooks passed)
- Whole-branch fix wave: complete. Repository-owned immutable safe
  representatives make the default suite success-capable; failure artifacts
  use diagnostic allowlists; MCP readiness is authenticated and CA-aware;
  every managed EE is exercised; wiring follows addon-created resources;
  Product Demos preparation precedes AO; discovery runs all acceptance tests;
  diagnostics require an approved context; duration/report/readiness gaps are
  closed. Final evidence is in `final-fix-report.md`.

## Deferred minors

None. The previously deferred Product Demos-only readiness coverage was added
as part of the whole-branch fix wave.

## Review notes

- Task 1: fixed missing Path import, populated FailureClass serialization, and
  direct FAIL/BLOCKED exit tests.
- Task 2: fixed missing-context mutation and Product Demos status parsing.
- Task 3: fixed whitespace-secret redaction, redirect authorization, list
  response handling, and delimiter over-redaction.
- Task 4: fixed AO `.resources` envelopes, credential relationships, and full
  managed template/EE selection.
- Task 5: fixed runner reachability, actual EE/AO pod probing, safe job
  allowlists, observed MCP/security checks, timeout propagation, redaction,
  malformed CA handling, AO identity, and MCP route discovery.
- Task 6: fixed safe default scenarios, actual pinned workflow names, strict
  runtime job allowlists, execution-only markers, shared deadlines, and clear
  blocked results before graph validation.
