"""Image refs, OS ids, and the fleet namespace default.

Playbooks receive ``namespace`` as an extra-var and do not hardcode it.
``addons.options.fleet.namespace`` overrides this default for a run.
"""

from __future__ import annotations

NAMESPACE = "fleet"

IMAGES = {
    "ubi9": "registry.access.redhat.com/ubi9/ubi:9.6",
    "fedora": "quay.io/fedora/fedora:41",
    "debian": "public.ecr.aws/docker/library/debian:bookworm",
}

OS_IDS = tuple(IMAGES)

DEFAULT_NODES = tuple({"name": f"fleet-{os_id}", "os": os_id} for os_id in OS_IDS)

SCM_URL = "https://github.com/RedHatOfficial/aap-demo.git"
SCM_BRANCH = "v2"

INVENTORY = "aap-demo-fleet"
CREDENTIAL = "aap-demo-fleet-ssh"
PROJECT = "aap-demo-fleet"
JOB_TEMPLATE = "aap-demo-fleet ping"
