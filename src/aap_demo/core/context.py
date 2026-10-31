"""AppContext — everything a core operation needs, and nothing from ``cli/``.

Every seam the test suite substitutes hangs off this object: the runner, the
console, the secret store, and the event emitter. ``cluster/``, ``addons/``,
``gui/``, and ``desktop/`` all receive one of these; none of them import
``cli/`` (design §2.2).
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Mapping, Optional

from aap_demo.core.config import Config
from aap_demo.core.console import Console
from aap_demo.core.events import EventEmitter
from aap_demo.core.paths import Paths
from aap_demo.core.secrets import SecretStore


@dataclass
class AppContext:
    config: Config
    paths: Paths
    console: Console
    runner: Any
    secrets: SecretStore
    events: EventEmitter = field(default_factory=EventEmitter)
    env: Mapping[str, str] = field(default_factory=lambda: dict(os.environ))

    #: CLI-shaped state that is not a persisted setting.
    output: str = "rich"
    force: bool = False
    assume_yes: bool = False
    verbose: bool = False
    kubeconfig_override: Optional[Path] = None
    kube_context: Optional[str] = None

    #: Preserves bash's ``_NAMESPACE_EXPLICIT`` (aap-demo.sh:59) — ``test``
    #: behaves differently when the namespace was set explicitly vs. defaulted.
    namespace_explicit: bool = False

    @property
    def namespace(self) -> str:
        return self.config.get("core.namespace", "aap-operator")

    @property
    def quiet(self) -> bool:
        return bool(self.config.get("core.quiet", False)) or self.console.quiet

    @property
    def kubeconfig(self) -> Path:
        if self.kubeconfig_override is not None:
            return self.kubeconfig_override
        env_path = self.env.get("AAP_DEMO_KUBECONFIG") or self.env.get("KUBECONFIG")
        if env_path:
            return Path(env_path)
        return self.paths.kubeconfig

    def kube_env(self) -> Dict[str, str]:
        env = dict(self.env)
        env["KUBECONFIG"] = str(self.kubeconfig)
        return env
