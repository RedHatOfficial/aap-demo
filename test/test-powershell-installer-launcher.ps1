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
if ($installer -notmatch '\$LegacyShim' -or $installer -notmatch 'bash .*aap-demo\.sh') {
  throw 'The installer must preserve the legacy Bash compatibility launcher'
}

Write-Output 'PowerShell installer launcher checks passed'
