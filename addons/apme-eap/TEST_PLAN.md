# APME Playbook Addon - Test Plan

## Overview

This test plan validates the AAP-native execution approach for the APME addon, which uses Ansible playbooks with `ansible.builtin.uri` to interact with AAP's REST API.

## Test Environment

### Prerequisites
- OpenShift Local (CRC) or MicroShift cluster running
- AAP 2.7+ deployed (`aap-demo deploy`)
- `kubectl` CLI available
- `python3` (3.8+) installed
- No manual token setup required (auto-created)

### Test Data
- **AAP Route**: Retrieved from `kubectl get route -n aap-operator`
- **Admin Password**: Retrieved from `kubectl get secret aap-admin-password -n aap-operator`
- **Test Namespace**: `apme`

---

## Test Cases

### TC-001: Clean Installation (First-Time Deploy)

**Objective**: Verify full deployment flow with no existing resources

**Prerequisites**:
- Fresh AAP deployment (no prior APME addon runs)
- No `aap-api-token` secret exists
- No APME resources in AAP

**Steps**:
1. Run: `./aap-demo.sh enable apme-eap`
2. Observe console output
3. Check AAP Web UI for job

**Expected Results**:
- ✅ Venv created at `~/.aap-demo/apme-eap-venv/` with ansible-core
- ✅ API token auto-created and stored in `aap-api-token` secret
- ✅ AAP resources created:
  - Organization: Default (existing)
  - Project: `aap-demo-apme` (manual type)
  - Inventory: `localhost` with host `localhost`
  - Job Template: `Deploy APME`
- ✅ Job launched in AAP
- ✅ Console displays AAP Web UI link
- ✅ APME namespace created with pods running

**Validation Commands**:
```bash
# Check token secret
kubectl get secret aap-api-token -n aap-operator

# Check venv
ls ~/.aap-demo/apme-eap-venv/

# Check APME deployment
kubectl get pods -n apme
kubectl get route -n apme
```

**Pass Criteria**: All resources created, job completes successfully, APME portal accessible

---

### TC-002: Idempotent Re-Run

**Objective**: Verify addon can run multiple times without errors

**Prerequisites**:
- TC-001 completed successfully
- All AAP resources exist
- Token secret exists

**Steps**:
1. Run: `./aap-demo.sh enable apme-eap` (second time)
2. Observe console output

**Expected Results**:
- ✅ Existing token reused (no new token created)
- ✅ Existing venv reused
- ✅ Project check finds existing project OR creates new one with unique timestamp path
- ✅ Inventory reused (not recreated)
- ✅ Job template updated (if needed) or reused
- ✅ New job launched successfully

**Validation**:
```bash
# Check token ID hasn't changed
kubectl get secret aap-api-token -n aap-operator -o jsonpath='{.data.token}' | base64 -d

# Check AAP for multiple projects (timestamp-based paths)
# Via AAP UI: Resources → Projects
```

**Pass Criteria**: No errors, job launches successfully, existing resources reused where appropriate

---

### TC-003: Token Auto-Creation

**Objective**: Verify automatic OAuth2 token creation via basic auth

**Prerequisites**:
- AAP deployed
- No `aap-api-token` secret exists

**Steps**:
1. Delete token secret: `kubectl delete secret aap-api-token -n aap-operator`
2. Run: `./aap-demo.sh enable apme-eap`
3. Check token creation output

**Expected Results**:
- ✅ Console shows: "API token not found. Creating new token..."
- ✅ `create_aap_token.yml` playbook runs
- ✅ Token created via `/api/gateway/v1/tokens/` endpoint
- ✅ Token stored in Kubernetes secret
- ✅ Console shows: "✓ API token created successfully"

