# Native V2 Bash Addon Migration Plan

## Goal

Migrate every non-AO addon with a legacy `deploy.sh` to the native Python V2
`Addon` interface, using one isolated feature branch and test gate per addon.

## Branch policy

Each migration starts from the current integration branch as
`feature/<addon>-v2`. A branch contains only that addon, its tests, and required
documentation. Commits are signed and use Conventional Commit messages. The
legacy installer remains for V1 and is the behavior reference; V2 must not
invoke it.

If a shared helper is missing, land a separate `feature/addon-common-v2` PR
first. Product-demo domain branches start after `product-demos-base-v2` lands;
`product-demos-v2` may be an additional dependency if it owns domain selection.

## Per-branch implementation steps

1. Read the addon README, ADRs, `deploy.sh`, sourced libraries, manifests, and
   shell tests. Record resource, secret, state, and cleanup ownership in the
   focused Python test module.
2. Add failing registry and lifecycle tests.
3. Implement one native class in `src/aap_demo/addons/<addon>.py` and register
   it in `src/aap_demo/addons/__init__.py`.
4. Add tests for repeat enable, failed operations, cleanup boundaries, status
   redaction, and addon-specific prerequisites.
5. Run focused tests, the complete unit suite, Ruff, format checks, and
   `git diff --check`.
6. Run the disposable-cluster smoke test: enable, inspect, re-enable, disable,
   and verify cleanup. Record unavailable external checks.
7. Open one PR for the branch; do not combine addon migrations.

## Branch matrix

| Branch | Addon | Dependency |
| --- | --- | --- |
| `feature/apme-eap-v2` | `apme-eap` | — |
| `feature/devspaces-v2` | `devspaces` | — |
| `feature/eda-playground-v2` | `eda-playground` | — |
| `feature/keycloak-v2` | `keycloak` | — |
| `feature/local-cache-v2` | `local-cache` | — |
| `feature/mcp-server-v2` | `mcp-server` | — |
| `feature/ollama-v2` | `ollama` | AO integration deferred if needed |
| `feature/olm-v2` | `olm` | — |
| `feature/opa-v2` | `opa` | — |
| `feature/portal-v2` | `portal` | — |
| `feature/portal-operator-v2` | `portal-operator` | — |
| `feature/registry-v2` | `registry` | — |
| `feature/setup-pah-v2` | `setup-pah` | — |
| `feature/subscription-attach-v2` | `subscription-attach` | — |
| `feature/product-demos-base-v2` | `product-demos-base` | — |
| `feature/product-demos-v2` | `product-demos` | `product-demos-base-v2` |
| `feature/product-demo-cloud-v2` | `product-demo-cloud` | `product-demos-base-v2` |
| `feature/product-demo-linux-v2` | `product-demo-linux` | `product-demos-base-v2` |
| `feature/product-demo-network-v2` | `product-demo-network` | `product-demos-base-v2` |
| `feature/product-demo-openshift-v2` | `product-demo-openshift` | `product-demos-base-v2` |
| `feature/product-demo-satellite-v2` | `product-demo-satellite` | `product-demos-base-v2` |
| `feature/product-demo-windows-v2` | `product-demo-windows` | `product-demos-base-v2` |

## Deferred AO work

Do not modify `ao` or `ao-eap`. Do not open `feature/ao-pr-testing-v2` until
Adam's AO V2 lifecycle/API contract is merged. Then create a separate plan for
AO PR testing's MCP registration, credentials, workflow, webhook, and cleanup.

## Final integration gate

After the individual PRs merge, run the full unit suite and registry tests,
package/install checks, Markdown lint, Ruff, format checks, and `git diff
--check`. Update the addon guide and V2 command reference to distinguish native
addons from the deferred AO family.
