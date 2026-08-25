# APME Execution Environment (optional)

By default, `apme-eap` uses the shared **Product Demos EE**
(`quay.io/ansible-product-demos/apd-ee-26:latest`) — the same image as
`product-demos-base`. That EE includes `kubernetes.core`, `redhat.openshift`,
`community.general`, and the `oc` CLI required for `oc process --local`.

## Custom EE (forks only)

Build and publish a custom image only when you cannot use Product Demos EE:

```bash
cd addons/apme-eap/execution-environment
ansible-builder build -t apme-ee:latest -f execution-environment.yml
podman tag apme-ee:latest quay.io/yourorg/apme-ee:latest
podman push quay.io/yourorg/apme-ee:latest
```

Override at deploy time:

```bash
APME_EE_IMAGE=quay.io/yourorg/apme-ee:1.0.0 aap-demo enable apme-eap
```

Requires `registry.redhat.io` pull secret for the base EE image.
