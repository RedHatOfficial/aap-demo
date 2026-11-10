# EDA Playground Addon

Deploys [EDA Playground](https://github.com/BBGrimmett2/EDA-Playground) into a
dedicated namespace in the local `aap-demo` cluster. The application provides
an interactive environment for testing Event-Driven Ansible integrations and
webhook payloads.

## Support and image

This addon is available through the legacy Bash workflow on macOS and Linux.
Python CLI and native Windows support are not included.
It is experimental and not supported for production use.

The current image is experimental and hosted in the maintainer's personal
GitHub Container Registry namespace. It is not an official Red Hat image.
Review the image before use. The default is the upstream
`ghcr.io/bbgrimmett2/eda-playground:latest` tag. For repeatable deployments,
set `EDA_PLAYGROUND_IMAGE` to a reviewed tag or digest before deploying.

## Prerequisites

- An `aap-demo` cluster running, with `kubectl` connected to it.
- OpenShift Route support. `oc` is optional; when available, the deployer uses
  it to grant the dedicated service account the required `anyuid` SCC.
- The addon provisions its AAP OAuth application and Kubernetes Secret during
  enablement.

## Usage

Use the legacy Bash `aap-demo` command after deploying AAP:

```bash
aap-demo enable eda-playground
kubectl get route eda-playground -n eda-playground
```

From this directory, `./deploy.sh` and `./deploy.sh --delete` (or
`./deploy.sh delete`) provide the same addon lifecycle. Set
`EDA_PLAYGROUND_NAMESPACE` to use a dedicated custom namespace for both enable
and disable. The CLI's `NAMESPACE` selects the AAP namespace and does not select
the addon namespace.

The generated Route host is based on the cluster's application domain. After
deployment, inspect it with:

```bash
kubectl get route eda-playground -n eda-playground
```

Open the Route in a browser and complete AAP Gateway OAuth login manually. The
addon provisions an OAuth application in AAP Gateway and stores its credentials
locally for guarded cleanup. Do not paste the OAuth client secret into a browser
or test output.

When finished with the manual check, remove the addon:

```bash
aap-demo disable eda-playground
```

For the disposable-cluster smoke test, set `AAP_DEMO_RUN_LIVE_TESTS=true` and
run `bash test/test-eda-playground-live.sh`. The live harness waits by default
after enable so you can open the printed Route and complete OAuth before
cleanup. Set `AAP_DEMO_LIVE_NONINTERACTIVE=true` only for unattended checks;
that mode skips the wait and reports OAuth as unverified.

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
run `aap-demo disable eda-playground`. Cleanup removes the owned OAuth
application, its local credential state, and only the configured addon
namespace. If cleanup fails, inspect the error and retry the disable command.

Source: [EDA Playground](https://github.com/BBGrimmett2/EDA-Playground).
