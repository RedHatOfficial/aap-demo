# EDA Playground Addon

Deploys [EDA Playground](https://github.com/BBGrimmett2/EDA-Playground) into a
dedicated namespace in the local `aap-demo` cluster. The application provides
an interactive environment for testing Event-Driven Ansible integrations and
webhook payloads.

## Support and image

This addon is available through the legacy Bash workflow on macOS and Linux.
Python CLI and native Windows support are not included.

The current image is experimental and hosted in the maintainer's personal
GitHub Container Registry namespace. It is not an official Red Hat image.
Set `EDA_PLAYGROUND_IMAGE` to a reviewed image tag or digest before deploying;
the default is `ghcr.io/bbgrimmett2/eda-playground:0.1.0`.

## Prerequisites

- An `aap-demo` cluster running, with `kubectl` connected to it.
- OpenShift Route support. `oc` is optional; when available, the deployer uses
  it to grant the dedicated service account the required `anyuid` SCC.
- AAP OAuth application credentials supplied in the
  `eda-playground-oauth` Kubernetes Secret in the `eda-playground` namespace.
  OAuth provisioning is managed by the addon workflow.

## Usage

From this directory, run `./deploy.sh` to deploy or `./deploy.sh --delete` (or
`./deploy.sh delete`) to remove the addon namespace. The default action is
deploy. The deployer also accepts `EDA_PLAYGROUND_IMAGE` to select a tag or
digest. Set `EDA_PLAYGROUND_NAMESPACE` to use a dedicated custom namespace
for both enable and disable. The CLI's `NAMESPACE` selects the AAP namespace
and does not select the addon namespace.

The generated Route host is based on the cluster's application domain. After
deployment, inspect it with:

```bash
kubectl get route eda-playground -n eda-playground
```

## Configuration

- Namespace: `EDA_PLAYGROUND_NAMESPACE` (default: `eda-playground`). Existing
  namespaces must carry the addon ownership label before deployment can reuse
  them. The AAP namespace and system namespaces are refused.
- Image: `EDA_PLAYGROUND_IMAGE`.
- Application resources: 100m CPU and 128Mi memory requested; 500m CPU and
  512Mi memory limit.
- OAuth client and session values are read from the Kubernetes Secret and are
  not embedded as plain environment values in the Deployment.

The `eda-playground-integrations` ConfigMap provides a mount point for custom
integration definitions. It can be edited with `kubectl` after deployment.

## Troubleshooting and cleanup

Check pod status and logs with `kubectl get pods -n eda-playground` and
`kubectl logs -n eda-playground -l app=eda-playground`. To remove the addon,
run `./deploy.sh --delete`; this deletes only the configured addon namespace.

Source: [EDA Playground](https://github.com/BBGrimmett2/EDA-Playground).
