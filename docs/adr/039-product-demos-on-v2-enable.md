# ADR-039: Product Demos Run from the New Enable Command

**Status**: Accepted

**Date**: 2026-11-06

**Authors**: aap-demo maintainers

## Context

`aap-demo enable product-demos` on the 2.0 command stopped with
`unknown addon 'product-demos'; only fleet is implemented`. The installer
itself was already in `addons/product-demos/deploy.sh` and worked from the
bash command. People who installed the published command, deployed AAP, and
then enabled product demos never reached that installer. The cluster and the
laptop were not involved.

The product-demos installers are large shell scripts that talk to the AAP API.
Rewriting them in Python in the same change would fork a path the bash command
still uses.

## Decision

`enable` and `disable` for the product-demos family run the existing
`addons/<name>/deploy.sh` scripts.

- `fleet` stays the Python addon.
- The new command passes its kubeconfig, namespace, and the enabled-addon list
  into the script. `AAP_DEMO_WIRE_AFTER_DEPLOY=0` keeps the script from
  sourcing `includes/addon-wire.sh`, which a wheel does not contain. After a
  successful install, a small wiring script sets the APD AAP, OpenShift, and
  Galaxy credentials. A wiring failure does not roll back the install.
- The wheel ships the product-demos addon directories so `pipx install aap-demo`
  can run the command. A checkout uses `addons/` in the repo.
- Any other addon name is still an error, and the message names
  `aap-demo-v1 enable <name>`.
- The scripts treat `AAP_DEMO_ENABLED_ADDONS` the same way they treat
  `~/.aap-demo/config`, so a second domain install does not repeat the base
  installer, and disabling the base installer still refuses while a domain is
  enabled.

## Consequences

### Positive

- `aap-demo enable product-demos` installs the demos on a cluster the new
  command already deployed.
- The bash installer remains the one implementation of the install.

### Negative

- Product demos need `bash`, `curl`, and `jq` on the computer. macOS does not
  ship jq.
- The wheel grows by the product-demos scripts, playbooks, and patches.
- Automation Orchestrator wiring still belongs to the bash `wire` command.
  This path only refreshes the APD credentials.

### Neutral

- Portal, the MCP server, and the other bash addons stay on `aap-demo-v1`
  until each one moves.

## Alternatives Considered

### Tell people to run `aap-demo-v1 enable product-demos`

Rejected. That was already documented, and the error did not say it. The
reported command is the one the guides now show for the new command.

### Reimplement the installer in Python

Rejected for this change. The shell installer is the behavior we need to
preserve, including project sync, job launch, and the subscription check.

## References

- [Issue #328](https://github.com/RedHatOfficial/aap-demo/issues/328)
- [ADR-008](008-addon-system.md)
- [ADR-018](018-product-demos-addon.md)
- [ADR-023](023-addon-auto-wiring.md)
