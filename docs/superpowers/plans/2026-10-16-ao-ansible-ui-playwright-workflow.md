# AO Ansible UI Playwright Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the live AO Ansible UI Playwright workflow reproducible from Git
and run one selected Playwright test case at a time with bounded prompts,
explicit execution mode, and branch-specific audits.

**Architecture:** A checked-in AO workflow export accepts a source ref, test path,
exact test title, unique target name, and an `execute_mutations` flag. It fetches
the source in identity-encoded ranges, analyzes chunks independently, selects one
test case, then routes to either read-only or mutation execution and a matching
audit branch. The existing Python importer and AAP synchronization playbook will
overlay this local workflow on top of the pinned upstream demos and preserve the
separate model/tool bindings required by AO.

**Tech Stack:** AO workflow schema `2.0.0`, AO REST API, AAP synchronization
playbook, Ansible/Jinja, Python 3, Bash, `jq`, `unittest`, GitHub raw HTTP range
requests, and the existing MCP/AAP integrations.

**Spec:** [`docs/adr/034-ao-ansible-ui-playwright-workflow.md`](../../adr/034-ao-ansible-ui-playwright-workflow.md)

<!-- markdownlint-disable MD013 -->

## Global Constraints

- AO workflow definitions use `schema_version: "2.0.0"`.
- Each HTTP range is `7,000` bytes and requests `Accept-Encoding: identity`; the initial workflow covers five ranges, `0-6999` through `28000-34999`.
- Every agent prompt must remain below AO's observed `10,000` character limit; agent responses use bounded JSON schemas.
- MCP-enabled nodes use `tool_selection_strategy: "SELECTED"` and fewer than `128` selected tools.
- `execute_mutations` defaults to `false`; read-only runs must not create, update, launch, or delete AAP resources.
- Tool-enabled executor and audit nodes use the configured non-reasoning tool-capable model; analysis and synthesis nodes may use the configured reasoning model.
- API keys, credentials, integration UUIDs, and model UUIDs are resolved at install/wiring time and never committed to workflow exports or tests.
- The local workflow import remains idempotent and must not change existing upstream demo behavior when its local workflow is absent.
- Each task ends with a focused test command and a separate Git commit.

## Repository File Map

- Create `addons/ao/workflows/ansible-ui-playwright-test-builder.json`: version-controlled AO workflow export with the single-test trigger contract, bounded graph, selected MCP tools, and branch-specific model roles.
- Modify `addons/ao/scripts/import-demos.py`: overlay local aap-demo workflow exports alongside upstream exports, identify their source label, and select the tool-capable model for nodes marked `model_role: "tool"`.
- Modify `addons/ao/deploy.sh`: pass the local workflow directory and resolved tool-agent model ID into the importer.
- Modify `addons/ao/playbooks/sync-ao-demos.yml`: find the checked-in local workflow when the control-plane project runs synchronization.
- Modify `addons/ao/playbooks/tasks/sync_workflow.yml`: preserve `model_role`, selected tools, and the local workflow source label while normalizing credentials and model IDs.
- Modify `includes/addon-wire.sh`: resolve the selected non-reasoning tool-capable model separately from the default reasoning model and preserve model roles during rebinding.
- Create `addons/ao/scripts/run-playwright-workflow.py`: invoke one selected AO test case through `POST /api/v1/executions` and poll its result without exposing credentials.
- Create `test/test-ao-playwright-workflow.py`: unit-test the export contract, selector behavior, tool bounds, model-role normalization, and runner payload.
- Modify `test/test-ao-import-demos.py`: test local workflow overlay and per-node model selection in the existing importer test suite.
- Modify `test/test-ao-llm-workflow-binding.sh`: cover both default reasoning and tool-capable model bindings.
- Modify `test/README.md`: document the focused local unit tests and the opt-in live test-by-test AO smoke procedure.
- Modify `addons/ao/README.md` and `addons/ao/demos/README.md`: document the workflow inputs, safe default, local export source, and test selection behavior.
- Modify `docs/adr/README.md`: already completed in this preparation branch by adding ADR-034 to the index.
- Create `docs/adr/034-ao-ansible-ui-playwright-workflow.md`: already completed in this preparation branch and used as the implementation spec.

---

