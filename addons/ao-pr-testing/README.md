# AO PR testing addon

ao-pr-testing is an optional addon for local pull-request validation. It
requires Automation Orchestrator, but it is deliberately not part of the core
ao addon.

The addon:

- registers the public `quay.io/cferman/plaibook-ee:latest` execution
  environment in AAP as `plaibook-ee` so PR checks can use the shared image
  without a local build or registry credential;
- creates or updates an AAP Project and Job Template for the local
  plaibook-result bridge;
- installs the official OpenShift MCP server in its own
  openshift-mcp-server namespace;
- binds the MCP server to the read-only view ClusterRole and disables
  destructive access;
- registers the MCP endpoint as a separate AO integration;
- creates or updates the aap-demo PR Validation workflow;
- provides both a GitHub webhook trigger and a manual PR-input trigger;
- runs the public `aknochow/ansible-plaibook` source inside that bridge,
  keeping GitHub access and review logic out of the AO agent; and
- publishes the run-scoped review JSON through AAP `set_stats`; and
- updates one marked GitHub PR comment with the review report when an AAP
  GitHub Personal Access Token credential is configured; and
- quarantines findings whose files are absent from the current PR diff in one
  marked GitHub issue; and
- binds the read-only OpenShift MCP with a separate short-lived AO bearer
  credential backed by its service account.

The workflow is intentionally PR-shaped: it analyzes the changed and directly
affected components, selects the complete set of relevant checks, and reports
missing source, diff, runner, or permissions as blocked. It does not run the
old disk-percentage workflow or any unrelated AO demo workflow.

## Enable

    aap-demo enable ao
    aap-demo enable ao-pr-testing

The addon requires an already-running AO deployment with the normal local
Ollama and AAP integrations. Public GitHub PRs are retrieved by plaibook from
the AAP Job Template, so a GitHub MCP integration or shared GitHub token is
not required. Private repositories need explicit AAP credential and plaibook
wiring; this addon does not copy local GitHub secrets into the cluster.

The execution environment defaults can be overridden for a fork or custom
build:

    AO_PR_TESTING_EE_NAME=my-plaibook-ee \\
    AO_PR_TESTING_EE_IMAGE=quay.io/example/plaibook-ee:latest \\
    aap-demo enable ao-pr-testing

The bridge project and Job Template can also be overridden. The bridge project
contains the playbook that fetches plaibook; the source variables select the
plaibook repository and branch:

    AO_PR_TESTING_PLAIBOOK_PROJECT_URL=https://github.com/example/review.git \\
    AO_PR_TESTING_PLAIBOOK_PROJECT_BRANCH=main \\
    AO_PR_TESTING_PLAIBOOK_PLAYBOOK=addons/ao-pr-testing/playbooks/plaibook-review-bridge.yml \\
    AO_PR_TESTING_PLAIBOOK_SOURCE_URL=https://github.com/aknochow/ansible-plaibook.git \\
    AO_PR_TESTING_PLAIBOOK_SOURCE_BRANCH=b6cf163c427749074c56ea3e3850688a06c70274 \\
    AO_PR_TESTING_PLAIBOOK_JOB_TEMPLATE_NAME='example | PR Review' \\
    aap-demo enable ao-pr-testing

The plaibook source defaults to the tested commit
`b6cf163c427749074c56ea3e3850688a06c70274` rather than mutable `main`. This
prevents an upstream change from silently changing or stalling the local
workflow. Set `AO_PR_TESTING_PLAIBOOK_SOURCE_BRANCH=main` to deliberately test
the latest source. The AAP Job Template also has a 900-second timeout by
default; override it with `AO_PR_TESTING_JOB_TIMEOUT` when testing a slower
model or source revision.

To publish review findings back to the PR, the addon uses the dedicated
`~/.aap-demo/ao-pr-testing-github-creds.yml` file. On an interactive enable,
the addon prompts for a fine-grained PAT when that file and the environment
variable below are absent. Create the token for `RedHatOfficial/aap-demo` with
`Issues: Read and write`, `Pull requests: Read and write`, and `Metadata:
Read-only`. The token is stored with mode 600. A different token can be
supplied explicitly:

    AO_PR_TESTING_GITHUB_TOKEN='github_pat_...' aap-demo enable ao-pr-testing

The addon stores the prompted value only in the local mode-600 file and in an
addon-owned AAP custom credential, then injects it into the ephemeral review EE
as `GITHUB_TOKEN`; it is not passed through AO workflow variables. In
non-interactive runs, set `AO_PR_TESTING_GITHUB_TOKEN` or pre-create the
credential file. Without a token, comments and stale-finding issues are
skipped while the AAP artifacts remain available. Reruns update the marked
comment and issue instead of creating duplicates.

The default review model is `qwen2.5:3b` through the local Ollama service.
This dev addon deliberately runs plaibook sandboxless inside the ephemeral AAP
execution environment. OpenShell is not deployed or configured by this addon;
use a separate production-oriented review deployment when per-review sandbox
isolation is required.

The optional plaibook exploration pass is disabled in this dev profile. The
deterministic checklist and model-backed review lenses still run. The bridge
reads the run-scoped JSON that plaibook writes inside the ephemeral runner and
publishes a compact structured result with Ansible `set_stats`, which AO
exposes as the AAP node's `artifacts` output. There is no agentic normalizer or
agentic verifier in the critical path, so an empty artifact is a hard bridge
failure rather than a model interpretation problem.

The addon warms the configured Ollama model before publishing. AO 2026.8 uses
its platform Task Agent timeout; a model that cannot produce MCP tool calls
within that limit is reported as a failed validation, not a successful PR
result.

From the local shell—or from an LLM session with access to the workspace—run:

    addons/ao-pr-testing/run-pr.sh owner/repository 123

The helper exchanges the addon-owned AO service-account client credentials for
a short-lived access token, then submits repository, pull request number, and
head SHA to the workflow. AO launches the bridge AAP Job Template with the
repository and PR number. The terminal AAP node exposes the plaibook verdict,
 scores, findings, comment status, and run status directly in its `artifacts`
 output.

## Make the OpenShift MCP available to Codex

The addon-owned OpenShift MCP route is local-only and read-only. To register it
with the local Codex client, run:

    addons/ao-pr-testing/register-codex.sh

The helper discovers the current route and updates the `openshift-aap-demo`
Codex MCP entry. Start a new Codex task/session after registration; an already
running task does not reload its MCP inventory. Do not expose this route through
a public tunnel without adding an explicit authentication boundary.

## Submit a PR

The webhook path is:

    /api/v1/webhooks/aap-demo-pr-validation

AO authorizes the webhook to the aap-demo webhook caller service account
created by the AO addon. The webhook body should contain the GitHub pull
request payload. For a local manual run, use the AO UI and provide
repository, pull_request_number, and head_sha; include changed_files and diff
when available.

This local deployment does not expose the route to GitHub-hosted webhooks by
itself. A reachable tunnel or a local relay must be added before configuring a
GitHub repository webhook. If plaibook cannot obtain the PR diff, checkout,
sandbox, or run-scoped summary, the workflow reports the validation as blocked.

## Disable

    aap-demo disable ao-pr-testing

This removes the addon-owned AO workflow, OpenShift MCP integration, any
legacy GitHub MCP resources from older addon versions, MCP Helm release,
namespace, and local addon state. It leaves the AAP execution environment,
plaibook Project, inventory, and Job Template in place so they can be shared
by other workflows.
