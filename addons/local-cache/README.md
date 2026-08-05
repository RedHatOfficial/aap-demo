# Local Cache Addon

Saves AAP container images from a running CRC VM to disk so you can reload them after
`aap-demo destroy` / `aap-demo create` without re-pulling ~30 GB from registries.

## Usage

```bash
# Save images from a running cluster (after aap-demo deploy)
aap-demo enable local-cache

# Load cached images into a fresh cluster (also runs automatically during deploy when enabled)
aap-demo enable local-cache load

# Delete the on-disk cache
aap-demo disable local-cache
# or: aap-demo enable local-cache clear
```

## Cache location

Images are stored per CRC preset:

```text
~/.aap-demo/local-cache/microshift/
```

Each image is saved as `<md5>.tar` plus a `<md5>.ref` sidecar with the original image reference.

## Prerequisites

- CRC cluster running with AAP deployed (for **save**)
- CRC cluster running (for **load**)
- SSH access to the CRC VM (port 2222)
- ~30 GB free disk space for a full AAP image set

## Notes

- **Save** adds `local-cache` to `~/.aap-demo/config` so deploy auto-loads on future runs.
- **Load** and **clear** are one-shot actions and do not change the saved addon list.
- `aap-demo destroy` clears `ADDONS=` from config but keeps on-disk cache files.

### After destroy and recreate

`destroy` removes the cluster and clears the enabled-addon list, but cached tarballs remain
under `~/.aap-demo/local-cache/microshift/`. To reuse them:

```bash
aap-demo create
aap-demo enable local-cache load   # load images into the fresh VM
aap-demo enable local-cache        # re-register auto-load for future deploys
aap-demo deploy
```

See [ADR-021](../../docs/adr/021-local-cache-addon.md) for design details.