### Task 1: Define the checked-in workflow contract and test fixture

**Files:**

- Create: `addons/ao/workflows/ansible-ui-playwright-test-builder.json`
- Create: `test/test-ao-playwright-workflow.py`

**Interfaces:**

- Consumes: AO manual trigger inputs `ref`, `test_path`, `test_title`, `target_name`, and `execute_mutations`.
- Produces: a JSON export whose top-level `schema_version` is `2.0.0`, whose trigger exposes the five inputs, and whose nodes have stable IDs used by later importer and live tests.

- [ ] **Step 1: Write the failing export-contract tests**

Add these tests to `test/test-ao-playwright-workflow.py`:

```python
import json
from pathlib import Path
import unittest


WORKFLOW = Path(__file__).parents[1] / "addons" / "ao" / "workflows" / "ansible-ui-playwright-test-builder.json"


class WorkflowExportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.document = json.loads(WORKFLOW.read_text())
        cls.nodes = {node["id"]: node for node in cls.document["nodes"]}

    def test_export_uses_current_schema_and_single_test_inputs(self):
        self.assertEqual(self.document["schema_version"], "2.0.0")
        trigger = next(item for item in self.document["triggers"] if item["id"] == "trigger_manual")
        self.assertEqual(
            set(trigger["parameters"]),
            {"ref", "test_path", "test_title", "target_name", "execute_mutations"},
        )

    def test_export_has_bounded_fetch_analysis_and_branch_audit_nodes(self):
        for node_id in (
            "fetch_chunk_1", "fetch_chunk_2", "fetch_chunk_3", "fetch_chunk_4", "fetch_chunk_5",
            "analyze_chunk_1", "analyze_chunk_2", "analyze_chunk_3", "analyze_chunk_4", "analyze_chunk_5",
            "select_test_case", "test_selection_gate", "execution_switch",
            "execute_aap_readonly", "execute_aap_mutations", "audit_readonly", "audit_mutations",
        ):
            self.assertIn(node_id, self.nodes)

    def test_mcp_nodes_use_selected_tools_and_tool_model_role(self):
        for node_id in ("execute_aap_readonly", "execute_aap_mutations", "audit_readonly", "audit_mutations"):
            parameters = self.nodes[node_id]["parameters"]
            self.assertEqual(parameters["tool_selection_strategy"], "SELECTED")
            self.assertGreater(len(parameters["tool_selections"]), 0)
            self.assertLess(len(parameters["tool_selections"]), 128)
            self.assertEqual(parameters["model_role"], "tool")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the contract tests and verify they fail because the export does not exist**

Run:

```bash
python3 -m unittest test/test-ao-playwright-workflow.py -v
```

Expected: FAIL with `FileNotFoundError` for `addons/ao/workflows/ansible-ui-playwright-test-builder.json`.

- [ ] **Step 3: Add the minimal checked-in export**

Create the export with these concrete trigger defaults and node rules:

```json
{
  "schema_version": "2.0.0",
  "name": "Ansible UI Playwright Test Builder",
  "description": "Analyze one ansible-ui Playwright test case and assess it against AAP.",
  "triggers": [{
    "id": "trigger_manual",
    "name": "Run one Playwright test",
    "type": "manual_trigger",
    "parameters": {
      "ref": "devel",
      "test_path": "playwright/tests/integration/automation-execution/workflow-job-templates/workflow-job-templates.spec.ts",
      "test_title": "",
      "target_name": "ao-playwright-validation",
      "execute_mutations": false
    }
  }],
  "nodes": []
}
```

Replace the empty `nodes` array with the complete bounded graph before running the test: five `http_request` nodes with `Range` values `bytes=0-6999`, `bytes=7000-13999`, `bytes=14000-20999`, `bytes=21000-27999`, and `bytes=28000-34999`; five chunk agents; `converge_fetches`; `fetch_gate`; `converge_analysis`; `select_test_case`; `test_selection_gate`; `synthesize_playwright`; `analysis_gate`; `execution_switch`; the two executors; the two audits; and `converge_audit`.

Set every fetch node's headers to include:

```json
{
  "Accept": "text/plain",
  "Accept-Encoding": "identity"
}
```

Give every chunk and synthesis agent a response schema with bounded arrays and strings. Use `model_role: "reasoning"` for analysis/synthesis nodes and `model_role: "tool"` for MCP nodes. Keep the MCP allowlist to the IDs for organization, inventory, project, job-template, and workflow-job-template list/retrieve operations plus the supported create/update/delete/launch operations used by the mutation branch.

- [ ] **Step 4: Run the contract tests and verify they pass**

Run:

```bash
python3 -m unittest test/test-ao-playwright-workflow.py -v
```

Expected: PASS for schema, trigger, node, tool-selection, and model-role assertions.

- [ ] **Step 5: Commit the export and contract tests**

```bash
git add addons/ao/workflows/ansible-ui-playwright-test-builder.json test/test-ao-playwright-workflow.py
git commit -m "feat(ao): add checked-in ansible-ui workflow contract"
```

---

### Task 2: Implement exact test-case selection and branch-specific AO logic

**Files:**

- Modify: `addons/ao/workflows/ansible-ui-playwright-test-builder.json`
- Modify: `test/test-ao-playwright-workflow.py`

**Interfaces:**

- Consumes: the five chunk reports and trigger `test_title`.
- Produces: `select_test_case.result.content` with `match_count`, `selected_title`, `setup_actions`, `test_actions`, `verification_actions`, `cleanup_actions`, and `unsupported_operations`; `test_selection_gate` routes only when `match_count == 1`; read-only and mutation audits consume their matching executor result directly.

- [ ] **Step 1: Write failing selector and graph tests**

Add these tests:

```python
    def test_selection_agent_requires_exactly_one_test_title(self):
        parameters = self.nodes["select_test_case"]["parameters"]
        self.assertIn("${trigger.test_title}", parameters["prompt"])
        schema = parameters["response_schema"]
        self.assertEqual(
            set(schema["required"]),
            {
                "match_count", "selected_title", "setup_actions", "test_actions",
                "verification_actions", "cleanup_actions", "unsupported_operations",
            },
        )

    def test_audit_branches_reference_their_own_executor(self):
        self.assertIn("${execute_aap_readonly.result.content}", self.nodes["audit_readonly"]["parameters"]["prompt"])
        self.assertIn("${execute_aap_mutations.result.content}", self.nodes["audit_mutations"]["parameters"]["prompt"])
        self.assertNotIn("${converge_executor.result.content}", self.nodes["audit_readonly"]["parameters"]["prompt"])

    def test_mutation_switch_uses_boolean_trigger_values(self):
        switch = self.nodes["execution_switch"]["parameters"]
        conditions = {case["port"]: case["condition"] for case in switch["cases"]}
        self.assertEqual(conditions["mutate"], "${trigger.execute_mutations} == True")
        self.assertEqual(conditions["readonly"], "${trigger.execute_mutations} == False")
