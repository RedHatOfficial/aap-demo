# Keycloak OIDC addon

Local OIDC provider for testing AAP 2.6 and Automation Orchestrator authentication.

```bash
aap-demo enable keycloak
aap-demo disable keycloak
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

This addon does not change AAP or AO authentication automatically. AO-to-AAP job
execution must continue using a separate AAP API key/PAT.

## Cleanup

`aap-demo disable keycloak` deletes only the Kubernetes namespace. Local credentials
remain so a later reinstall can reproduce the same realm data. Remove that directory
only when its test credentials are no longer needed.

Realm import runs on first startup. To apply changed route or client data, disable
then enable the addon so Keycloak starts with a fresh local realm.
