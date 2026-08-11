# Product Demos

Installs **all** [Ansible Product Demos](https://github.com/ansible/product-demos) domains in one command.

## Usage

```bash
aap-demo enable product-demos
```

This runs `product-demos-base` and then installs every domain via dedicated AAP job templates:

- `APD | Install Linux Demos`
- `APD | Install Windows Demos`
- `APD | Install Network Demos`
- `APD | Install Cloud Demos`
- `APD | Install OpenShift Demos`
- `APD | Install Satellite Demos`

Each template runs `setup_demo.yml` for one domain so you can see per-domain job history and failures in the UI.

Deploy automatically removes legacy `APD | Install Domain Demo` templates and duplicate
`Ansible Product Demos` projects in the Default org (setup jobs sometimes recreate them).

## Customization

Install a subset of domains:

```bash
PRODUCT_DEMOS_DOMAINS="linux cloud" aap-demo enable product-demos
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

Bulk install creates Satellite job templates with **placeholder** credentials
(`https://satellite.example.com`). The auto-launched **SETUP | Satellite** job fails until you
configure a real Satellite server.

1. Update **Satellite Credential** and **Satellite Inventory** in the **Ansible Product Demos (APD)** org.
2. Re-run **SETUP | Satellite** from the Templates page.
3. Sync the **Satellite Inventory** source on **Ansible Product Demos Inventory**.

Skip Satellite during bulk install if you do not have a server yet:

```bash
PRODUCT_DEMOS_DOMAINS="linux windows network cloud openshift" aap-demo enable product-demos
```

Full Satellite configuration steps: [`../product-demo-satellite/README.md`](../product-demo-satellite/README.md).

## Individual domains

To install one domain only, use the matching addon instead:

```bash
aap-demo enable product-demo-linux
```
