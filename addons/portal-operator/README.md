# Portal Operator addon

Deploys the AAP 2.7 Automation Portal Operator and an `AutomationPortal`
custom resource. This is a separate deployment path from the existing Helm
`portal` addon and uses the namespace `automation-portal` by default.

The addon follows the Red Hat AAP 2.7 operator configuration reference:

- `secrets-rhaap-portal` contains the AAP host, OAuth client credentials, and
  a write-scoped catalog token.
- `secrets-scm` optionally contains GitHub App or PAT credentials. The addon
  reuses `GITHUB_*` environment variables and the existing
  `~/.aap-demo/apme-eap-github-creds.yml` credential names.
- AAP remains the portal’s OIDC/OAuth provider through the AAP authorization
  code application and `/api/auth/rhaap/handler/frame` callback.
- `portal-registry-auth` is created from the existing AAP pull secret when it
  is available.
- On clusters where the Red Hat catalog is namespace-scoped instead of being
  in `openshift-marketplace`, the addon copies the catalog into each OLM
  consumer namespace so the portal and RHDH operators can resolve it.
- The operator-based addon currently supports AMD64 clusters only because its
  RHDH Operator dependency is AMD64-only. ARM64 users should use the existing
  Helm-based `portal` addon until ARM64 operator support is available.

## Usage

```bash
aap-demo enable portal-operator
aap-demo status
aap-demo disable portal-operator
```

GitHub is disabled by default. To enable a GitHub App-backed SCM and auth
provider, set `PORTAL_GITHUB_ENABLED=true` and provide the existing credentials:

```bash
export PORTAL_GITHUB_ENABLED=true
export PORTAL_GITHUB_AUTH_TYPE=app
export GITHUB_APP_ID=12345
export GITHUB_APP_CLIENT_ID=Iv1.example
export GITHUB_APP_CLIENT_SECRET=...
export GITHUB_APP_PRIVATE_KEY_PATH="$HOME/.aap-demo/github-app.pem"
PORTAL_OPERATOR_GRANT_SCC=true aap-demo enable portal-operator
```

Inspect the operator-managed resource directly when troubleshooting:

```bash
kubectl get automationportal portal -n automation-portal
kubectl get automationportal portal -n automation-portal -o yaml
```

For a PAT-based integration use `PORTAL_GITHUB_AUTH_TYPE=token` and
`GITHUB_TOKEN`. The operator is a Red Hat Technology Preview feature in AAP
2.7; it is not recommended for production service-level workloads.

`PORTAL_OPERATOR_GRANT_SCC=true` is only needed on local or custom OLM setups
where catalog and bundle pods run with a fixed UID that the restricted SCC
does not allow. It grants the privileged SCC only to the `redhat-operators`
and `default` service accounts in the relevant consumer namespaces.
