# ADR-032: APME Local OCI Plugin Publishing

**Status**: Accepted

**Date**: 2026-10-07

**Authors**: aap-demo maintainers

## Context

The `apme-eap` addon publishes a bundled dynamic-plugin OCI archive to the in-cluster registry
before installing the Ansible Portal Helm release. In OpenShift Local, the registry is exposed
through an OpenShift Route. Registry API requests can therefore return HTTP redirects, including
when starting blob uploads or writing manifests.

The portal's runtime plugin installer also expects a repository path that includes the plugin
image name. Publishing the archive to a shorter repository such as `apme:<version>` leaves the
portal requesting a different reference, `apme/apme-prototype-plugins:<version>`, and the portal
init container fails with `manifest unknown`.

The deployment must also work with newer Ansible versions. Standalone boolean values in Ansible
`when` expressions are subject to stricter conditional handling, and the `kubernetes.core.k8s_exec`
module is not usable in the APME execution environment used by this addon.

## Decision

The APME OCI publisher will:

1. Follow registry redirects for blob existence checks, blob upload starts, blob writes, and
   manifest requests.
2. Publish the bundled archive to the full repository path
   `apme/apme-prototype-plugins:<version>`.
3. Use explicit `== true` and `== false` comparisons for standalone boolean Ansible conditions.
4. Use `kubectl exec` through `ansible.builtin.command` for gateway API seeding, while retaining
   the pod's in-cluster network context.

The local registry remains a development-only registry, and the OpenShift Route hostname remains
the public-facing reference used by the portal and CRI-O configuration.

## Consequences

### Positive

- APME enablement works when the local registry API responds with Route redirects.
- The portal and publisher use the same OCI repository reference.
- The playbooks remain compatible with strict Ansible conditional evaluation.
- Gateway seeding does not depend on the unavailable `kubernetes.core.k8s_exec` client path.
- Redirect handling and repository wiring are covered by focused regression tests.

### Negative

- The publisher must manage redirected connections and preserve the registry authentication
  headers across requests.
- The repository path is now a deployment contract that must stay aligned with the portal chart's
  runtime installer configuration.
- `kubectl` is required in the execution environment for gateway seeding.

### Neutral

- The registry is still intended only for local/demo deployments and is not a production registry.
- The bundled archive remains versioned by the APME plugin version.

## Alternatives Considered

### Disable redirects at the registry route

Rejected. The route and registry behavior are part of the local OpenShift environment, and the
client should correctly handle normal OCI Distribution API redirects.

### Publish to the short `apme` repository

Rejected. The portal requests `apme/apme-prototype-plugins`, so the shorter path causes a runtime
manifest lookup failure.

### Continue using `kubernetes.core.k8s_exec`

Rejected. The module fails internally in the execution environment before it can run the gateway
request. `kubectl exec` provides the same pod-local execution context with the tools already used
by the addon.

## References

- [APME addon README](../../addons/apme-eap/README.md)
- [In-Cluster Container Registry](013-in-cluster-registry.md)
- [APME Playbook Addon](019-apme-playbook-addon.md)
- [APME Pre-Built Portal Hub Deployment](022-apme-prebuilt-portal-hub.md)
- [PR #218](https://github.com/RedHatOfficial/aap-demo/pull/218)
