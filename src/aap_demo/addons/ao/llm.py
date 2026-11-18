"""Which LLM AO uses, and its API key. Ports includes/ao-llm.sh without the prompts.

Settings come from the environment, then ``addons.options.ao`` in config.yaml,
then the Bash command's ``~/.aap-demo/config`` (ADR-045). The external API key
is read from ``AO_LLM_API_KEY``, else a 0600 file in the Python state
directory, else the Bash command's ``~/.aap-demo/ao/llm-api-key``.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Optional

from aap_demo.addons.common.state import options_for
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError, UsageError

PROVIDERS = ("ollama", "external", "none")
DEFAULT_PROVIDER = "ollama"
DEFAULT_BASE_URL = "https://api.openai.com/v1"
DEFAULT_EXTERNAL_MODEL = "gpt-6-luna"
DEFAULT_OLLAMA_MODEL = "qwen2.5:3b"
KEY_FILE = "llm-api-key"
#: config.yaml ``addons.options.ao`` key -> environment variable.
OPTION_ENV = {
    "llm_provider": "AO_LLM_PROVIDER",
    "llm_base_url": "AO_LLM_BASE_URL",
    "llm_model": "AO_LLM_MODEL",
}


@dataclass(frozen=True)
class Settings:
    provider: str
    base_url: str
    model: str

    @property
    def integration(self) -> str:
        return "aap-demo External LLM" if self.provider == "external" else "aap-demo Ollama"


def _legacy(ctx: AppContext) -> Dict[str, str]:
    from aap_demo.core.migration import parse_legacy_config

    path = ctx.paths.legacy_config_file
    try:
        return parse_legacy_config(path.read_text(encoding="utf-8")) if path.is_file() else {}
    except OSError as exc:
        raise AddonError("could not read the existing AO configuration", hint=str(exc)) from exc


def _value(ctx: AppContext, option: str, legacy: Dict[str, str]) -> str:
    variable = OPTION_ENV[option]
    return str(
        ctx.env.get(variable) or options_for(ctx, "ao").get(option) or legacy.get(variable) or ""
    ).strip()


def settings(ctx: AppContext) -> Settings:
    legacy = _legacy(ctx)
    provider = _value(ctx, "llm_provider", legacy) or DEFAULT_PROVIDER
    if provider not in PROVIDERS:
        raise UsageError(
            f"AO_LLM_PROVIDER={provider} is not a known provider",
            hint="Use ollama, external, or none.",
        )
    if provider == "ollama":
        model = str(
            ctx.env.get("WIRE_OLLAMA_MODEL") or ctx.env.get("OLLAMA_MODEL") or DEFAULT_OLLAMA_MODEL
        )
    else:
        model = _value(ctx, "llm_model", legacy) or DEFAULT_EXTERNAL_MODEL
        if model == "luna":
            model = DEFAULT_EXTERNAL_MODEL
    return Settings(
        provider=provider,
        base_url=_value(ctx, "llm_base_url", legacy) or DEFAULT_BASE_URL,
        model=model,
    )


def key_path(ctx: AppContext) -> Path:
    return ctx.paths.addon_dir("ao") / KEY_FILE


def _read(path: Path) -> str:
    if not path.is_file() or path.is_symlink():
        return ""
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def _save(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(value)
    os.chmod(path, 0o600)


def api_key(ctx: AppContext) -> Optional[str]:
    """The external provider's key, kept for the next enable."""
    from_env = str(ctx.env.get("AO_LLM_API_KEY") or "").strip()
    if from_env:
        _save(key_path(ctx), from_env)
        return from_env
    saved = _read(key_path(ctx))
    if saved:
        return saved
    legacy = _read(ctx.paths.legacy_dir / "ao" / KEY_FILE)
    if legacy:
        _save(key_path(ctx), legacy)
        return legacy
    return None
