# ADR-018: APME Addon Architecture

**Status:** Accepted
**Date:** 2026-07-17
**Author:** Chad Ferman

## Context

Ansible Portal Managed Engine (APME) is a gateway service that connects Red Hat
Developer Hub (RHDH) with Ansible Automation Platform, enabling self-service
automation workflows via the RHDH UI. aap-demo needed an addon to deploy APME
alongside an existing AAP instance for developer testing.

**Deployment constraints:**

- x86 OpenShift: official APME Helm chart exists (`apme/apme`)
- ARM/macOS (CRC/MicroShift): APME Helm chart is x86-only; no multi-arch image
- RHDH plugins are built from CI and not yet available via `registry.redhat.io`
  on ARM (no public multi-arch image at time of implementation)
- Plugin artifacts are available as OCI tarballs from GitHub Actions CI runs

## Decision

Add `apme` addon following the established addon architecture. Use a dual-path
deployment strategy keyed on cluster CPU architecture, mirroring the pattern
established by the `portal` addon (ADR-004).

### Architecture Decision 1: Dual-Path Deployment

**x86:** Deploy the official APME Helm chart from `apme/apme`. Provides the full
APME gateway component.

**ARM:** Deploy community RHDH via `openshift-helm-charts/redhat-rhaap-portal`
with APME plugins loaded from CI-built OCI artifacts. No APME gateway/engine
on ARM — UI plugins only.

Architecture detection uses `kubectl get nodes` (cluster arch, not laptop CPU),
with `APME_ARCH` env var override.

### Architecture Decision 2: In-Cluster Plugin Registry for ARM

ARM has no `registry.redhat.io` APME plugin image. CI builds produce OCI
tarballs as GitHub Actions artifacts.

**Solution:** In-cluster HTTP OCI registry (plain Docker registry v2) deployed
as a `Deployment + Service` in the `apme` namespace. Plugins loaded via:

1. `gh api` to fetch download URL for artifact `CI_ARTIFACT_ID`
2. `curl` download of GitHub Actions artifact (zip-wrapped OCI tar.gz)
3. `kubectl port-forward` to in-cluster registry
4. `skopeo copy` to push OCI image over port-forward
5. `kubectl patch` of `dynamic-plugins` ConfigMap to reference in-cluster registry

The `install-dynamic-plugins` init container then pulls from
`plugin-registry.apme.svc:5000` at pod startup.

Override with `CI_ARTIFACT_ID=<id>` to pick up newer CI builds without
changing script defaults.

### Architecture Decision 3: PVC Label Caching to Avoid Plugin Reinstall

The `install-dynamic-plugins` init container runs on every RHDH pod restart,
reinstalling all plugins into the `dynamic-plugins` PVC. Without intervention,
a config change (new OAuth token, updated AAP URL) triggering a rollout restart
also forces a full plugin reinstall — adding 3–10 minutes per re-deploy.

**Solution:** Label the `dynamic-plugins` PVC with `apme.io/artifact-id` after
a successful deploy. On subsequent runs, `reset_dynamic_plugins_pvc` checks the
label against `CI_ARTIFACT_ID`:

- **Match:** Skip PVC deletion. Init container finds existing plugins on the
  volume and skips reinstall (RHDH 1.10+ checks plugin hashes).
- **Mismatch or no label:** Delete PVC, force clean install, relabel on success.

Restart of the RHDH Deployment still runs on every deploy to apply ConfigMap and
Secret changes. Only the init container plugin reinstall is skipped when the
artifact ID is unchanged.

### Architecture Decision 4: OAuth Two-Phase Configuration

Identical pattern to portal addon (ADR-004). APME requires an OAuth application
in AAP with a redirect URI pointing to the RHDH route, which is unknown
pre-deployment.

**Phase 1 (pre-deploy):** Create OAuth app with placeholder redirect URI.
Credentials stored in `apme-rhdh-secrets-rhaap-portal` secret.

**Phase 2 (post-deploy):** Fetch RHDH route, `PATCH` OAuth app redirect URI.

Existing OAuth apps are reused across re-deploys. Client secret is cached in
`~/.aap-demo/apme/` to survive re-runs (AAP only returns it on creation).

### Architecture Decision 5: Namespace and Credential Isolation

