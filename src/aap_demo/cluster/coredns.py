"""CoreDNS Corefile rewrite rule for in-cluster route resolution.

Two entry points, both of which ``deploy`` touches:

* :func:`verify` ports ``verify_coredns`` (aap-demo.sh:2231-2260), which
  ``deploy_latest`` calls immediately after ``setup_namespace``. It is a
  *detector*: it re-configures only when the rewrite rule is missing, or
  present but malformed (a Corefile containing both ``router-internal-default``
  and a stray ``baseDomain:`` is the malformed shape bash learned to spot).
* :func:`configure` ports ``configure_coredns`` (includes/crc-create.sh:58).
  ``verify`` shells out to it in bash by re-sourcing ``crc-create.sh`` with
  ``AAP_DEMO_CONFIGURE_COREDNS_ONLY=1``; here it is simply a call. The rest of
  ``crc-create.sh`` is phase 4 — only this function is on the deploy path.

The re-patch after the first attempt is not defensive padding: MicroShift's
DNS controller overwrites the ConfigMap during startup (§14 R1), so bash
patches, waits, checks, and patches again before giving up with a warning.
"""

from __future__ import annotations

import json
import time
from typing import Any, Callable, Optional

from aap_demo.core.context import AppContext
from aap_demo.exec import kubectl
from aap_demo.exec import ssh as ssh_mod

DNS_NAMESPACE = "openshift-dns"
DNS_CONFIGMAP = "dns-default"
ROUTER_TARGET = "router-internal-default"
DEFAULT_ROUTE_DOMAIN = "apps.crc.testing"
#: MCP and older addons still publish this host after the cluster domain moved.
NIPIO_ROUTE_DOMAIN = "apps.127.0.0.1.nip.io"

#: Bash waits 5 seconds after the rollout before re-reading the ConfigMap
#: (includes/crc-create.sh:126, 139).
SETTLE_SECONDS = 5

_COREFILE_TEMPLATE = """\
.:5353 {{
    bufsize 1232
    errors
    log . {{
        class error
    }}
    health {{
        lameduck 20s
    }}
    ready
{rewrites}
    kubernetes cluster.local in-addr.arpa ip6.arpa {{
        pods insecure
        fallthrough in-addr.arpa ip6.arpa
    }}
    prometheus 127.0.0.1:9153
    forward . /etc/resolv.conf {{
        policy sequential
    }}
    cache 900 {{
        denial 9984 30
    }}
    reload
}}"""


def _rewrite_stanza(domain: str) -> str:
    """One ``rewrite stop`` block, dots escaped the way bash ``sed`` does it.

    ``sed 's/\\./\\\\./g'`` escapes dots and nothing else — deliberately not
    ``re.escape``, which also escapes ``-`` and would change the emitted
    Corefile for any hyphenated base domain.
    """
    router_svc = f"{ROUTER_TARGET}.openshift-ingress.svc.cluster.local"
    escaped = domain.replace(".", "\\.")
    return (
        "    rewrite stop {\n"
        f"        name regex (.*)\\.{escaped} {router_svc}\n"
        "        answer auto\n"
        "    }"
    )


def render_corefile(route_domain: str) -> str:
    """The Corefile heredoc from ``configure_coredns``.

    When the cluster domain is not already the nip.io name, a second rewrite
    covers ``apps.127.0.0.1.nip.io`` so in-cluster clients do not resolve those
    routes to the pod loopback (upstream #127). No trailing newline, because
    bash builds this with ``$(cat <<EOF)`` and command substitution strips
    them; the value ends up inside a JSON patch where the difference is real.
    """
    stanzas = [_rewrite_stanza(route_domain)]
    if route_domain != NIPIO_ROUTE_DOMAIN:
        stanzas.append(_rewrite_stanza(NIPIO_ROUTE_DOMAIN))
    else:
        # Bash still emits the empty ``${nipio_rewrite}`` line, which leaves a
        # blank line before ``kubernetes`` when the second rewrite is omitted.
        stanzas.append("")
    return _COREFILE_TEMPLATE.format(rewrites="\n".join(stanzas))


