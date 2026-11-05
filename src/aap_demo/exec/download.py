"""curl arguments for a file download that must not wait forever.

``--max-time`` is not set. A CRC bundle is large, and a slow transfer that
keeps receiving data should finish. ``--speed-time`` stops a transfer that
falls below ``--speed-limit`` and stays there. ``--connect-timeout`` stops a
connection that never starts.
"""

from __future__ import annotations

from aap_demo.core.errors import AapDemoError

CONNECT_TIMEOUT_SECONDS = "30"
SPEED_LIMIT_BYTES = "1024"
SPEED_TIME_SECONDS = "60"
RETRIES = "3"


def curl_argv(url: str, dest: str) -> list[str]:
    return [
        "curl",
        "-fsSL",
        "--retry",
        RETRIES,
        "--connect-timeout",
        CONNECT_TIMEOUT_SECONDS,
        "--speed-limit",
        SPEED_LIMIT_BYTES,
        "--speed-time",
        SPEED_TIME_SECONDS,
        "-o",
        dest,
        url,
    ]


def failed(name: str, url: str) -> AapDemoError:
    """An error that names the URL and tells the user to retry."""
    return AapDemoError(
        f"Failed to download {name}",
        hint=f"Retry the command, or download it from {url}",
    )