```

- [ ] **Step 2: Run the focused tests and verify the selection logic is missing or incorrect**

Run:

```bash
python3 -m unittest test/test-ao-playwright-workflow.py -v
```

Expected: FAIL until the selector agent, selection gate, direct audit references, and boolean switch are present.

- [ ] **Step 3: Implement the test-case selector and gates**

Configure `select_test_case` to receive only the converged chunk reports and the exact title. Its prompt must instruct the agent to include the nearest `beforeEach` and `afterEach` hooks but exclude unrelated `test()` blocks. Configure the response schema with:

```json
{
  "type": "object",
  "required": ["match_count", "selected_title", "setup_actions", "test_actions", "verification_actions", "cleanup_actions", "unsupported_operations"],
  "properties": {
    "match_count": {"type": "integer", "minimum": 0, "maximum": 2},
    "selected_title": {"type": "string", "maxLength": 240},
    "setup_actions": {"type": "array", "maxItems": 12, "items": {"type": "string", "maxLength": 220}},
    "test_actions": {"type": "array", "maxItems": 20, "items": {"type": "string", "maxLength": 220}},
    "verification_actions": {"type": "array", "maxItems": 16, "items": {"type": "string", "maxLength": 220}},
    "cleanup_actions": {"type": "array", "maxItems": 12, "items": {"type": "string", "maxLength": 220}},
    "unsupported_operations": {"type": "array", "maxItems": 12, "items": {"type": "string", "maxLength": 220}}
  }
}
```

Set `test_selection_gate` to `${select_test_case.result.content.match_count} == 1`. Connect its true port to `synthesize_playwright`; connect its false port to a structured `selection_error` agent that reports the discovered titles and does not call MCP.

Set `execution_switch` cases exactly as follows:

```json
[
  {"port": "mutate", "condition": "${trigger.execute_mutations} == True"},
  {"port": "readonly", "condition": "${trigger.execute_mutations} == False"}
]
```

Connect `execute_aap_readonly` directly to `audit_readonly` and `execute_aap_mutations` directly to `audit_mutations`; connect both audits to `converge_audit`. Do not make either audit reference a converge node's `result` property.

- [ ] **Step 4: Run the focused tests and verify they pass**

Run:

```bash
python3 -m unittest test/test-ao-playwright-workflow.py -v
```

Expected: PASS, including the direct audit branch and boolean switch assertions.

- [ ] **Step 5: Commit the test-selection graph**

```bash
git add addons/ao/workflows/ansible-ui-playwright-test-builder.json test/test-ao-playwright-workflow.py
git commit -m "feat(ao): select and audit one playwright test case"
```

---

### Task 3: Overlay the local workflow during Python AO import

**Files:**

- Modify: `addons/ao/scripts/import-demos.py`
- Modify: `addons/ao/deploy.sh`
- Modify: `test/test-ao-import-demos.py`

**Interfaces:**

- Consumes: `--local-workflow-dir`, `--tool-agent-model-id`, and checked-in JSON files under `addons/ao/workflows/`.
- Produces: `collect_workflow_sources(upstream_root: Path, local_workflow_dir: Path | None) -> list[tuple[Path, str]]`, where each tuple contains a JSON path and source label (`ansible-tmm/aap-orchestrator-demos` or `aap-demo`).

- [ ] **Step 1: Add failing importer tests**

Add these tests to `test/test-ao-import-demos.py`:

```python
import tempfile

