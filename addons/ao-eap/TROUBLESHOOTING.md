# Automation Orchestrator Deployment Troubleshooting

## Common Issues

### 1. OLM Subscription Resolution Failures

**Symptom:**
```
ERROR: CSV not found after 5 minutes.
Subscription status: ResolutionFailed
Message: "no operators found from catalog cs-automation-orchestrator in namespace..."
```

**Root Cause:**
OLM has two types of catalog namespaces:
- **Global catalog namespaces**: No OperatorGroup present. Catalogs here are visible to all namespaces.
- **Scoped catalog namespaces**: Have an OperatorGroup. Catalogs here are only visible within that namespace.

On MicroShift with operator-sdk OLM:
- `olm` namespace has an OperatorGroup → scoped catalogs only
- `openshift-marketplace` namespace has NO OperatorGroup → global catalogs

**Fix:**
The deploy script auto-detects which namespace catalog-operator watches and creates the CatalogSource there. The fix ensures the detection logic correctly identifies `openshift-marketplace` when catalog-operator watches both `olm,openshift-marketplace`.

**Verification:**
```bash
# Check which namespaces catalog-operator watches
kubectl get deployment catalog-operator -n olm \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | grep namespace

# Verify CatalogSource is in the correct namespace
kubectl get catalogsource -n openshift-marketplace
```

### 2. CloudNativePG Operator Installation

**Symptom:**
```
Error: failed calling webhook "mcluster.cnpg.io": service "cnpg-webhook-service" not found
```

**Root Cause:**
The script only installs CloudNativePG operator if the CRDs don't exist. If CRDs were registered from a previous partial run, the operator installation is skipped.

**Fix:**
Ensure both CRDs AND operator are installed:
```bash
kubectl apply --server-side -f https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v1.25.1/cnpg-1.25.1.yaml
kubectl wait --for=condition=available deployment/cnpg-controller-manager -n cnpg-system --timeout=120s
```

### 3. CatalogSource Pod Creation Failures

**Symptom:**
```
pods "cs-automation-orchestrator-xxx" is forbidden: 
violates PodSecurity "restricted:latest"
```

**Root Cause:**
The `openshift-marketplace` namespace needs:
1. SCCs granted to service accounts
2. Pod Security admission set to at least `baseline`

**Fix:**
The deploy script handles this in Step 3:
```bash
oc adm policy add-scc-to-group anyuid "system:serviceaccounts:openshift-marketplace"
oc adm policy add-scc-to-group privileged "system:serviceaccounts:openshift-marketplace"
kubectl label namespace openshift-marketplace \
  pod-security.kubernetes.io/enforce=baseline --overwrite
```

## Architecture Notes

### OLM Catalog Resolution Flow

1. **Subscription** (in `automation-orchestrator` namespace) references:
   - `source: cs-automation-orchestrator`
   - `sourceNamespace: openshift-marketplace`

2. **CatalogSource** (in `openshift-marketplace` namespace):
   - Has no OperatorGroup in its namespace → global visibility
   - Creates a catalog pod serving gRPC API

3. **catalog-operator** queries the catalog via gRPC and creates:
   - InstallPlan
   - ClusterServiceVersion (CSV)

### Namespace Requirements

| Namespace | OperatorGroup | SCCs | Pod Security | Purpose |
|-----------|---------------|------|--------------|---------|
| `automation-orchestrator` | Yes | anyuid, privileged | baseline | AO operator and workloads |
| `openshift-marketplace` | No | anyuid, privileged | baseline | Global OLM catalogs |
| `olm` | Yes | anyuid, privileged | baseline | OLM operators |

## Debugging Commands

```bash
# Check subscription status
kubectl get subscription automation-orchestrator-operator -n automation-orchestrator -o yaml

# Check catalog health
kubectl get catalogsource -n openshift-marketplace
kubectl get pods -n openshift-marketplace
kubectl logs -n openshift-marketplace -l olm.catalogSource=cs-automation-orchestrator

# Check OLM operator logs
kubectl logs -n olm deployment/catalog-operator --tail=100
kubectl logs -n olm deployment/olm-operator --tail=100

# Check package availability
kubectl get packagemanifests -n automation-orchestrator | grep automation-orchestrator-operator

# Check InstallPlan and CSV
kubectl get installplan,csv -n automation-orchestrator
```
