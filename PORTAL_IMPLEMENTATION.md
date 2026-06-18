# Self-Service Portal Implementation Summary

## Overview

This implementation adds Self-Service Automation Portal support to aap-demo per GitHub issue #18.

## Changes Made

### 1. Portal Custom Resource Template

**File:** `config/crs/aap-with-portal.yaml`

New CR template that enables all AAP 2.7 components including the Self-Service Portal:

```yaml
apiVersion: aap.ansible.com/v1alpha1
kind: AnsibleAutomationPlatform
metadata:
  name: aap
spec:
  no_log: false

  controller:
    disabled: false

  eda:
    disabled: false

  hub:
    disabled: false
    storage_type: file
    file_storage_storage_class: nfs-local-rwx
    file_storage_access_mode: ReadWriteMany
    file_storage_size: 5Gi
    route_host: aap-hub-aap-operator.apps.127.0.0.1.nip.io

  portal:
    disabled: false
```

**Key points:**

- Follows existing AAP component pattern (controller, eda, hub)
- Portal section simply sets `disabled: false` to enable it
- Operator handles all portal deployment details (pods, services, routes)
- Storage requirements automatically managed by operator

### 2. New `aap-demo portal` Command

**File:** `aap-demo.sh`

New dedicated command for portal deployment:

```bash
aap-demo portal
```

**Implementation:**

- Added `portal` to command parser (line 116)
- Implemented `cmd_deploy_portal()` function
- Sets `CR=with-portal` by default
- Checks for existing deployments and provides patch command if needed
- Full cluster creation and validation flow

**User experience:**

```bash
$ aap-demo portal
aap-demo portal - Deploying AAP with Self-Service Portal...
Infrastructure: OpenShift Local
Using CR: with-portal (includes Self-Service Portal)
...
```

### 3. Documentation Updates

**File:** `README.md`

Added comprehensive portal documentation:

- Quick start section shows `aap-demo portal` command
- New "Self-Service Portal (AAP 2.7)" section explaining features
- Portal capabilities and access credentials
- Manual enable command for existing deployments

## Validation Steps

### Before Cluster Creation

1. **Verify files are present:**

   ```bash
   ls -l config/crs/aap-with-portal.yaml
   grep -A5 "cmd_deploy_portal" aap-demo.sh
   ```

2. **Check help text:**

   ```bash
   aap-demo help | grep portal
   # Should show: portal          Deploy AAP with Self-Service Portal enabled
   ```

### With Fresh Deployment

1. **Deploy portal:**

   ```bash
   aap-demo portal
   ```

2. **Verify CR applied:**

   ```bash
   kubectl get aap aap -n aap-operator -o yaml | grep -A2 "portal:"
   # Expected output:
   #   portal:
   #     disabled: false
   ```

3. **Check portal pods:**

   ```bash
   kubectl get pods -n aap-operator | grep portal
   # Should show portal-related pods when ready
   ```

4. **Verify portal route:**

   ```bash
   kubectl get routes -n aap-operator | grep portal
   # Portal route should be created by operator
   ```

5. **Test portal access:**

   ```bash
   aap-demo status
   # Portal route and credentials should be shown
   ```

### With Existing Deployment

1. **Enable on existing AAP:**

   ```bash
   kubectl patch aap aap -n aap-operator --type merge -p '{"spec":{"portal":{"disabled":false}}}'
   ```

2. **Watch portal startup:**

   ```bash
   aap-demo watch
   # Monitor portal pods appearing
   ```

## Architecture Notes

### CR Pattern Consistency

The portal implementation follows AAP's established CR pattern:

```yaml
spec:
  component:
    disabled: true/false
    # component-specific config
```

This pattern is used by:

- `controller.disabled`
- `eda.disabled`
- `hub.disabled`
- `portal.disabled` (new)

### Operator Responsibilities

The AAP operator handles:

- Pod creation (portal server, API, UI)
- Service and route generation
- Database schema initialization (uses shared PostgreSQL)
- Integration with existing components (controller, hub, eda)
- Network policy and RBAC setup

### Storage Requirements

Portal uses:

- **Shared PostgreSQL:** Database tables in AAP's PostgreSQL instance
- **No additional PVCs:** Portal is stateless with DB backend
- **Existing NFS:** If needed for shared files, uses hub's nfs-local-rwx

### Routes and Access

Portal access:

- **Route:** Auto-created by operator (e.g., `aap-portal-aap-operator.apps.127.0.0.1.nip.io`)
- **Credentials:** Same as AAP gateway (`admin` user from `aap-admin-password` secret)
- **Integration:** Portal UI links to controller, hub, and eda

## Known Limitations

1. **Operator version:** Portal requires AAP operator 2.7+
2. **Resource requirements:** Portal adds ~2GB memory overhead
3. **Storage class:** RWX storage (nfs-local-rwx) recommended for hub file storage

## Troubleshooting

### Portal pods not starting

```bash
# Check operator logs
kubectl logs -l app.kubernetes.io/managed-by=aap-gateway-operator -n aap-operator --tail=50

# Check portal pod status
kubectl get pods -n aap-operator | grep portal
kubectl describe pod <portal-pod-name> -n aap-operator
```

### Portal route not accessible

```bash
# Verify route exists
kubectl get routes -n aap-operator

# Check CoreDNS (portal needs DNS resolution)
aap-demo diagnose

# Test from inside cluster
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
  curl -I https://<portal-route>
```

### Portal not showing in AAP CR

```bash
# Check if portal spec was applied
kubectl get aap aap -n aap-operator -o jsonpath='{.spec.portal}'

# If missing, patch manually
kubectl patch aap aap -n aap-operator --type merge -p '{"spec":{"portal":{"disabled":false}}}'
```

## References

- [GitHub Issue #18](https://github.com/RedHatOfficial/aap-demo/issues/18)
- [AAP 2.7 Self-Service Portal Docs](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.7/install-assembly_self_service_about) (requires Red Hat login)
- [AAP Operator Customization](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.6/html/installing_on_openshift_container_platform/assembly-operator-customize-aap)
- Existing aap-demo CR templates: `config/crs/aap-*.yaml`

## Implementation Checklist

- [x] Created portal CR template (`aap-with-portal.yaml`)
- [x] Implemented `aap-demo portal` command
- [x] Updated `aap-demo help` output
- [x] Added README documentation
- [x] Committed to `self-service-portal` branch
- [ ] Test deployment on live cluster
- [ ] Verify portal pods start successfully
- [ ] Confirm portal route is accessible
- [ ] Validate integration with controller/hub/eda
- [ ] Create pull request to main branch

## Next Steps

1. **Test on live cluster:**
   - Deploy: `aap-demo portal`
   - Verify all portal pods reach Running state
   - Access portal UI via route

2. **Validate integration:**
   - Log into portal with admin credentials
   - Test workflow catalog functionality
   - Verify controller/hub connectivity

3. **Document edge cases:**
   - Upgrade path (minimal → with-portal)
   - Portal-only deployment (disable controller/eda)
   - Custom portal configuration options

4. **Create PR:**
   - Push branch: `git push origin self-service-portal`
   - Open PR against main
   - Link to issue #18
   - Include validation screenshots