def rewrite_covers(corefile: str, route_domain: str) -> bool:
    """Ports ``configure_coredns``'s early-return test.

    A Corefile that rewrites only the cluster domain is not done: nip.io routes
    still need their own rule, unless the cluster domain *is* that nip.io name.
    """
    if ROUTER_TARGET not in corefile:
        return False
    if route_domain == NIPIO_ROUTE_DOMAIN:
        return True
    # The rewrite regex escapes dots, so the Corefile contains ``nip\.io``.
    # Bash ``grep -q "nip.io"`` does not match that (``.`` consumes the
    # backslash and the next character is ``.``, not ``i``), which would
    # restart CoreDNS on every ``start``. Accept the literal name or the
    # escaped regex we emit.
    return "nip.io" in corefile or "nip\\.io" in corefile


def render_resolv(existing: str, domain: str = NIPIO_ROUTE_DOMAIN) -> str:
    """Node ``resolv.conf`` with the nip.io route zone removed from ``search``.

    Kubelet copies this list onto every pod and sets ``ndots:5``. A service
    name such as ``aap-postgres-15.aap-operator.svc.cluster.local`` has four
    dots, so it is tried with each search suffix before it is tried as itself.
    Suffix ``apps.127.0.0.1.nip.io`` hits the CoreDNS router rewrite and the
    client connects to the router on port 5432. Absolute nip.io names still
    use that rewrite. They do not belong on the search list.
    """
    search_tokens: list[str] = []
    nameservers: list[str] = []
    options: list[str] = []
    for raw in existing.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("search "):
            search_tokens = line.split()[1:]
        elif line.startswith("nameserver "):
            nameservers.append(line)
        elif line.startswith("options "):
            options.append(line)
    if not nameservers:
        nameservers = ["nameserver 192.168.127.1"]
    ordered = [token for token in search_tokens if token != domain]
    lines: list[str] = []
    if ordered:
        lines.append("search " + " ".join(ordered))
    lines.extend(nameservers)
    lines.extend(options)
    return "\n".join(lines) + "\n"


def _resolv_matches(existing: str, rendered: str) -> bool:
    def norm(text: str) -> str:
        return "\n".join(line.strip() for line in text.splitlines() if line.strip())

    return norm(existing) == norm(rendered)


def ensure_search_domain(ctx: AppContext) -> bool:
    """Drop the nip.io route zone from the VM search list pods inherit.

    Create, start, and deploy all call this, including on a VM that already
    got the zone from an earlier run. A missing SSH key is not a failure.
    """
    key = ssh_mod.detect_ssh_key(ssh_mod.crc_machines_dir(ctx.env))
    if key is None:
        return False
    current = ssh_mod.exec_remote(ctx.runner, key, "cat", "/etc/resolv.conf", sudo=True)
    existing = current.stdout if current.ok else ""
    rendered = render_resolv(existing)
    if current.ok and _resolv_matches(existing, rendered):
        return True
    script = "tee /etc/resolv.conf >/dev/null <<'EOF'\n" + rendered + "EOF\n"
    wrote = ssh_mod.exec_remote(ctx.runner, key, "bash", "-c", script, sudo=True)
    if not wrote.ok:
        ctx.console.warn("Could not remove the nip.io zone from the pod DNS search list")
        return False
    ctx.console.progress(f"Pod DNS no longer searches {NIPIO_ROUTE_DOMAIN}")
    return True


def read_corefile(ctx: AppContext) -> str:
    return kubectl.jsonpath(
        ctx.runner,
        "configmap",
        DNS_CONFIGMAP,
        "-n",
        DNS_NAMESPACE,
        path="{.data.Corefile}",
    )


def needs_configuration(corefile: str) -> bool:
    """Ports ``verify_coredns``'s two-branch test (aap-demo.sh:2240-2249).

    Note the asymmetry, preserved deliberately: a Corefile *with* the rewrite
    is only considered broken when it also mentions ``baseDomain:`` — the
    signature of a Corefile that got a raw MicroShift config fragment spliced
    into it — and an empty Corefile means "no DNS ConfigMap to judge", which
    bash returns from before either test.
    """
    if ROUTER_TARGET in corefile:
        return "baseDomain:" in corefile
    return True


