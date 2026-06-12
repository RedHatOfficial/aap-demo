#Requires -Version 5.1
<#
.SYNOPSIS
  Delegates to aap-demo.sh via Git Bash (fallback for commands not yet in PowerShell).
#>
[CmdletBinding()]
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Arguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-AapDemoRepoRoot {
  $marker = Join-Path $env:USERPROFILE '.aap-demo\repo-path'
  if (-not (Test-Path -LiteralPath $marker)) {
    throw @"
aap-demo is not installed.

From the aap-demo repo directory run:
  .\powershell\install.ps1
"@
  }

  $root = (Get-Content -LiteralPath $marker -Raw).Trim()
  if (-not (Test-Path -LiteralPath (Join-Path $root 'aap-demo.sh'))) {
    throw "Repo path invalid or moved: $root`nRe-run .\powershell\install.ps1 from the repo."
  }
  return $root
}

function Find-GitBash {
  $candidates = @(
    (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

  if ($candidates.Count -eq 0) {
    throw @"
Git Bash not found.

Install Git for Windows: https://git-scm.com/download/win
Required for this command (not yet implemented in PowerShell).
"@
  }
  return $candidates[0]
}

$repoRoot = Get-AapDemoRepoRoot
$bashExe = Find-GitBash

$env:HOME = $env:USERPROFILE

$userBin = Join-Path $env:USERPROFILE '.local\bin'
if ((Test-Path -LiteralPath $userBin) -and ($env:Path -notlike "*$userBin*")) {
  $env:Path = "$userBin;$env:Path"
}

if (-not $env:KUBECONFIG) {
  $defaultKube = Join-Path $env:USERPROFILE '.crc\machines\crc\kubeconfig'
  if (Test-Path -LiteralPath $defaultKube) {
    $env:KUBECONFIG = $defaultKube
  }
}

$scriptWin = Join-Path $repoRoot 'aap-demo.sh'
& $bashExe $scriptWin @Arguments
exit $LASTEXITCODE
