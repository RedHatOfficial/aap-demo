"""Run inside the portal image to validate the installed six-plugin contract."""

import json
from pathlib import Path
import sys


PLUGINS = (
    "ansible-plugin-scaffolder-backend-module-backstage-rhaap",
    "ansible-backstage-plugin-catalog-backend-module-rhaap",
    "ansible-plugin-backstage-self-service",
    "ansible-backstage-plugin-auth-backend-module-rhaap-provider",
    "ansible-plugin-backstage-apme",
    "ansible-backstage-plugin-catalog-backend-module-apme",
)


def validate(root):
    for plugin in PLUGINS:
        path = root / plugin / "package.json"
        try:
            metadata = json.loads(path.read_text())
        except (OSError, ValueError) as error:
            raise ValueError("missing or invalid package.json for " + plugin) from error
        scoped = "@ansible/" + plugin[len("ansible-"):]
        if not isinstance(metadata, dict) or metadata.get("name") not in (
            plugin, plugin + "-dynamic", scoped, scoped + "-dynamic"
        ):
            raise ValueError("invalid package.json identity for " + plugin)
    print("Validated all six APME plugins")


if __name__ == "__main__":
    try:
        validate(Path("/opt/app-root/src/dynamic-plugins/dist"))
    except ValueError as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
