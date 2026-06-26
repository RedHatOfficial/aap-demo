# ADR-004: Portal Helm Addon Architecture

**Status:** Accepted
**Date:** 2026-06-25
**Author:** DevOps Automator Agent

## Context

aap-demo deploys the Ansible Automation Portal via the `portal` Helm addon on
OpenShift. Portal provides a self-service web interface built on Red Hat Developer
Hub (RHDH) with AAP-specific plugins.

**Why Helm deployment:**

- Official Red Hat supported deployment method on x86 OpenShift
- Production-ready architecture (HA, resource management, OCP native)
- Aligns with AAP operator deployment patterns
- Single addon auto-detects cluster CPU for x86 vs ARM image profiles (see ADR-002)

## Decision

Add `portal` addon to aap-demo following the established addon architecture pattern.
Deploy portal via official OpenShift Helm chart from `openshift-helm-charts/redhat-rhaap-portal`.

### Key Implementation Decisions

#### 1. OAuth Chicken-Egg Resolution

Portal requires OAuth application in AAP, but OAuth redirect URI must point to deployed portal route (unknown pre-deployment).

**Solution:** Two-phase OAuth configuration:

1. **Pre-deployment:** Create OAuth app with placeholder redirect URI (`https://example.com`)
2. **Post-deployment:** Update OAuth app with real portal route

#### 2. Registry Credentials Handling

Portal uses OCI container delivery from `registry.redhat.io` (recommended over deprecated HTTP registry).

**Credential Resolution Order:**

1. Check existing OpenShift global pull secret
2. Extract `registry.redhat.io` auth from existing secret
3. Fallback to user prompt if not found
4. Create namespace-scoped secret: `redhat-rhaap-portal-dynamic-plugins-registry-auth`

#### 3. Architecture-Aware Deployment

Portal uses **cluster node architecture** (not laptop CPU) to select Helm values:

- **amd64:** Chart-default Red Hat RHDH images (supported)
- **arm64:** Community multi-arch RHDH + image overrides (experimental)

See [ADR-002](002-portal-helm-deployment.md) for profile details, MicroShift OAuth,
and ARM-specific post-install steps.

**Behavior:**

- Detect arch via `kubectl get nodes`
- Optional override: `PORTAL_ARCH=arm` or `PORTAL_ARCH=x86`
- ARM Mac with x86 remote cluster: deploy normally (cluster arch wins)
- ARM Mac with CRC/MicroShift: ARM profile applied automatically

#### 4. Helm Version Pinning

Portal lifecycle page specifies version compatibility:

- Portal version (e.g., 2.1)
- OCP version compatibility
- Image tags (`imageTagInfo`)
- Platform image tag (`<platform-version>`)

**Strategy:** Query Helm chart metadata for supported versions, select latest compatible with AAP 2.7.

```bash
helm show values openshift-helm-charts/redhat-rhaap-portal --version <chart-version>
```

#### 5. AAP Configuration Automation

Portal requires these AAP settings:

1. OAuth application (authorization-code grant, confidential client)
2. "Allow external users to create OAuth2 tokens" enabled
3. API token with Write scope
4. Organization selected for template synchronization

**AAP host URL:** Store the external AAP route in `secrets-rhaap-portal` key
`aap-host-url` (for example `https://aap-aap-operator.apps.127.0.0.1.nip.io`).
Do not use in-cluster service DNS such as `http://aap.aap-operator.svc` — the
browser OAuth redirect sends users to `AAP_HOST_URL`, which must be reachable
from the user's machine. Portal pods read this value at startup, so the
deployment must be restarted after updating the secret.

**Automation via AAP API:**

- Create organization if needed (or use existing)
- Create OAuth app: `POST /api/gateway/v1/applications/`
- Enable OAuth tokens: `PATCH /api/gateway/v1/settings/`
- Generate API token: `POST /api/gateway/v1/tokens/`

All credentials stored in OpenShift secret, read by Helm chart.

## Architecture

### Component Flow

