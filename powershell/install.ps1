#Requires -Version 5.1
<#
.SYNOPSIS
  Install aap-demo on Windows.

.DESCRIPTION
  Checks prerequisites, records repo location, installs aap-demo to
  %USERPROFILE%\.local\bin, adds that directory to the user PATH, and
  installs optional dependencies (oc, Git for Windows) via winget when missing.

.EXAMPLE
  .\powershell\install.ps1

.EXAMPLE
  .\powershell\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
  [switch]$Uninstall,
  [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ConfigDir = Join-Path $env:USERPROFILE '.aap-demo'
$BinDir = Join-Path $env:USERPROFILE '.local\bin'
$RepoMarker = Join-Path $ConfigDir 'repo-path'
$WrapperTarget = Join-Path $BinDir 'aap-demo.ps1'
$CmdShim = Join-Path $BinDir 'aap-demo.cmd'

function Write-Info([string]$Message) { Write-Host "  $Message" }
function Write-Ok([string]$Message) { Write-Host "  OK $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "  WARN $Message" -ForegroundColor Yellow }
function Write-Err([string]$Message) { Write-Host "  ERROR $Message" -ForegroundColor Red }

function Test-CommandExists {
  param([string]$Name)
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Find-GitBash {
  $paths = @(
    (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
  return $paths | Select-Object -First 1
}

function Install-Oc {
  if (Test-CommandExists 'oc') {
    Write-Ok 'oc already on PATH'
    return
  }

  if (-not (Test-CommandExists 'winget')) {
    Write-Warn 'oc not found and winget is unavailable'
    return
  }

  Write-Info 'Installing oc via winget (RedHat.OpenShift-Client)...'
  $wingetArgs = @(
    'install', '--id', 'RedHat.OpenShift-Client', '-e', '--source', 'winget',
    '--accept-package-agreements', '--accept-source-agreements'
  )
  if ($Quiet) { $wingetArgs += '--disable-interactivity' }

  try {
    & winget @wingetArgs
    if ($LASTEXITCODE -ne 0) {
      Write-Warn "winget install RedHat.OpenShift-Client failed (exit $LASTEXITCODE)"
      return
    }
  } catch {
    Write-Warn "Could not install oc via winget: $($_.Exception.Message)"
    return
  }

  $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = @($machinePath, $userPath) -join ';'

  if (Test-CommandExists 'oc') {
    Write-Ok 'oc installed via winget'
  } else {
    Write-Warn 'OpenShift Client installed but oc is not on PATH yet — open a new PowerShell window'
  }
}

function Install-GitBash {
  if (Find-GitBash) {
    Write-Ok 'Git Bash already installed'
    return
  }

  if (-not (Test-CommandExists 'winget')) {
    Write-Warn 'Git Bash not found and winget is unavailable'
    return
  }

  Write-Info 'Installing Git for Windows via winget (Git.Git)...'
  $wingetArgs = @(
    'install', '--id', 'Git.Git', '-e', '--source', 'winget',
    '--accept-package-agreements', '--accept-source-agreements'
  )
  if ($Quiet) { $wingetArgs += '--disable-interactivity' }

  try {
    & winget @wingetArgs
    if ($LASTEXITCODE -ne 0) {
      Write-Warn "winget install Git.Git failed (exit $LASTEXITCODE)"
      return
    }
  } catch {
    Write-Warn "Could not install Git for Windows via winget: $($_.Exception.Message)"
    return
  }

  $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = @($machinePath, $userPath) -join ';'

  if (Find-GitBash) {
    Write-Ok 'Git Bash installed via winget'
  } else {
    Write-Warn 'Git for Windows installed but bash.exe not found yet — open a new PowerShell window'
  }
}

function Install-OperatorSdk {
  if (Test-CommandExists 'operator-sdk') {
    Write-Ok 'operator-sdk already on PATH'
    return
  }

  Write-Ok 'operator-sdk not installed on Windows host (no official Windows binary)'
  Write-Info 'OLM is installed on the CRC Linux VM automatically during aap-demo create'
}

function Get-UserPathEntries {
  $raw = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
  return $raw -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

function Add-UserPathEntry {
  param([Parameter(Mandatory)][string]$Directory)

  $entries = Get-UserPathEntries
  $normalized = [System.IO.Path]::GetFullPath($Directory)
  if ($entries -contains $normalized) { return $false }

  $newPath = if ($entries.Count -eq 0) { $normalized } else { ($entries + $normalized) -join ';' }
  [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
  $env:Path = "$normalized;$env:Path"
  return $true
}

function Remove-UserPathEntry {
  param([Parameter(Mandatory)][string]$Directory)

  $normalized = [System.IO.Path]::GetFullPath($Directory)
  $entries = Get-UserPathEntries | Where-Object { $_ -ne $normalized }
  [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')
}

function Test-Prerequisites {
  $missing = [System.Collections.Generic.List[string]]::new()
  $warnings = [System.Collections.Generic.List[string]]::new()

  if (-not (Find-GitBash)) {
    $warnings.Add('Git for Windows — needed for diagnose, test, watch, and other advanced commands')
  }

  foreach ($tool in @('crc', 'oc')) {
    if (-not (Test-CommandExists $tool)) {
      $missing.Add($tool)
    }
  }

  foreach ($tool in @('jq', 'python', 'python3', 'ansible-playbook')) {
    if (-not (Test-CommandExists $tool)) {
      $warnings.Add($tool)
    }
  }

  if (-not (Test-CommandExists 'operator-sdk')) {
    $warnings.Add('operator-sdk (not required on Windows; OLM installs via CRC VM during create)')
  }

  return [PSCustomObject]@{
    Missing  = $missing
    Warnings = $warnings
  }
}

function Ensure-PullSecretHint {
  $secretPaths = @(
    (Join-Path $ConfigDir 'pull-secret.txt'),
    (Join-Path $ConfigDir 'pull-secret.json'),
    (Join-Path $ConfigDir 'pull-secret')
  )

  foreach ($path in $secretPaths) {
    if (Test-Path -LiteralPath $path) {
      Write-Ok "Pull secret found: $path"
      return
    }
  }

  Write-Warn 'No pull secret in %USERPROFILE%\.aap-demo\'
  Write-Info 'Download from https://console.redhat.com/openshift/install/pull-secret'
  Write-Info "Save as: $((Join-Path $ConfigDir 'pull-secret.txt'))"
}

function Install-AapDemo {
  Write-Host ''
  Write-Host 'Installing aap-demo for Windows...' -ForegroundColor Cyan
  Write-Host ''

  if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'aap-demo.sh'))) {
    throw "Run install.ps1 from the aap-demo repo (expected aap-demo.sh in $RepoRoot)"
  }

  Install-Oc
  Install-GitBash

  $checks = Test-Prerequisites
  if ($checks.Missing.Count -gt 0) {
    Write-Err 'Missing required tools:'
    foreach ($item in $checks.Missing) { Write-Info "- $item" }
    Write-Host ''
    Write-Info 'OpenShift Local (crc): https://console.redhat.com/openshift/create/local'
    Write-Info 'oc: winget install --id RedHat.OpenShift-Client -e --source winget'
    throw 'Install missing prerequisites and re-run install.ps1'
  }

  Write-Ok 'Required tools: crc, oc'

  if (Find-GitBash) {
    Write-Ok 'Git Bash available for advanced commands'
  } else {
    Write-Warn 'Git Bash not found — create/deploy/status work; other commands need Git for Windows'
  }

  if ($checks.Warnings.Count -gt 0 -and -not $Quiet) {
    Write-Warn 'Optional tools not found (deploy may still work):'
    foreach ($item in $checks.Warnings) { Write-Info "- $item" }
  }

  New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
  New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

  Set-Content -LiteralPath $RepoMarker -Value $RepoRoot -NoNewline -Encoding ascii
  Write-Ok "Repo registered: $RepoRoot"

  @(
    '#Requires -Version 5.1'
    '$repo = (Get-Content -LiteralPath "$env:USERPROFILE\.aap-demo\repo-path" -Raw).Trim()'
    '& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo ''powershell\aap-demo.ps1'') @args'
    'exit $LASTEXITCODE'
  ) | Set-Content -LiteralPath $WrapperTarget -Encoding ascii
  Write-Ok "Launcher installed: $WrapperTarget"

  @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.local\bin\aap-demo.ps1" %*
"@ | Set-Content -LiteralPath $CmdShim -Encoding ascii
  Write-Ok "CMD shim installed: $CmdShim"

  if (Add-UserPathEntry -Directory $BinDir) {
    Write-Ok 'Added %USERPROFILE%\.local\bin to user PATH'
  } else {
    Write-Ok 'PATH already contains %USERPROFILE%\.local\bin'
  }

  Install-OperatorSdk
  Ensure-PullSecretHint

  Write-Host ''
  Write-Host 'Done.' -ForegroundColor Green
  Write-Host ''
  Write-Info 'Open a new PowerShell window, then:'
  Write-Info '  aap-demo help'
  Write-Info '  aap-demo create'
  Write-Info '  aap-demo deploy'
  Write-Host ''
  Write-Info 'Notes:'
  Write-Info '- create, deploy, status, diagnose run in PowerShell.'
  Write-Info '- Other commands (diagnose --ai, test, watch, ...) use Git Bash via aap-demo.sh.'
  Write-Info '- OpenShift Local on Windows needs Hyper-V enabled.'
  Write-Info '- Kubeconfig default: %USERPROFILE%\.crc\machines\crc\kubeconfig'
  Write-Host ''
}

function Uninstall-AapDemo {
  Write-Host ''
  Write-Host 'Uninstalling aap-demo...' -ForegroundColor Cyan
  Write-Host ''

  Remove-Item -LiteralPath $WrapperTarget -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $CmdShim -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $RepoMarker -Force -ErrorAction SilentlyContinue

  Write-Ok 'Removed wrapper, shim, and repo marker'
  Write-Info 'VM data under %USERPROFILE%\.aap-demo\ and %USERPROFILE%\.crc\ was NOT removed'
  Write-Host ''
}

if ($Uninstall) {
  Uninstall-AapDemo
} else {
  Install-AapDemo
}
