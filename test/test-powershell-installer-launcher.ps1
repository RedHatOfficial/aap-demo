# Verify the Windows installer delegates launch and setup behavior to Python.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$installer = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'powershell/install.ps1') -Raw
$setup = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/aap_demo/setup.py') -Raw

if ($installer -match '(?s)Set-Content\s+-LiteralPath\s+\$WrapperTarget') {
  throw 'The installer still creates a .ps1 launcher that PowerShell may block before resolving the .cmd shim'
}
if ($installer -notmatch 'src\\aap_demo\\setup\.py' -or $installer -notmatch 'Get-OrBootstrapPython') {
  throw 'The installer must bootstrap Python and locate the Python setup module'
}
if ($installer -notmatch '&\s+\$python\s+@arguments') {
  throw 'The installer must invoke the Python setup module with the selected Python runtime'
}
if ($installer -notmatch '\|\s*Out-Host') {
  throw 'Winget output must not leak into the Python executable returned by the bootstrap function'
}
if ($setup -notmatch 'aap-demo\.ps1') {
  throw 'Python setup must remove stale PowerShell wrappers'
}

Write-Output 'PowerShell Python bootstrap checks passed'
