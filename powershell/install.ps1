#Requires -Version 5.1
<#
.SYNOPSIS
  Bootstrap Python and delegate aap-demo setup to Python.

.EXAMPLE
  .\powershell\install.ps1

.EXAMPLE
  .\powershell\install.ps1 -Uninstall

.EXAMPLE
  .\powershell\install.ps1 -RollbackToV1
#>
[CmdletBinding()]
param(
  [switch]$Uninstall,
  [switch]$RollbackToV1,
  [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Uninstall -and $RollbackToV1) {
  throw 'Choose either -Uninstall or -RollbackToV1, not both.'
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$SetupScript = Join-Path $RepoRoot 'src\aap_demo\setup.py'
if (-not (Test-Path -LiteralPath $SetupScript -PathType Leaf)) {
  throw "Python setup module was not found: $SetupScript"
}

function Get-PythonCommand {
  foreach ($name in @('python', 'py')) {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($null -eq $command) { continue }

    $version = & $command.Source --version 2>$null
    if ($LASTEXITCODE -eq 0 -and $version -match '^Python (\d+)\.(\d+)') {
      $major = [int]$Matches[1]
      $minor = [int]$Matches[2]
      if ($major -gt 3 -or ($major -eq 3 -and $minor -ge 11)) {
        return $command.Source
      }
    }
  }
  return $null
}

function Refresh-UserPath {
  $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = @($machinePath, $userPath) -join ';'
}

function Get-OrBootstrapPython {
  $python = Get-PythonCommand
  if ($null -ne $python) { return $python }

  $winget = Get-Command winget -ErrorAction SilentlyContinue
  if ($null -eq $winget) {
    throw 'Python 3.11+ is required for pipx. Install Python or install winget, then rerun this bootstrap.'
  }

  Write-Host 'Bootstrapping Python 3.12 with winget...'
  $arguments = @(
    'install', '--id', 'Python.Python.3.12', '-e', '--source', 'winget',
    '--accept-package-agreements', '--accept-source-agreements'
  )
  if ($Quiet) { $arguments += '--disable-interactivity' }
  & $winget.Source @arguments | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "Python bootstrap failed (winget exit $LASTEXITCODE)"
  }

  Refresh-UserPath
  $python = Get-PythonCommand
  if ($null -eq $python) {
    throw 'Python installation finished, but Python 3.11+ was not found. Open a new PowerShell window and rerun.'
  }
  return $python
}

$python = Get-OrBootstrapPython
$action = if ($RollbackToV1) { 'rollback-to-v1' } elseif ($Uninstall) { 'uninstall' } else { 'install' }
$arguments = @($SetupScript, $action, '--repo-root', $RepoRoot)
if ($Quiet) { $arguments += '--quiet' }

& $python @arguments
if ($LASTEXITCODE -ne 0) {
  exit $LASTEXITCODE
}