class LocalWorkflowOverlayTests(unittest.TestCase):
    def test_collect_workflow_sources_appends_checked_in_workflows(self):
        with tempfile.TemporaryDirectory() as root:
            upstream = Path(root) / "upstream" / "nested" / "ao"
            local = Path(root) / "local"
            upstream.mkdir(parents=True)
            local.mkdir()
            (upstream / "upstream.json").write_text("{}")
            (local / "local.json").write_text("{}")
            sources = IMPORT_DEMOS.collect_workflow_sources(upstream.parents[1], local)
        self.assertEqual(sources[-1][0].name, "local.json")
        self.assertEqual(sources[-1][1], "aap-demo")

    def test_normalize_keeps_selected_tools_and_uses_tool_model_role(self):
        workflow = {
            "nodes": [{
                "type": "agentic",
                "parameters": {
                    "model_role": "tool",
                    "tool_selection_strategy": "SELECTED",
                    "tool_selections": ["tool-id"],
                },
            }],
        }
        normalized = IMPORT_DEMOS.normalize(
            workflow,
            "aap-credential",
            agent_credential_id="reasoning-credential",
            agent_integration_id="llm-integration",
            agent_model_id="reasoning-model",
            tool_agent_model_id="tool-model",
        )
        parameters = normalized["nodes"][0]["parameters"]
        self.assertEqual(parameters["tool_selection_strategy"], "SELECTED")
        self.assertEqual(parameters["tool_selections"], ["tool-id"])
        self.assertEqual(parameters["llm_model_id"], "tool-model")
```

- [ ] **Step 2: Run the importer tests and verify they fail**

Run:

```bash
python3 -m unittest test/test-ao-import-demos.py -v
```

Expected: FAIL because the new collector, CLI option, and `tool_agent_model_id` argument do not exist.

- [ ] **Step 3: Implement the local source collector and model-role selection**

Add the function:

```python
def collect_workflow_sources(
    upstream_root: Path,
    local_workflow_dir: Path | None,
) -> list[tuple[Path, str]]:
    sources = [
        (path, "ansible-tmm/aap-orchestrator-demos")
        for path in sorted(upstream_root.rglob("ao/*.json"))
    ]
    if local_workflow_dir:
        sources.extend(
            (path, "aap-demo")
            for path in sorted(local_workflow_dir.glob("*.json"))
        )
    return sources
