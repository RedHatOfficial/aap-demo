"""Addon catalog contract for the legacy Bash dashboard."""

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_addon_catalog_matches_bash_list():
    catalog = json.loads((ROOT / "config/addons-dashboard.json").read_text())
    cli = (ROOT / "aap-demo.sh").read_text()
    match = re.search(r'^AVAILABLE_ADDONS="([^"]+)"$', cli, re.MULTILINE)
    assert match is not None
    bash_addons = match.group(1).split()
    ids = [addon["id"] for addon in catalog["addons"]]
    assert len(ids) == len(set(ids))
    assert set(ids) == set(bash_addons)
    assert ids.count("eda-playground") == 1


def test_eda_playground_addon_health():
    catalog = json.loads((ROOT / "config/addons-dashboard.json").read_text())
    addon = next(item for item in catalog["addons"] if item["id"] == "eda-playground")
    assert addon["health"] == {"namespace": "eda-playground", "deployment": "eda-playground"}
