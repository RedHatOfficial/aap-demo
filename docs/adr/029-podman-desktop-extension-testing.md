# ADR-029: Podman Desktop Extension Testing and Local Development

**Status**: Accepted

**Date**: 2026-10-02

**Authors**: aap-demo maintainers

## Context

The AAP Demo Podman Desktop extension has two compiled outputs:

- `dist/extension.js` for the extension host
- `media/` for the dashboard webview

Podman Desktop loads the JavaScript entry declared by the extension's
`package.json`; it does not execute the TypeScript source directly. Requiring a
manual production build after every source edit slows UI iteration and makes it
easy to test a stale extension directory.

The extension also needs two levels of confidence:

1. Fast automated checks for parsing, command execution, protocol handling, and
   UI presentation helpers.
2. A local Podman Desktop smoke test against a real `aap-demo` environment,
   including status, prerequisites, routes, credentials, and add-on controls.

## Decision

Use a watcher-backed local extension workflow plus automated checks.

### Automated checks

Run these from `podman-desktop-extension/`:

```bash
npm test
npm run typecheck
npm run build
```

Vitest covers the command runner, service actions, executable resolution,
status parsing, prerequisites, dashboard protocol, and add-on presentation.
TypeScript validation catches host and webview API mistakes. The production
build confirms that both extension outputs can be generated.

### Local Podman Desktop iteration

Use the existing watch script while developing:

```bash
npm run watch
```

The watcher continuously rebuilds both `dist/` and `media/`. Podman Desktop
development mode should load the `podman-desktop-extension/` folder through
**Extensions → Local Extensions → Add a local folder extension**. After a
backend change, stop and start the local extension if Podman Desktop does not
reload the extension host automatically. Reopen the AAP Demo dashboard after a
webview change.

For a one-shot build and Podman Desktop launch from the repository root, use:

```bash
aap-demo podman-extension
```

The command installs Node.js/npm with Homebrew when needed, installs extension
dependencies, and builds both outputs. The first local-folder registration
remains a one-time UI step because Podman
Desktop does not expose a supported CLI for enabling an arbitrary local folder.

### OCI image packaging

For environments that should not install Node.js/npm on the host, use the
standalone image build script:

```bash
./podman-desktop-extension/build-image.sh
```

It builds `localhost/aap-demo-podman-extension:dev` from the extension's
`Containerfile` and prints the **Install custom...** steps. The image uses a
`scratch` runtime and contains the compiled extension assets; the extension
continues to invoke the host `aap-demo` and CRC executables. Catalog publication
is outside this ADR.

The repository also provides a manual/tagged GitHub Actions workflow that
publishes the image to GHCR as
`ghcr.io/redhatofficial/aap-demo-podman-desktop-extension`. It grants the job
`packages: write` permission and uses `GITHUB_TOKEN`; package visibility and
release governance remain repository-owner decisions.

### Manual smoke test

The smoke test is documented in
[`podman-desktop-extension/TESTING.md`](../../podman-desktop-extension/TESTING.md)
and must cover:

- extension activation and dashboard opening;
- running/stopped cluster status and prerequisite results;
- create/deploy actions when a disposable environment is available;
- route opening and masked credential display/copy;
- alphabetical add-on controls and enable/disable state changes;
- command output and failure messages.

Destructive operations such as destroy are opt-in and must not be used against
an environment containing data that needs to be preserved.

## Consequences

### Positive

- Source edits are rebuilt automatically during local development.
- Automated checks remain fast and repeatable.
- The manual smoke test exercises the actual Podman Desktop host/webview
  boundary and the real CLI environment.
- The workflow explains common stale-build, restricted-PATH, and missing-CLI
  failures.

### Negative

- The watch process must remain running during UI development.
- Full smoke testing requires Podman Desktop, `aap-demo`, CRC, a pull secret,
  and sufficient memory.
- Live create, deploy, and destroy tests remain slower and potentially
  destructive.

### Neutral

- The extension supports local-folder development and OCI image installation;
  catalog publication remains outside this ADR.
- CLI-level testing remains governed by [ADR-014](014-testing-strategy.md).

## Alternatives Considered

### Manual `npm run build` for every edit

Rejected for normal iteration: it is easy to forget and produces stale UI
behavior during development. It remains a valid final verification command.

### Opening `src/webview/index.html` directly

Rejected: a `file://` page does not provide the Podman Desktop host bridge, so
commands, status messages, and external-link handling cannot be tested there.

### Testing only with a packaged OCI image

Rejected for development: packaging adds registry and image-build overhead and
does not provide the fastest feedback loop. It remains appropriate for release
distribution.

## References

- [Podman Desktop extension testing guide](../../podman-desktop-extension/TESTING.md)
- [Podman Desktop local extension debugging](https://podman-desktop.io/docs/extensions/debugging-an-extension)
- [Podman Desktop extension development](https://podman-desktop.io/docs/extensions/developing)
- [ADR-014: CLI Testing Strategy](014-testing-strategy.md)
