# ADR-022: APME Pre-Built Portal Hub Deployment

**Status:** Accepted

**Date:** 2026-08-14

**Authors:** Chad Ferman

## Context

The `apme-eap` addon deploys the Ansible Portal (RHDH) with APME plugins on OpenShift Local
(MicroShift/CRC). Early implementations pushed OCI plugin archives to an in-cluster registry at
deploy time and relied on runtime plugin injection — a flow that worked but added registry,
`skopeo`, and `install-dynamic-plugins` dependencies to every deploy.

A **pre-built portal hub image** (`portal-hub-eap`) was introduced to bake ansible-portal plugin
packages into the container at image build time (see
[ansible-rhdh-plugins `feature/pre-baked-portal-hub`](https://github.com/ansible/ansible-rhdh-plugins)).
The aap-demo addon was refactored to use this image by default.

During integration (August 2026), several failures appeared that did **not** occur on the runtime
OCI path:

| Symptom | Page / area |
| ------- | ----------- |
| GitHub sign-in instead of RHAAP OAuth | Portal login |
| Missing routes, 404 on `/` | Self Service landing |
| `install-dynamic-plugins` CrashLoopBackOff | Init container |
| `quay-dynamic` install failure | Init container |
| `Cannot read properties of null (reading 'scrollWidth')` | `/self-service/repositories/catalog` |
| `NotImplementedError: apiRef{plugin.apme.api}` | Git Repositories / Self Service |

These were caused by misunderstanding how pre-built hub images differ from runtime OCI injection,
not by missing plugins in the image itself.

### Pre-built hub vs runtime OCI injection

Both paths must end with the same **runtime state**: plugins installed under a writable volume and
a merged `app-config.dynamic-plugins.yaml` that wires routes, sign-in, scaffolder fields, and API
factories.

| Aspect | Runtime OCI injection | Pre-built hub (correct) |
| ------ | --------------------- | ------------------------ |
| Plugin source | OCI archives in cluster registry | `./dynamic-plugins/dist/ansible-portal/<plugin>` baked in image |
| Init step | `install-dynamic-plugins.sh` | **Same** — `install-dynamic-plugins.sh` |
| `pluginConfig` merge | From Helm `dynamic-plugins.yaml` | **Same** — from Helm `dynamic-plugins.yaml` |
| Served bundles | `dynamic-plugins-root/*/dist-scalprum/static/` | **Same** |
| Registry / skopeo at deploy | Required | **Not required** |

**Anti-pattern:** Copying `/pre-installed/dynamic-plugins-root/` into the volume and skipping
`install-dynamic-plugins`, or running copy **before** install. The install script's cleanup phase
removes plugins that were not declared in `dynamic-plugins.yaml`, which silently deletes APME
packages and reverts sign-in to GitHub.

### Two plugin trees inside the hub image

```text
/opt/app-root/src/
├── dynamic-plugins/dist/ansible-portal/     # Source packages (install reads these)
│   ├── ansible-plugin-backstage-apme
│   ├── ansible-plugin-backstage-self-service
│   └── …
└── dynamic-plugins-root/                    # Writable volume (scalprum serves from here)
    ├── app-config.dynamic-plugins.yaml      # Merged at init
    └── <plugin>-dynamic-*/dist-scalprum/    # Bundles served to the browser
```

Optional `/pre-installed/dynamic-plugins-root/` may exist from image build CI, but **deploy must
not treat it as the source of truth**. Init always runs `install-dynamic-plugins` from baked local
paths.

## Decision

Adopt the following deployment contract for `apme-eap` when `portal_hub_image` is set (default).

### 1. Init container runs `install-dynamic-plugins` only

**File:** `playbooks/roles/apme_helm_values/tasks/prebuilt_hub.yml`

Init command:

1. `cd /opt/app-root/src`
2. `./install-dynamic-plugins.sh /opt/app-root/src/dynamic-plugins-root`
3. Optional `scrollWidth` patch on `dist-scalprum` bundles only (see §5)
4. Copy `/pre-installed/extensions/` → `/extensions/` if present

**Do not** copy `/pre-installed/dynamic-plugins-root/` before install.

Init container must mount the same `dynamic-plugins-root` volume as the main container
(`/opt/app-root/src/dynamic-plugins-root` and `/dynamic-plugins-root`).

### 2. Point dynamic-plugins packages at baked local paths

Replace OCI `package:` URLs for ansible-portal plugins with:

```yaml
package: ./dynamic-plugins/dist/ansible-portal/<plugin-name>
```

Plugins affected:

- `ansible-plugin-scaffolder-backend-module-backstage-rhaap`
- `ansible-backstage-plugin-catalog-backend-module-rhaap`
- `ansible-plugin-backstage-self-service`
- `ansible-backstage-plugin-auth-backend-module-rhaap-provider`
- `ansible-plugin-backstage-apme`
- `ansible-backstage-plugin-catalog-backend-module-apme`

### 3. Drop `dynamic-plugins.default.yaml` include

Set `includes: []` in the dynamic-plugins ConfigMap for pre-built hub mode.

The default catalog index pulls plugins (e.g. `quay-dynamic`) that are **not** in the custom hub
image, causing `install-dynamic-plugins` to fail on ARM and other constrained environments.

### 4. Register both APME API factories

`ansible.plugin-backstage-apme` exports **two** frontend API factories:

| `importName` | Binds | Purpose |
| ------------ | ----- | ------- |
| `apmeApiFactory` | `plugin.apme.api` | Core APME client (calls `apme-gateway` / catalog backend) |
| `gitRepositoriesExtensionsApiFactory` | Git Repos UI extensions | Catalog table columns, actions, etc. |

**Both** must appear under `dynamicPlugins.frontend.ansible.plugin-backstage-apme.apiFactories` in:

- Helm `dynamic-plugins.yaml` (`pluginConfig` on the apme package entry)
- Helm `app-config` ConfigMap (`dynamicPlugins.frontend` section)
- Hub image `plugin-config-overrides.yaml` (for future image bakes)

Registering only `gitRepositoriesExtensionsApiFactory` produces:

```text
NotImplementedError: No implementation available for apiRef{plugin.apme.api}
```

when Git Repositories pages call `useApi(apmeApiRef)`.

### 5. Patch `scrollWidth` in served bundles only

`@material-table/core` with React 18 can throw on `/self-service/repositories/catalog`:

```text
Cannot read properties of null (reading 'scrollWidth')
```

**Fix at init** (after install): patch only files under `dynamic-plugins-root/*/dist-scalprum/`,
replacing unsafe `tableContainerDiv.current.scrollWidth` access with optional chaining.

**Do not** patch the full `dynamic-plugins/dist` tree at image build time — CI can traverse broken
`node_modules` symlinks and fail (learned from ansible-rhdh-plugins PR #6, later reverted).

### 6. RHAAP OAuth-only sign-in for aap-demo

**File:** `playbooks/roles/apme_helm_values/tasks/aap_auth_only.yml`

For demo clusters without GitHub/GitLab OAuth apps configured:

- Disable GitHub and GitLab **auth frontend** plugins
- Remove GitHub/GitLab OAuth env vars from the portal deployment
- Keep `signInPage: rhaap` and RHAAP `providerSettings` on self-service plugin config

SCM tokens may remain for catalog integration when `configure_github_secrets: true`; default is
`false`.

### 7. Remove deploy-time OCI plugin push

Delete the `apme_oci_push` role and `resolve_plugin_pack.yml` task. Deploy no longer requires:

- In-cluster registry addon (for plugins)
- `skopeo` copy to cluster
- Plugin pack SHA push on every deploy

Plugin versions are fixed at **image build** time; deploy only wires config and runs install.

### 8. Split Helm value tasks by concern

Refactor `apme_helm_values` into focused task files:

| Task file | Responsibility |
| --------- | -------------- |
| `prebuilt_hub.yml` | Hub image, local plugin paths, init command |
| `aap_auth_only.yml` | RHAAP-only sign-in |
| `pah_integration.yml` | Automation Hub catalog sync |
| `portal_app_config_substitution.yml` | AAP token, routes, support URL placeholders |

### 9. Bake `pluginConfig` in hub image builds (upstream)

In ansible-rhdh-plugins, `containers/portal-hub/plugin-config-overrides.yaml` merges routes,
sign-in, scaffolder fields, and API factories into `portal-dynamic-plugins.yaml` at **image build**
time. This reduces reliance on Helm duplicating the same `dynamicPlugins.frontend` blocks.

Helm `app-config` and `dynamic-plugins` ConfigMaps remain the deploy-time source for
cluster-specific values (`ansible.apme.baseUrl`, AAP host, tokens).

## Incident log (do not repeat)

| # | Mistake | Symptom | Correct approach |
| - | ------- | ------- | ---------------- |
| 1 | Copy `/pre-installed/dynamic-plugins-root/` then run install | APME plugins removed at cleanup; GitHub sign-in returns | Install only from `./dynamic-plugins/dist/ansible-portal/` |
| 2 | Copy pre-installed tree, skip install | Routes/sign-in missing; minimal `app-config.dynamic-plugins.yaml` | Always run `install-dynamic-plugins` |
| 3 | Keep `includes: dynamic-plugins.default.yaml` | Init fails on `quay-dynamic` (not in custom image) | `includes: []` for pre-built hub |
| 4 | Init volume not mounted at `/opt/app-root/src/dynamic-plugins-root` | Init CrashLoopBackOff | Mount same PVC in init and main containers |
| 5 | Patch `scrollWidth` in full `dist/` at image build | CI fails on symlinks; unnecessary | Patch `dist-scalprum` only at init |
| 6 | Only `gitRepositoriesExtensionsApiFactory` in config | `NotImplementedError: apiRef{plugin.apme.api}` | Add `apmeApiFactory` **and** `gitRepositoriesExtensionsApiFactory` |
| 7 | Duplicate `dynamicPlugins.frontend` in Helm without install | Config present but plugins not in volume | Config + install are both required |
| 8 | `helm upgrade` blocked by field manager conflict on init command | Stale pod, failed release | `helm template \| kubectl apply --server-side --force-conflicts` if needed |

## Verification checklist

After deploy:

```bash
# Pod healthy
oc -n apme get pods -l app.kubernetes.io/instance=redhat-rhaap-portal

# Expected plugins in volume
oc -n apme exec deploy/redhat-rhaap-portal -c backstage-backend -- \
  ls /opt/app-root/src/dynamic-plugins-root/

# Both API factories registered
oc -n apme exec deploy/redhat-rhaap-portal -c backstage-backend -- \
  grep -A5 ansible.plugin-backstage-apme \
  /opt/app-root/src/dynamic-plugins-root/app-config.dynamic-plugins.yaml

# scrollWidth patch present in served bundle
oc -n apme exec deploy/redhat-rhaap-portal -c backstage-backend -- \
  grep -l 'tableContainerDiv.current?' \
  /opt/app-root/src/dynamic-plugins-root/ansible-plugin-backstage-self-service-dynamic-*/dist-scalprum/static/*.js
```

Browser: hard refresh (Cmd+Shift+R) after rollout — cached scalprum chunks mask fixes.

Functional smoke test:

1. Sign in via **RHAAP** (not GitHub)
2. Open **Self Service** landing (`/`)
3. Open **Git Repositories** → **Catalog** (`/self-service/repositories/catalog`)

## Alternatives considered

### Copy-init only (no install)

**Rejected.** Skips `pluginConfig` merge; produced empty or stale `app-config.dynamic-plugins.yaml`.
Required duplicating large `dynamicPlugins.frontend` blocks in Helm app-config as a fragile
workaround.

### Material-table patch at image build time

**Rejected** (ansible-rhdh-plugins). Patch walked entire `dynamic-plugins/dist` and hit broken
symlinks in CI. Init-time patch on `dist-scalprum` only is sufficient.

### Runtime OCI injection (previous default)

**Superseded** for aap-demo default. Still valid for environments that need deploy-time plugin
version changes without rebuilding the hub image. Requires registry addon and `apme_oci_push`
machinery (removed from this addon).

### Register APME API via self-service plugin

**Rejected.** `plugin.apme.api` is owned by `ansible.plugin-backstage-apme`; self-service routes
import APME components but do not register APME API factories. Factories must be configured on the
apme plugin entry.

## Consequences

### Positive

- Deploy no longer depends on in-cluster registry or `skopeo` for plugins
- Faster, more reproducible deploys (plugin versions pinned in hub image)
- Clear init contract documented; fewer silent plugin deletions
- Git Repositories and catalog pages work with RHAAP OAuth on CRC/MicroShift

### Negative

- Plugin version bumps require rebuilding and publishing `portal-hub-eap`
- Init still runs `install-dynamic-plugins` on every pod start (adds ~30–60s to rollout)
- `scrollWidth` patch is a deploy-time workaround until upstream fixes `@material-table/core`
- Hub image and aap-demo Helm values must stay aligned on `pluginConfig` (especially API factories)

### Neutral

- APME gateway Helm release and PAH integration unchanged in scope
- GitHub SCM integration remains optional via `configure_github_secrets`

## References

- [ADR-019](019-apme-playbook-addon.md) — APME playbook addon architecture
- [ADR-013](013-in-cluster-registry.md) — In-cluster registry (no longer required for plugins)
- [addons/apme-eap/README.md](../../addons/apme-eap/README.md) — Operator docs and troubleshooting
- [addons/apme-eap/playbooks/roles/apme_helm_values/tasks/prebuilt_hub.yml](../../addons/apme-eap/playbooks/roles/apme_helm_values/tasks/prebuilt_hub.yml)
- ansible-rhdh-plugins: `containers/portal-hub/plugin-config-overrides.yaml`
- ansible-rhdh-plugins: `docs/guides/eap-portal-hub-image.md`