```
┌─────────────────────────────────────────────────────────┐
│ aap-demo enable portal                                   │
└────────────────┬────────────────────────────────────────┘
                 │
                 ├─> 1. Prerequisites Check
                 │     - AAP deployed and reachable
                 │     - Helm 3.10+ installed
                 │     - oc CLI authenticated
                 │     - registry.redhat.io credentials
                 │     - x86_64 architecture (cluster or local)
                 │
                 ├─> 2. AAP Configuration (API)
                 │     - Select/create organization
                 │     - Create OAuth app (placeholder redirect)
                 │     - Enable external OAuth tokens
                 │     - Generate API token
                 │
                 ├─> 3. Portal Namespace (`redhat-rhaap-portal`)
                 │     - Create namespace, grant SCCs, copy pull secret from AAP ns
                 │     - Migrate legacy install from `aap-operator` if present
                 │
                 ├─> 4. OpenShift Secrets (in portal namespace)
                 │     - redhat-rhaap-portal-dynamic-plugins-registry-auth
                 │       (auth.json with registry.redhat.io credentials)
                 │     - secrets-rhaap-portal (AAP host URL, OAuth, API token)
                 │
                 ├─> 5. Helm Install (namespace: redhat-rhaap-portal)
                 │     - Repo: openshift-helm-charts/redhat-rhaap-portal
                 │     - Values: clusterRouterBase, pluginMode=oci, imageTagInfo
                 │     - Upstream: AAP org name for template sync
                 │
                 ├─> 6. Post-Install
                 │     - Get portal route from OpenShift
                 │     - Update OAuth app redirect URI
                 │     - Verify deployment ready
                 │
                 └─> 7. Status Display
                       - Portal URL
                       - OAuth login instructions
```

### Helm Values Template

```yaml
global:
  clusterRouterBase: apps.127.0.0.1.nip.io  # From oc get ingresses.config/cluster
  pluginMode: oci                            # OCI container delivery (recommended)
  imageTagInfo: "<plugin-version>"           # From lifecycle page

upstream:
  backstage:
    appConfig:
      catalog:
        providers:
          rhaap:
            orgs: "<aap-organization-name>"  # AAP org for template sync
```

### Directory Structure

```
addons/portal/
├── deploy.sh              # Main deployment script
├── README.md              # Usage and troubleshooting
└── values.yaml.template   # Helm values with placeholders
```

## Integration with Main Script

### Argument Parsing (Line 123)

```bash
console | registry | mcp-server | registry-ui | olm | portal)
```

### Help Text (Lines 377-387)

```bash
enable portal    Enable Self-Service Portal (Helm; auto-detects arm64 vs amd64)
                 Requires: AAP 2.6+, Helm 3.10+, registry.redhat.io credentials
disable portal   Disable Portal addon
status portal    Check Portal deployment status
```

### Status Display (Lines 1726-1749)

```bash
portal)
  url=$(kubectl get route redhat-rhaap-portal -n redhat-rhaap-portal \
    -o jsonpath='{.spec.host}' 2>/dev/null)
  [ -n "$url" ] && echo "https://$url" || echo "not-deployed"
  ;;
```

### Available Addons (Line 2433)

```bash
AVAILABLE_ADDONS="mcp-server portal"
```

## Deploy Script Functions

### Core Functions

```bash
check_prerequisites() {
  # Verify AAP deployed
  # Verify Helm 3.10+ installed
  # Verify oc CLI logged in
  # Verify registry credentials (or prompt)
  # Warn if ARM architecture detected
}

get_aap_credentials() {
  # Fetch AAP route from OpenShift
  # Fetch admin password from secret
  # Test connectivity to AAP API
}

create_oauth_app() {
  # POST /api/gateway/v1/applications/
  # Store client_id, client_secret, app_id
}

enable_oauth_tokens() {
  # PATCH /api/gateway/v1/settings/
  # Set ALLOW_OAUTH2_FOR_EXTERNAL_USERS=true
}

create_api_token() {
  # POST /api/gateway/v1/tokens/
  # Scope: Write
  # Store token value
}

create_registry_secret() {
  # Generate auth.json with registry.redhat.io credentials
  # Create OpenShift secret in namespace
}

install_helm_chart() {
  # helm repo add openshift-helm-charts
  # helm install with values file
  # kubectl wait for deployment ready
}

update_oauth_redirect() {
  # Get portal route from OpenShift
  # PATCH OAuth app with real redirect URI
}

cleanup() {
  # helm uninstall (--delete flag)
  # Delete OAuth app via AAP API
  # Delete registry secret
}
```

## Rationale

### Cluster vs laptop architecture

Helm-based portal deployment runs on the OpenShift cluster, not the laptop:

1. Cluster node architecture selects the x86 or ARM Helm profile
2. ARM Mac developers use CRC/MicroShift with the ARM profile (native, no emulation)
3. Remote x86 clusters work from any laptop via KUBECONFIG

See [ADR-002](002-portal-helm-deployment.md) for profile differences and MicroShift OAuth.

### Why Two-Phase OAuth Configuration?

OAuth redirect URI must match deployed portal route for security. Helm chart requires OAuth credentials during install.

**Alternatives considered:**

1. **Dynamic DNS with predictable route:** OpenShift route names are deterministic but require namespace.
   Still need to update OAuth app post-install.
