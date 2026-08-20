# Compliance Dashboard Addon

Adds the Compliance Dashboard plugin to the Ansible Automation Portal (RHDH).

> **Note:** The compliance plugin is currently in **prototype/preview** status. It downloads
> artifacts from the `feat/2216-compliance-pipelines` branch of `ansible/ansible-rhdh-plugins`.

## Prerequisites

- Portal addon deployed (`aap-demo enable portal`)
- Local registry addon deployed (`aap-demo enable registry`)
- `gh` CLI authenticated (`gh auth login`)
- `skopeo` installed

## Installation

```bash
./deploy.sh
```

## What it does

1. Downloads the latest compliance plugin OCI artifact from GitHub Actions
2. Pushes the plugin image to the local registry
3. Configures insecure registry access for the portal init container (required for MicroShift HTTP registries)
4. Updates the portal's `dynamic-plugins` configmap with compliance plugin entries
5. Updates the portal's `app-config` configmap with `ansible.compliance` settings
6. Restarts the portal to apply changes

## Accessing

After installation, navigate to:

```
https://redhat-rhaap-portal-redhat-rhaap-portal.apps.127.0.0.1.nip.io/compliance
```

Or click "Compliance" in the portal sidebar (security shield icon).

## Features

- Infrastructure compliance scanning for RHEL 9 STIG, CIS L1/L2, and SBOM profiles
- Findings review and selective remediation
- Integration with AAP job templates for scanning and remediation

## Removal

```bash
./deploy.sh --delete
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "gh CLI not authenticated" | Run `gh auth login` |
| "Portal not deployed" | Run `aap-demo enable portal` first |
| "Registry not found" | Run `aap-demo enable registry` first |
| Plugin not appearing in sidebar | Check portal logs: `kubectl logs -n redhat-rhaap-portal -l app.kubernetes.io/component=backstage` |
| Blank compliance page | Verify `ansible.compliance.enabled: true` in app-config |

## References

- [ansible-backstage-plugins][plugins] - Plugin source (feature branch)
- [Compliance Dashboard Installation Guide][guide] - Detailed manual installation steps

[plugins]: https://github.com/ansible/ansible-backstage-plugins/tree/feat/2216-compliance-pipelines
[guide]: ../../docs/Compliance_Dashboard_Installation_Guide_v3.md
