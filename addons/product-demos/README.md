# Product Demos

Installs [Ansible Product Demos](https://github.com/ansible/product-demos) domains in one command.

## Usage

```bash
aap-demo enable product-demos
```

This runs `product-demos-base` and then installs five domains via dedicated AAP job templates:

- `APD | Install Linux Demos`
- `APD | Install Windows Demos`
- `APD | Install Network Demos`
- `APD | Install Cloud Demos`
- `APD | Install OpenShift Demos`

Each template runs `setup_demo.yml` for one domain so you can see per-domain job history and failures in the UI.

The Python command also requires an existing, ready Kubernetes-native Fleet pod and its AAP inventory
and machine credential. It enables Automation Orchestrator (AO) as needed and creates Fleet-specific
disk-check and disk-and-service workflows. The latter uses the Product Demos Linux shell playbook to
start a temporary `aap-demo-fleet-smoke.service`; the service expires after five minutes. If no AO
LLM provider is configured, setup uses `none` without prompting. The other imported workflows are
reported individually because their Fleet adaptations or external integrations are still pending.

`Fleet | disk-demo-101` keeps the source workflow's disk-usage switch and checks the Fleet pod's
`/var` volume. The healthy branch records that no action is needed. The warning branch runs the
upstream disk-cleanup playbook in **check mode**, so it previews cleanup without deleting files.
Its reported removed-file counts and reclaimed space are estimates of candidates, not actual changes.
The critical and fallback branches deliberately fail the AO workflow to flag manual intervention;
open the linked AAP job output for the explanation. This adaptation does not expand a Fleet PVC.
Mattermost notifications are not sent.

The legacy shell command does not yet provide the same Fleet integration.

### Verify the Fleet workflow

From a repository checkout, set `AO_API_TOKEN` in your environment to an AO token with workflow
execution permission. Supply the AO workflow ID and manual trigger ID from the workflow, the Fleet
namespace and pod, and the CA certificate for your AO route:

```bash
python scripts/ao-fleet-smoke.py \
  --ao-url "https://<ao-route>/api/v1" \
  --workflow-id "<fleet-disk-and-service-workflow-id>" \
  --trigger-id "trigger_manual" \
  --namespace fleet --pod deployment/fleet-ubi10 \
  --service aap-demo-fleet-smoke.service --expected-state active \
  --ca-file "<ingress-ca-file>"
```

The test requires the service to be inactive before it starts. It launches the workflow, checks that
the service job completed successfully, and verifies that the pod service changed to active. Wait for
the temporary service to expire before repeating the test.

**Satellite is not included by default** — it requires a real Satellite server and causes the domain
install job to fail when placeholders are used. Install it separately when ready (see below).

Deploy automatically removes legacy `APD | Install Domain Demo` templates and duplicate
`Ansible Product Demos` projects in the Default org (setup jobs sometimes recreate them).

## Customization

Install a subset of domains:

```bash
PRODUCT_DEMOS_DOMAINS="linux cloud" aap-demo enable product-demos
```

Include Satellite in bulk install (only if you have a configured Satellite server):

```bash
PRODUCT_DEMOS_DOMAINS="linux windows network cloud openshift satellite" aap-demo enable product-demos
```

Use a custom fork or branch (inherited by base):

```bash
PRODUCT_DEMOS_REPO=https://github.com/myorg/product-demos \
PRODUCT_DEMOS_BRANCH=main \
  aap-demo enable product-demos
```

## Disable

```bash
aap-demo disable product-demos
```

Demo job templates remain in AAP until removed manually from the UI.
The Fleet-specific AO workflows and AAP templates currently also require manual cleanup; disabling
product-demos leaves AO running.

## Satellite domain

Install Satellite demos when you have a reachable Red Hat Satellite server:

```bash
aap-demo enable product-demo-satellite
```

Or include `satellite` in `PRODUCT_DEMOS_DOMAINS` after updating credentials.

1. Update **Satellite Credential** and **Satellite Inventory** in the **Ansible Product Demos (APD)** org.
2. Run **SETUP | Satellite** from the Templates page (or re-launch **APD | Install Satellite Demos**).
3. Sync the **Satellite Inventory** source on **Ansible Product Demos Inventory**.

Full Satellite configuration steps: [`../product-demo-satellite/README.md`](../product-demo-satellite/README.md).

## Individual domains

To install one domain only, use the matching addon instead:

```bash
aap-demo enable product-demo-linux
```
