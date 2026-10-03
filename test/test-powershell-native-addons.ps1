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
    $source -notmatch 'postgres-cluster\.yaml' -or
    $source -notmatch 'automationorchestrator-cr\.yaml' -or
    $source -notmatch 'installplan' -or
    $source -notmatch 'approved') {
  throw 'Native AO implementation must apply the checked-in AO manifests'
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
