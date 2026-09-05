# OpenShift Dev Spaces Addon (`devspaces`)

Deploys **Red Hat OpenShift Dev Spaces** on aap-demo MicroShift clusters, providing browser-based
VS Code workspaces for AAP/Ansible development.

- **Command:** `aap-demo enable devspaces`
- **Namespace:** `openshift-devspaces`
- **Requires:** `aap-demo deploy` (OLM must be installed; `aap-demo deploy` does this automatically)
- **Requires:** `operator-sdk` installed locally
- **Storage:** per-user workspace PVCs use `topolvm-provisioner` (RWO) — already provisioned by
  `aap-demo create`, no extra storage setup needed

`deploy.sh` installs the `devworkspace-operator` (a DevSpaces dependency) followed by the
`devspaces-operator`, then applies the [`checluster.yaml`](checluster.yaml) CheCluster instance.

## Prerequisites

Dev Spaces is heavier than the other addons. Suggested minimum CRC sizing:

```bash
CRC_CPUS=8 CRC_MEMORY=18432 aap-demo create
```

(8 vCPU / 18GB — adjust upward if you plan to run several workspaces at once.)

Or use the `--dev-spaces` shortcut, which sizes memory to 18GB automatically and installs OLM +
enables the addon in one step (no `aap-demo deploy`/AAP install required — Dev Spaces doesn't
need AAP):

```bash
aap-demo create --dev-spaces
```

## Quick start

```bash
aap-demo create                # with CRC_CPUS/CRC_MEMORY above if not already running
aap-demo deploy                # installs OLM (required by devspaces)
aap-demo enable devspaces       # installs Dev Spaces
aap-demo status                 # shows devspaces addon state
```

Or in one step: `aap-demo create --dev-spaces` (see above).

Remove:

```bash
aap-demo disable devspaces
```

This deletes the `CheCluster`, the `devspaces` and `devworkspace-operator` subscriptions/CSVs,
and the `openshift-devspaces` namespace.

## GitHub OAuth (optional)

Dev Spaces can authenticate directly against GitHub so workspaces created from GitHub repos don't
prompt for credentials. Follow the [DevSpaces OAuth for Git Providers guide][oauth-doc] to
register a GitHub OAuth App, then provide the client ID/secret to `aap-demo` via either:

**Option 1 — creds file** (`~/.aap-demo/devspaces-github-oauth.env`):

```bash
mkdir -p ~/.aap-demo
cat > ~/.aap-demo/devspaces-github-oauth.env <<'EOF'
GITHUB_OAUTH_CLIENT_ID=your-client-id
GITHUB_OAUTH_CLIENT_SECRET=your-client-secret
EOF
```

**Option 2 — environment variables** at enable time:

```bash
GITHUB_OAUTH_CLIENT_ID=your-client-id GITHUB_OAUTH_CLIENT_SECRET=your-client-secret \
  aap-demo enable devspaces
```

If credentials are present (either way), `deploy.sh` automatically creates the required
`devspaces-github-oauth-config` Secret in `openshift-devspaces`, labeled and annotated per the
Che OAuth SCM configuration convention. If not provided, Dev Spaces still deploys — GitHub OAuth
is optional and can be added later by re-running `aap-demo enable devspaces` after setting up
credentials.

## Troubleshooting

```bash
kubectl get checluster devspaces -n openshift-devspaces
kubectl get pods -n openshift-devspaces
kubectl get csv -n openshift-devspaces
```

[oauth-doc]: https://docs.redhat.com/en/documentation/red_hat_openshift_dev_spaces/3.27/html/administration_guide/assembly_configuring-oauth-for-git-providers_administration_guide#proc_setting-up-the-github-oauth-app_administration_guide
