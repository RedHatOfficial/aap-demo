# Offline checks for the Windows addon dispatch boundary.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $repoRoot 'powershell/native/AapDemo.psm1') -Force -PassThru

foreach ($name in @('Invoke-AapGitBash', 'Get-AapGitBashExecutable', 'Invoke-AapAddonDeployScript')) {
  if (-not (& $module { param($n) Get-Command $n -ErrorAction SilentlyContinue } $name)) {
    throw "Missing Git Bash addon bridge command: $name"
  }
}

$source = Get-Content (Join-Path $repoRoot 'powershell/native/Private/NativeAo.ps1') -Raw
if ($source -match '(?im)\b(bash|wsl|sh)\b') {
  throw 'Native AO implementation must not invoke Bash, WSL, or shell interpreters'
}
if ($source -notmatch 'operator-subscription\.yaml' -or
    $source -notmatch "'postgres\.yaml'" -or
    $source -notmatch 'automationorchestrator-cr\.yaml' -or
    $source -notmatch 'installplan' -or
    $source -notmatch 'approved') {
  throw 'Native AO implementation must apply the checked-in AO manifests'
}
if ($source -notmatch 'data-orchestrator-postgres-0' -or
    $source -notmatch 'Reset:\$force' -or
    $source -notmatch 'Restart-AapAoPostgresClients -Namespace') {
  throw 'Native AO must reset PostgreSQL on --force and restart AO when the CA rotates'
}

# --force must not delete the PVC while the old StatefulSet or pod remains.
# Present lists what `kubectl get` still finds; GetError makes `get` fail.
$resetCases = @(
  @{ Name = 'clean delete'; Present = @('pvc/data-orchestrator-postgres-0'); DeleteFails = $false; GetError = $false; PvcStuck = $false; Throws = $false; DeletesPvc = $true },
  @{ Name = 'old pod running'; Present = @('pod/orchestrator-postgres-0', 'pvc/data-orchestrator-postgres-0'); DeleteFails = $true; GetError = $false; PvcStuck = $false; Throws = $true; DeletesPvc = $false },
  @{ Name = 'old StatefulSet present'; Present = @('statefulset/orchestrator-postgres', 'pvc/data-orchestrator-postgres-0'); DeleteFails = $true; GetError = $false; PvcStuck = $false; Throws = $true; DeletesPvc = $false },
  @{ Name = 'cannot check'; Present = @('pvc/data-orchestrator-postgres-0'); DeleteFails = $false; GetError = $true; PvcStuck = $false; Throws = $true; DeletesPvc = $false },
  @{ Name = 'PVC stuck'; Present = @('pvc/data-orchestrator-postgres-0'); DeleteFails = $false; GetError = $false; PvcStuck = $true; Throws = $true; DeletesPvc = $true }
)
foreach ($case in $resetCases) {
  $outcome = & $module {
    param($Case)
    $script:ResetCase = $Case
    $script:ResetPresent = [System.Collections.Generic.List[string]]::new([string[]]$Case.Present)
    $script:ResetCalls = [System.Collections.Generic.List[string]]::new()
    $original = ${function:script:Invoke-AapKubectlNative}
    function script:Invoke-AapKubectlNative {
      param([string[]]$Arguments, [switch]$AllowFailure)
      $line = $Arguments -join ' '
      $script:ResetCalls.Add($line)
      $ok = $true
      $out = ''
      if ($line -like 'delete statefulset*' -or $line -like 'wait --for=delete pod/*') {
        $ok = -not $script:ResetCase.DeleteFails
      } elseif ($line -like 'get *') {
        if ($script:ResetCase.GetError) { $ok = $false }
        elseif ($script:ResetPresent.Contains($Arguments[1])) { $out = $Arguments[1] }
      } elseif ($line -like 'delete pvc*') {
        [void]$script:ResetPresent.Remove('pvc/data-orchestrator-postgres-0')
      } elseif ($line -like 'wait --for=delete pvc/*') {
        $ok = -not $script:ResetCase.PvcStuck
      }
      [pscustomobject]@{ Success = $ok; Stdout = $out; Stderr = ''; ExitCode = [int](-not $ok) }
    }
    $threw = $false
    try { Reset-AapAoPostgresStorage -Namespace 'automation-orchestrator' 6>$null } catch { $threw = $true }
    finally { ${function:script:Invoke-AapKubectlNative} = $original }
    [pscustomobject]@{
      Threw = $threw
      DeletedPvc = [bool]($script:ResetCalls | Where-Object { $_ -like 'delete pvc*' })
    }
  } $case
  if ($outcome.Threw -ne $case.Throws -or $outcome.DeletedPvc -ne $case.DeletesPvc) {
    throw "Reset-AapAoPostgresStorage '$($case.Name)': threw=$($outcome.Threw) deletedPvc=$($outcome.DeletedPvc)"
  }
}
$manifestPath = & $module {
  New-AapAoManifestFile -Name 'automationorchestrator-cr.yaml' -Replacements @{
    '__NAMESPACE__' = 'automation-orchestrator-test'
    '__INGRESS_HOST__' = 'automation-orchestrator.apps.example.test'
    '__PULL_SECRET_NAME__' = 'automation-orchestrator-pull-secret'
    '__AO_REPLICA_COUNT__' = '1'
  }
}
try {
  $manifest = Get-Content -LiteralPath $manifestPath -Raw
  if ($manifest -match '__[A-Z_]+__') { throw 'AO manifest replacement left placeholders behind' }
  if ($manifest -notmatch 'automation-orchestrator\.apps\.example\.test') {
    throw 'AO manifest replacement did not set the ingress host'
  }
} finally {
  Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
}

$dispatch = Get-Content (Join-Path $repoRoot 'powershell/native/Private/Addons.ps1') -Raw
if ($dispatch -notmatch 'Invoke-AapGitBash' -or $dispatch -notmatch 'aap-demo\.sh') {
  throw 'Addon dispatcher must route addon lifecycle commands through Git Bash'
}
$duration = & $module { ConvertTo-AapDurationSeconds -Value '1h30m' }
if ($duration -ne 5400) { throw "Expected 1h30m to convert to 5400 seconds, got $duration" }
$allowedHosts = & $module { ConvertTo-AapAoHostListJson -Hosts @('aap.apps.example.test') }
if ($allowedHosts -ne '["aap.apps.example.test"]') {
  throw "Expected AO host allowlist JSON array, got '$allowedHosts'"
}

Write-Output 'Native addon checks passed'