def _detect_route_domain(ctx: AppContext) -> str:
    """Ports the ``grep -h baseDomain`` SSH probe (includes/crc-create.sh:74)."""
    key = ssh_mod.detect_ssh_key(ssh_mod.crc_machines_dir(ctx.env))
    if key is None:
        return DEFAULT_ROUTE_DOMAIN
    result = ssh_mod.exec_remote(
        ctx.runner,
        key,
        "grep",
        "-h",
        "baseDomain",
        "/etc/microshift/config.d/99-aap-demo-dns.yaml",
        "/etc/microshift/config.yaml",
        sudo=False,
    )
    if not result.ok:
        return DEFAULT_ROUTE_DOMAIN
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            return f"apps.{parts[1]}"
    return DEFAULT_ROUTE_DOMAIN


def _patch_and_roll(ctx: AppContext, corefile: str, *, sleep: Callable[[float], None]) -> bool:
    patch = json.dumps({"data": {"Corefile": corefile}})
    ctx.runner.run(
        [
            "kubectl",
            "patch",
            "configmap",
            DNS_CONFIGMAP,
            "-n",
            DNS_NAMESPACE,
            "--type",
            "merge",
            "-p",
            patch,
        ]
    )
    ctx.runner.run(
        ["kubectl", "rollout", "restart", f"daemonset/{DNS_CONFIGMAP}", "-n", DNS_NAMESPACE]
    )
    ctx.runner.run(
        [
            "kubectl",
            "rollout",
            "status",
            f"daemonset/{DNS_CONFIGMAP}",
            "-n",
            DNS_NAMESPACE,
            "--timeout=60s",
        ]
    )
    sleep(SETTLE_SECONDS)
    return ROUTER_TARGET in read_corefile(ctx)


def configure(
    ctx: AppContext,
    *,
    sleep: Callable[[float], None] = time.sleep,
    route_domain: Optional[str] = None,
) -> bool:
    """Ports ``configure_coredns`` (includes/crc-create.sh:58-142)."""
    key = ssh_mod.detect_ssh_key(ssh_mod.crc_machines_dir(ctx.env))
    if key is None:
        ctx.console.failure("No CRC SSH key found. Cannot configure CoreDNS.")
        return False

    domain = route_domain or _detect_route_domain(ctx)
    ctx.console.step("Configuring CoreDNS")
    ensure_search_domain(ctx)

    if rewrite_covers(read_corefile(ctx), domain):
        ctx.console.checkpoint(f"CoreDNS already configured for {domain}")
        return True

    ctx.console.progress("Patching CoreDNS ConfigMap...")
    corefile = render_corefile(domain)
    if _patch_and_roll(ctx, corefile, sleep=sleep):
        ctx.console.checkpoint(f"CoreDNS configured: {domain} → router service")
        return True

    ctx.console.progress("CoreDNS config was overwritten by DNS operator — re-patching...")
    if _patch_and_roll(ctx, corefile, sleep=sleep):
        ctx.console.checkpoint(f"CoreDNS configured (re-patched): {domain} → router service")
        return True

    ctx.console.warn("CoreDNS config not persisting — DNS operator keeps overwriting")
    ctx.console.out("  If pods can't resolve nip.io routes, run: crc start")
    return False


def verify(ctx: AppContext, *, sleep: Callable[[float], None] = time.sleep) -> bool:
    """Ports ``verify_coredns`` (aap-demo.sh:2231). Never fails the deploy."""
    corefile = read_corefile(ctx)
    if not corefile:
        # No DNS ConfigMap at all — not a MicroShift-shaped cluster, or the API
        # is not answering yet. Bash returns 0 without comment.
        return True
    if not needs_configuration(corefile):
        # The rewrite can already be in place on a VM whose search list still
        # contains the nip.io zone. Deploy takes this path and removes it.
        ensure_search_domain(ctx)
        return True
    if ROUTER_TARGET in corefile:
        ctx.console.out("  CoreDNS rewrite rule is malformed — fixing...")
    else:
        ctx.console.out("  CoreDNS missing rewrite rule — configuring...")
    if configure(ctx, sleep=sleep):
        return True
    ctx.console.warn("CoreDNS auto-fix failed")
    ctx.console.out("  Run 'aap-demo create' to configure CoreDNS manually.")
    return False


__all__: Any = [
    "configure",
    "ensure_search_domain",
    "needs_configuration",
    "read_corefile",
    "render_corefile",
    "render_resolv",
    "rewrite_covers",
    "verify",
]
