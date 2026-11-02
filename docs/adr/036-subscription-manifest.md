# ADR-036: Apply a Subscription Manifest Only When Asked

**Status**: Accepted

**Date**: 2026-11-01

**Authors**: aap-demo maintainers

---

## Context

AAP refuses to add hosts without a subscription, which stops Fleet from registering its nodes.
The bash `subscription-attach` addon runs after every deploy, using a Red Hat username and
password. The Python command had no equivalent.

Applying a subscription uses its capacity, and some users have little to spare.

## Decision

`deploy` looks for a manifest, in this order: `--manifest`, `AAP_DEMO_MANIFEST`, or the
`deploy.manifest_path` setting, then the newest `manifest*.zip` in the config directory, then in
the state directory. The file is only read. It is not moved, copied, or linked.

If AAP has no subscription and a manifest is found:

- `--auto-license`, `AAP_DEMO_AUTO_LICENSE`, or `deploy.auto_license` applies it. The default is off.
- Otherwise `deploy` asks in a terminal, and the answer defaults to no.
- With no terminal, or with `--yes`, it does not apply it and says how to.

A missing or rejected manifest is a note or a warning, not a failed deploy, because AAP works
without one. The pull secret gets the same two search folders.

## Consequences

### Positive

- No Red Hat password is stored or prompted for.
- A file can be dropped in `~/.config/aap-demo/`, which is easy to create.
- Nothing uses a subscription without an explicit choice.

### Negative

- Reads a credential into the process, which the pull secret avoids.
- A second place to look for each file, which `deploy` reports for the manifest.

### Neutral

- An AAP that already has a subscription is left alone.
- The bash addon is unchanged.

## Alternatives Considered

### Port the username and password flow

Requires storing Red Hat account credentials.

### Move the file into the state directory, or link it

Files that change location are confusing, and a move or link adds failure modes without a benefit,
because AAP stores the subscription once it is applied.

### Apply automatically by default

Could use up capacity the user meant for something else.

## References

- [ADR-032: Fleet v2 Addon](032-fleet-v2-addon.md)
