# AAP + Red Hat Lightspeed integration notes

## Dynamic inventory (two supported patterns)

1. **Built-in source (recommended for demos):** AAP Controller ships a
   `Red Hat Satellite 6` credential type and inventory source — no custom EE
   needed. `aap-controller-config.yml` automates exactly that. UI equivalent:
   Credentials → Add → type *Red Hat Satellite 6*; then Inventories →
   *Satellite Fleet* → Sources → Add → source *Red Hat Satellite 6*.

2. **Plugin config (`foreman-inventory.yml`):** use when you need custom
   grouping/filters. Requires the `theforeman.foreman` collection in the
   Execution Environment, then either `ansible-inventory -i foreman-inventory.yml`
   or an SCM-sourced inventory in Controller.

Groups you get for free (with the keyed_groups in `foreman-inventory.yml`):
`hg_hg_rhel9_prod`, `hg_hg_rhel10_prod`, `os_RedHat_9_5`, `os_RedHat_10_0`,
`domain_demo_lab` — ideal `limit:` targets for job templates.

## Red Hat Lightspeed (Ansible code generation) targeting Satellite hosts

"Red Hat Lightspeed" is the unified brand covering Insights **and** Ansible
Lightspeed (with IBM watsonx Code Assistant). Setup for this lab:

1. **Service**: with an AAP subscription, use the hosted Ansible Lightspeed
   (activate + assign seats in the admin portal on console.redhat.com), or
   deploy Ansible Lightspeed on-premise connected to IBM watsonx Code
   Assistant if the lab must stay disconnected.
2. **Authoring**: install the **Ansible** VS Code extension, sign in with your
   Red Hat account, and use playbook generation / task generation. Generated
   content lands in a Git project that AAP syncs as a Project.
3. **Targeting Satellite-registered hosts**: create Job Templates that pair the
   generated playbooks with the **Satellite Fleet** inventory and a `limit:`
   (or smart inventory) built from the Satellite groups above — e.g. generate a
   "harden sshd" playbook with Lightspeed, then run it against
   `hg_hg_rhel10_prod`. Survey/launch-time limits make this fully self-service.
4. **Closed loop**: Insights findings (via `rhc`, see `06-integrations.sh`)
   → Lightspeed-generated remediation playbook → AAP job template →
   Satellite dynamic inventory → REX/SSH execution, with results visible in
   both AAP and the Satellite host pages.
