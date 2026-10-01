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

foreach ($label in @('Git Bash', 'CRC', 'oc or kubectl', 'jq', 'Python')) {
  if ($missing -notcontains $label) {
    throw "Deploy preflight did not report missing ${label}: $($missing -join ', ')"
  }
}

$complete = @(& $module {
  Get-AapWindowsDeployPrerequisiteFailures `
    -GitBashPath 'C:\Program Files\Git\bin\bash.exe' `
    -CrcPath 'C:\Program Files\crc\crc.exe' `
    -KubernetesPath 'C:\Program Files\oc\oc.exe' `
    -JqPath 'C:\Program Files\jq\jq.exe' `
    -PythonPath 'C:\Program Files\Python313\python.exe'
})
if ($complete.Count -ne 0) {
  throw "Deploy preflight reported false failures: $($complete -join ', ')"
}

$wrapperSource = Get-Content (Join-Path $repoRoot 'powershell/aap-demo.ps1') -Raw
if ($wrapperSource -notmatch 'Assert-AapWindowsDeployPrerequisites' -or
    $wrapperSource -notmatch "'deploy', 'deploy-all', 'redeploy', 'redeploy-all'") {
  throw 'PowerShell wrapper must preflight every deploy-family command'
}
if ($wrapperSource -notmatch '\$isDemoEnable' -or
    $wrapperSource -notmatch "'ao', 'product-demos', 'product-demos-base'") {
  throw 'PowerShell wrapper must preflight AO and product-demos enablement'
}
$prerequisiteSource = Get-Content (Join-Path $repoRoot 'powershell/native/Private/Prerequisites.ps1') -Raw
if ($prerequisiteSource -notmatch 'Ensure-AapJq' -or
    $prerequisiteSource -notmatch 'Ensure-AapPython' -or
    $prerequisiteSource -notmatch 'jqlang\.jq' -or
    $prerequisiteSource -notmatch 'Python\.Python\.3\.13') {
  throw 'Windows deploy preflight must attempt to install jq and Python via winget'
}

Write-Output 'PowerShell deploy prerequisite checks passed'
