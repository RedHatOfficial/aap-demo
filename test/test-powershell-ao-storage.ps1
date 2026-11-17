[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $repoRoot 'powershell/native/AapDemo.psm1') -Force -PassThru
$statefulset = '{"spec":{"volumeClaimTemplates":[{"metadata":{"name":"data"},"spec":{"resources":{"requests":{"storage":"5Gi"}}}}]}}'
$pvc = '{"spec":{"resources":{"requests":{"storage":"10Gi"}}}}'
$cases = @(
  @{ Name = 'fresh default'; Set = ''; Pvc = ''; Requested = '3Gi'; Expected = '3Gi'; Fail = '' },
  @{ Name = 'fresh override'; Set = ''; Pvc = ''; Requested = '10Gi'; Expected = '10Gi'; Fail = '' },
  @{ Name = 'existing template'; Set = $statefulset; Pvc = $pvc; Requested = '3Gi'; Expected = '5Gi'; Fail = '' },
  @{ Name = 'retained PVC'; Set = ''; Pvc = $pvc; Requested = '3Gi'; Expected = '10Gi'; Fail = '' },
  @{ Name = 'set lookup error'; Set = ''; Pvc = ''; Requested = '3Gi'; Expected = ''; Fail = 'statefulset' },
  @{ Name = 'PVC lookup error'; Set = ''; Pvc = ''; Requested = '3Gi'; Expected = ''; Fail = 'pvc' },
  @{ Name = 'malformed set'; Set = '{"spec":{}}'; Pvc = ''; Requested = '3Gi'; Expected = ''; Fail = '' },
  @{ Name = 'malformed PVC'; Set = ''; Pvc = '{"spec":{}}'; Requested = '3Gi'; Expected = ''; Fail = '' },
  @{ Name = 'unsafe value'; Set = ''; Pvc = ''; Requested = '3Gi|bad'; Expected = ''; Fail = '' }
  @{ Name = 'zero value'; Set = ''; Pvc = ''; Requested = '0Gi'; Expected = ''; Fail = '' }
)
foreach ($case in $cases) {
  $outcome = & $module {
    param($Case)
    $script:StorageCase = $Case
    $originalKubectl = ${function:script:Invoke-AapKubectlNative}
    $originalSetting = ${function:script:Get-AapAoSetting}
    function script:Get-AapAoSetting { param($Name, $Default) return $script:StorageCase.Requested }
    function script:Invoke-AapKubectlNative {
      param([string[]]$Arguments, [switch]$AllowFailure)
      $kind = $Arguments[1]
      $ok = $kind -ne $script:StorageCase.Fail
      $output = if ($kind -eq 'statefulset') { $script:StorageCase.Set } else { $script:StorageCase.Pvc }
      return [pscustomobject]@{ Success = $ok; Stdout = $output; Stderr = ''; ExitCode = [int](-not $ok) }
    }
    try {
      $size = Get-AapAoPostgresStorageSize -Namespace 'automation-orchestrator' 6>$null
      [pscustomobject]@{ Size = $size; Failed = $false }
    } catch {
      [pscustomobject]@{ Size = ''; Failed = $true }
    } finally {
      ${function:script:Invoke-AapKubectlNative} = $originalKubectl
      ${function:script:Get-AapAoSetting} = $originalSetting
    }
  } $case
  if ($case.Expected) {
    if ($outcome.Failed -or $outcome.Size -ne $case.Expected) { throw "Case '$($case.Name)' failed" }
  } elseif (-not $outcome.Failed) {
    throw "Case '$($case.Name)' must fail closed"
  }
}

