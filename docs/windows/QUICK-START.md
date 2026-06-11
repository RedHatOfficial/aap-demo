# aap-demo on Windows — Quick Start

PowerShell-native install. Requires Windows 10/11 with Hyper-V and [OpenShift Local](https://console.redhat.com/openshift/create/local).

See [ARCHITECTURE.md](./ARCHITECTURE.md) for the full design and phased implementation plan.

## Prerequisites

1. Enable Hyper-V and install OpenShift Local (`crc setup` may require reboot)
2. Install `oc` and `kubectl` — add to PATH
3. Save pull secret to `%USERPROFILE%\.aap-demo\pull-secret.txt`
4. PowerShell 7+ (`pwsh`)

## Install

```powershell
git clone https://github.com/ansible-automation-platform/aap-demo.git
cd aap-demo
.\powershell\Install.ps1
# Restart shell or: $env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
aap-demo help
```

## Deploy

```powershell
aap-demo create    # Create CRC MicroShift cluster (~15 min first run)
aap-demo deploy    # Deploy AAP 2.7
aap-demo status    # Routes and credentials
```

## Common commands (phase 1)

```powershell
aap-demo stop
aap-demo start
aap-demo destroy
$env:QUIET = 'true'; aap-demo destroy   # Skip confirmation wait
$env:NAMESPACE = 'aap-operator'; aap-demo deploy
```

## Troubleshooting

- **Hyper-V permissions:** User must be in Hyper-V Administrators; reboot after `crc setup`
- **CA trust warnings:** Run PowerShell as Administrator on first `create`, or import ingress CA manually
- **kubectl not connecting:** `$env:KUBECONFIG = "$env:USERPROFILE\.crc\machines\crc\kubeconfig"`

For bash/macOS/Linux, use `./install.sh` and `aap-demo.sh` at the repo root.
