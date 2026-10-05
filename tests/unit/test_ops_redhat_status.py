"""``cli/ops.py::redhat_status`` (design §3.3 phase 1: ``cmd_redhat_status``).

Fetches via ``curl`` through the ``CommandRunner`` (see the docstring on
``_fetch_rss`` for why), so a realistic RSS payload is fed in as the curl
call's fixture stdout rather than mocking an HTTP client.
"""

from __future__ import annotations

import argparse
import json

import pytest

from aap_demo.cli import ops
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AapDemoError
from aap_demo.exec.runner import FakeRunner

SAMPLE_RSS_WITH_INCIDENT = """\
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
<channel>
<title>Red Hat Status - Incident History</title>
<item>
<title>Registry authentication failures for quay.io</title>
<link>https://status.redhat.com/incidents/abc123</link>
<description>We are currently Investigating reports of 403 errors.</description>
<pubDate>Mon, 01 Sep 2026 12:00:00 +0000</pubDate>
</item>
<item>
<title>Elevated error rates resolved</title>
<link>https://status.redhat.com/incidents/def456</link>
<description>This incident affected the registry and has been Resolved.</description>
<pubDate>Sun, 31 Aug 2026 08:00:00 +0000</pubDate>
</item>
<item>
<title>Unrelated console outage</title>
<link>https://status.redhat.com/incidents/ghi789</link>
<description>The console was briefly unreachable.</description>
<pubDate>Sat, 30 Aug 2026 08:00:00 +0000</pubDate>
</item>
</channel>
</rss>
"""

SAMPLE_RSS_NO_INCIDENTS = """\
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
<channel>
<title>Red Hat Status - Incident History</title>
<item>
<title>Elevated error rates resolved</title>
<link>https://status.redhat.com/incidents/def456</link>
<description>This incident affected the registry and has been Resolved.</description>
</item>
</channel>
</rss>
"""


def _ns(**kwargs) -> argparse.Namespace:
    return argparse.Namespace(**kwargs)


def test_raises_when_curl_returns_nothing(app_ctx: AppContext, fake_runner: FakeRunner) -> None:
    fake_runner.fail("curl -s --connect-timeout 5")
    with pytest.raises(AapDemoError, match="Unable to fetch status"):
        ops.redhat_status(app_ctx, _ns())
    # Bash prints the header before fetching, so a failed fetch still shows it.
    assert "Checking Red Hat service status" in app_ctx.console.stdout


def test_reports_active_registry_incident(app_ctx: AppContext, fake_runner: FakeRunner) -> None:
    fake_runner.ok("curl -s --connect-timeout 5", stdout=SAMPLE_RSS_WITH_INCIDENT)

    rc = ops.redhat_status(app_ctx, _ns())

    assert rc == 0
    # The whole report body is stdout — incident titles included. Splitting
    # title (stderr) from its Status:/Details: lines (stdout) left the two
    # halves of each incident on different streams with no ordering between.
    assert app_ctx.console.stderr == ""
    out = app_ctx.console.stdout
    assert "  [!] Registry authentication failures for quay.io" in app_ctx.console.stdout_lines
    assert "Registry authentication failures for quay.io" in out
    assert "Investigating" in out
    assert "https://status.redhat.com/incidents/abc123" in out
    # Resolved and unrelated (non-keyword) items must not appear.
    assert "Elevated error rates resolved" not in out
    assert "Unrelated console outage" not in out


def test_reports_no_active_incidents_when_all_resolved_or_unrelated(
    app_ctx: AppContext, fake_runner: FakeRunner
) -> None:
    fake_runner.ok("curl -s --connect-timeout 5", stdout=SAMPLE_RSS_NO_INCIDENTS)

    rc = ops.redhat_status(app_ctx, _ns())

    assert rc == 0
    assert "No active registry-related incidents" in app_ctx.console.stdout


def test_json_output_is_well_formed(app_ctx: AppContext, fake_runner: FakeRunner) -> None:
    fake_runner.ok("curl -s --connect-timeout 5", stdout=SAMPLE_RSS_WITH_INCIDENT)
    app_ctx.output = "json"

    rc = ops.redhat_status(app_ctx, _ns())

    assert rc == 0
    payload = json.loads(app_ctx.console.stdout)
    titles = [incident["title"] for incident in payload["incidents"]]
    assert titles == ["Registry authentication failures for quay.io"]


def test_parse_incidents_unescapes_xml_entities() -> None:
    rss = "<item><title>Registry &amp; Quay degraded</title><link>https://example.com</link></item>"
    incidents = ops._parse_incidents(rss)
    assert incidents[0]["title"] == "Registry & Quay degraded"
