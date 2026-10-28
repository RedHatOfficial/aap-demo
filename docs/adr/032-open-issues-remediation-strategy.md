# ADR-032: Open Issue Remediation Strategy

**Status**: Proposed

**Date**: 2026-10-12

**Authors**: aap-demo maintainers

## Context

The repository had 30 open GitHub issues spanning production defects, portability
and documentation gaps, feature proposals, architecture questions, and stale
automated-review findings. Treating all of them as equivalent implementation
work would create oversized pull requests and encourage architectural changes
without an agreed design.

The audit also found several issues already fixed in the default branch or
covered by active pull requests. Those issues need to remain linked to their
existing changes rather than receive duplicate implementations.

The project requires optional addons to avoid increasing the default CRC
resource footprint, credentials and generated cluster state to stay out of Git,
and deployment-specific claims to be validated on a live CRC/OpenShift
environment. Static shell, manifest, and documentation tests are still
required for behavior that can be verified without a cluster.

## Decision

Remediate the open issue inventory as independently reviewable change streams:

1. **Defects and bounded documentation fixes** use one
   `codex/issue-<number>-<slug>` branch per issue and a focused pull request.
   Each pull request includes regression coverage, a conventional-commit title,
   and a test plan.
2. **Architecture-changing work** must first have an ADR or evidence-backed
   design decision. This applies to OAuth/OIDC, Vault, OS-native secret
   storage, KubeVirt, catalog/SCC architecture, and similarly cross-cutting
   changes.
3. **Large feature proposals** are decomposed into a requirements/design
   decision and a minimal vertical slice before broader implementation. No
   partial addon is added solely to make an issue appear closed.
4. **Stale or non-actionable automated findings** are reported to maintainers
   and closed without code changes.
5. Existing merged or active pull requests remain the source of truth for
   issues they already address.

### Audit matrix

<!-- markdownlint-disable MD013 -->

| Issue | Finding on 2026-10-12 | Disposition |
| --- | --- | --- |
| #229 | Bare `OLLAMA_STORAGE_SIZE=20` can be interpreted as an invalid Kubernetes quantity. | Implemented in PR #232 with normalization and tests. |
| #224 | AAP/AO OAuth2 SSO requires an OIDC and credential architecture decision. | ADR and live contract validation before implementation. |
| #220 | Ollama reported a pod as missing even when the namespace showed a ready pod. | Implemented diagnostics in PR #240. |
| #213 | Kubeconfig is saved, but shell export setup is not offered. | Implemented in PR #237. |
| #211 | `Makefile` includes missing `aap-demo.mk`. | Implemented in PR #231. |
| #197 | Fleet checks for QEMU tools but does not offer installation. | Implemented in PR #236. |
| #196 | KubeVirt/container-native Fleet is a research question. | Evidence-backed ADR/recommendation required. |
| #194 | `enable fleet` stops after printing next steps. | Implemented in PR #238, stacked on PR #236. |
| #188 | AAP readiness condition was fixed in merged PR #208. | No duplicate implementation. |
| #187 | MCP route admission does not prove host-side DNS resolution. | Implemented diagnostics in PR #235. |
| #178 | Vault OIDC demo has no defined deployment and credential contract. | ADR/design first. |
| #173 | CVE remediation workflow needs validation against the upstream guide. | Pinned workflow design and validation required. |
| #172 | OS-native secret storage affects all supported platforms and migration. | ADR comparing platform stores and safe fallback. |
| #160 | Stale synthetic findings reference nonexistent paths. | Non-actionable; report and close. |
| #156 | Stale synthetic findings reference nonexistent paths. | Non-actionable; report and close. |
| #139 | Addon version checks lack source, cadence, and bypass semantics. | Define contract before implementation. |
| #135 | Portal catalog resolution depends on namespace and SCC architecture. | Live-cluster investigation and ADR first. |
| #104 | APME optional developer paths and historical ADR sections need cleanup. | Documentation review and targeted follow-up. |
| #96 | Fix is in active PR #212. | No duplicate implementation. |
| #93 | Local and CI lint scopes are inconsistent. | Implemented in PR #239, stacked on PR #231. |
| #90 | Monitoring addon is a substantial new platform component. | Resource analysis and ADR/design first. |
| #73 | Requested development skills were added in merged PR #223. | No duplicate implementation. |
| #72 | Decision environments require image, registry, resource, and AAP-association choices. | ADR/design first. |
| #70 | OPA acceptance criteria exceed the currently implemented addon behavior. | Audit concrete gaps before follow-up code. |
| #48 | EDA payload generator is a large new addon proposal. | ADR/design and minimal vertical slice first. |
| #38 | ALIA request has no integration or deployment contract. | Capture requirements before implementation. |
| #35 | Collection authentication guidance is substantially present. | Verify acceptance criteria; avoid duplicate work. |
| #34 | Credential-scoping guidance was not explicit by environment. | Implemented in PR #233. |
| #21 | Shell portability still used avoidable `compgen` and process substitution. | Implemented in PR #234. |
| #20 | Fix is in active PR #186. | No duplicate implementation. |

<!-- markdownlint-enable MD013 -->

### Implementation guardrails

- Preserve the clean user worktree and never commit credentials or generated
  cluster state.
- Keep addon installation optional and avoid increasing the default CRC
  resource footprint.
- Keep auto-install prompts disabled in quiet and non-interactive modes.
- Pin new images and avoid namespace-wide privilege grants.
- Run `bash -n` for changed shell scripts, focused regression tests,
  `git diff --check`, and the applicable repository lint checks.
- Record live-cluster limitations explicitly in each pull request.

## Consequences

### Positive

- Each bounded fix can be reviewed, tested, reverted, and merged independently.
- Architecture decisions are recorded before implementation commits establish
  an accidental design.
- Existing fixes and active pull requests are not duplicated.
- The issue inventory provides maintainers with a traceable path from report to
  branch, test evidence, and pull request.

### Negative

- Large feature issues remain open longer while requirements and architecture
  are clarified.
- Several small pull requests may require dependency ordering, such as Fleet
  enablement depending on prerequisite installation.
- Live CRC/OpenShift validation cannot be replaced entirely by static tests.

### Neutral

- The default addon set and existing user-facing commands remain unchanged by
  the audit itself.
- Stale automated findings receive no code changes because their referenced
  files are not part of the repository state.

## Alternatives Considered

### One omnibus issue-fix pull request

Rejected because unrelated shell, documentation, addon, and architecture
changes would be difficult to review and would make rollback unsafe.

### Implement every feature request immediately

Rejected because OAuth, Vault, KubeVirt, secret storage, monitoring, and new
addons require decisions about compatibility, resource usage, security, and
operational ownership that are not specified by the issue text alone.

### Close every issue that lacks an immediate code patch

Rejected because research and design issues are still valid work; they need
explicit decisions and acceptance criteria rather than premature closure.

## References

- [ADR directory](README.md)
- [Open issue inventory](https://github.com/RedHatOfficial/aap-demo/issues)
- [Audit and remediation PR #230](https://github.com/RedHatOfficial/aap-demo/pull/230)
- [Ollama quantity fix PR #232](https://github.com/RedHatOfficial/aap-demo/pull/232)
- [Fleet prerequisite PR #236](https://github.com/RedHatOfficial/aap-demo/pull/236)
- [Fleet enable PR #238](https://github.com/RedHatOfficial/aap-demo/pull/238)
- [Lint scope PR #239](https://github.com/RedHatOfficial/aap-demo/pull/239)
- [Ollama diagnostics PR #240](https://github.com/RedHatOfficial/aap-demo/pull/240)