```

Extend `normalize()` with `tool_agent_model_id: str | None = None`. Before replacing the agent model, select `tool_agent_model_id` when `parameters.get("model_role") == "tool"`; otherwise select `agent_model_id`. Preserve `model_role`, `tool_selection_strategy`, and non-empty `tool_selections`. Add parser options `--local-workflow-dir` and `--tool-agent-model-id`, and pass the source label into the payload labels so local workflows use `source: "aap-demo"`.

Update `addons/ao/deploy.sh` to append:

```bash
--local-workflow-dir "${SCRIPT_DIR}/workflows"
```

and, when the tool-agent model resolves, append:

```bash
--tool-agent-model-id "${_tool_agent_model_id}"
```

Do not print either credential or model UUID in user-facing output.

- [ ] **Step 4: Run importer tests and the syntax check**

Run:

```bash
python3 -m unittest test/test-ao-import-demos.py -v
python3 -m py_compile addons/ao/scripts/import-demos.py
bash -n addons/ao/deploy.sh
```

Expected: all importer tests pass, Python compilation succeeds, and Bash syntax validation succeeds.

- [ ] **Step 5: Commit the importer overlay**

```bash
git add addons/ao/scripts/import-demos.py addons/ao/deploy.sh test/test-ao-import-demos.py
git commit -m "feat(ao): import checked-in local workflows"
```

---

### Task 4: Make AAP control-plane synchronization reproduce the local workflow

**Files:**

- Modify: `addons/ao/playbooks/sync-ao-demos.yml`
- Modify: `addons/ao/playbooks/tasks/sync_workflow.yml`
- Modify: `includes/addon-wire.sh`
- Modify: `test/test-ao-llm-workflow-binding.sh`

**Interfaces:**

- Consumes: local workflow files at `{{ playbook_dir }}/../workflows`, `ao_tool_agent_model_id`, `AO_AGENT_TOOL_MODEL`, optional `AO_AGENT_TOOL_MODEL_ID`, and the existing AAP/AO/MCP variables.
- Produces: an idempotent AO PATCH payload labeled `source: aap-demo` for the local export, with `llm_model_id` selected from `model_role` and MCP tool IDs preserved.

- [ ] **Step 1: Add failing binding assertions**

Extend `test/test-ao-llm-workflow-binding.sh` with an agentic node containing `model_role: tool`, `tool_selection_strategy: SELECTED`, and one tool UUID. Set `AO_AGENT_TOOL_MODEL_ID=tool-model-id`, invoke the rebinding function, and assert:

```bash
[ "$(jq -r '.workflow_definition.nodes[0].parameters.llm_model_id' "$TEST_DIR/demo-patch.json")" = tool-model-id ]
[ "$(jq -r '.workflow_definition.nodes[0].parameters.tool_selection_strategy' "$TEST_DIR/demo-patch.json")" = SELECTED ]
[ "$(jq -r '.workflow_definition.nodes[0].parameters.tool_selections[0]' "$TEST_DIR/demo-patch.json")" = tool-id ]
```

- [ ] **Step 2: Run the binding test and verify it fails**

Run:

```bash
bash test/test-ao-llm-workflow-binding.sh
```

Expected: FAIL because the existing rebinding code applies one model ID to every agentic node.

- [ ] **Step 3: Add local source discovery to the playbook**

After the upstream archive is extracted, find local files with:

```yaml
- name: Locate checked-in aap-demo AO workflows
  ansible.builtin.find:
    paths: "{{ playbook_dir }}/../workflows"
    patterns: "*.json"
    file_type: file
  register: __ao_local_workflow_files
