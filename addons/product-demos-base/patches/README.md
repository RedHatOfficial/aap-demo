# install-apd.yml patch for aap-demo

Upstream [`install-apd.yml`](https://github.com/ansible/product-demos/blob/main/install-apd.yml)
queries the AAP gateway ping API to discover `_aap_version` before loading bootstrap vars.

aap-demo always deploys **AAP 2.7** with a pinned Product Demos EE, so runtime discovery is
unnecessary and fails on MicroShift when job pods use the external HTTPS route.

This patch adds:

```yaml
when: _aap_version is not defined
```

to the version ping and set_fact tasks. aap-demo passes `_aap_version: "2.7"` via job template
extra_vars and overlays [`playbooks/install-apd-aap-demo.yml`](../playbooks/install-apd-aap-demo.yml)
into the synced AAP project.

Submit this change upstream to ansible/product-demos to remove the overlay requirement.
