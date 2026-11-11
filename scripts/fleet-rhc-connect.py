#!/usr/bin/env python3
"""Drive RHC's installed interactive prompts without credentials in argv or logs."""

import errno
import json
import os
import pty
import re
import select
import signal
import subprocess
import sys
import termios
import time


def connected(output: str) -> bool:
    return all(
        re.search(pattern, output, re.IGNORECASE)
        for pattern in (
            r"(?m)^.*(?<!not )connected to Red Hat Subscription Management",
            r"(?m)^.*(?<!not )connected to Red Hat Insights",
            r"Remote Host Configuration daemon is active",
        )
    )


def read_status() -> str:
    result = subprocess.run(
        ["rhc", "status"], capture_output=True, text=True, timeout=30, check=False
    )
    if result.returncode != 0:
        raise RuntimeError("RHC status failed; enrollment state cannot be verified")
    return result.stdout


def ensure_insights(output: str) -> None:
    # RHC 0.2.7 can exit zero with RHSM/rhcd connected but Insights incomplete.
    if connected(output):
        return
    if not insights_pending(output):
        raise RuntimeError("RHC connection is incomplete; inspect rhc status locally")
    result = subprocess.run(
        ["insights-client", "--register"], capture_output=True, timeout=180, check=False
    )
    if result.returncode != 0:
        raise RuntimeError("Insights registration/upload failed; inspect insights-client locally")


def insights_pending(output: str) -> bool:
    return connected(output.replace("Not connected to Red Hat Insights",
                                    "Connected to Red Hat Insights"))


def connect(username: str, password: str, timeout: float = 300) -> None:
    pid, fd = pty.fork()
    if pid == 0:
        attributes = termios.tcgetattr(0)
        attributes[3] &= ~termios.ECHO
        termios.tcsetattr(0, termios.TCSANOW, attributes)
        os.execvp("rhc", ["rhc", "connect"])
    exited = False
    buffer = b""
    sent: set[str] = set()
    deadline = time.monotonic() + timeout
    try:
        while time.monotonic() < deadline:
            if select.select([fd], [], [], 0.2)[0]:
                try:
                    chunk = os.read(fd, 4096)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    chunk = b""
                if chunk:
                    buffer = (buffer + chunk)[-8192:]
                    for label, secret in (("Username", username), ("Password", password)):
                        if re.search(label.encode() + rb":\s*$", buffer, re.IGNORECASE):
                            if label in sent:
                                raise RuntimeError("RHC requested credentials again; enrollment failed")
                            os.write(fd, secret.encode() + b"\n")
                            sent.add(label)
                            buffer = b""
            result, wait_status = os.waitpid(pid, os.WNOHANG)
            if result:
                exited = True
                if os.waitstatus_to_exitcode(wait_status) != 0:
                    raise RuntimeError(
                        "RHC connect failed (authentication, entitlement, or network error); "
                        "check rhc status locally. Raw output withheld to protect credentials."
                    )
                return
        raise RuntimeError("RHC connect timed out; check connectivity and rhc status locally")
    finally:
        if not exited:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        os.close(fd)


def main() -> None:
    credentials = json.load(sys.stdin)
    username = credentials["username"]
    password = credentials["password"]
    if not all(isinstance(value, str) and value and not re.search(r"[\r\n\x00]", value)
               for value in (username, password)):
        raise ValueError("CDN credentials must be nonempty single-line values")
    initial = read_status()
    if connected(initial):
        print("Already connected to RHSM, Insights, and Remote Host Configuration")
        return
    if not insights_pending(initial):
        connect(username, password)
    ensure_insights(read_status())
    if not connected(read_status()):
        raise RuntimeError("RHC exited successfully but full connection status was not verified")
    print("Verified connection to RHSM, Insights, and Remote Host Configuration")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.TimeoutExpired) as error:
        # Never include tool output, credential values, or exception repr in diagnostics.
        if isinstance(error, RuntimeError):
            print(str(error), file=sys.stderr)
        else:
            print("Unable to complete RHC enrollment; verify tools, credentials, and connectivity",
                  file=sys.stderr)
        sys.exit(1)
