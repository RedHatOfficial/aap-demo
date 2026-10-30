"""Unimplemented commands share one help line, exit code, and error."""

from __future__ import annotations

import pytest

from aap_demo.cli.main import build_parser, main

STUBS = (
    ["addon"],
    ["addon", "list"],
    ["playbooks"],
    ["playbooks", "list"],
    ["gui"],
    ["completion"],
    ["completion", "bash"],
)


def test_unimplemented_stubs_share_help_exit_and_error(tmp_path, capsys, monkeypatch) -> None:
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("AAP_DEMO_DIR", str(tmp_path))
    help_text = build_parser().format_help()
    for name in ("addon", "playbooks", "gui", "completion"):
        assert "Not yet implemented (use aap-demo-v1)" in help_text
        assert name in help_text

    config = tmp_path / "c.yaml"
    for argv in STUBS:
        with pytest.raises(SystemExit) as excinfo:
            main([argv[0], "--help"])
        assert excinfo.value.code == 0
        help_out = capsys.readouterr().out
        assert "Not yet implemented (use aap-demo-v1)" in help_out

        rc = main([*argv, "--config", str(config)])
        captured = capsys.readouterr()
        assert rc == 1
        assert "not yet implemented" in captured.err
        assert "aap-demo-v1" in captured.err
        assert "kubectl" not in captured.err
        assert captured.out == ""
