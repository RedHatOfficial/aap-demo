"""The ``ollama`` LLM provider: an Ollama server the user runs on the host (ADR-046).

aap-demo does not install Ollama or pull models. Before AO installs, this checks
that Ollama answers on the host, picks one of the models already pulled, and
checks from a pod that the cluster reaches the host. With CRC's
``host-network-access`` on macOS and Windows, pods reach the host at
``192.168.127.254``; Ollama itself can stay on ``127.0.0.1``.
"""

from __future__ import annotations

import json
import sys
import urllib.error
import urllib.request
from typing import Any, Callable, Dict, List, Optional

from aap_demo.addons.common.state import options_for, save_options_for
from aap_demo.core import prompts
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError
from aap_demo.exec import kubectl

#: CRC's address for the host, as seen from the VM and its pods.
CLUSTER_HOST = "192.168.127.254"
PORT = 11434
HOST_API = f"http://127.0.0.1:{PORT}"
CLUSTER_URL = f"http://{CLUSTER_HOST}:{PORT}/v1"
#: ``addons.options.ao`` key that keeps the chosen model.
MODEL_OPTION = "ollama_model"
#: The in-cluster Ollama that earlier releases installed (ADR-024).
OLD_NAMESPACE = "aap-demo-ollama"
CHECK_POD = "aap-demo-ollama-check"
CHECK_IMAGE = "registry.access.redhat.com/ubi9/ubi-minimal:latest"
TIMEOUT = 5
#: Seconds for the check pod, including its first image pull.
CHECK_TIMEOUT = 300

#: GET (no body) or POST (JSON body) a URL. Parsed JSON, or None on any failure.
Fetch = Callable[[str, Optional[Dict[str, Any]]], Optional[Any]]
Read = Callable[[str], str]

INSTALL_HINT = (
    "Install Ollama from https://ollama.com/download (on macOS: brew install ollama), "
    "start it, pull a model that supports tools (ollama pull <model>), then run "
    "aap-demo enable ao again. To use another LLM, set AO_LLM_PROVIDER=external, "
    "or AO_LLM_PROVIDER=none to install AO without one."
)


def fetch(url: str, body: Optional[Dict[str, Any]] = None) -> Optional[Any]:
    """Call the host's Ollama directly, never through a proxy."""
    data = json.dumps(body).encode("utf-8") if body is not None else None
    request = urllib.request.Request(url, data=data, method="POST" if data else "GET")
    if data:
        request.add_header("Content-Type", "application/json")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=TIMEOUT) as response:
            return json.loads(response.read().decode("utf-8") or "null")
    except (urllib.error.URLError, OSError, ValueError):
        return None


def api_root(base_url: str) -> str:
    """``http://host:port`` from an OpenAI-style ``.../v1`` URL."""
    root = base_url.rstrip("/")
    return root[: -len("/v1")] if root.endswith("/v1") else root


def host_api(base_url: str) -> str:
    """Where this machine reaches Ollama: 127.0.0.1, unless AO_LLM_BASE_URL is set."""
    return api_root(base_url) if base_url != CLUSTER_URL else HOST_API


def version(api: str, get: Fetch) -> str:
    found = get(f"{api}/api/version", None)
    return str(found.get("version") or "") if isinstance(found, dict) else ""


def models(api: str, get: Fetch) -> List[str]:
    found = get(f"{api}/api/tags", None)
    listed = found.get("models") if isinstance(found, dict) else None
    names = [str(m.get("name") or "") for m in listed or [] if isinstance(m, dict)]
    return sorted(n for n in names if n)


def capabilities(api: str, model: str, get: Fetch) -> Optional[List[str]]:
    """The model's capabilities, or None when this Ollama does not report them."""
    found = get(f"{api}/api/show", {"model": model})
    listed = found.get("capabilities") if isinstance(found, dict) else None
    return [str(c) for c in listed] if isinstance(listed, list) else None


def _saved(ctx: AppContext) -> str:
    return str(options_for(ctx, "ao").get(MODEL_OPTION) or "").strip()


def requested_model(ctx: AppContext) -> str:
    """OLLAMA_MODEL, then the model saved by an earlier enable, or ""."""
    return str(
        ctx.env.get("OLLAMA_MODEL") or ctx.env.get("WIRE_OLLAMA_MODEL") or _saved(ctx)
    ).strip()


def _matches(wanted: str, available: List[str]) -> str:
    """Ollama names a model without a tag ``<name>:latest``."""
    if wanted in available:
        return wanted
    tagged = f"{wanted}:latest"
    return tagged if ":" not in wanted and tagged in available else ""


def _ask(ctx: AppContext, available: List[str], read: Read) -> str:
    ctx.console.out("")
    ctx.console.out("Models on this host's Ollama:")
    for number, name in enumerate(available, start=1):
        ctx.console.out(f"  {number}) {name}")
    try:
        answer = read(f"Model for AO [1-{len(available)}]: ").strip()
    except EOFError:
        answer = ""
    ctx.console.out("")
    if answer.isdigit() and 1 <= int(answer) <= len(available):
        return available[int(answer) - 1]
    chosen = _matches(answer, available) if answer else ""
    if not chosen:
        raise AddonError(
            f"No model chosen{f': {answer!r} is not on this host' if answer else ''}",
            hint="Run aap-demo enable ao again, or set OLLAMA_MODEL=<model>.",
        )
    return chosen


