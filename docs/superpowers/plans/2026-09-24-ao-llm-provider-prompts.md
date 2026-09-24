# AO LLM Provider Prompts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `aap-demo enable ao` choose between the existing local Ollama
provider, an external OpenAI-compatible LLM provider, or no LLM provider
without installing Ollama when it is not wanted.

**Architecture:** Add a small shared shell helper for provider selection,
non-secret configuration, and mode-600 API-key storage. The CLI will select the
provider before resolving AO dependencies, while the existing AO wiring layer
will route to either the Ollama integration, a generic external LLM
integration, or no LLM integration. An already-exported `OPENAI_API_KEY` may
populate external mode; shell profile files are never sourced or parsed.

**Tech Stack:** Bash, kubectl/curl/jq integration wiring, shell regression tests, Markdown documentation.

**Spec:** GitHub issue [#177](https://github.com/RedHatOfficial/aap-demo/issues/177), “add prompts to ao addon”.

## Global Constraints

- Preserve the current Ollama behavior as the default for quiet/non-interactive enablement.
- The explicit `none` provider must skip LLM dependency installation, wiring,
  and agent credential/model import while still installing AO and MCP.
- The external provider must use an OpenAI-compatible API, default base URL
  `https://api.openai.com/v1`, and default model `luna`.
- When external mode is selected and no saved key exists, reuse an already
  exported `OPENAI_API_KEY` before prompting for hidden input.
- `AO_LLM_BASE_URL` and `AO_LLM_MODEL` must override the external defaults.
- API keys must never be written to the plaintext config, command output, test
  fixtures, or logs; store the local key file with mode `600`.
- Provider selection must be idempotent and must not automatically delete an already-installed Ollama addon.
- Selecting `none` must never import `OPENAI_API_KEY`.
- Existing AAP, MCP, and Ollama wiring must remain functional.

---

### Task 1: Add provider-selection and secure local configuration helpers

**Files:**

- Create: `includes/ao-llm.sh`
- Create: `test/test-ao-llm-provider.sh`

**Interfaces:**

- Produces `aap_demo_ao_llm_choice(choice)` returning `ollama`, `external`, or `none` and failing for unsupported choices.
- Produces `aap_demo_ao_llm_key_file()` returning `${AO_LLM_API_KEY_FILE:-${AAP_DEMO_DIR}/ao/llm-api-key}`.
- Produces `aap_demo_ao_llm_save_key(key)` which writes only the supplied key to
  the mode-600 key file without printing it.
- Produces `aap_demo_ao_llm_save_config(key, value)` which updates one
  non-secret `KEY=value` entry in `AAP_DEMO_CONFIG`.
- Produces `aap_demo_ao_llm_external_defaults()` which exports `AO_LLM_BASE_URL` and `AO_LLM_MODEL` only when unset.

- [ ] **Step 1: Write the failing tests**

```bash
source includes/ao-llm.sh

test_choice_mapping() {
  [ "$(aap_demo_ao_llm_choice 1)" = ollama ]
  [ "$(aap_demo_ao_llm_choice 2)" = external ]
  [ "$(aap_demo_ao_llm_choice 3)" = none ]
}

test_key_is_private_and_not_printed() {
  AAP_DEMO_DIR="$TEST_DIR/state"
  AO_LLM_API_KEY_FILE="$TEST_DIR/state/ao/llm-api-key"
  output=$(aap_demo_ao_llm_save_key 'secret-fixture' 2>&1)
  [ -z "$output" ]
  [ "$(<"$AO_LLM_API_KEY_FILE")" = 'secret-fixture' ]
  [ "$(stat -f '%Lp' "$AO_LLM_API_KEY_FILE" 2>/dev/null || stat -c '%a' "$AO_LLM_API_KEY_FILE")" = 600 ]
}

test_external_defaults() {
  unset AO_LLM_BASE_URL AO_LLM_MODEL
  aap_demo_ao_llm_external_defaults
  [ "$AO_LLM_BASE_URL" = 'https://api.openai.com/v1' ]
  [ "$AO_LLM_MODEL" = luna ]
}

test_choice_mapping
test_key_is_private_and_not_printed
test_external_defaults
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/test-ao-llm-provider.sh`
Expected: FAIL because `includes/ao-llm.sh` and its helper functions do not exist.

- [ ] **Step 3: Write the minimal helper implementation**

Implement the four functions with `set -euo pipefail`-safe behavior, `mkdir -p`
plus `umask 077` for the key file, and an atomic temporary-file replacement
for config entries. Do not include API-key values in diagnostics.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash test/test-ao-llm-provider.sh`
Expected: PASS, including a mode-600 key file and the `luna` default.

- [ ] **Step 5: Commit**

```bash
git add includes/ao-llm.sh test/test-ao-llm-provider.sh
git commit -m "feat: add AO LLM provider configuration helpers"
```

### Task 2: Prompt during AO enablement and gate Ollama dependency installation

**Files:**

- Modify: `aap-demo.sh:40-90, 2790-2895`
- Modify: `test/test-core-commands.sh`
- Create: `test/test-ao-enable-provider.sh`

**Interfaces:**

- Consumes the helpers from `includes/ao-llm.sh`.
- Produces provider state in `AO_LLM_PROVIDER` with values `ollama`, `external`, or `none`.
- Produces the child-process environment needed by `addons/ao/deploy.sh` and `includes/addon-wire.sh`.

- [ ] **Step 1: Write the failing tests**

Add static and isolated command-flow assertions that verify:

```bash
grep -q 'source .*includes/ao-llm.sh' aap-demo.sh
grep -q 'aap_demo_ao_llm_choice' aap-demo.sh
grep -q 'AO_LLM_PROVIDER.*external' aap-demo.sh
grep -q '_ensure_addon_dependency ollama' aap-demo.sh
```

The behavioral test must exercise the provider-preparation helper with a
temporary config and assert that the external choice writes
`AO_LLM_PROVIDER=external`, `AO_LLM_BASE_URL`, and `AO_LLM_MODEL`, while the
external branch does not call the Ollama dependency function. It must also
assert that `QUIET=true` selects Ollama without reading a terminal.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash test/test-ao-enable-provider.sh && bash test/test-core-commands.sh`
Expected: FAIL because AO enablement currently always calls
`_ensure_addon_dependency ollama` and has no provider-selection path.

- [ ] **Step 3: Implement the minimal CLI flow**

Source `includes/ao-llm.sh` after the shared path helper. Before
`_ensure_addon_dependency ollama`, prepare the provider:

```bash
if [ "${AO_LLM_PROVIDER:-}" = external ]; then
  aap_demo_ao_llm_external_defaults
  [ -s "$(aap_demo_ao_llm_key_file)" ] || prompt for a hidden API key
elif [ "${QUIET:-false}" = true ]; then
  AO_LLM_PROVIDER=ollama
else
  prompt with Ollama as option 1 and external API-key provider as option 2
fi
```

Persist only non-secret provider settings. Call
`_ensure_addon_dependency ollama` only for `AO_LLM_PROVIDER=ollama`; always
keep `mcp-server` as an AO dependency. Forward the selected provider settings
to the AO child process.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash test/test-ao-enable-provider.sh && bash test/test-core-commands.sh`
Expected: PASS; external mode skips Ollama, quiet mode preserves the current
dependency behavior, and existing core command checks remain green.

- [ ] **Step 5: Commit**

```bash
git add aap-demo.sh test/test-core-commands.sh test/test-ao-enable-provider.sh
git commit -m "feat: prompt for AO LLM provider"
```

### Task 3: Wire external OpenAI-compatible providers through AO

**Files:**

- Modify: `includes/addon-wire.sh:25-40, 890-1035`
- Modify: `addons/ao/deploy.sh:840-865`
- Create: `test/test-ao-llm-wiring.sh`

**Interfaces:**

- Consumes `AO_LLM_PROVIDER`, `AO_LLM_BASE_URL`, `AO_LLM_MODEL`, and the private key file from Tasks 1–2.
- Produces an AO credential named `aap-demo External LLM` and an
  `llm_provider` integration with `provider_hint: custom`, the configured base
  URL, and the configured model selected as default.
- Preserves `wire_ao_ollama` for local mode and changes the top-level wiring
  dispatcher to invoke exactly one LLM provider path.

- [ ] **Step 1: Write the failing tests**

Add source-level and mocked API assertions that verify:

```bash
grep -q 'wire_ao_external_llm' includes/addon-wire.sh
grep -q 'provider_hint: "custom"' includes/addon-wire.sh
grep -q 'AO_LLM_MODEL.*luna' includes/addon-wire.sh
```

The mocked wiring test must assert that external mode sends the API key only
inside the `LLM Provider` credential payload, uses the configured base URL,
refreshes models, and skips `wire_ao_ollama`; local mode must continue to call
the existing Ollama path.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/test-ao-llm-wiring.sh`
Expected: FAIL because the wiring layer has no external provider function or provider dispatcher.

- [ ] **Step 3: Implement the minimal wiring path**

Extract the shared model-default PATCH behavior from
`wire_ao_set_default_ollama_model` into a generic helper, then implement
`wire_ao_external_llm` using the existing credential and integration upsert
patterns. Read the key from the mode-600 file only when creating/updating the
credential; reuse an existing credential when a later wire run has no key
file. Build the integration with the configured base URL,
`provider_hint: custom`, and secure defaults for HTTP/TLS, then validate,
refresh, and select `AO_LLM_MODEL` as default.

Update AO demo import lookup so external mode can supply the external LLM
credential/model just as Ollama currently does, without assuming the Ollama
deployment exists. In `none` mode, omit the optional agent credential and
model arguments.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash test/test-ao-llm-wiring.sh && bash test/test-ollama.sh`
Expected: PASS for external mocked payloads and unchanged Ollama regression coverage.

- [ ] **Step 5: Commit**

```bash
git add includes/addon-wire.sh addons/ao/deploy.sh test/test-ao-llm-wiring.sh
git commit -m "feat: wire external AO LLM providers"
```

### Task 4: Document the provider choices and run full verification

**Files:**

- Modify: `addons/ao/README.md`
- Modify: `addons/ollama/README.md`
- Modify: `aap-demo.sh` help text if the provider choices need to be discoverable there

- [ ] **Step 1: Update documentation**

Document the interactive prompt, the non-interactive default, the `none`
behavior, the external defaults (`https://api.openai.com/v1` and `luna`),
`AO_LLM_BASE_URL`/`AO_LLM_MODEL` overrides, secure key-file behavior, and how
to reuse an exported `OPENAI_API_KEY` without sourcing profile files or
automatically uninstalling Ollama.

- [ ] **Step 2: Run focused verification**

Run: `bash -n aap-demo.sh includes/ao-llm.sh includes/addon-wire.sh
addons/ao/deploy.sh` and all new/modified shell regression tests.
Expected: exit 0 with no syntax errors.

- [ ] **Step 3: Run the repository test target**

Run: `make test`
Expected: shell syntax checks and dry-run checks pass.

- [ ] **Step 4: Review the diff and commit**

```bash
git diff --check
git status --short
git add addons/ao/README.md addons/ollama/README.md aap-demo.sh
git commit -m "docs: describe AO LLM provider choices"
```

- [ ] **Step 5: Final verification**

Run: `make lint`
Expected: ShellCheck, yamllint, and markdownlint pass, or any pre-existing unrelated failures are reported explicitly.
