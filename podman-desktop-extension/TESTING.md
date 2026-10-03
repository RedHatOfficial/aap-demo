# Testing the AAP Demo Podman Desktop extension

This guide covers automated checks and local testing through Podman Desktop.
The dashboard must be opened from the installed local extension; opening
`src/webview/index.html` directly with `file://` does not provide the Podman
Desktop host bridge.

## Prerequisites

- Podman Desktop 1.12 or newer
- Node.js 24 or newer
- `aap-demo` installed and usable from the shell
- OpenShift Local (CRC) installed
- A Red Hat pull secret at a known path
- At least 16 GiB available to the CRC environment

For a full live smoke test, create or use a disposable AAP Demo environment.
Do not destroy an environment that contains data you need.

## Automated checks

From this directory:

```bash
npm install
npm test
npm run typecheck
npm run build
```

The test suite is non-destructive. It does not create or destroy a cluster.

## Build and open from the AAP Demo CLI

From the repository root, use the helper command to install Node.js/npm with
Homebrew when needed, install missing extension dependencies, build both
extension outputs, and open Podman Desktop:

```bash
aap-demo podman-extension
```

The first run still requires the one-time Podman Desktop setup below because
Podman Desktop does not provide a supported CLI for registering an arbitrary
local extension folder. Once the folder is registered, rerunning the command
rebuilds the extension and the local-extension watcher can reload it.

Set `AAP_DEMO_PODMAN_EXTENSION_SKIP_NPM_INSTALL=true` to disable automatic
Node.js/npm installation in CI or another managed environment.

## Build an OCI extension image

To build the extension without installing npm on the host, use the standalone
container build script from the repository root:

```bash
./podman-desktop-extension/build-image.sh
```

Pass a different image name as the first argument when needed.

This uses the extension `Containerfile` and defaults to:

```text
localhost/aap-demo-podman-extension:dev
```

The script prints the image name. In Podman Desktop, open
**Extensions → Install custom...**, enter that image name, and install it.
The container contains the compiled extension assets; the extension still calls
the host `aap-demo` and CRC executables at runtime.

## Local development without manually rebuilding

Start the continuous compiler:

```bash
npm run watch
```

Keep this terminal open. It rebuilds the extension host output in `dist/` and
the webview output in `media/` whenever source files change.

In Podman Desktop:

1. Open **Settings → Preferences → Extensions**.
2. Enable **Development mode**.
3. Open **Extensions → Local Extensions**.
4. Select **Add a local folder extension...**.
5. Choose this directory:

   ```text
   /Users/cferman/Documents/GitHub/aap-demo/podman-desktop-extension
   ```

6. Start the extension and confirm it is **ACTIVE**.
7. Open **AAP Demo Dashboard** from the navigation or the status bar.

After backend changes, stop and start the local extension if the extension host
does not reload. After webview changes, close and reopen the dashboard. If the
dashboard still shows old markup, confirm the watch terminal rebuilt the files
and reload the local extension.

## Manual smoke test

### Dashboard and status

1. Open the AAP Demo dashboard from Podman Desktop.
2. Confirm the **Status** box shows the cluster state, infrastructure, and
   last-updated time.
3. Confirm prerequisites appear inside the Status box:
   - CRC executable and resolved path;
   - pull-secret path and existence;
   - available memory and the minimum.
4. Click **Refresh status** and confirm the timestamp and command output update.

### Lifecycle actions

Use a disposable environment for state-changing tests.

1. Click **Create cluster** when no cluster exists and confirm streamed output.
2. Click **Deploy AAP** after the cluster is ready.
3. Refresh status and confirm routes, credentials, and add-ons appear.
4. Use **Diagnose** and confirm command output is shown.
5. Test **Set idle** and confirm it changes to **Wake AAP**.
6. Use **Destroy cluster** only when cleanup is explicitly intended.

If the cluster already exists and should be preserved, limit the test to
**Refresh status**, **Diagnose**, and read-only dashboard checks.

### Add-ons

1. Confirm add-ons are displayed alphabetically.
2. Confirm enabled add-ons are green and disabled add-ons are grey.
3. Confirm the helper text says `green means enabled and grey means disabled`.
4. Click an add-on toggle and confirm it becomes temporarily unavailable while
   the command runs.
5. Refresh status and confirm the add-on state changed.

### Routes and credentials

1. Click each AAP route and confirm it opens in the default browser.
2. Confirm credentials are masked initially.
3. Use **Show**/**Hide** to reveal and re-mask a credential.
4. Use **Copy** and confirm the button reports **Copied**.

## Troubleshooting

### Manifest metadata error

The selected folder must contain the extension `package.json` with `name`,
`displayName`, `version`, `publisher`, and `description`. Select the
`podman-desktop-extension` folder, not the repository parent or `src` folder.

### `spawn ... ENOENT`

Podman Desktop may have a smaller `PATH` than your terminal. Set the full path
in **Settings → Extensions → AAP Demo**:

```text
aap-demo.cliPath = /Users/cferman/.local/bin/aap-demo
```

Alternatively, use the configured path supported by your installation and
restart the local extension.

### Status says not running even though CRC is running

Check the CLI and CRC directly from a terminal:

```bash
aap-demo status
crc status -o json
```

Then verify `aap-demo.crcPath` points to the actual CRC executable and refresh
the dashboard.

### Changes are not visible

Confirm `npm run watch` is still running, then:

1. Check that `dist/extension.js` or `media/index.html` has a recent timestamp.
2. Stop and start the local extension from the Extensions page.
3. Reopen AAP Demo Dashboard.

### Host bridge unavailable

Do not test by opening the HTML file directly. Open the dashboard from the
active Podman Desktop extension so the `acquirePodmanDesktopApi()` bridge is
available.

## Cleanup

Stop the watcher with `Ctrl-C` when finished. Stop the local extension from the
Podman Desktop Extensions page if it should no longer run.
