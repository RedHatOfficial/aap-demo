"""JSON and YAML responses are one document, with no human log mixed in."""

from __future__ import annotations

import io
import json

import yaml

from aap_demo.cli.main import run
from aap_demo.core.console import Console
from aap_demo.core.output import render


def test_structured_stdout_is_only_the_document() -> None:
    stdout = io.StringIO()
    stderr = io.StringIO()
    console = Console(stdout=stdout, stderr=stderr, structured=True, style="basic")

    console.progress("Becoming Successful")
    console.step("Starting CRC")
    console.checkpoint("CRC is running")
    console.warn("sudo: a password is required")
    console.out("Password: secret")
    console.success("AAP deployment successful!")
    render(console, {"ready": True, "route": "https://aap.example"}, output="json")

    document = stdout.getvalue()
    assert json.loads(document) == {"ready": True, "route": "https://aap.example"}
    assert "Password" not in document
    assert "Starting CRC" not in document
    assert "sudo" not in document
    assert "successful" not in document
    assert "sudo" in stderr.getvalue()


def test_yaml_emit_is_one_document() -> None:
    stdout = io.StringIO()
    console = Console(stdout=stdout, structured=True, style="basic")
    console.out("not part of the document")
    render(console, {"ready": False, "warnings": ["still reconciling"]}, output="yaml")

    documents = list(yaml.safe_load_all(stdout.getvalue()))
    assert documents == [{"ready": False, "warnings": ["still reconciling"]}]
    assert "not part of the document" not in stdout.getvalue()


def test_version_json_and_yaml_are_one_document(tmp_path, capsys) -> None:
    env = {"HOME": str(tmp_path), "AAP_DEMO_DIR": str(tmp_path), "QUIET": "1"}
    for output, load in (("json", json.loads), ("yaml", yaml.safe_load)):
        rc = run(["--output", output, "version"], env=env)
        captured = capsys.readouterr()
        assert rc == 0
        payload = load(captured.out)
        assert isinstance(payload, dict)
        assert payload["version"] == "2.0.0.dev1"
        assert "Password" not in captured.out
        if output == "yaml":
            assert list(yaml.safe_load_all(captured.out)) == [payload]


def test_quiet_json_version_is_still_one_document(tmp_path, capsys) -> None:
    rc = run(
        ["--quiet", "--output", "json", "version"],
        env={"HOME": str(tmp_path), "AAP_DEMO_DIR": str(tmp_path)},
    )
    captured = capsys.readouterr()
    assert rc == 0
    payload = json.loads(captured.out)
    assert payload["version"] == "2.0.0.dev1"
    assert captured.out.strip().startswith("{")
    assert captured.out.strip().endswith("}")