**Validation**:
```bash
# Verify token secret exists
kubectl get secret aap-api-token -n aap-operator -o yaml

# Check token works
export AAP_HOST="https://$(kubectl get route -n aap-operator -o jsonpath='{.items[0].spec.host}')"
export AAP_TOKEN="$(kubectl get secret aap-api-token -n aap-operator -o jsonpath='{.data.token}' | base64 -d)"
curl -k -H "Authorization: Bearer $AAP_TOKEN" "$AAP_HOST/api/controller/v2/me/" | jq .
```

**Pass Criteria**: Token auto-created, stored in secret, validates successfully against AAP API

---

### TC-004: AAP Resource Creation via API

**Objective**: Verify all AAP resources created correctly via REST API

**Prerequisites**:
- Clean AAP (no APME resources)
- Token exists

**Steps**:
1. Run: `./aap-demo.sh enable apme-eap`
2. Check AAP Web UI: Resources → Projects/Inventories/Templates

**Expected Results**:
- ✅ **Project**:
  - Name: `aap-demo-apme`
  - Type: Manual
  - Local Path: `aap-demo-apme-<timestamp>`
  - Organization: Default
  - Files exist in controller pod at `/var/lib/awx/projects/aap-demo-apme-<timestamp>/`
- ✅ **Inventory**:
  - Name: `localhost`
  - Organization: Default
  - Hosts: 1 (localhost with `ansible_connection: local`)
- ✅ **Job Template**:
  - Name: `Deploy APME`
  - Project: `aap-demo-apme`
  - Inventory: `localhost`
  - Playbook: `playbooks/deploy_apme_portal.yml`
  - Ask variables on launch: Yes

**Validation**:
```bash
# Check files in controller pod
POD=$(kubectl get pods -n aap-operator -l app.kubernetes.io/name=aap-controller-task -o name | head -1)
kubectl exec -n aap-operator $POD -- ls -la /var/lib/awx/projects/ | grep aap-demo-apme
```

**Pass Criteria**: All resources visible in AAP UI, files present on controller pod

---

### TC-005: Job Launch and Monitoring

**Objective**: Verify job launches correctly and output is streamed

**Prerequisites**:
- AAP resources exist (TC-004)

**Steps**:
1. Run: `./aap-demo.sh enable apme-eap`
2. Watch console output during job execution
3. Click AAP Web UI link from console

**Expected Results**:
- ✅ Console shows: "Launching APME deployment job..."
- ✅ Job ID displayed
- ✅ AAP Web UI link provided
- ✅ Job status polled (waiting message)
- ✅ Job output streamed to console
- ✅ Success/failure status displayed
- ✅ AAP UI shows same job with matching output

**Validation**:
```bash
# Check AAP UI manually
# Resources → Jobs → Recent Jobs → "Deploy APME"
```

**Pass Criteria**: Job launches, output streams, status reported correctly

---

### TC-006: MicroShift Compatibility (Namespace vs Project)

**Objective**: Verify playbooks use Kubernetes Namespace API (not OpenShift Project)

**Prerequisites**:
- MicroShift or OpenShift Local cluster

**Steps**:
1. Run: `./aap-demo.sh enable apme-eap`
2. Check for API errors related to `project.openshift.io`

**Expected Results**:
- ✅ No errors about `ProjectRequest` not found
- ✅ Namespace `apme` created successfully
- ✅ Playbook uses `kind: Namespace` not `kind: Project`

**Validation**:
```bash
# Verify namespace exists
kubectl get namespace apme

# Check playbook code
grep -r "kind: Namespace" addons/apme-eap/roles/openshift_apme_setup/tasks/
grep -r "ProjectRequest" addons/apme-eap/roles/openshift_apme_setup/tasks/ || echo "Good - no ProjectRequest"
```

**Pass Criteria**: Namespace created without Project API errors

---

### TC-007: Tar-Free File Copy

**Objective**: Verify file copy works without `tar` in controller pod

**Prerequisites**:
- AAP controller pod lacks `tar` binary (typical minimal image)