$cnpgCases = @(
  @{ Name = 'no CRD'; Crd = ''; Cluster = ''; Fail = ''; Expected = $false; Throws = $false },
  @{ Name = 'no cluster'; Crd = 'crd/clusters'; Cluster = ''; Fail = ''; Expected = $false; Throws = $false },
  @{ Name = 'existing cluster'; Crd = 'crd/clusters'; Cluster = 'cluster/orchestrator-postgres'; Fail = ''; Expected = $true; Throws = $false },
  @{ Name = 'CRD lookup fails'; Crd = ''; Cluster = ''; Fail = 'crd'; Expected = $false; Throws = $true },
  @{ Name = 'cluster lookup fails'; Crd = 'crd/clusters'; Cluster = ''; Fail = 'clusters.postgresql.cnpg.io'; Expected = $false; Throws = $true }
)
foreach ($case in $cnpgCases) {
  $outcome = & $module {
    param($Case)
    $script:CnpgCase = $Case
    $original = ${function:script:Invoke-AapKubectlNative}
    function script:Invoke-AapKubectlNative {
      param([string[]]$Arguments, [switch]$AllowFailure)
      $kind = $Arguments[1]
      $out = if ($kind -eq 'crd') { $script:CnpgCase.Crd } else { $script:CnpgCase.Cluster }
      return [pscustomobject]@{ Success = ($kind -ne $script:CnpgCase.Fail); Stdout = $out; Stderr = '' }
    }
    try {
      [pscustomobject]@{ Present = (Test-AapAoCnpgClusterPresent -Namespace ao); Failed = $false }
    } catch {
      [pscustomobject]@{ Present = $false; Failed = $true }
    } finally { ${function:script:Invoke-AapKubectlNative} = $original }
  } $case
  if ($outcome.Failed -ne $case.Throws -or $outcome.Present -ne $case.Expected) {
    throw "CNPG detection case '$($case.Name)' failed"
  }
}
$deleteCases = @(
  @{ Name = 'success'; Fail = ''; Throws = $false; DeletesPvc = $true },
  @{ Name = 'cluster deletion fails'; Fail = 'cluster-delete'; Throws = $true; DeletesPvc = $false },
  @{ Name = 'cluster remains'; Fail = 'cluster-stuck'; Throws = $true; DeletesPvc = $false },
  @{ Name = 'cluster lookup fails'; Fail = 'cluster-check'; Throws = $true; DeletesPvc = $false },
  @{ Name = 'database CRD lookup fails'; Fail = 'database-crd'; Throws = $true; DeletesPvc = $false },
  @{ Name = 'database deletion fails'; Fail = 'database-delete'; Throws = $true; DeletesPvc = $false },
  @{ Name = 'database ownership lookup fails'; Fail = 'database-lookup'; Throws = $true; DeletesPvc = $false },
  @{ Name = 'database belongs to another cluster'; Fail = 'database-owner'; Throws = $true; DeletesPvc = $false },
  @{ Name = 'PVC deletion fails'; Fail = 'pvc-delete'; Throws = $true; DeletesPvc = $true }
)
foreach ($case in $deleteCases) {
  $outcome = & $module {
    param($Case)
    $script:DeleteCase = $Case
    $script:ClusterPresent = $true
    $script:PvcDeleted = $false
    $original = ${function:script:Invoke-AapKubectlNative}
    function script:Invoke-AapKubectlNative {
      param([string[]]$Arguments, [switch]$AllowFailure)
      $line = $Arguments -join ' '
      $ok = $true; $out = ''
      if ($line -like 'delete clusters.postgresql.cnpg.io*') {
        $ok = $script:DeleteCase.Fail -ne 'cluster-delete'
        if ($ok -and $script:DeleteCase.Fail -ne 'cluster-stuck') { $script:ClusterPresent = $false }
      } elseif ($line -like 'get crd clusters.postgresql.cnpg.io*') {
        $ok = $script:DeleteCase.Fail -ne 'cluster-check'; $out = 'crd/clusters'
      } elseif ($line -like 'get clusters.postgresql.cnpg.io*') {
        if ($script:ClusterPresent) { $out = 'cluster/orchestrator-postgres' }
      } elseif ($line -like 'get crd databases.postgresql.cnpg.io*') {
        $ok = $script:DeleteCase.Fail -ne 'database-crd'; $out = 'crd/databases'
      } elseif ($line -like 'get database *') {
        $ok = $script:DeleteCase.Fail -ne 'database-lookup'
        $out = if ($script:DeleteCase.Fail -eq 'database-owner') { 'other-cluster' } else { 'orchestrator-postgres' }
      } elseif ($line -like 'delete database *') {
        $ok = $script:DeleteCase.Fail -ne 'database-delete'
      } elseif ($line -like 'delete pvc orchestrator-postgres-1*') {
        $script:PvcDeleted = $true; $ok = $script:DeleteCase.Fail -ne 'pvc-delete'
      } else { throw "Unexpected kubectl command: $line" }
      return [pscustomobject]@{ Success = $ok; Stdout = $out; Stderr = '' }
    }
    try {
      Remove-AapAoCnpgStorage -Namespace ao
      [pscustomobject]@{ Failed = $false; DeletedPvc = $script:PvcDeleted }
    } catch {
      [pscustomobject]@{ Failed = $true; DeletedPvc = $script:PvcDeleted }
    } finally { ${function:script:Invoke-AapKubectlNative} = $original }
  } $case
  if ($outcome.Failed -ne $case.Throws -or $outcome.DeletedPvc -ne $case.DeletesPvc) {
    throw "CNPG deletion case '$($case.Name)' failed"
  }
}
$forceOutcome = & $module {
  $originalSetting = ${function:script:Get-AapAoSetting}
  $originalReset = ${function:script:Reset-AapAoPostgresStorage}
  $script:ResetCalled = $false
  function script:Get-AapAoSetting { param($Name, $Default) return 'invalid|size' }
  function script:Reset-AapAoPostgresStorage { param($Namespace) $script:ResetCalled = $true }
  try {
    Ensure-AapAoPostgres -Namespace ao -Reset
    [pscustomobject]@{ Failed = $false; Reset = $script:ResetCalled }
  } catch {
    [pscustomobject]@{ Failed = $true; Reset = $script:ResetCalled }
  } finally {
    ${function:script:Get-AapAoSetting} = $originalSetting
    ${function:script:Reset-AapAoPostgresStorage} = $originalReset
  }
}
if (-not $forceOutcome.Failed -or $forceOutcome.Reset) {
  throw 'Invalid forced storage size must stop before deleting the database'
}
$manifestPath = & $module {
  New-AapAoManifestFile -Name 'postgres.yaml' -Replacements @{
    '__NAMESPACE__' = 'ao-test'; '__STORAGE_CLASS__' = 'block'
    '__STORAGE_SIZE__' = '5Gi'; '__POSTGRES_IMAGE__' = 'registry.example/postgres:15'
  }
}
try {
  $manifest = Get-Content -LiteralPath $manifestPath -Raw
  if ($manifest -match '__[A-Z_]+__' -or $manifest -notmatch 'storage: 5Gi') {
    throw 'PostgreSQL manifest did not render the storage size'
  }
} finally { Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue }
Write-Host 'AO PostgreSQL storage selection passed'
