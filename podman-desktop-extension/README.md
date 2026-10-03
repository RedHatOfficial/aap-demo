# AAP Demo Podman Desktop extension

This directory contains the initial Podman Desktop extension for managing the
local `aap-demo` environment.

## Development

```bash
npm install
npm test
npm run typecheck
npm run build
```

For local UI iteration without manually rebuilding after every edit, use:

```bash
npm run watch
```

From the repository root, `aap-demo podman-extension` installs missing
dependencies, builds the extension, and opens Podman Desktop. On first use,
follow the printed Local Extensions steps to register this folder; subsequent
runs rebuild the registered local extension.

See [TESTING.md](TESTING.md) for the Podman Desktop local-extension setup,
automated checks, smoke tests, and troubleshooting.

The extension reads the `aap-demo.cliPath` setting (default: `aap-demo`), resolves
common user-local install locations such as `~/.local/bin`, and registers the
CLI in Podman Desktop's **CLI Tools** settings. It exposes these command-palette
actions:

- Open the AAP Demo dashboard
- Open the dashboard from the Podman Desktop status bar and see the latest cluster state
- Create, deploy, destroy, diagnose, show status, and toggle the AAP idle state
- View routes, masked credentials, add-on state, and prerequisite readiness
- Enable or disable reported add-ons from the dashboard

The `aap-demo.pullSecretPath` and `aap-demo.memory` settings are passed to the
CLI as `PULL_SECRET_PATH` and `CRC_MEMORY` when commands run. CRC is detected
from the configured `aap-demo.crcPath` or common installation locations.

The dashboard provides lifecycle controls, prerequisite checks, streamed command
output, parsed routes and credentials, add-on controls, and periodic status
refresh. Automatic CLI installation is not yet included; install `aap-demo`
separately or set `aap-demo.cliPath` to its full path. A leading `~` is
expanded to the current user's home directory.

To load the extension locally, enable Podman Desktop development extensions and
point the Local Extensions page at this directory. Keep `npm run watch` running
while iterating so the extension host and webview outputs stay current.
