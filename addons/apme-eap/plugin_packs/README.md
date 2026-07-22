# Prototype OCI plugin pack (bundled in welcome pack zip)

The welcome pack ships with an OCI archive in this directory. **Do not unzip it** — deploy pushes it to your cluster registry with `skopeo`.

`plugin-pack.manifest.yml` records the bundled `plugin_sha`. Deploy auto-detects the pack and defaults `oci_registry` to the OpenShift integrated registry for your namespace:

```text
image-registry.openshift-image-registry.svc:5000/<namespace>
```

For an external registry (Quay, Harbor), set `oci_registry` and `registry_authfile` in `vars/apme_portal.yml` (paths can be anywhere on your workstation).

> Not the collection `plugins/` directory (Ansible plugin types).
