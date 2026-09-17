# AO PR testing addon

ao-pr-testing is an optional addon for local pull-request validation. It
requires Automation Orchestrator, but it is deliberately not part of the core
ao addon.

The addon:

- registers the public `quay.io/cferman/plaibook-ee:latest` execution
  environment in AAP as `plaibook-ee` so PR checks can use the shared image
  without a local build or registry credential;
- creates or updates an AAP Project and Job Template for the public
  `aknochow/ansible-plaibook` repository;
- installs the official OpenShift MCP server in its own
  openshift-mcp-server namespace;
- binds the MCP server to the read-only view ClusterRole and disables
  destructive access;
- registers the MCP endpoint as a separate AO integration;
- creates or updates the aap-demo PR Validation workflow;
- provides both a GitHub webhook trigger and a manual PR-input trigger;
- runs the PR checkout, diff, and review in the AAP-managed plaibook Job
  Template, keeping GitHub access and review logic out of the AO agent; and
- uses small AO stages only to normalize plaibook's run-scoped result and
  verify bounded AAP/OpenShift evidence; and
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

The plaibook project and Job Template can also be overridden:

    AO_PR_TESTING_PLAIBOOK_PROJECT_URL=https://github.com/example/review.git \\
    AO_PR_TESTING_PLAIBOOK_PROJECT_BRANCH=main \\
    AO_PR_TESTING_PLAIBOOK_JOB_TEMPLATE_NAME='example | PR Review' \\
    aap-demo enable ao-pr-testing

The default review model is `qwen2.5:3b` through the local Ollama service.
This dev addon deliberately runs plaibook sandboxless inside the ephemeral AAP
execution environment. OpenShell is not deployed or configured by this addon;
use a separate production-oriented review deployment when per-review sandbox
isolation is required.

The optional plaibook exploration pass is disabled in this dev profile. The
deterministic checklist and model-backed review lenses still run, while the
bounded AO verification stage checks the resulting AAP job and live
`aap-demo` evidence. A production profile can enable exploration with a model
that reliably emits the required read-only tool calls.

The public plaibook playbook currently persists its structured summary inside
the ephemeral runner but does not publish it through Ansible `set_stats`, so
the AO normalizer intentionally reports a missing run-scoped result as
blocked. The remaining integration work is a deterministic result bridge and
live smoke-test stage; the current agentic verifier is evidence-only and must
not be treated as a replacement for those tests.

The addon warms the configured Ollama model before publishing. AO 2026.8 uses
its platform Task Agent timeout; a model that cannot produce MCP tool calls
within that limit is reported as a failed validation, not a successful PR
result.

From the local shell—or from an LLM session with access to the workspace—run:

    addons/ao-pr-testing/run-pr.sh owner/repository 123

The helper exchanges the addon-owned AO service-account client credentials for
a short-lived access token, then submits repository, pull request number, and
head SHA to the workflow. The agent uses GitHub MCP to read the PR and changed
head SHA to the workflow. AO launches the plaibook AAP Job Template with the
repository and PR number, then summarizes the run-scoped result and checks
local deployment evidence.

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