2. **Pre-calculate route name:** Route format is `<release-name>-<namespace>.apps.<cluster-domain>`.
   Works but brittle if Helm chart changes naming.
3. **Manual OAuth configuration:** Forces user to create OAuth app. Defeats automation goal.

**Chosen approach:** Placeholder → real redirect URI post-install. AAP API supports PATCH, no downtime.

### Why OCI Container Delivery?

Portal supports two plugin delivery methods:

1. **OCI container delivery** (recommended): Pulls plugins from `registry.redhat.io`
2. **HTTP plug-in registry** (deprecated): Hosts tarball files

**Reasons for OCI:**

- Official recommendation from Red Hat
- Future-proof (HTTP deprecated in next AAP release)
- Better security (registry auth, image signing)
- Consistent with operator-based deployments

**Trade-off:** Requires registry credentials. Mitigated by auto-detecting existing pull secret or prompting user.

## Consequences

### Positive

1. **Production-ready deployment:** Helm chart supported by Red Hat
2. **Consistent with AAP patterns:** Operator → Helm → OCI delivery
3. **Minimal user interaction:** Full automation except registry credentials
4. **No sudo required:** Runs via oc/kubectl with user permissions
5. **Idempotent:** Re-running enable updates existing deployment
6. **Proper cleanup:** Disable removes Helm release and AAP OAuth app

### Negative

1. **ARM profile experimental:** Community RHDH overrides are not Red Hat supported
2. **Registry dependency:** Requires registry.redhat.io access or mirroring
3. **OAuth complexity:** Two-phase configuration may confuse debugging
4. **Helm version requirement:** Older Helm versions unsupported
5. **MicroShift OAuth:** Requires host alias and HTTP token URL (see ADR-002)

### Mitigation Strategies

1. **Profile detection:** Auto-select x86 vs ARM from cluster nodes; `PORTAL_ARCH` override
2. **Registry fallback:** Auto-detect existing secret before prompting
3. **OAuth logging:** Verbose output showing placeholder → real URI transition
4. **Helm version check:** Fail fast with upgrade instructions
5. **OAuth verification:** Post-install curl check from portal pod to AAP `/o/token/`

## Verification

After implementation:

```bash
# Enable portal
$ aap-demo enable portal

# Expected output:
# ✓ AAP deployed and reachable
# ✓ Helm 3.10+ installed
# ✓ Registry credentials found (or prompted)
# ✓ OAuth app created: <app-id>
# ✓ API token generated
# ✓ Helm chart installed: redhat-rhaap-portal
# ✓ Portal route: https://redhat-rhaap-portal-redhat-rhaap-portal.apps.127.0.0.1.nip.io
# ✓ OAuth app updated with redirect URI

# Check status
$ aap-demo status portal
# Output: https://redhat-rhaap-portal-redhat-rhaap-portal.apps.127.0.0.1.nip.io

# Disable portal
$ aap-demo disable portal
# ✓ Helm release uninstalled from redhat-rhaap-portal namespace
# ✓ redhat-rhaap-portal namespace deleted
# ✓ OAuth app deleted
# ✓ Registry secret removed
```

## Alternatives Considered

### 1. Operator-based deployment instead of Helm

**Rejected:** Portal ships as Helm chart, not operator. Creating custom operator adds maintenance burden.

### 2. HTTP plug-in registry instead of OCI

**Rejected:** HTTP registry deprecated. OCI is future direction.

### 3. Single-phase OAuth with pre-calculated route

**Rejected:** Route naming may change in Helm chart updates. Placeholder → update is more resilient.

### 4. Manual organization creation

**Rejected:** AAP API makes automation straightforward. Better UX to auto-create or prompt.

## References

- AAP Extend 2.7 docs, pages 128-145: Portal Helm installation
- OpenShift Helm catalog: `openshift-helm-charts/redhat-rhaap-portal`
- AAP API docs: OAuth applications, settings, tokens
- Ansible Automation Portal lifecycle: Version compatibility matrix
- [ADR-002](002-portal-helm-deployment.md): x86 and ARM Helm profiles, MicroShift OAuth

## Related ADRs

- **[ADR-002](002-portal-helm-deployment.md):** x86 and ARM Helm profiles, MicroShift OAuth

## Next Steps

Implemented in `addons/portal/deploy.sh`. Ongoing maintenance:

1. Test both x86 and ARM profiles on chart upgrades
2. Switch ARM profile to Red Hat RHDH images when multi-arch hub is available
3. Keep troubleshooting in `addons/portal/README.md` aligned with deploy script behavior
