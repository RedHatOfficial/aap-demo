"""Infrastructure backend queries (design §2.2).

Only OpenShift Local (``crc``) is a supported backend today — ``core.infra``'s
schema enum is ``[crc]`` — so this is a flat module (``infra/crc.py``) rather
than the ABC + registry dispatch the design sketches (§2.2's ``infra/base.py``
+ ``infra/registry.py``) for when a second backend exists.
"""

from __future__ import annotations
