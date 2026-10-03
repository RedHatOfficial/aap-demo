# Verify the Windows installer cannot leave a policy-blocked .ps1 command ahead of the .cmd shim.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$installer = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'powershell/install.ps1') -Raw

if ($installer -match '(?s)Set-Content\s+-LiteralPath\s+\$WrapperTarget') {
  throw 'The installer still creates a .ps1 launcher that PowerShell may block before resolving the .cmd shim'
}
if ($installer -notmatch 'Remove-Item\s+-LiteralPath\s+\$WrapperTarget\s+-Force') {
  throw 'The installer must remove stale .ps1 launchers during installation'
}
if ($installer -notmatch 'ExecutionPolicy Bypass' -or $installer -notmatch '\$CmdShim') {
  throw 'The installer .cmd shim must invoke PowerShell with ExecutionPolicy Bypass'
}

Write-Output 'PowerShell installer launcher checks passed'
