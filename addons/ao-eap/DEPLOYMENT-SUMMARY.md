# Automation Orchestrator Deployment Summary

## ✅ Deployment Complete

All fixes have been applied to `deploy.sh` and verified with a full end-to-end deployment.

### What Was Fixed

#### 1. **OLM Catalog Namespace Detection** (Critical Fix)

**File**: `addons/ao-eap/deploy.sh` line 23

**Problem**:

- Pattern `'"openshift-marketplace"'` didn't match the actual catalog-operator args format
- Args are in JSON array format: `["--namespace","olm,openshift-marketplace"]`
- The grep pattern with literal quotes never matched, causing script to default to `olm` namespace

**Root Cause**:

- OLM has two catalog namespace types:
  - **Global**: No OperatorGroup (e.g., `openshift-marketplace`) - visible to all namespaces
  - **Scoped**: Has OperatorGroup (e.g., `olm`) - only visible within that namespace
- Subscriptions can only resolve operators from global catalog namespaces
- The script was placing CatalogSource in `olm` (scoped), not `openshift-marketplace` (global)

**Fix**: Changed grep pattern from `'"openshift-marketplace"'` to `'openshift-marketplace'`

**Impact**: CatalogSource now correctly created in `openshift-marketplace`, enabling subscription resolution

#### 2. **CloudNativePG Installation Check** (Bug Fix)

**File**: `addons/ao-eap/deploy.sh` line 375

**Problem**:

- Script only checked for `clusters.postgresql.cnpg.io` CRD
- Missing `databases.postgresql.cnpg.io` CRD caused migration jobs to fail
- `tail -5` hid full kubectl output, masking partial install issues

**Fix**:

- Changed check from `clusters.postgresql.cnpg.io` to `databases.postgresql.cnpg.io` (required CRD)
- Removed `tail -5` to show full kubectl output for debugging

**Impact**: Ensures all CNPG CRDs are installed, preventing database creation failures

### Architecture Verified

```
┌─────────────────────────────────────────────────────────────┐
│  openshift-marketplace (global catalog namespace)          │
│  ├─ CatalogSource: cs-automation-orchestrator              │
│  ├─ Pull Secret: ao-registry-pull-secret                   │
│  ├─ SCCs: anyuid, privileged                               │
│  └─ Pod Security: baseline                                 │
└─────────────────────────────────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  automation-orchestrator (workload namespace)               │
│  ├─ OperatorGroup: automation-orchestrator-operator        │
│  ├─ Subscription: sourceNamespace=openshift-marketplace    │
│  ├─ CSV: automation-orchestrator-operator.v0.0.1           │
│  ├─ AutomationOrchestrator CR                              │
│  ├─ PostgreSQL Cluster (CNPG)                              │
│  │   ├─ Database: orchestrator                             │
│  │   ├─ Database: temporal                                 │
│  │   └─ Database: temporal_visibility                      │
│  └─ Application Pods (11 running)                          │
└─────────────────────────────────────────────────────────────┘
```

### Deployment Results

**Test Run Date**: 2026-07-23  
**Cluster**: MicroShift (aap-demo)  
**Result**: ✅ Success

**Components Verified**:

- ✅ CatalogSource: READY in `openshift-marketplace`
- ✅ CSV Phase: Succeeded
- ✅ PostgreSQL Cluster: Healthy (1/1 instances ready)
- ✅ PostgreSQL Databases: All 3 applied (orchestrator, temporal, temporal_visibility)
- ✅ AutomationOrchestrator CR: Created
- ✅ Application Pods: 11/14 Running (3 completed migration jobs)
- ✅ Route: Admitted and accessible

**Access Information**:

- URL: `http://automation-orchestrator-automation-orchestrator.apps.127.0.0.1.nip.io`
- Username: `admin`
- Password: Retrieved from secret `automation-orchestrator-initial-admin-password`

### Known Issues Resolved

1. ❌ ~~"CSV not found after 5 minutes"~~ → ✅ Fixed by correct catalog namespace
2. ❌ ~~"database 'orchestrator' does not exist"~~ → ✅ Fixed by installing all CNPG CRDs
3. ❌ ~~Pod Security violations in marketplace~~ → ✅ Script sets baseline enforcement
4. ❌ ~~Catalog pod creation failures~~ → ✅ Script grants SCCs to marketplace namespace

### Manual Intervention Required

**None** - The script now handles end-to-end deployment automatically.

### Future Improvements

1. **Idempotency**: Script already handles cleanup of stale resources before install
2. **Retry Logic**: Consider adding retry for transient OLM resolution delays
3. **Health Checks**: Consider adding post-deployment smoke tests

## Usage

```bash
# Clean deployment
./addons/ao-eap/deploy.sh

# With custom index image
echo "registry.redhat.io/redhat/redhat-operator-index:vX.XX-..." | ./addons/ao-eap/deploy.sh

# Cleanup
./addons/ao-eap/deploy.sh --delete
```

## References

- [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) - Common issues and debugging
- [README.md](./README.md) - Full deployment guide
