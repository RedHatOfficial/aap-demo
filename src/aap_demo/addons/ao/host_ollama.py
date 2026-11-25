"""The ``ollama`` LLM provider: an Ollama server the user runs on the host (ADR-046).

aap-demo does not install Ollama or pull models. Before AO installs, this checks
that Ollama answers on the host, picks one of the models already pulled, and
checks from a pod that the cluster reaches the host. With CRC's
``host-network-access`` on macOS and Windows, pods reach the host at
``192.168.127.254``; Ollama itself can stay on ``127.0.0.1``.
"""

from __future__ import annotations

import json
import platform as _platform
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
#: Times the model prompt asks again after an answer that names no model.
ASK_ATTEMPTS = 3
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


def is_cluster_url(base_url: str) -> bool:
    """True for CRC's address for the host, however the URL is written."""
    return api_root(base_url.strip()).lower() == api_root(CLUSTER_URL)


def host_api(base_url: str) -> str:
    """Where this machine reaches Ollama: 127.0.0.1, unless AO_LLM_BASE_URL is set."""
    return HOST_API if is_cluster_url(base_url) else api_root(base_url)


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
    return str(ctx.env.get("OLLAMA_MODEL") or _saved(ctx)).strip()


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
    answer = ""
    for _ in range(ASK_ATTEMPTS):
        try:
            answer = read(f"Model for AO [1-{len(available)}]: ").strip()
        except EOFError:
            answer = ""
        if not answer:
            break
        if answer.isdigit() and 1 <= int(answer) <= len(available):
            ctx.console.out("")
            return available[int(answer) - 1]
        chosen = _matches(answer, available)
        if chosen:
            ctx.console.out("")
            return chosen
        ctx.console.out(f"{answer!r} is not on this host. Enter a number or a model name.")
    ctx.console.out("")
    raise AddonError(
        f"No model chosen{f': {answer!r} is not on this host' if answer else ''}",
        hint="Run aap-demo enable ao again, or set OLLAMA_MODEL=<model>.",
    )


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
    """True when a pod in ``namespace`` gets HTTP 200 from Ollama's version API.

    False when the pod ran and Ollama did not answer. Raises when the pod
    itself did not run, which is a cluster problem rather than a network one.
    """
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
    output = (result.stdout or "").strip()
    code = output[-3:]
    if len(code) == 3 and code.isdigit():
        return result.ok and code == "200"
    detail = (result.stderr or output).strip()
    raise AddonError(
        f"The pod that checks the path to Ollama did not run in namespace {namespace}",
        hint=f"{detail + '. ' if detail else ''}The pod pulls {CHECK_IMAGE}; check that "
        f"the cluster can pull it, then run aap-demo enable ao again "
        f"(kubectl get events -n {namespace}).",
    )


def _host_network_access(ctx: AppContext) -> str:
    result = ctx.runner.run(["crc", "config", "get", "host-network-access"])
    text = (result.stdout or "").strip().lower() if result.ok else ""
    return "true" if text.endswith("true") else "false" if text.endswith("false") else ""


def unreachable(ctx: AppContext, base_url: str, *, platform: Optional[str] = None) -> AddonError:
    message = f"The cluster cannot reach Ollama at {api_root(base_url)}"
    other = "Or set AO_LLM_PROVIDER=external, or none to install AO without an LLM."
    if not is_cluster_url(base_url):
        return AddonError(
            message,
            hint="Check that Ollama listens on an address the VM reaches, and that "
            f"AO_LLM_BASE_URL points at it. {other}",
        )
    if (platform or _platform.system()).lower().startswith("linux"):
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
    elif not setting:
        why = (
            "Could not read CRC's host-network-access setting (crc config get "
            "host-network-access). Pods reach the host only when it was on at create time."
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
    platform: Optional[str] = None,
) -> str:
    """Check the host's Ollama and the path to it. Saves and returns the model.

    The cluster check runs before the model prompt, so a VM that cannot reach
    the host fails before anyone answers a question.
    """
    api = host_api(base_url)
    found = version(api, get)
    if not found:
        raise AddonError(
            f"Ollama is not responding at {api}",
            hint=f"Is it running? It has {TIMEOUT} seconds to answer. {INSTALL_HINT}",
        )
    ctx.console.success(f"Ollama {found} on the host")
    if kubectl.exists(ctx.runner, "namespace", OLD_NAMESPACE):
        ctx.console.note(
            "The in-cluster Ollama from an earlier aap-demo is still installed, and AO no "
            "longer uses it. Remove it with: aap-demo disable ollama"
        )
    ctx.console.info("Checking that the cluster reaches the host's Ollama...")
    if not reaches(ctx, base_url, ctx.namespace):
        raise unreachable(ctx, base_url, platform=platform)
    ctx.console.success(f"The cluster reaches Ollama at {api_root(base_url)}")
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
    return model


__all__ = [
    "CLUSTER_URL",
    "choose_model",
    "is_cluster_url",
    "prepare",
    "reaches",
]
