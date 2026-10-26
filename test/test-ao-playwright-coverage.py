#!/usr/bin/env python3
"""Tests for the deterministic AAP-UI Playwright coverage analyzer."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "addons/ao/scripts/analyze-playwright-coverage.py"
SPEC = importlib.util.spec_from_file_location("coverage_analyzer", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CoverageAnalyzerTests(unittest.TestCase):
    def test_extracts_tests_actions_and_assertions(self) -> None:
        source = '''
        test("creates a job template", async ({page}) => {
          await page.getByRole("button", {name: "Create"}).click();
          await expect(page.getByText("Created")).toBeVisible();
        });
        '''
        tests = MODULE.extract_tests(source)
        self.assertEqual(["creates a job template"], [item["title"] for item in tests])
        self.assertTrue(tests[0]["actions"])
        self.assertTrue(tests[0]["assertions"])

    def test_groups_redundant_tests(self) -> None:
        source = '''
        test("job template create", async ({page}) => {
          await page.goto("/job-templates");
          await page.getByRole("button", {name: "Create"}).click();
          await expect(page.getByText("Created")).toBeVisible();
        });
        test("job template create again", async ({page}) => {
          await page.goto("/job-templates");
          await page.getByRole("button", {name: "Create"}).click();
          await expect(page.getByText("Created")).toBeVisible();
        });
        '''
        groups = MODULE.redundancy_groups(MODULE.extract_tests(source))
        self.assertEqual(1, len(groups))
        self.assertEqual(2, len(groups[0]["tests"]))

    def test_reports_missing_deployment_areas(self) -> None:
        report = MODULE.build_report(
            'test("login", async ({page}) => { await page.goto("/login"); });',
            "fixture",
            ["authentication", "controller"],
        )
        self.assertIn("controller", report["coverage_gaps"])
        self.assertEqual(1, report["test_count"])

    def test_builds_one_report_across_multiple_spec_files(self) -> None:
        files = [
            ("playwright/tests/integration/controller.spec.ts", 'test("creates", async ({page}) => { await page.goto("/jobs"); await expect(page).toBeVisible(); });'),
            ("playwright/tests/integration/execution.spec.ts", 'test("launches", async ({page}) => { await page.getByRole("button").click(); await expect(page).toHaveText("Done"); });'),
        ]
        report = MODULE.build_report_from_files(files, "full suite", ["controller", "execution"])
        self.assertEqual(2, report["file_count"])
        self.assertEqual(2, report["test_count"])
        self.assertEqual([], report["coverage_gaps"])
        self.assertEqual(2, len(report["coverage_matrix"]))


if __name__ == "__main__":
    unittest.main()
