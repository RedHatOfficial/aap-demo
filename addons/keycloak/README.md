# Keycloak OIDC addon

Local OIDC provider for testing AAP 2.6 and Automation Orchestrator authentication.

```bash
aap-demo enable keycloak
aap-demo disable keycloak
aap-demo keycloak configure --target all
aap-demo keycloak configure --target all --apply
aap-demo keycloak configure --target all --map-groups --apply
```

Addon creates namespace `aap-demo-keycloak`, Route `keycloak.<cluster-domain>`, realm
`aap-lab`, groups `aap-admins`, `aap-operators`, `aap-auditors`, and `aap-developers`,
and separate confidential clients:

| Client | Target | Secret file |
|---|---|---|
| `aap-demo-aap` | AAP 2.6 Gateway | `~/.aap-demo/keycloak/aap-client-secret` |
| `aap-demo-ao` | Automation Orchestrator | `~/.aap-demo/keycloak/ao-client-secret` |

Generated admin and user passwords stay under `~/.aap-demo/keycloak` with mode `0600`.
They are never printed by the addon.

Users and groups:

| User | Group | Password file |
|---|---|---|
| `aap-oidc-admin` | `aap-admins` | `aap-user-password` |
| `aap-oidc-operator` | `aap-operators` | `ao-user-password` |
| `aap-oidc-auditor` | `aap-auditors` | `aap-auditor-password` |
| `aap-oidc-developer` | `aap-developers` | `aap-developer-password` |

Map these groups to AAP organizations, teams, and roles, and to AO roles when
configuring each OIDC client. Keycloak emits membership in the `groups` claim.

## Configure consumers

Use the issuer printed by `aap-demo enable keycloak`:

```text
https://keycloak.<cluster-domain>/realms/aap-lab
```

AAP 2.6: open `Access Management → Authentication Methods`, create a Keycloak
authentication provider, and use the realm token endpoint, provider URL, client ID
`aap-demo-aap`, and its secret file. Set the callback URL shown by the AAP Gateway
configuration. Red Hat documents the AAP 2.6 Keycloak fields in the
[AAP authentication guide](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.6/html-single/access_management_and_authentication/index).

AO: create an OIDC identity provider using the realm issuer, client ID
`aap-demo-ao`, and its secret file. Set the callback URL shown by the AO instance.
For local MicroShift, AO may require its private-network OIDC allowance; keep this
setting limited to the local lab.

The generated clients use exact callback URLs. Override the defaults when AAP or AO
provides its generated callback URL:

```bash
KEYCLOAK_AAP_REDIRECT_URI=https://aap.example.test/generated-callback \\
KEYCLOAK_AO_REDIRECT_URI=https://ao.example.test/generated-callback \\
aap-demo enable keycloak
```

The addon marks its namespace with
`app.kubernetes.io/managed-by=aap-demo-keycloak` and refuses to deploy to or delete
an unowned namespace.

`keycloak configure` discovers local routes and configures both consumers through
their APIs. It is dry-run by default; `--apply` is required for mutation. Use
`--target aap` or `--target ao` to configure one consumer. AAP Gateway callback
URL is derived from the authenticator slug and applied to the Keycloak AAP client
redirect URI. Set `KEYCLOAK_AAP_REDIRECT_URI` when enabling Keycloak or running
configure only when you need to override that generated URL.
AO group claim extraction is configured as `groups[*]`; lab mode allows all
authenticated users.
AO-to-AAP job execution must continue using a separate AAP API key/PAT.

Configuration verifies TLS by default. Set `KEYCLOAK_CA_FILE` if the ingress CA
is not at the default aap-demo path. When applying AAP configuration with a CA
file available, the script merges it into the AAP `bundle-ca-secret`, links that
secret through `spec.bundle_cacert_secret`, and waits for the Gateway rollout.
This makes Gateway trust the local Keycloak route while keeping certificate
verification enabled. The AAP CA bundle is shared across AAP services, so an
existing bundle is preserved and extended.

On CRC/MicroShift, `KEYCLOAK_INSECURE_TLS=true` remains available as an explicit
local-lab fallback to disable verification for the configure script and AAP's
Keycloak token exchange through `ADDITIONAL_UNVERIFIED_ARGS.VERIFY_SSL`. It is
not needed after Gateway trusts the ingress CA.
The AO redirect URI used by `enable keycloak` is retained under
`~/.aap-demo/keycloak/` so a later configure run continues to match the registered
Keycloak client.

`--map-groups` creates matching AO groups and explicit mappings, then creates
local AAP authenticator maps: `aap-admins` becomes AAP superuser,
`aap-auditors` becomes Platform Auditor, and operators/developers receive
Organization Admin/Member in `AAP Demo`. This role profile is for local testing.

## Cleanup

`aap-demo disable keycloak` deletes only the Kubernetes namespace. Local credentials
remain so a later reinstall can reproduce the same realm data. Remove that directory
only when its test credentials are no longer needed.

Realm import runs on first startup. Re-enabling the addon also reconciles the
generated client claims and user profile fields in an existing realm; route and
consumer configuration is applied by `keycloak configure --apply`.
