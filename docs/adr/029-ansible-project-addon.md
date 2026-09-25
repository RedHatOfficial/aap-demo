# ADR-029: Ansible Project Addon

**Status**: Accepted
**Date**: 2026-09-25
**Authors**: aap-demo maintainers

## Context

Users need a repeatable GitOps/bootstrap path to configure AAP Controller from
an HTTPS Git repository without manually creating credentials, a project,
an inventory, and a job template. The addon must work with the AAP Operator
custom resources and must avoid placing secrets in the repository.

## Decision

Add `addons/ansible-project/` under the addon contract defined by ADR-008 and
expose it as:

```text
aap-demo enable ansible-project <git-url> [project-name]
```

The addon will:

- accept HTTPS Git URLs only and reject SSH URLs;
- use the Git credential helper for the short-lived bootstrap clone;
- render Kubernetes custom resources from Jinja templates;
- create source-control and AAP credentials, a Project, an Inventory, and a
  JobTemplate;
- keep non-secret `project.yml` separate from secret `vault.yml`, and require
  users to encrypt private values with `ansible-vault`;
- support `--delete` cleanup and ignore generated `.auto-*.yml` and
  `.rendered/` files; and
- let the AAP Operator reconcile the resources into Controller objects without
  modifying the core AAP custom resource.

| Artifact | Role |
| --- | --- |
| `project.yml` | Non-secret repository and project configuration |
| `vault.yml` | Credentials and other values that must be encrypted |
| `deploy.sh` | Validation, rendering, apply, and cleanup workflow |
| `templates/*.j2` | AAP Operator custom-resource definitions |

## Consequences

Positive consequences:

- A single command bootstraps a useful AAP Controller project.
- Resources are Kubernetes-native and remain visible to the Operator.
- Git credentials can be supplied through the user's existing credential helper.

Negative consequences:

- HTTPS Git URLs are required; SSH URLs are intentionally unsupported.
- Python, Jinja2, and PyYAML are required for rendering.
- A live AAP installation and the matching Operator custom-resource definitions
  are required for deployment.
- Generated vault data must be explicitly encrypted before it is committed.

## Alternatives Considered

### Manual Controller UI or REST configuration

This does not provide a reproducible GitOps workflow and makes configuration
drift harder to detect.

### SSH Git URLs

SSH would require users to provision and mount keys. HTTPS plus the Git
credential helper keeps the addon self-contained while retaining secure
credential handling.

### Direct `kubectl` manifests without templates

Static manifests cannot represent repository-specific values without either
editing generated files manually or committing secrets. Jinja rendering keeps
inputs separate from generated resources.

## References

- [Ansible Project addon](../../addons/ansible-project/README.md)
- [ADR-008: Addon Architecture](008-addon-system.md)
- [Issue #20](https://github.com/RedHatOfficial/aap-demo/issues/20)
