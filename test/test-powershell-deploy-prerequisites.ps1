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
$helperSource = Get-Content (Join-Path $repoRoot 'powershell/native/Private/Helpers.ps1') -Raw
$deploySource = Get-Content (Join-Path $repoRoot 'powershell/native/Private/Deploy.ps1') -Raw
if ($prerequisiteSource -notmatch 'Ensure-AapJq' -or
    $prerequisiteSource -notmatch 'Ensure-AapPython' -or
    $helperSource -notmatch "'python3', 'python', 'py'" -or
    $helperSource -notmatch 'Programs\\Python\\Python\*\\python\.exe' -or
    $helperSource -notmatch 'Add-AapPythonRuntimePath' -or
    $prerequisiteSource -notmatch 'jqlang\.jq' -or
    $prerequisiteSource -notmatch 'Python\.Python\.3\.12') {
  throw 'Windows deploy preflight must discover installed Python and attempt winget installation when needed'
}

$deployFunctionStart = $deploySource.IndexOf('function Invoke-AapDemoDeploy')
$deployFunction = $deploySource.Substring($deployFunctionStart)
$storageCheckIndex = $deployFunction.IndexOf('Assert-AapStoragePrerequisites -CrName $CrName')
$olmInstallIndex = $deployFunction.IndexOf('Install-AapOlm')
if ($storageCheckIndex -lt 0 -or $olmInstallIndex -lt 0 -or $storageCheckIndex -ge $olmInstallIndex) {
  throw 'PowerShell deploy must validate AAP storage before installing OLM'
}
if ($deploySource -match 'nfs-local-rwx missing - applying CR with ReadWriteOnce fallback') {
  throw 'PowerShell deploy must fail clearly instead of silently changing the requested storage mode'
}

$createSource = Get-Content (Join-Path $repoRoot 'powershell/native/Private/Create.ps1') -Raw
if ($createSource -notmatch 'Disk in GB' -or $createSource -notmatch 'Persistent volume storage in GB') {
  throw 'Windows create must prompt for disk and persistent-volume size'
}
if ($wrapperSource -notmatch "'create', 'storage'") {
  throw 'Windows wrapper must keep aap-demo storage interactive'
}
$oldDisk = $env:CRC_DISK
$oldPv = $env:CRC_PV_SIZE
try {
  $env:CRC_DISK = '160'
  $env:CRC_PV_SIZE = '90'
  $resolved = & $module { Get-AapResolvedCrcStorage }
  if ($resolved.Disk -ne '160' -or $resolved.PvSize -ne '90') {
    throw "Resolved storage was $($resolved.Disk)/$($resolved.PvSize)"
  }
  & $module { Assert-AapCrcStoragePair -Disk '160' -PvSize '90' }
  $rejected = $false
  try {
    & $module { Assert-AapCrcStoragePair -Disk '90' -PvSize '90' }
  } catch {
    $rejected = $true
  }
  if (-not $rejected) { throw 'Equal disk and PV size must be rejected' }
} finally {
  if ($null -eq $oldDisk) { Remove-Item Env:CRC_DISK -ErrorAction SilentlyContinue } else { $env:CRC_DISK = $oldDisk }
  if ($null -eq $oldPv) { Remove-Item Env:CRC_PV_SIZE -ErrorAction SilentlyContinue } else { $env:CRC_PV_SIZE = $oldPv }
}

Write-Output 'PowerShell deploy prerequisite checks passed'
