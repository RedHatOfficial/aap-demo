# Shared helpers for aap-demo PowerShell module.

Set-StrictMode -Version Latest

$Script:AapDemoRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$Script:AapDemoConfigDir = Join-Path $env:USERPROFILE '.aap-demo'
$Script:AapDemoDefaultNamespace = 'aap-operator'
$Script:AapDemoDefaultChannel = 'stable-2.7'
$Script:AapDemoDefaultOcpVersion = '4.20'

function Write-AapHeader {
  param([string]$Title)
  Write-Host ''
  Write-Host $Title -ForegroundColor Cyan
  Write-Host ('=' * $Title.Length)
  Write-Host ''
}

function Write-AapStep {
  param([string]$Message)
  Write-Host "  $Message" -ForegroundColor Green
}

function Write-AapWarn {
  param([string]$Message)
  Write-Host "  WARN $Message" -ForegroundColor Yellow
}

function Write-AapErr {
  param([string]$Message)
  Write-Host "  ERROR $Message" -ForegroundColor Red
}

function Test-AapCommand {
  param([Parameter(Mandatory)][string]$Name)
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Assert-AapCommand {
  param(
    [Parameter(Mandatory)][string]$Name,
    [string]$InstallHint
  )
  if (-not (Test-AapCommand $Name)) {
    if ($InstallHint) { Write-AapErr $InstallHint }
    throw "$Name not found"
  }
}

function Get-AapConfigPath {
  Join-Path $Script:AapDemoConfigDir 'config'
}

function Get-AapConfigValue {
  param([Parameter(Mandatory)][string]$Key)
  $path = Get-AapConfigPath
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  foreach ($line in Get-Content -LiteralPath $path) {
    if ($line -match "^$([regex]::Escape($Key))=(.*)$") {
      return $Matches[1].Trim()
    }
  }
  return $null
}

function Set-AapConfigValue {
  param(
    [Parameter(Mandatory)][string]$Key,
    [Parameter(Mandatory)][string]$Value
  )
  New-Item -ItemType Directory -Force -Path $Script:AapDemoConfigDir | Out-Null
  $path = Get-AapConfigPath
  $lines = @()
  $found = $false
  if (Test-Path -LiteralPath $path) {
    foreach ($line in Get-Content -LiteralPath $path) {
      if ($line -match "^$([regex]::Escape($Key))=") {
        $lines += "$Key=$Value"
        $found = $true
      } else {
        $lines += $line
      }
    }
  }
  if (-not $found) { $lines += "$Key=$Value" }
  Set-Content -LiteralPath $path -Value $lines -Encoding ascii
}

function Get-AapPullSecretPath {
  $candidates = @(
    $env:PULL_SECRET_PATH,
    (Join-Path $Script:AapDemoConfigDir 'pull-secret.json'),
    (Join-Path $Script:AapDemoConfigDir 'pull-secret.txt'),
    (Join-Path $Script:AapDemoConfigDir 'pull-secret')
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
  return $candidates | Select-Object -First 1
}

function Get-AapKubeconfigPath {
  if ($env:KUBECONFIG -and (Test-Path -LiteralPath $env:KUBECONFIG)) {
    return $env:KUBECONFIG
  }
  $crcKube = Join-Path $env:USERPROFILE '.crc\machines\crc\kubeconfig'
  if (Test-Path -LiteralPath $crcKube) { return $crcKube }
  return $null
}

function Initialize-AapKubeEnvironment {
  $kube = Get-AapKubeconfigPath
  if ($kube) {
    $env:KUBECONFIG = $kube
  }
}

function Invoke-AapExternal {
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [string[]]$ArgumentList = @()
  )
  $output = & $FilePath @ArgumentList 2>&1
  $code = $LASTEXITCODE
  return [PSCustomObject]@{
    ExitCode = $code
    Output   = ($output | Out-String).TrimEnd()
    Lines    = @($output)
  }
}

function Invoke-AapKubectl {
  param([Parameter(Mandatory)][string[]]$Args)
  Assert-AapCommand kubectl 'Install kubectl or OpenShift Local (crc)'
  Initialize-AapKubeEnvironment
  $result = Invoke-AapExternal kubectl $Args
  if ($result.ExitCode -ne 0) {
    throw "kubectl failed ($($result.ExitCode)): $($result.Output)"
  }
  return $result
}

function Invoke-AapKubectlQuiet {
  param([Parameter(Mandatory)][string[]]$Args)
  Initialize-AapKubeEnvironment
  & kubectl @Args 2>&1 | Out-Null
  return $LASTEXITCODE
}

function Invoke-AapOc {
  param([Parameter(Mandatory)][string[]]$Args)
  if (-not (Test-AapCommand oc)) {
    # Fall back to kubectl create clusterrolebinding equivalents where possible
    return $null
  }
  Initialize-AapKubeEnvironment
  $result = Invoke-AapExternal oc $Args
  if ($result.ExitCode -ne 0) {
    throw "oc failed ($($result.ExitCode)): $($result.Output)"
  }
  return $result
}

function Get-AapCrcStatus {
  Assert-AapCommand crc 'Install OpenShift Local: https://console.redhat.com/openshift/create/local'
  $raw = & crc status --output json 2>$null
  if (-not $raw) { return @{ crcStatus = 'Unknown' } }
  try {
    return ($raw | ConvertFrom-Json)
  } catch {
    return @{ crcStatus = 'Unknown' }
  }
}

function Get-AapCrcSshKey {
  Join-Path $env:USERPROFILE '.crc\machines\crc\id_ed25519'
}

function Invoke-AapCrcSsh {
  param([Parameter(Mandatory)][string]$RemoteCommand)
  $key = Get-AapCrcSshKey
  if (-not (Test-Path -LiteralPath $key)) {
    throw "CRC SSH key not found: $key"
  }
  $args = @(
    '-p', '2222',
    '-i', $key,
    '-o', 'StrictHostKeyChecking=no',
    '-o', 'UserKnownHostsFile=NUL',
    '-o', 'LogLevel=ERROR',
    'core@127.0.0.1',
    $RemoteCommand
  )
  $result = Invoke-AapExternal ssh $args
  if ($result.ExitCode -ne 0) {
    throw "ssh failed ($($result.ExitCode)): $($result.Output)"
  }
  return $result.Output
}

function Get-AapManifestPath {
  param([Parameter(Mandatory)][string]$RelativePath)
  Join-Path $Script:AapDemoRepoRoot $RelativePath
}

function Apply-AapManifestTemplate {
  param(
    [Parameter(Mandatory)][string]$RelativePath,
    [hashtable]$Replacements = @{}
  )
  $path = Get-AapManifestPath $RelativePath
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Manifest not found: $path"
  }
  $content = Get-Content -LiteralPath $path -Raw
  foreach ($key in $Replacements.Keys) {
    $content = $content -replace [regex]::Escape($key), [string]$Replacements[$key]
  }
  $temp = [System.IO.Path]::GetTempFileName()
  try {
    Set-Content -LiteralPath $temp -Value $content -Encoding utf8NoBOM
    Invoke-AapKubectl @('apply', '-f', $temp) | Out-Null
  } finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
  }
}