APME deploys to its own `apme` namespace (separate from AAP's `aap-operator`
and portal's `redhat-rhaap-portal`). This allows:

- Independent lifecycle (enable/disable without touching portal)
- Separate SCCs (anyuid granted to `system:serviceaccounts:apme`)
- Clean `kubectl delete namespace apme` on disable

AAP credentials (route, admin password) are read from the existing AAP
namespace at deploy time rather than stored separately.

## Implementation

### Key Files

```
addons/apme/
└── deploy.sh              # ~1100 lines: full deploy, delete, and ARM plugin pipeline

aap-demo.sh               # Status display (apme gateway URL) + AVAILABLE_ADDONS
```

### ARM Deploy Flow

```
check_prerequisites        # kubectl, helm 3.10+, skopeo, gh CLI + auth
setup_apme_namespace       # namespace, SCCs, pull secret
get_aap_credentials        # route + admin password from aap-operator
select_organization        # create or reuse default org
create_oauth_app           # POST /api/gateway/v1/applications/
enable_oauth_tokens        # PATCH /api/gateway/v1/settings/
create_api_token           # POST /api/gateway/v1/tokens/
create_aap_secrets         # OpenShift secret with AAP creds
create_helm_values         # Generate values.yaml from template
install_helm_chart         # helm upgrade --install (community RHDH)
download_ci_plugins        # gh api + curl; cached by CI_ARTIFACT_ID
deploy_plugin_registry     # docker registry v2 Deployment in apme ns
push_plugins_to_registry   # port-forward + skopeo copy
create_plugin_registry_secret  # registries.conf for insecure HTTP registry
patch_plugin_configmap     # swap registry.redhat.io refs → in-cluster registry
reset_dynamic_plugins_pvc  # skip if PVC labeled with current CI_ARTIFACT_ID
restart_rhdh_deployment    # kubectl rollout restart
wait_for_apme              # kubectl rollout status --timeout=600s
label_dynamic_plugins_pvc  # apme.io/artifact-id=<CI_ARTIFACT_ID>
update_oauth_redirect      # PATCH OAuth app with real RHDH route
display_success            # URLs, next steps
```

### PVC Cache Mechanism

```bash
# reset_dynamic_plugins_pvc: skip delete if labeled
kubectl get pvc -n apme \
  --no-headers -o custom-columns=":metadata.name" \
  -l "apme.io/artifact-id=${CI_ARTIFACT_ID}" | grep dynamic-plugins

# label_dynamic_plugins_pvc: set after successful rollout
kubectl label pvc <name> -n apme \
  "apme.io/artifact-id=${CI_ARTIFACT_ID}" --overwrite
```

### aap-demo.sh Integration

```bash
AVAILABLE_ADDONS="mcp-server portal setup-pah apme"

apme)
  if kubectl get pods -n apme -l "app.kubernetes.io/component=gateway" \
      &>/dev/null 2>&1; then
    url="http://apme-gateway.apme.svc:8080 (cluster-internal)"
  fi
```

## Consequences

### Positive

- ARM developers can test APME UI plugins with CI builds before official release
- PVC label cache eliminates 3–10 min plugin reinstall on config-only re-deploys
- Consistent addon lifecycle (`enable`, `disable`, `status`) with other addons
- `CI_ARTIFACT_ID` override makes it easy to test specific CI builds
- OAuth app and API token are reused across re-deploys (no AAP churn)

### Negative

- ARM path requires `skopeo` and authenticated `gh` CLI (two extra prerequisites)
- Plugin registry is HTTP (insecure) — only internal to cluster, not exposed
- ARM profile provides UI plugins only; no APME gateway/engine (x86-only feature)
- `wait_for_apme` timeout is 600s on ARM (init container installs 6 plugins)
- PVC label cache only skips reinstall when `CI_ARTIFACT_ID` is unchanged;
  any artifact upgrade triggers full reinstall

### Neutral

- Cached OCI artifact stored at `~/.aap-demo/apme/plugins-oci.tar.gz`
- Re-running with same `CI_ARTIFACT_ID` skips download (file cache) and
  optionally skips PVC wipe (label cache) — both independent mechanisms

## Alternatives Considered

### 1. Build plugins into a custom RHDH image

Pre-bake APME plugins into a custom RHDH container image at build time.

**Rejected:** Requires image build pipeline, custom registry, rebuild on every
plugin update. In-cluster OCI registry + CI artifact download achieves the same
result without build infrastructure, and `CI_ARTIFACT_ID` makes plugin
version switching trivial.

### 2. Single ARM/x86 path using emulation

Use QEMU/emulation to run x86 APME chart on ARM.

**Rejected:** MicroShift doesn't support mixed-arch node pools. Emulation adds
significant overhead and is unreliable for production-like testing.

### 3. Wait for official multi-arch APME image

Block ARM support until Red Hat ships a multi-arch APME gateway image.

**Rejected:** Blocks ARM developers from testing APME UI plugins, which don't
require the gateway. Community RHDH is multi-arch; only the gateway is x86-only.

### 4. Use `kubectl cp` instead of port-forward + skopeo for plugin push

Copy OCI tarball directly into registry pod filesystem via `kubectl cp`.

**Rejected:** Registry pod would need special startup logic to import from
filesystem. `skopeo copy` over port-forward is the standard OCI push path and
works with the registry's native API.

## References

- [ADR-004](004-portal-helm-addon.md): Portal Helm addon (OAuth pattern, ARM profile)
- [ADR-002](002-portal-helm-deployment.md): x86 and ARM Helm profiles
- [ADR-008](008-addon-system.md): Addon system architecture
- [ADR-013](013-in-cluster-registry.md): In-cluster registry pattern
- APME GitHub: `ansible/apme`
- APME plugins: `ansible/ansible-rhdh-plugins`
