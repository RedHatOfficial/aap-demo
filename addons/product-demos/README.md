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
