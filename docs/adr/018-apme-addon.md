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

### Architecture Decision 3: PVC Preservation for Plugin Caching

The `install-dynamic-plugins` init container runs on every RHDH pod restart,
reinstalling all plugins into the `dynamic-plugins` PVC. Without intervention,
a config change (new OAuth token, updated AAP URL) triggering a rollout restart
also forces a full plugin reinstall — adding 3–10 minutes per re-deploy.

**Solution:** Never delete the `dynamic-plugins` PVC. RHDH 1.10+ checks plugin
hashes on init container startup and skips reinstall when plugins on the volume
match the configured versions. The PVC is labeled with `apme.io/artifact-id`
after a successful deploy for observability, but deletion is never triggered
automatically.

Restart of the RHDH Deployment still runs on every deploy to apply ConfigMap and
Secret changes. The init container plugin reinstall is skipped as long as the
PVC contents are valid — regardless of whether `CI_ARTIFACT_ID` changed.

To force a clean plugin install manually:

```bash
kubectl delete pvc -n apme -l app.kubernetes.io/name=apme-rhdh
```

### Architecture Decision 4: OAuth Two-Phase Configuration

Identical pattern to portal addon (ADR-004). APME requires an OAuth application
in AAP with a redirect URI pointing to the RHDH route, which is unknown
pre-deployment.

**Phase 1 (pre-deploy):** Create OAuth app with placeholder redirect URI.
Credentials stored in `apme-rhdh-secrets-rhaap-portal` secret.

**Phase 2 (post-deploy):** Fetch RHDH route, `PATCH` OAuth app redirect URI.

Existing OAuth apps are reused across re-deploys. Client secret is cached in
`~/.aap-demo/apme/` to survive re-runs (AAP only returns it on creation).

### Architecture Decision 5: AAP Host URL on MicroShift Uses Internal Service

**Problem:** The `aap-host-url` value in `secrets-rhaap-portal` controls where the RHDH
backend sends OAuth token exchange POST requests. On MicroShift the AAP route hostname
uses nip.io wildcard DNS (`*.apps.127.0.0.1.nip.io`), which always resolves to `127.0.0.1`.
From a pod, `127.0.0.1` is the pod's own loopback — no listener there — so every
server-side OAuth POST fails with "fetch failed".

**Solution:** `get_aap_host_url()` returns `http://<svc>.<namespace>.svc` when
`IS_MICROSHIFT=true` instead of the external route hostname. The service name is
resolved from the route's `spec.to.name` field so it stays accurate even if the
service is renamed:

```bash
svc_name=$(kubectl get route aap -n "$AAP_NAMESPACE" \
  -o jsonpath='{.spec.to.name}' 2>/dev/null || echo "aap")
echo "http://${svc_name}.${AAP_NAMESPACE}.svc"
```

On non-MicroShift clusters the external HTTPS route is used as before.
The `ansible.rhaap.checkSSL: false` values.yaml flag remains in place; the internal
service is HTTP so TLS verification is not relevant on MicroShift.

**Detection:** `IS_MICROSHIFT=true` when `kubectl get ingresses.config/cluster` returns
empty — the same check used by the NFS provisioner for its `__NFS_SERVER_IP__`
substitution (see CLAUDE.md).

### Architecture Decision 6: Namespace and Credential Isolation

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
[background] download_ci_plugins  # gh api + curl; runs in parallel with Helm
install_helm_chart         # helm upgrade --install (community RHDH); no --wait on ARM
[wait] download_ci_plugins # join background download before registry steps
deploy_plugin_registry     # docker registry v2 Deployment in apme ns
push_plugins_to_registry   # port-forward + skopeo copy
create_plugin_registry_secret  # registries.conf for insecure HTTP registry
patch_plugin_configmap     # swap registry.redhat.io refs → in-cluster registry
restart_rhdh_deployment    # kubectl rollout restart
wait_for_apme              # rollout status --timeout=360s; streams init container logs
label_dynamic_plugins_pvc  # apme.io/artifact-id=<CI_ARTIFACT_ID>
update_oauth_redirect      # PATCH OAuth app with real RHDH route
display_success            # URLs, next steps
```

### PVC Cache Mechanism

PVCs are never deleted automatically. After a successful rollout, the PVC is
labeled for observability:

```bash
# label_dynamic_plugins_pvc: set after successful rollout
kubectl label pvc <name> -n apme \
  "apme.io/artifact-id=${CI_ARTIFACT_ID}" --overwrite

# Manual clean slate if needed
kubectl delete pvc -n apme -l app.kubernetes.io/name=apme-rhdh
```

### Helm Timeouts

`helm repo update` is wrapped with `timeout 30` to prevent silent VPN hangs.
x86 `helm install`/`helm upgrade` use `--timeout=300s --wait` — Helm waits for
pod readiness before returning, making `wait_for_apme` a belt-and-suspenders
fallback on x86. ARM skips `--wait` to avoid a deadlock: the RHDH pod cannot
become Ready until the init container pulls plugins from the in-cluster registry,
which is not deployed until after `install_helm_chart` returns.

### x86 Readiness Wait

`wait_for_apme` on x86 resolves the gateway deployment name by label
(`app.kubernetes.io/component=gateway`) and delegates to
`kubectl rollout status --timeout=300s`, replacing an unreliable
`Running`-phase poll that could report false positives before readiness probes
passed.

### ARM Init Container Log Streaming

`wait_for_apme` on ARM streams `install-dynamic-plugins` init container logs to
stdout during the rollout wait, providing plugin-by-plugin install visibility
instead of a silent 360s black hole.

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
- PVC preservation eliminates 3–10 min plugin reinstall on re-deploys
- CI plugin download runs in parallel with Helm, saving 60–120s on ARM
- Init container log streaming gives plugin-by-plugin visibility during ARM wait
- x86 readiness wait uses `kubectl rollout status` — no false positives
- Helm repo update bounded to 30s — no silent VPN hangs
- Consistent addon lifecycle (`enable`, `disable`, `status`) with other addons
- `CI_ARTIFACT_ID` override makes it easy to test specific CI builds
- OAuth app and API token are reused across re-deploys (no AAP churn)
- RHDH backend OAuth token exchange works on MicroShift — internal service URL bypasses nip.io loopback resolution

### Negative

- ARM path requires `skopeo` and authenticated `gh` CLI (two extra prerequisites)
- Plugin registry is HTTP (insecure) — only internal to cluster, not exposed
- ARM profile provides UI plugins only; no APME gateway/engine (x86-only feature)
- `wait_for_apme` timeout is 360s on ARM (init container installs 6 plugins)
- PVC contents can become stale if the in-cluster registry image changes but PVC
  is not manually cleared — `kubectl delete pvc -n apme -l app.kubernetes.io/name=apme-rhdh`

### Neutral

- Cached OCI artifact stored at `~/.aap-demo/apme/plugins-oci.tar.gz`
- Re-running with same `CI_ARTIFACT_ID` skips download (file cache); PVC plugin
  cache is always preserved regardless of artifact ID

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
