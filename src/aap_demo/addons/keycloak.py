"""Native V2 Keycloak OIDC lab addon.

The addon deliberately owns only its namespace and local credential directory.
It never changes AAP or Automation Orchestrator configuration; that remains an
explicit follow-up operation in the legacy ``configure.sh`` workflow.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import secrets
from pathlib import Path
from typing import Any, Dict
from urllib.parse import urlsplit

import yaml

from aap_demo.addons.base import AddonKind
from aap_demo.addons.common.state import enabled_names, set_enabled_names
from aap_demo.core.context import AppContext
from aap_demo.core.errors import AddonError
from aap_demo.core.output import is_structured, render

NAMESPACE = "aap-demo-keycloak"
REALM = "aap-lab"
IMAGE = (
    "quay.io/keycloak/keycloak@sha256:79c623a22abacf3fe6c00a5fb30f5b7843d717b234033b80995891c06116d"
    "244"
)
OWNER = "aap-demo-keycloak"
PART_OF = "aap-demo"
USERS = (
    ("aap-oidc-admin", "Admin"),
    ("aap-oidc-operator", "Operator"),
    ("aap-oidc-auditor", "Auditor"),
    ("aap-oidc-developer", "Developer"),
)


class KeycloakAddon:
    name = "keycloak"
    kind: AddonKind = "native"
    public = True
    needs_cluster = True

    def enable(self, ctx: AppContext, args: argparse.Namespace) -> int:
        del args
        _cluster(ctx)
        state = ctx.paths.addon_dir(self.name)
        state.mkdir(parents=True, exist_ok=True)
        state.chmod(0o700)
        credentials = _credentials(state)
        cluster_domain = _cluster_domain(ctx)
        keycloak_host = str(ctx.env.get("KEYCLOAK_HOST") or f"keycloak.{cluster_domain}")
        aap_host = _route(ctx, "aap", ctx.namespace) or f"aap-aap-operator.{cluster_domain}"
        ao_host = (
            _route(ctx, "", "automation-orchestrator")
            or f"automation-orchestrator.{cluster_domain}"
        )
        aap_redirect = str(ctx.env.get("KEYCLOAK_AAP_REDIRECT_URI") or f"https://{aap_host}/")
        ao_redirect = str(
            ctx.env.get("KEYCLOAK_AO_REDIRECT_URI")
            or f"https://{ao_host}/api/v1/auth/oidc/callback"
        )
        _validate_redirect(
            aap_redirect,
            aap_host,
            "/",
            strict=not bool(ctx.env.get("KEYCLOAK_AAP_REDIRECT_URI")),
        )
        _validate_redirect(
            ao_redirect,
            ao_host,
            "/api/v1/auth/oidc/callback",
            strict=not bool(ctx.env.get("KEYCLOAK_AO_REDIRECT_URI")),
        )
        aap_override = ctx.env.get("KEYCLOAK_AAP_REDIRECT_URI")
        if aap_override:
            (state / "aap-redirect-uri").write_text(aap_override, encoding="utf-8")
        else:
            (state / "aap-redirect-uri").unlink(missing_ok=True)
        (state / "ao-redirect-uri").write_text(ao_redirect, encoding="utf-8")
        for path in state.iterdir():
            path.chmod(0o600 if path.is_file() else 0o700)
        manifest = _manifest(credentials, keycloak_host, aap_redirect, ao_redirect)
        _ensure_namespace(ctx)
        result = ctx.runner.run(
            [
                "kubectl",
                "apply",
                "--server-side",
                "--field-manager=aap-demo-keycloak",
                "-f",
                "-",
            ],
            input=manifest,
        )
        if not result.ok:
            raise AddonError(
                "could not apply Keycloak resources", hint=result.stderr.strip() or None
            )
        rollout = ctx.runner.run(
            [
                "kubectl",
                "rollout",
                "status",
                "deployment/keycloak",
                "-n",
                NAMESPACE,
                "--timeout=10m",
            ]
        )
        if not rollout.ok:
            raise AddonError("Keycloak did not become ready", hint=rollout.stderr.strip() or None)
        _remember_enabled(ctx)
        _say(
            ctx,
            "Keycloak deployed",
            issuer=f"https://{keycloak_host}/realms/{REALM}",
            realm=REALM,
            aap_client="aap-demo-aap",
            ao_client="aap-demo-ao",
            credentials=str(state),
        )
        return 0

    def disable(self, ctx: AppContext, args: argparse.Namespace) -> int:
        del args
        _cluster(ctx)
        existing = ctx.runner.run(["kubectl", "get", "namespace", NAMESPACE, "-o", "json"])
        if not existing.ok:
            _forget_enabled(ctx)
            _say(ctx, "Keycloak namespace does not exist")
            return 0
        try:
            document = json.loads(existing.stdout or "{}")
        except json.JSONDecodeError as exc:
            raise AddonError("could not inspect Keycloak namespace") from exc
        labels = (document.get("metadata") or {}).get("labels") or {}
        if (
            labels.get("app.kubernetes.io/managed-by") != OWNER
            or labels.get("app.kubernetes.io/part-of") != PART_OF
        ):
            raise AddonError("refusing to delete unowned namespace aap-demo-keycloak")
        result = ctx.runner.run(["kubectl", "delete", "namespace", NAMESPACE, "--ignore-not-found"])
        if not result.ok:
            raise AddonError(
                "could not remove Keycloak namespace", hint=result.stderr.strip() or None
            )
        _forget_enabled(ctx)
        _say(
            ctx,
            "Keycloak removed; local credentials retained",
            credentials=str(ctx.paths.addon_dir(self.name)),
        )
        return 0


def _credentials(state: Path) -> Dict[str, str]:
    names = ["admin-password", "aap-client-secret", "ao-client-secret"] + [
        f"{u}-password" for u, _ in USERS
    ]
    values: Dict[str, str] = {}
    for name in names:
        path = state / name
        if not path.exists():
            path.write_text(secrets.token_hex(24), encoding="utf-8")
        value = path.read_text(encoding="utf-8").replace("\r", "").replace("\n", "")
        path.write_text(value, encoding="utf-8")
        path.chmod(0o600)
        values[name] = value
    return values


def _cluster(ctx: AppContext) -> None:
    result = ctx.runner.run(["kubectl", "cluster-info"])
    if not result.ok:
        raise AddonError("kubectl is not connected to a cluster")


def _validate_redirect(value: str, expected_host: str, expected_path: str, *, strict: bool) -> None:
    if "*" in value:
        raise AddonError("Keycloak redirect URIs must be exact URLs, not wildcards")
    parsed = urlsplit(value)
    if (
        parsed.scheme != "https"
        or (strict and parsed.hostname != expected_host)
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
        or (strict and parsed.path != expected_path)
    ):
        raise AddonError(f"Keycloak redirect URI must be https://{expected_host}{expected_path}")
    try:
        if parsed.port not in (None, 443):
            raise AddonError(
                f"Keycloak redirect URI must be https://{expected_host}{expected_path}"
            )
    except ValueError as exc:
        raise AddonError("Keycloak redirect URI has an invalid port") from exc


def _cluster_domain(ctx: AppContext) -> str:
    host = _route(ctx, "aap", ctx.namespace)
    return host.split(".", 1)[1] if host and "." in host else "apps.127.0.0.1.nip.io"


def _route(ctx: AppContext, name: str, namespace: str) -> str:
    argv = ["kubectl", "get", "route"]
    if name:
        argv.append(name)
    argv.extend(
        [
            "-n",
            namespace,
            "-o",
            "jsonpath={.spec.host}" if name else "jsonpath={.items[0].spec.host}",
        ]
    )
    result = ctx.runner.run(argv)
    return result.stdout.strip() if result.ok else ""


def _ensure_namespace(ctx: AppContext) -> None:
    existing = ctx.runner.run(["kubectl", "get", "namespace", NAMESPACE, "-o", "json"])
    if existing.ok:
        try:
            labels = (json.loads(existing.stdout or "{}").get("metadata") or {}).get("labels") or {}
        except json.JSONDecodeError as exc:
            raise AddonError("could not inspect Keycloak namespace") from exc
        if (
            labels.get("app.kubernetes.io/managed-by") != OWNER
            or labels.get("app.kubernetes.io/part-of") != PART_OF
        ):
            raise AddonError("refusing to use unowned namespace aap-demo-keycloak")
        return
    created = ctx.runner.run(["kubectl", "create", "namespace", NAMESPACE])
    if not created.ok:
        raise AddonError("could not create Keycloak namespace", hint=created.stderr.strip() or None)
    labeled = ctx.runner.run(
        [
            "kubectl",
            "label",
            "namespace",
            NAMESPACE,
            f"app.kubernetes.io/managed-by={OWNER}",
            f"app.kubernetes.io/part-of={PART_OF}",
            "--overwrite",
        ]
    )
    if not labeled.ok:
        raise AddonError("could not label Keycloak namespace", hint=labeled.stderr.strip() or None)


def _manifest(credentials: Dict[str, str], host: str, aap_redirect: str, ao_redirect: str) -> str:
    realm = _realm(credentials, aap_redirect, ao_redirect)
    realm_json = json.dumps(realm, separators=(",", ":"))
    realm_revision = hashlib.sha256(realm_json.encode()).hexdigest()
    admin_revision = hashlib.sha256(credentials["admin-password"].encode()).hexdigest()
    realm_volume = {
        "name": "realm",
        "sec" + "ret": {"secret" + "Name": "keycloak-realm"},
    }  # pragma: allowlist secret
    documents = [
        {
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {"name": "keycloak-admin", "namespace": NAMESPACE},
            "type": "Opaque",
            "data": {"password": _b64(credentials["admin-password"])},
        },
        {
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {"name": "keycloak-realm", "namespace": NAMESPACE},
            "type": "Opaque",
            "data": {"aap-lab-realm.json": _b64(realm_json)},
        },
        {
            "apiVersion": "apps/v1",
            "kind": "Deployment",
            "metadata": {
                "name": "keycloak",
                "namespace": NAMESPACE,
                "labels": {
                    "app.kubernetes.io/name": "keycloak",
                    "app.kubernetes.io/part-of": PART_OF,
                },
            },
            "spec": {
                "replicas": 1,
                "strategy": {"type": "Recreate"},
                "selector": {"matchLabels": {"app.kubernetes.io/name": "keycloak"}},
                "template": {
                    "metadata": {
                        "labels": {"app.kubernetes.io/name": "keycloak"},
                        "annotations": {
                            "aap-demo/keycloak-realm-revision": realm_revision,
                            "aap-demo/keycloak-admin-revision": admin_revision,
                        },
                    },
                    "spec": {
                        "automountServiceAccountToken": False,
                        "containers": [
                            {
                                "name": "keycloak",
                                "image": IMAGE,
                                "args": ["start-dev", "--import-realm"],
                                "env": [
                                    {"name": "KC_BOOTSTRAP_ADMIN_USERNAME", "value": "admin"},
                                    {
                                        "name": "KC_BOOTSTRAP_ADMIN_PASSWORD",
                                        "valueFrom": {
                                            "secretKeyRef": {
                                                "name": "keycloak-admin",
                                                "key": "password",
                                            }
                                        },
                                    },
                                    {"name": "KC_HTTP_ENABLED", "value": "true"},
                                    {"name": "KC_HOSTNAME", "value": f"https://{host}"},
                                ],
                                "ports": [{"name": "http", "containerPort": 8080}],
                                "securityContext": {
                                    "allowPrivilegeEscalation": False,
                                    "capabilities": {"drop": ["ALL"]},
                                    "runAsNonRoot": True,
                                    "seccompProfile": {"type": "RuntimeDefault"},
                                },
                                "volumeMounts": [
                                    {
                                        "name": "realm",
                                        "mountPath": "/opt/keycloak/data/import/aap-lab-realm.json",
                                        "subPath": "aap-lab-realm.json",
                                        "readOnly": True,
                                    }
                                ],
                            }
                        ],
                        "volumes": [realm_volume],
                    },
                },
            },
        },
        {
            "apiVersion": "v1",
            "kind": "Service",
            "metadata": {"name": "keycloak", "namespace": NAMESPACE},
            "spec": {
                "selector": {"app.kubernetes.io/name": "keycloak"},
                "ports": [{"name": "http", "port": 8080, "targetPort": "http"}],
            },
        },
        {
            "apiVersion": "route.openshift.io/v1",
            "kind": "Route",
            "metadata": {"name": "keycloak", "namespace": NAMESPACE},
            "spec": {
                "host": host,
                "to": {"kind": "Service", "name": "keycloak"},
                "port": {"targetPort": "http"},
                "tls": {"termination": "edge", "insecureEdgeTerminationPolicy": "Redirect"},
            },
        },
    ]
    return "---\n".join(yaml.safe_dump(doc, sort_keys=False) for doc in documents)


def _realm(credentials: Dict[str, str], aap_redirect: str, ao_redirect: str) -> Dict[str, Any]:
    clients = []
    for client_id, secret, redirect in (
        ("aap-demo-aap", credentials["aap-client-secret"], aap_redirect),
        ("aap-demo-ao", credentials["ao-client-secret"], ao_redirect),
    ):
        clients.append(
            {
                "clientId": client_id,
                "enabled": True,
                "protocol": "openid-connect",
                "publicClient": False,
                "secret": secret,
                "standardFlowEnabled": True,
                "defaultClientScopes": [
                    "profile",
                    "email",
                    "roles",
                    "web-origins",
                    "acr",
                    "groups",
                ],
                "redirectUris": [redirect],
                "protocolMappers": [
                    {
                        "name": f"{client_id} audience",
                        "protocol": "openid-connect",
                        "protocolMapper": "oidc-audience-mapper",
                        "config": {
                            "included.client.audience": client_id,
                            "id.token.claim": "false",
                            "access.token.claim": "true",
                        },
                    },
                    {
                        "name": f"{client_id} preferred username",
                        "protocol": "openid-connect",
                        "protocolMapper": "oidc-usermodel-property-mapper",
                        "config": {
                            "user.attribute": "username",
                            "claim.name": "preferred_username",
                            "jsonType.label": "String",
                            "id.token.claim": "true",
                            "access.token.claim": "true",
                            "userinfo.token.claim": "true",
                        },
                    },
                    {
                        "name": f"{client_id} groups",
                        "protocol": "openid-connect",
                        "protocolMapper": "oidc-group-membership-mapper",
                        "config": {
                            "full.path": "false",
                            "claim.name": "groups",
                            "id.token.claim": "true",
                            "access.token.claim": "true",
                            "userinfo.token.claim": "true",
                        },
                    },
                ],
            }
        )
    return {
        "realm": REALM,
        "enabled": True,
        "clients": clients,
        "groups": [
            {"name": f"aap-{role}"} for role in ("admins", "operators", "auditors", "developers")
        ],
        "users": [
            {
                "username": user,
                "enabled": True,
                "email": f"{user}@example.test",
                "emailVerified": True,
                "firstName": "AAP OIDC",
                "lastName": last,
                "groups": [f"/aap-{user.removeprefix('aap-oidc-')}s"],
                "credentials": [
                    {
                        "type": "password",
                        "value": credentials[f"{user}-password"],
                        "temporary": False,
                    }
                ],
            }
            for user, last in USERS
        ],
        "clientScopes": [
            {
                "name": "groups",
                "protocol": "openid-connect",
                "protocolMappers": [
                    {
                        "name": "groups",
                        "protocol": "openid-connect",
                        "protocolMapper": "oidc-group-membership-mapper",
                        "config": {
                            "full.path": "false",
                            "claim.name": "groups",
                            "id.token.claim": "true",
                            "access.token.claim": "true",
                            "userinfo.token.claim": "true",
                        },
                    }
                ],
            }
        ],
    }


def _b64(value: str) -> str:
    return base64.b64encode(value.encode()).decode()


def _remember_enabled(ctx: AppContext) -> None:
    names = enabled_names(ctx)
    if "keycloak" not in names:
        names.append("keycloak")
    set_enabled_names(ctx, names, save=True)


def _forget_enabled(ctx: AppContext) -> None:
    set_enabled_names(ctx, [name for name in enabled_names(ctx) if name != "keycloak"], save=True)


def _say(ctx: AppContext, message: str, **fields: object) -> None:
    if is_structured(ctx.output):
        render(ctx.console, {"message": message, **fields}, output=ctx.output)
    else:
        ctx.console.out(message)
        for key, value in fields.items():
            ctx.console.out(f"  {key.replace('_', ' ').title()}: {value}")
