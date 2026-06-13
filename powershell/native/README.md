# PowerShell module (Windows)



PowerShell implementation of aap-demo commands on Windows. Installed via

`.\powershell\install.ps1` as the `aap-demo` command.



## Commands



All commands run in PowerShell via `AapDemo.psm1`. Git Bash is only used for `diagnose --ai`.



## Layout



```

powershell/

  aap-demo.ps1           # CLI router

  install.ps1

  native/

    AapDemo.psm1

    Private/

      Helpers.ps1

      Create.ps1

      Deploy.ps1

      Status.ps1

      Diagnose.ps1

      Watch.ps1

      Addons.ps1         # enable/disable (mcp-server)

      Commands.ps1       # stop, destroy, clean, kubeconfig, ...

```



## Install



```powershell

.\powershell\install.ps1

```



## Gaps vs bash



- No gateway capability patch loop during deploy

- No podman remote connection setup

- `cmd_config` in bash is a stub; PowerShell adds get/set support

- `cmd_update` missing in bash; implemented in PowerShell as `aap-demo update`



## Ingress CA trust



`create`, `deploy`, and `status` auto-trust the MicroShift ingress CA on Windows

(user + system certificate stores). See [../README.md](../README.md).

