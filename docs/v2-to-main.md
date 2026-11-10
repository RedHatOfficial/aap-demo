# v2 to main

People installing the product should start at the [guides](guides/index.md), not here.
This note is the install and state-path record for proposing the Python release candidate on `v2` as `main`.
It does not change either install. The package version is `2.0.0rc2`.

As of 29 October 2026 the draft pull request into `main` is
[#264](https://github.com/RedHatOfficial/aap-demo/pull/264).
The fleet flag work in [#261](https://github.com/RedHatOfficial/aap-demo/pull/261) is already merged.
The inventory of bash `main` against Python `v2`, and this note, are already in that draft.

`main` at `55ff2dd` is the bash release. `v2` at `8726739` is the Python beta.
Those commits are the baseline for this note. Later commits on `v2` do not move the paths below.

## If you clone main today

`main` is the supported release. Install from a checkout:

```bash
git clone https://github.com/RedHatOfficial/aap-demo.git
cd aap-demo
./install.sh
```

`./install.sh` links `~/.local/bin/aap-demo` to `aap-demo.sh`. Put a pull secret in `~/.aap-demo` before `deploy`:

```bash
mkdir -p ~/.aap-demo
cp ~/Downloads/pull-secret.txt ~/.aap-demo/pull-secret.txt
```

Cluster credentials are `~/.aap-demo/kubeconfig.microshift`. They are not merged into `~/.kube/config`.
`aap-demo update` pulls the latest code and reinstalls. `./install.sh --uninstall` removes the command
and leaves `~/.aap-demo` in place.

Bash `enable fleet` on `main` is the QEMU addon. That branch has no `--backend` flag and no `v2` subcommand.

## If you use v2

`v2` is a release candidate. The supported release line remains `main`.

Install the published release candidate with pipx. pip and uv install the same release:

```bash
pipx install aap-demo
pip install aap-demo
uv tool install aap-demo
```

Check out `v2` only to change the code. `./install.sh` on `v2` still installs the bash command at
`~/.local/bin/aap-demo`. pipx installs the Python command on that same path, so move or remove the bash
command first. Do not use `mkdir ~/.aap-demo` for the Python tool.

### Migrating from bash to Python

If you have the bash version installed via `./install.sh`, you'll encounter a symlink conflict when installing
the Python package with pipx:

```
⚠️  File exists at /Users/user/.local/bin/aap-demo and points to /path/to/aap-demo.sh, not /Users/user/Library/Application
    Support/pipx/venvs/aap-demo/bin/aap-demo. Not modifying.
  installed package aap-demo 2.0.0rc2, installed using Python 3.15.2
  These apps are now available
    - aap-demo (symlink missing or pointing to unexpected location)
done! ✨ 🌟 ✨
```

The old symlink at `~/.local/bin/aap-demo` points to the bash script, but pipx wants to create its own symlink
to the Python package entry point.

**To resolve this:**

1. Remove the old symlink:

   ```bash
   rm ~/.local/bin/aap-demo
   ```

2. Reinstall the Python package so pipx creates the correct symlink:

   ```bash
   pipx reinstall aap-demo
   ```

3. Verify the Python version is active:

   ```bash
   aap-demo version
   # Should show: 2.0.0rc2
   ```

Your bash checkout remains untouched. You can still run `./aap-demo.sh` directly from the repository if needed,
but the `aap-demo` command in your PATH now points to the Python version.

After that, `./install.sh` (and `install.sh --uninstall`) leaves the Python command in place and prints
how to switch back: remove it with `pipx uninstall aap-demo` (or `pip uninstall aap-demo`), then rerun `./install.sh`.

Python state is strict XDG on every OS. With the defaults (`XDG_*` unset):

| What | Path |
|---|---|
| Pull secret, console download | `~/.local/state/aap-demo/pull-secret.txt` |
| Pull secret, reserved state file | `~/.local/state/aap-demo/pull-secret.json` |
| Kubeconfig | `~/.local/state/aap-demo/kubeconfig.microshift` |
| Ingress CA | `~/.local/state/aap-demo/certs/crc-ingress-ca.crt` |
| Config | `~/.config/aap-demo/config.yaml` |
| Cache | `~/.cache/aap-demo` |

`XDG_STATE_HOME`, `XDG_CONFIG_HOME`, and `XDG_CACHE_HOME` move those roots. `AAP_DEMO_DIR` collapses
config, cache, and state under one directory. That is the escape hatch for CI and for a migration overlap.
It is not the path for a normal install. Python also finds a pull secret or manifest in `~/.aap-demo`, after the
config and state directories, so one file can serve both commands.

`src/aap_demo/__init__.py` sets `__version__ = "2.0.0rc2"`.

Python `enable fleet` is Kubernetes-native: pods in namespace `fleet`. `--no-import` skips AAP registration.
Bash `enable fleet` on `v2` stays on the QEMU addon unless the command passes `--backend kube-native`.

## What stays true on merge day

- The release candidate wording stays until Adam says otherwise. Do not rewrite the README so that this tree
  claims to be the supported release.
- The version is `2.0.0rc2`. Do not publish `2.0.0`. A push to `main` runs the PyPI workflow only when
  `src/aap_demo/__init__.py` changes, and PyPI keeps each version forever. That trigger lands when this
  cutover merges.
  This merge does not upload again, because the workflow skips a version already on PyPI. It fails on
  anything other than a 2.0.0 pre-release: `2.0.0.devN`, `2.0.0aN`, `2.0.0bN`, or `2.0.0rcN`.
- `aap-demo.sh`, `includes/`, and the bash addon deployers stay. Removing them is separate work, not this cutover.
- QEMU stays the bash fleet default. Python fleet stays Kubernetes-native.
- Contributors branch from `main` and open pull requests against it. `CONTRIBUTING.md` already says so.
  Until this cutover merges, keep sending pull requests for the Python command to `v2`.

## The pull request into main

Draft [#264](https://github.com/RedHatOfficial/aap-demo/pull/264) is already open from `v2` into `main`.
The inventory and this note are done.
[#261](https://github.com/RedHatOfficial/aap-demo/pull/261) is merged, so the bash fleet flags are on `v2`.

Leave the pull request in draft. Adam merges it with a merge commit after the team has reviewed it.
Do not squash `v2` into `main`.
