# Verify the Windows installer preserves the Python default and Bash compatibility command.
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
if ($installer -notmatch '\$LegacyShim' -or $installer -notmatch 'powershell\.exe .*powershell\\aap-demo\.ps1') {
  throw 'The installer must forward the legacy compatibility launcher through powershell/aap-demo.ps1'
}

Write-Output 'PowerShell installer launcher checks passed'
