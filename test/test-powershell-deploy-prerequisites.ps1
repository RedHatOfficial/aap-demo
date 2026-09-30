# Verify deploy commands fail early with actionable Windows prerequisite errors.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $repoRoot 'powershell/native/AapDemo.psm1') -Force -PassThru

$missing = @(& $module {
  Get-AapWindowsDeployPrerequisiteFailures `
    -GitBashPath '' `
    -CrcPath '' `
    -KubernetesPath ''
})

foreach ($label in @('Git Bash', 'CRC', 'oc or kubectl')) {
  if ($missing -notcontains $label) {
    throw "Deploy preflight did not report missing ${label}: $($missing -join ', ')"
  }
}

$complete = @(& $module {
  Get-AapWindowsDeployPrerequisiteFailures `
    -GitBashPath 'C:\Program Files\Git\bin\bash.exe' `
    -CrcPath 'C:\Program Files\crc\crc.exe' `
    -KubernetesPath 'C:\Program Files\oc\oc.exe'
})
if ($complete.Count -ne 0) {
  throw "Deploy preflight reported false failures: $($complete -join ', ')"
}

$wrapperSource = Get-Content (Join-Path $repoRoot 'powershell/aap-demo.ps1') -Raw
if ($wrapperSource -notmatch 'Assert-AapWindowsDeployPrerequisites' -or
    $wrapperSource -notmatch "'deploy', 'deploy-all', 'redeploy', 'redeploy-all'") {
  throw 'PowerShell wrapper must preflight every deploy-family command'
}

Write-Output 'PowerShell deploy prerequisite checks passed'