function Grant-AapNamespaceSccs {
  param([Parameter(Mandatory)][string]$Namespace)
  if (Test-AapCommand oc) {
    Invoke-AapOc @('adm', 'policy', 'add-scc-to-group', 'anyuid', "system:serviceaccounts:$Namespace") | Out-Null
    Invoke-AapOc @('adm', 'policy', 'add-scc-to-group', 'privileged', "system:serviceaccounts:$Namespace") | Out-Null
    return
  }
  foreach ($scc in @('anyuid', 'privileged')) {
    $name = "system:openshift:scc:${scc}:${Namespace}"
    if ((Invoke-AapKubectlQuiet @('get', 'clusterrolebinding', $name)) -ne 0) {
      Invoke-AapKubectl @(
        'create', 'clusterrolebinding', $name,
        "--clusterrole=system:openshift:scc:$scc",
        "--group=system:serviceaccounts:$Namespace"
      ) | Out-Null
    }
  }
}

function Install-AapOlm {
  Assert-AapCommand operator-sdk 'Install operator-sdk or run .\powershell\install.ps1'
  if ((Invoke-AapKubectlQuiet @('get', 'crd', 'subscriptions.operators.coreos.com')) -eq 0) {
    Write-AapStep 'OLM already installed'
    return
  }
  Write-AapStep 'Installing OLM...'
  $result = Invoke-AapExternal operator-sdk @('olm', 'install')
  if ($result.ExitCode -ne 0 -and (Invoke-AapKubectlQuiet @('get', 'crd', 'subscriptions.operators.coreos.com')) -ne 0) {
    throw "OLM install failed: $($result.Output)"
  }
  Invoke-AapKubectlQuiet @('delete', 'catsrc', 'operatorhubio-catalog', '-n', 'olm') | Out-Null
  Write-AapStep 'OLM installed'
}

function Wait-AapCatalogSourceReady {
  param(
    [Parameter(Mandatory)][string]$Namespace,
    [int]$Attempts = 60
  )
  Write-Host '  Waiting for CatalogSource...'
  for ($i = 1; $i -le $Attempts; $i++) {
    $state = (& kubectl get catalogsource redhat-operators -n $Namespace `
      -o jsonpath='{.status.connectionState.lastObservedState}' 2>$null)
    if ($state -eq 'READY') {
      Write-AapStep 'CatalogSource ready'
      return
    }
    Write-Host "    attempt $i/$Attempts ($state)"
    Start-Sleep -Seconds 5
  }
  Write-AapWarn 'CatalogSource not READY after timeout — continuing'
}

function Wait-AapCsv {
  param(
    [Parameter(Mandatory)][string]$Namespace,
    [int]$Attempts = 60
  )
  Write-Host '  Waiting for operator CSV...'
  for ($i = 1; $i -le $Attempts; $i++) {
    $csv = (& kubectl get csv -n $Namespace --no-headers 2>$null | Select-String 'aap-operator' | ForEach-Object { ($_ -split '\s+')[0] } | Select-Object -First 1)
    if ($csv) {
      Write-AapStep "Found CSV: $csv"
      & kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "csv/$csv" -n $Namespace --timeout=600s 2>$null | Out-Null
      return $csv
    }
    Write-Host "    attempt $i/$Attempts"
    Start-Sleep -Seconds 10
  }
  throw 'CSV not found after timeout'
}
