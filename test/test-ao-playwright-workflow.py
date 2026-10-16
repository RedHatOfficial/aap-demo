"""Contract tests for the checked-in AO ansible-ui Playwright workflow."""

import importlib.util
import json
from pathlib import Path
import unittest


WORKFLOW = (
    Path(__file__).parents[1]
    / "addons"
    / "ao"
    / "workflows"
    / "ansible-ui-playwright-test-builder.json"
)


def load_runner():
    script = (
        Path(__file__).parents[1]
        / "addons"
        / "ao"
        / "scripts"
        / "run-playwright-workflow.py"
    )
    spec = importlib.util.spec_from_file_location("run_playwright_workflow", script)
    if spec is None or spec.loader is None:
        raise AssertionError(f"unable to load {script}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class WorkflowExportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.document = json.loads(WORKFLOW.read_text())
        cls.nodes = {node["id"]: node for node in cls.document["nodes"]}

    def test_export_uses_current_schema_and_single_test_inputs(self):
        self.assertEqual(self.document["schema_version"], "2.0.0")
        trigger = next(
            item for item in self.document["triggers"] if item["id"] == "trigger_manual"
        )
        input_schema = trigger["parameters"]["input_schema"]
        self.assertEqual(
            set(input_schema["properties"]),
            {"ref", "test_path", "test_title", "target_name", "execute_mutations"},
        )
        self.assertEqual(input_schema["required"], ["test_path", "test_title"])

    def test_export_has_bounded_fetch_analysis_and_branch_audit_nodes(self):
        for node_id in (
            "fetch_chunk_1",
            "fetch_chunk_2",
            "fetch_chunk_3",
            "fetch_chunk_4",
            "fetch_chunk_5",
            "analyze_chunk_1",
            "analyze_chunk_2",
            "analyze_chunk_3",
            "analyze_chunk_4",
            "analyze_chunk_5",
            "select_test_case",
            "test_selection_gate",
            "execution_switch",
            "execute_aap_readonly",
            "execute_aap_mutations",
            "audit_readonly",
            "audit_mutations",
        ):
            self.assertIn(node_id, self.nodes)

    def test_mcp_nodes_use_selected_tools_and_tool_model_role(self):
        for node_id in (
            "execute_aap_readonly",
            "execute_aap_mutations",
            "audit_readonly",
            "audit_mutations",
        ):
            parameters = self.nodes[node_id]["parameters"]
            self.assertEqual(parameters["tool_selection_strategy"], "SELECTED")
            self.assertGreater(len(parameters["tool_selection_names"]), 0)
            self.assertLess(len(parameters["tool_selection_names"]), 128)
            self.assertNotIn("tool_selections", parameters)
            self.assertEqual(parameters["model_role"], "tool")

    def test_selection_agent_requires_exactly_one_test_title(self):
        parameters = self.nodes["select_test_case"]["parameters"]
        self.assertIn("${trigger.test_title}", parameters["prompt"])
        schema = parameters["response_schema"]
        self.assertEqual(
            set(schema["required"]),
            {
                "match_count",
                "selected_title",
                "setup_actions",
                "test_actions",
                "verification_actions",
                "cleanup_actions",
                "unsupported_operations",
            },
        )

    def test_audit_branches_reference_their_own_executor(self):
        self.assertIn(
            "${execute_aap_readonly.result.content}",
            self.nodes["audit_readonly"]["parameters"]["prompt"],
        )
        self.assertIn(
            "${execute_aap_mutations.result.content}",
            self.nodes["audit_mutations"]["parameters"]["prompt"],
        )
        self.assertNotIn(
            "${converge_executor.result.content}",
            self.nodes["audit_readonly"]["parameters"]["prompt"],
        )

    def test_mutation_switch_uses_boolean_trigger_values(self):
        switch = self.nodes["execution_switch"]["parameters"]
        conditions = {case["port"]: case["condition"] for case in switch["cases"]}
        self.assertEqual(conditions["mutate"], "${trigger.execute_mutations} == True")
        self.assertEqual(
            conditions["readonly"], "${trigger.execute_mutations} == False"
        )


class RunnerPayloadTests(unittest.TestCase):
    def test_build_execution_payload_defaults_to_read_only(self):
        module = load_runner()
        payload = module.build_execution_payload(
            "workflow-id", "devel", "spec.ts", "can edit", "unique-target", False
        )
        self.assertEqual(payload["trigger_node_id"], "trigger_manual")
        self.assertFalse(payload["input_data"]["execute_mutations"])
        self.assertFalse(payload["use_published"])


class DocumentationTests(unittest.TestCase):
    def test_docs_describe_single_test_input_and_read_only_default(self):
        readme = Path(__file__).parents[1] / "addons" / "ao" / "README.md"
        text = readme.read_text()
        self.assertIn("test_title", text)
        self.assertIn("execute_mutations", text)
        self.assertIn("read-only", text)


if __name__ == "__main__":
    unittest.main()
