# APME plugin OCI pack

APME deploy pushes this OCI archive to the local registry and lets the standard portal
Helm chart run `install-dynamic-plugins`.

To use a different plugin build, replace the archive and update `plugin-pack.manifest.yml`.