**Steps**:
1. Run: `./aap-demo.sh enable apme-eap`
2. Check file copy output

**Expected Results**:
- ✅ No errors about "tar not found"
- ✅ Files copied using `kubectl exec` + `cat` method
- ✅ All playbook files present in controller pod
- ✅ Directory structure preserved

**Validation**:
```bash
POD=$(kubectl get pods -n aap-operator -l app.kubernetes.io/name=aap-controller-task -o name | head -1)

# Check tar availability
kubectl exec -n aap-operator $POD -- which tar || echo "tar not found (expected)"

# Check files copied
kubectl exec -n aap-operator $POD -- find /var/lib/awx/projects/ -name "aap-demo-apme-*" -type d
kubectl exec -n aap-operator $POD -- ls /var/lib/awx/projects/aap-demo-apme-*/playbooks/
```

**Pass Criteria**: Files copied successfully without tar, all files present

---

### TC-008: Cleanup and Re-Deploy

**Objective**: Verify addon can be disabled and re-enabled cleanly

**Prerequisites**:
- APME addon currently deployed

**Steps**:
1. Run: `./aap-demo.sh disable apme-eap` or `./aap-demo.sh enable apme-eap --delete`
2. Verify cleanup
3. Run: `./aap-demo.sh enable apme-eap` again

**Expected Results**:
- ✅ Namespace deleted
- ✅ Vars file removed
- ✅ Token secret preserved (optional)
- ✅ AAP resources may remain (not critical)
- ✅ Re-deploy works without errors

**Validation**:
```bash
# After disable
kubectl get namespace apme  # Should not exist
ls ~/.aap-demo/apme-eap-vars.yml  # Should not exist

# After re-enable
kubectl get pods -n apme  # Should exist again
```

**Pass Criteria**: Clean disable, successful re-enable

---

### TC-009: Error Handling - AAP Not Deployed

**Objective**: Verify graceful failure when AAP is not available

**Prerequisites**:
- No AAP deployed in cluster

**Steps**:
1. Run: `./aap-demo.sh enable apme-eap`

**Expected Results**:
- ✅ Error message: "AAP not deployed. Run 'aap-demo deploy' first."
- ✅ No resources created
- ✅ Exit code non-zero

**Pass Criteria**: Clear error message, graceful exit

---

### TC-010: Error Handling - Invalid Credentials

**Objective**: Verify error handling when AAP credentials fail

**Prerequisites**:
- AAP deployed
- Corrupt `aap-admin-password` secret

**Steps**:
1. Backup secret: `kubectl get secret aap-admin-password -n aap-operator -o yaml > /tmp/aap-secret.yaml`
2. Corrupt it: `kubectl create secret generic aap-admin-password -n aap-operator --from-literal=password=WRONG --dry-run=client -o yaml | kubectl apply -f -`
3. Run: `./aap-demo.sh enable apme-eap`
4. Restore: `kubectl apply -f /tmp/aap-secret.yaml`

**Expected Results**:
- ✅ Error during token creation: "Invalid username/password"
- ✅ Clear error message displayed
- ✅ Deployment stops

**Pass Criteria**: Authentication error caught and reported

---

## Performance Tests

### PT-001: Initial Deployment Time

**Objective**: Measure end-to-end deployment time

**Steps**:
1. Time full deployment: `time ./aap-demo.sh enable apme-eap`

**Acceptance Criteria**:
- First run (venv creation): < 5 minutes
- Subsequent runs (venv exists): < 3 minutes

---

### PT-002: Venv Size

**Objective**: Verify minimal venv footprint

**Steps**:
1. After deployment: `du -sh ~/.aap-demo/apme-eap-venv/`

**Acceptance Criteria**:
- Venv size: < 100 MB (target: ~50 MB)
- Much smaller than full Ansible install (150+ MB)

---

## Security Tests

### ST-001: Token Permissions

**Objective**: Verify token has minimal required scope