def choose_model(
    ctx: AppContext, available: List[str], *, read: Read = input, can_ask: bool = False
) -> str:
    wanted = requested_model(ctx)
    if wanted:
        found = _matches(wanted, available)
        if found:
            return found
        raise AddonError(
            f"Model {wanted} is not on this host's Ollama",
            hint=f"Pull it with: ollama pull {wanted}. Or choose another with "
            f"OLLAMA_MODEL=<model>. Models here: {', '.join(available) or 'none'}.",
        )
    if not available:
        raise AddonError(
            "This host's Ollama has no models",
            hint="Pull a model that supports tools (ollama pull <model>), then run "
            "aap-demo enable ao again. aap-demo does not choose or download models.",
        )
    if len(available) == 1:
        return available[0]
    if can_ask:
        return _ask(ctx, available, read)
    raise AddonError(
        "This host's Ollama has several models; choose one for AO",
        hint=f"Set OLLAMA_MODEL=<model> and run aap-demo enable ao again. "
        f"Models here: {', '.join(available)}.",
    )


def _check_pod_overrides(url: str) -> str:
    """A pod the restricted Pod Security profile admits, that curls ``url``."""
    container = {
        "name": "check",
        "image": CHECK_IMAGE,
        "command": ["curl", "-s", "-m", "10", "-o", "/dev/null", "-w", "%{http_code}", url],
        "securityContext": {
            "allowPrivilegeEscalation": False,
            "capabilities": {"drop": ["ALL"]},
        },
    }
    spec = {
        "securityContext": {"runAsNonRoot": True, "seccompProfile": {"type": "RuntimeDefault"}},
        "containers": [container],
    }
    return json.dumps({"spec": spec})


def reaches(ctx: AppContext, base_url: str, namespace: str) -> bool:
    """True when a pod in ``namespace`` gets HTTP 200 from Ollama's version API."""
    url = f"{api_root(base_url)}/api/version"
    kubectl.run(
        ctx.runner, "delete", "pod", CHECK_POD, "-n", namespace, "--ignore-not-found", "--wait"
    )
    result = kubectl.run(
        ctx.runner,
        "run",
        CHECK_POD,
        "-n",
        namespace,
        "--rm",
        "-i",
        "--quiet",
        "--restart=Never",
        "--pod-running-timeout=3m",
        f"--image={CHECK_IMAGE}",
        f"--overrides={_check_pod_overrides(url)}",
        timeout=CHECK_TIMEOUT,
    )
    return result.ok and (result.stdout or "").strip().endswith("200")


def _host_network_access(ctx: AppContext) -> str:
    result = ctx.runner.run(["crc", "config", "get", "host-network-access"])
    text = (result.stdout or "").strip().lower() if result.ok else ""
    return "true" if text.endswith("true") else "false" if text.endswith("false") else ""


def unreachable(ctx: AppContext, base_url: str, *, platform: str = sys.platform) -> AddonError:
    message = f"The cluster cannot reach Ollama at {api_root(base_url)}"
    other = "Or set AO_LLM_PROVIDER=external, or none to install AO without an LLM."
    if base_url != CLUSTER_URL:
        return AddonError(
            message,
            hint="Check that Ollama listens on an address the VM reaches, and that "
            f"AO_LLM_BASE_URL points at it. {other}",
        )
    if platform.startswith("linux"):
        return AddonError(
            message,
            hint="On Linux, CRC has no host network access setting. Make Ollama listen "
            "on the libvirt bridge (OLLAMA_HOST) and set AO_LLM_BASE_URL to that "
            f"address and port with /v1. {other}",
        )
    setting = _host_network_access(ctx)
    if setting == "true":
        why = (
            "CRC's host-network-access is on, but this VM may have been created before it was set."
        )
    else:
        why = (
            "This VM was created without CRC's host-network-access, which lets pods reach the "
            "host. AAP_DEMO_HOST_NETWORK_ACCESS=false at create time turns it off."
        )
    return AddonError(
        message,
        hint=f"{why} The setting needs a new VM: aap-demo destroy, then aap-demo create "
        f"(which turns it on), then aap-demo deploy. {other}",
    )


def prepare(
    ctx: AppContext,
    base_url: str,
    *,
    get: Fetch = fetch,
    read: Read = input,
    platform: str = sys.platform,
) -> str:
    """Check the host's Ollama and the path to it. Saves and returns the model."""
    api = host_api(base_url)
    found = version(api, get)
    if not found:
        raise AddonError(f"Ollama is not running at {api}", hint=INSTALL_HINT)
    ctx.console.success(f"Ollama {found} on the host")
    if kubectl.exists(ctx.runner, "namespace", OLD_NAMESPACE):
        ctx.console.note(
            "The in-cluster Ollama from an earlier aap-demo is still installed, and AO no "
            "longer uses it. Remove it with: aap-demo disable ollama"
        )
    model = choose_model(ctx, models(api, get), read=read, can_ask=prompts.can_ask(ctx.env))
    if model != _saved(ctx):
        save_options_for(ctx, "ao", {**options_for(ctx, "ao"), MODEL_OPTION: model})
    ctx.console.success(f"Ollama model for AO: {model}")
    listed = capabilities(api, model, get)
    if listed is None:
        ctx.console.warn(
            "This Ollama does not report model capabilities; could not check that "
            f"{model} supports tools, which AO's agents need."
        )
    elif "tools" not in listed:
        ctx.console.warn(
            f"{model} does not list tool support, which AO's agents need. Choose a model "
            "that does with OLLAMA_MODEL=<model>."
        )
    ctx.console.info("Checking that the cluster reaches the host's Ollama...")
    if not reaches(ctx, base_url, ctx.namespace):
        raise unreachable(ctx, base_url, platform=platform)
    ctx.console.success(f"The cluster reaches Ollama at {api_root(base_url)}")
    return model


__all__ = [
    "CLUSTER_URL",
    "choose_model",
    "prepare",
    "reaches",
]