```

Combine the local files with `__ao_sources` and pass an explicit source label to `sync_workflow.yml`. In `sync_workflow.yml`, use `aap-demo` for local files and `ansible-tmm/aap-orchestrator-demos` for upstream files. Add `ao_tool_agent_model_id` to the play vars and select it only when the normalized agent node has `model_role: tool`.

Add `wire_ao_llm_agent_tool_model_id()` beside the existing `wire_ao_llm_agent_model_id()` helper. It must return `AO_AGENT_TOOL_MODEL_ID` when that variable is set; otherwise resolve `AO_AGENT_TOOL_MODEL` (default `gpt-4.1`) against the same LLM integration and return only the AO model UUID. Update `wire_ao_rebind_agentic_workflows()` so nodes with `parameters.model_role == "tool"` receive that model UUID while all other agentic nodes retain the selected default model. Keep model UUIDs out of logs.

- [ ] **Step 4: Run playbook lint/syntax and binding tests**

Run:

```bash
bash test/test-ao-llm-workflow-binding.sh
ansible-playbook --syntax-check addons/ao/playbooks/sync-ao-demos.yml
```

Expected: PASS for model-role rebinding and playbook syntax. The syntax check must not contact AO or AAP.

- [ ] **Step 5: Commit control-plane synchronization**

```bash
git add addons/ao/playbooks/sync-ao-demos.yml addons/ao/playbooks/tasks/sync_workflow.yml includes/addon-wire.sh test/test-ao-llm-workflow-binding.sh
git commit -m "feat(ao): sync local playwright workflow through aap"
```

---

### Task 5: Add a focused one-test AO runner

**Files:**

- Create: `addons/ao/scripts/run-playwright-workflow.py`
- Modify: `test/test-ao-playwright-workflow.py`

**Interfaces:**

- Consumes: `--route`, `--token`, `--workflow-id`, `--ref`, `--test-path`, `--test-title`, `--target-name`, and optional `--execute-mutations`.
- Produces: one `POST /api/v1/executions` request with `trigger_node_id: trigger_manual`, `use_published: false`, and a redacted terminal status; exit code `0` for completed, `1` for failed/canceled, and `2` for invalid arguments or missing selection.

- [ ] **Step 1: Write runner payload tests**

Add:

```python
class RunnerPayloadTests(unittest.TestCase):
    def test_build_execution_payload_defaults_to_read_only(self):
        from importlib.util import spec_from_file_location, module_from_spec
        script = Path(__file__).parents[1] / "addons" / "ao" / "scripts" / "run-playwright-workflow.py"
        spec = spec_from_file_location("run_playwright_workflow", script)
        module = module_from_spec(spec)
        spec.loader.exec_module(module)
        payload = module.build_execution_payload(
            "workflow-id", "devel", "spec.ts", "can edit", "unique-target", False
        )
        self.assertEqual(payload["trigger_node_id"], "trigger_manual")
        self.assertFalse(payload["input_data"]["execute_mutations"])
        self.assertFalse(payload["use_published"])
```

- [ ] **Step 2: Run the runner test and verify it fails**

Run:

```bash
python3 -m unittest test/test-ao-playwright-workflow.py -v
```

Expected: FAIL because the runner module and `build_execution_payload()` do not exist.

- [ ] **Step 3: Implement the runner**

Define:

```python
def build_execution_payload(
    workflow_id: str,
    ref: str,
    test_path: str,
    test_title: str,
    target_name: str,
    execute_mutations: bool,
) -> dict[str, object]:
    return {
        "workflow_id": workflow_id,
        "trigger_node_id": "trigger_manual",
        "input_data": {
            "ref": ref,
            "test_path": test_path,
            "test_title": test_title,
            "target_name": target_name,
            "execute_mutations": execute_mutations,
        },
        "use_published": False,
    }
```

Use `urllib.request` with an `Authorization: Bearer` header, parse the returned execution ID, poll `/api/v1/executions/{id}` every five seconds, and print only `execution_id`, `status`, `workflow_version`, and `error_details`. Reject an empty `test_title` before making the API request. Never print the token or raw execution input.

- [ ] **Step 4: Run the runner tests and CLI help**

Run:

```bash
python3 -m unittest test/test-ao-playwright-workflow.py -v
python3 addons/ao/scripts/run-playwright-workflow.py --help
```

Expected: PASS and help output containing all required arguments.

- [ ] **Step 5: Commit the focused runner**

```bash
git add addons/ao/scripts/run-playwright-workflow.py test/test-ao-playwright-workflow.py
git commit -m "feat(ao): add one-test playwright workflow runner"
```

---

### Task 6: Document and verify the test-by-test operating procedure

**Files:**

- Modify: `addons/ao/README.md`
- Modify: `addons/ao/demos/README.md`
- Modify: `test/README.md`
- Modify: `test/test-ao-playwright-workflow.py`

**Interfaces:**

- Consumes: the checked-in workflow, importer, playbook synchronization, and runner from Tasks 1–5.
- Produces: a documented safe smoke test and a repeatable command for each individual Playwright test title.

- [ ] **Step 1: Add the failing documentation-contract test**

Add:

```python
class DocumentationTests(unittest.TestCase):
    def test_docs_describe_single_test_input_and_read_only_default(self):
        readme = Path(__file__).parents[1] / "addons" / "ao" / "README.md"
        text = readme.read_text()
        self.assertIn("test_title", text)
        self.assertIn("execute_mutations", text)
        self.assertIn("read-only", text)