**Steps**:
1. Retrieve token: `kubectl get secret aap-api-token -n aap-operator -o jsonpath='{.data.token}' | base64 -d`
2. Check token in AAP UI: Settings → Users → admin → Tokens

**Expected Results**:
- ✅ Scope: `write` (not `admin` or broader)
- ✅ Description: "aap-demo APME addon API access"

---

### ST-002: Secret Storage

**Objective**: Verify sensitive data stored securely

**Steps**:
1. Check token secret: `kubectl get secret aap-api-token -n aap-operator -o yaml`

**Expected Results**:
- ✅ Token stored base64-encoded in Kubernetes secret
- ✅ Not logged to console or files
- ✅ No plaintext tokens in logs

---

## Regression Tests

### RT-001: Portal Addon Pattern Compatibility

**Objective**: Verify similar pattern to portal addon (basic auth token creation)

**Steps**:
1. Compare with portal addon: `grep -A 10 "create_api_token" addons/portal/deploy.sh`
2. Verify APME uses same approach

**Expected Results**:
- ✅ Both use basic auth with `aap-admin-password`
- ✅ Both POST to `/api/gateway/v1/tokens/`
- ✅ Both store in Kubernetes secrets

---

## Test Summary Template

```markdown
## Test Execution Summary

**Date**: YYYY-MM-DD
**Tester**: Name
**Environment**: OpenShift Local / MicroShift
**AAP Version**: 2.7.x

### Test Results

| Test ID | Test Name | Status | Notes |
|---------|-----------|--------|-------|
| TC-001 | Clean Installation | ✅ PASS | |
| TC-002 | Idempotent Re-Run | ✅ PASS | |
| TC-003 | Token Auto-Creation | ✅ PASS | |
| TC-004 | AAP Resource Creation | ✅ PASS | |
| TC-005 | Job Launch and Monitoring | ✅ PASS | |
| TC-006 | MicroShift Compatibility | ✅ PASS | |
| TC-007 | Tar-Free File Copy | ✅ PASS | |
| TC-008 | Cleanup and Re-Deploy | ✅ PASS | |
| TC-009 | AAP Not Deployed Error | ✅ PASS | |
| TC-010 | Invalid Credentials Error | ✅ PASS | |
| PT-001 | Deployment Time | ✅ PASS | X min XX sec |
| PT-002 | Venv Size | ✅ PASS | XX MB |
| ST-001 | Token Permissions | ✅ PASS | |
| ST-002 | Secret Storage | ✅ PASS | |
| RT-001 | Portal Addon Compatibility | ✅ PASS | |

### Issues Found

1. [If any issues] Description, severity, workaround

### Recommendations

1. [If applicable] Suggestions for improvements
```

---

## Automated Test Script

```bash
#!/usr/bin/env bash
# Quick smoke test for APME addon

set -e

echo "=== APME Addon Smoke Test ==="

# TC-003: Token creation
echo "TEST: Token auto-creation"
kubectl delete secret aap-api-token -n aap-operator 2>/dev/null || true
./aap-demo.sh enable apme-eap
kubectl get secret aap-api-token -n aap-operator || exit 1
echo "✅ PASS: Token created"

# TC-004: AAP resources
echo "TEST: AAP resources exist"
# Would need API calls to verify - left as manual test

# TC-006: MicroShift compat
echo "TEST: Namespace created"
kubectl get namespace apme || exit 1
echo "✅ PASS: Namespace exists"

# TC-007: Files copied
echo "TEST: Files in controller pod"
POD=$(kubectl get pods -n aap-operator -l app.kubernetes.io/name=aap-controller-task -o name | head -1)
kubectl exec -n aap-operator $POD -- ls /var/lib/awx/projects/ | grep aap-demo-apme || exit 1
echo "✅ PASS: Files copied"

echo ""
echo "=== Smoke Test Complete ==="
echo "Run full test plan manually for comprehensive validation"
```
