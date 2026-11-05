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
  $belowMinimum = $false
  try {
    & $module { Assert-AapCrcStoragePair -Disk '30' -PvSize '20' }
  } catch {
    if ($_.Exception.Message -notmatch 'at least 31') { throw }
    $belowMinimum = $true
  }
  if (-not $belowMinimum) { throw 'Disk below 31GB must be rejected' }
} finally {
  if ($null -eq $oldDisk) { Remove-Item Env:CRC_DISK -ErrorAction SilentlyContinue } else { $env:CRC_DISK = $oldDisk }
  if ($null -eq $oldPv) { Remove-Item Env:CRC_PV_SIZE -ErrorAction SilentlyContinue } else { $env:CRC_PV_SIZE = $oldPv }
}

$isolatedRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('aap-demo-crc-storage-' + [guid]::NewGuid().ToString('n'))
$isolatedBin = Join-Path $isolatedRoot 'bin'
$isolatedHome = Join-Path $isolatedRoot 'home'
$isolatedLog = Join-Path $isolatedRoot 'crc.log'
$isolatedRunner = Join-Path $isolatedRoot 'reject-crc-storage.ps1'
New-Item -ItemType Directory -Force -Path $isolatedBin, $isolatedHome | Out-Null
if ($env:OS -eq 'Windows_NT') {
  @(
    '@echo off'
    '>>"%AAP_DEMO_TEST_CRC_LOG%" echo %*'
    'echo %* | findstr /C:"config set disk-size 32" >nul && exit /b 1'
    'echo %* | findstr /C:"config set persistent-volume-size 16" >nul && exit /b 1'
    'exit /b 0'
  ) | Set-Content -LiteralPath (Join-Path $isolatedBin 'crc.cmd') -Encoding ascii
} else {
  $crcPath = Join-Path $isolatedBin 'crc'
  @(
    '#!/bin/sh'
    'printf "%s\n" "$*" >> "$AAP_DEMO_TEST_CRC_LOG"'
    'case "$*" in'
    '  "config set disk-size 32") exit 1 ;;'
    '  "config set persistent-volume-size 16") exit 1 ;;'
    '  *) exit 0 ;;'
    'esac'
  ) | Set-Content -LiteralPath $crcPath -Encoding ascii
  chmod +x $crcPath
}
@(
  '$ErrorActionPreference = "Stop"'
  '$env:USERPROFILE = $env:AAP_DEMO_TEST_HOME'
  '$env:PATH = $env:AAP_DEMO_TEST_BIN + [IO.Path]::PathSeparator + $env:PATH'
  '$crcCommand = Get-Command crc -ErrorAction Stop'
  'if ($crcCommand.Source -notlike ($env:AAP_DEMO_TEST_BIN + [IO.Path]::DirectorySeparatorChar + "*")) {'
  '  throw "Refusing to run crc outside the test double: $($crcCommand.Source)"'
  '}'
  '$module = Import-Module $env:AAP_DEMO_MODULE -Force -PassThru'
  '& $module { Set-AapConfigValue "CRC_DISK" "120"; Set-AapConfigValue "CRC_PV_SIZE" "70" }'
  '$rejected = $false'
  'try { & $module { Set-AapCrcStorageConfig -Disk "30" -PvSize "20" } } catch {'
  '  if ($_.Exception.Message -notmatch "at least 31") { throw }'
  '  $rejected = $true'
  '}'
  'if (-not $rejected) { throw "30/20 must be rejected before crc config set" }'
  'if (Test-Path -LiteralPath $env:AAP_DEMO_TEST_CRC_LOG) {'
  '  $earlyLog = Get-Content -LiteralPath $env:AAP_DEMO_TEST_CRC_LOG -Raw'
  '  if ($earlyLog -match "disk-size 30") { throw "30GB disk must not be sent to crc" }'
  '}'
  '$rejected = $false'
  'try { & $module { Set-AapCrcStorageConfig -Disk "32" -PvSize "16" } } catch {'
  '  if ($_.Exception.Message -notmatch "not changed") { throw }'
  '  $rejected = $true'
  '}'
  'if (-not $rejected) { throw "crc must be able to reject a locally valid disk" }'
  '$configPath = Join-Path $env:USERPROFILE ".aap-demo/config"'
  '$config = Get-Content -LiteralPath $configPath -Raw'
  'if ($config -notmatch "CRC_DISK=120") { throw "saved disk changed: $config" }'
  'if ($config -match "CRC_DISK=32") { throw "rejected disk was saved: $config" }'
  '$rejected = $false'
  'try { & $module { Set-AapCrcStorageConfig -Disk "40" -PvSize "16" } } catch {'
  '  if ($_.Exception.Message -notmatch "persistent volume") { throw }'
  '  $rejected = $true'
  '}'
  'if (-not $rejected) { throw "crc must be able to reject a locally valid PV size" }'
  '$config = Get-Content -LiteralPath $configPath -Raw'
  'if ($config -match "CRC_DISK=40" -or $config -match "CRC_PV_SIZE=16") { throw "rejected PV size was saved: $config" }'
  '$log = Get-Content -LiteralPath $env:AAP_DEMO_TEST_CRC_LOG -Raw'
  'if ($log -notmatch "disk-size 40") { throw "expected the requested disk to be sent to crc" }'
  'if ($log -notmatch "disk-size 120") { throw "expected the previous disk to be restored after a PV rejection" }'
) | Set-Content -LiteralPath $isolatedRunner -Encoding ascii
$env:AAP_DEMO_TEST_HOME = $isolatedHome
$env:AAP_DEMO_TEST_BIN = $isolatedBin
$env:AAP_DEMO_TEST_CRC_LOG = $isolatedLog
$env:AAP_DEMO_MODULE = Join-Path $repoRoot 'powershell/native/AapDemo.psm1'
try {
  $powershellExe = (Get-Process -Id $PID).Path
  & $powershellExe -NoProfile -File $isolatedRunner
  if ($LASTEXITCODE -ne 0) { throw 'Rejected CRC storage was saved or applied' }
} finally {
  Remove-Item Env:\AAP_DEMO_TEST_HOME, Env:\AAP_DEMO_TEST_BIN, Env:\AAP_DEMO_TEST_CRC_LOG, Env:\AAP_DEMO_MODULE -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $isolatedRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'PowerShell deploy prerequisite checks passed'