```

- [ ] **Step 2: Run the test and verify the documentation contract fails**

Run:

```bash
python3 -m unittest test/test-ao-playwright-workflow.py -v
```

Expected: FAIL until the AO README documents the new trigger contract.

- [ ] **Step 3: Document one-test execution and safety rules**

Add a section to `addons/ao/README.md` containing this command shape:

```bash
python3 addons/ao/scripts/run-playwright-workflow.py \
  --route "$AO_ROUTE" \
  --token "$AO_TOKEN" \
  --workflow-id "$AO_PLAYWRIGHT_WORKFLOW_ID" \
  --ref devel \
  --test-path playwright/tests/integration/automation-execution/workflow-job-templates/workflow-job-templates.spec.ts \
  --test-title "can edit a workflow job template from the details view" \
  --target-name "ao-playwright-validation-$(date +%s)"
```

State explicitly that omitting `--execute-mutations` is read-only, that mutation runs require a unique target name and disposable AAP resources, and that each run should select one exact Playwright test title rather than a whole file. Document how to list candidate titles from `select_test_case` when a title is ambiguous or missing.

Update `addons/ao/demos/README.md` to distinguish upstream downloaded exports from the checked-in `addons/ao/workflows/` local workflow. Update `test/README.md` with the unit command and an opt-in live command that uses `execute_mutations=false`.

- [ ] **Step 4: Run all focused tests and static checks**

Run:

```bash
python3 -m unittest test/test-ao-playwright-workflow.py test/test-ao-import-demos.py -v
bash test/test-ao-llm-workflow-binding.sh
python3 -m py_compile addons/ao/scripts/import-demos.py addons/ao/scripts/run-playwright-workflow.py
bash -n addons/ao/deploy.sh
ansible-playbook --syntax-check addons/ao/playbooks/sync-ao-demos.yml
```

Expected: all unit tests and the shell test pass, Python compilation succeeds, Bash syntax validation succeeds, and the playbook syntax check succeeds.

- [ ] **Step 5: Run one live read-only test-case execution**

On the disposable MicroShift/AO environment, resolve the AO route and token with the existing `includes/addon-wire.sh` helpers, then run the documented runner for one exact test title with mutations disabled. Confirm:

```text
workflow_version: current checked-in version
fetch_chunk_1..fetch_chunk_5: completed
select_test_case: completed with match_count=1
execute_aap_mutations: skipped
execute_aap_readonly: completed
audit_readonly: completed with status=pass or blocked and explicit findings
```

Run a second title from the same file and confirm the two executions have different selected titles but the same bounded graph. Do not run the mutation path in this task.

- [ ] **Step 6: Commit documentation and verification updates**

```bash
git add addons/ao/README.md addons/ao/demos/README.md test/README.md test/test-ao-playwright-workflow.py
git commit -m "docs(ao): document test-by-test playwright validation"
```

---

## Self-Review Checklist

- [ ] The plan covers the source-controlled AO export, Python importer, local deployment path, AAP control-plane sync, model/tool binding, one-test runner, tests, and documentation.
- [ ] Every task has exact files, interfaces, focused tests, commands, and a commit boundary.
- [ ] The plan does not require secrets or hard-coded environment-specific UUIDs in Git.
- [ ] The read-only default, selected MCP tools, non-reasoning tool model, prompt limits, and direct branch-specific audit references are explicit.
- [ ] The planned test sequence validates one Playwright test title before any mutation-capable execution is considered.
