# Satellite Manifest Addon

Creates and downloads a Red Hat Satellite subscription manifest programmatically
via the RHSM management API, so the [satellite-lab](../../satellite-lab/README.md)
content stage (`03-content-hammer.sh`) does not need a manual portal download.

## Usage

```bash
# Create (or reuse) the allocation and download the manifest
aap-demo enable satellite-manifest

# Override the allocation name or Satellite version
MANIFEST_NAME=my-lab MANIFEST_SAT_VERSION=sat-6.17 aap-demo enable satellite-manifest
```

The manifest is written to `~/.aap-demo/satellite/manifest.zip` (mode 600).

## How it works

The addon reuses the credential Vault's Red Hat offline token (the same
`rhsm-api` exchange the fleet addon uses for image downloads) and drives the
RHSM management API:

1. **Find-or-create** the subscription allocation (`aap-demo-satellite` by
   default) at the requested Satellite version.
2. **Trigger an export job** for the allocation.
3. **Poll** the export job until the manifest is ready.
4. **Download** the signed `manifest.zip`.

A freshly created allocation has no subscriptions attached. Add Satellite
infrastructure + RHEL entitlements before the manifest is useful:
console.redhat.com → Subscriptions → Subscription Allocations →
`<allocation-name>` → Add subscriptions. (Entitlement auto-attach is
account-specific and not automated here.)

## Prerequisites

- A Red Hat offline token in the credential Vault (`aap-demo fleet auth` sets
  this up; the same token is reused).
- The Red Hat account must hold the **"View/Renew Subscription Information"**
  permission. Without it the RHSM allocations API returns `401`/`403` and the
  addon stops with guidance. Grant it under console.redhat.com → Settings →
  User Access → Users → your user → Subscription Management role.

## Use with the Satellite lab

```bash
scp ~/.aap-demo/satellite/manifest.zip root@192.168.122.20:/root/manifest.zip
ssh root@192.168.122.20 'cd satellite-lab && ./03-content-hammer.sh /root/manifest.zip'
```

## Notes

- Re-running the addon reuses an existing allocation with the same name and
  re-exports the manifest, so it is safe to run repeatedly.
- The manifest contains subscription credentials; the file is created with
  mode 600 and should be treated as sensitive.
