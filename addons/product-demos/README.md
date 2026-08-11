# Product Demos

Installs **all** [Ansible Product Demos](https://github.com/ansible/product-demos) domains in one command.

## Usage

```bash
aap-demo enable product-demos
```

This runs `product-demos-base` and then installs every domain via AAP job templates:

- linux
- windows
- network
- cloud
- openshift
- satellite

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

## Individual domains

To install one domain only, use the matching addon instead:

```bash
aap-demo enable product-demo-linux
```
