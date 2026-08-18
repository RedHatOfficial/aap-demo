# Deprecated — plugin OCI packs are no longer used

APME deploy uses a **pre-built portal hub container image** with plugins baked in at
build time. Deploy does not push OCI plugin archives or run `install-dynamic-plugins`.

To use a different plugin build, publish a new `portal-hub-eap` image and set
`portal_hub_image` in `~/.aap-demo/apme-eap-vars.yml`.

The `*.oci.tar.gz` files in this directory are retained for reference only.
