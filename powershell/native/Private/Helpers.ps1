# Shared helpers for aap-demo PowerShell module.

Set-StrictMode -Version Latest

$Script:AapDemoRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$Script:AapDemoConfigDir = Join-Path $env:USERPROFILE '.aap-demo'
$Script:AapDemoDefaultNamespace = 'aap-operator'
$Script:AapDemoDefaultChannel = 'stable-2.7'
$Script:AapDemoDefaultOcpVersion = '4.20'
$Script:AapDemoUserBin = Join-Path $env:USERPROFILE '.local\bin'

if ((Test-Path -LiteralPath $Script:AapDemoUserBin) -and ($env:Path -notlike "*$Script:AapDemoUserBin*")) {
  $env:Path = "$Script:AapDemoUserBin;$env:Path"
}

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

function Update-AapSessionPath {
  $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = @($machinePath, $userPath) -join ';'
}

function Install-AapHelm {
  if (Test-AapCommand 'helm') {
    return $true
  }

  if (-not (Test-AapCommand 'winget')) {
    Write-AapWarn 'helm not found and winget is unavailable'
    return $false
  }

  Write-Host 'Installing Helm via winget (Helm.Helm)...'
  $wingetArgs = @(
    'install', '--id', 'Helm.Helm', '-e', '--source', 'winget',
    '--accept-package-agreements', '--accept-source-agreements',
    '--disable-interactivity'
  )

  $previousEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & winget @wingetArgs
    if ($LASTEXITCODE -ne 0) {
      Write-AapWarn "winget install Helm.Helm failed (exit $LASTEXITCODE)"
      return $false
    }
  } catch {
    Write-AapWarn "Could not install Helm via winget: $($_.Exception.Message)"
    return $false
  } finally {
    $ErrorActionPreference = $previousEap
  }

  Update-AapSessionPath
  return (Test-AapCommand 'helm')
}

function Ensure-AapHelm {
  if (Test-AapCommand 'helm') { return }

  Write-Host 'Helm not found — installing via winget...'
  if (-not (Install-AapHelm)) {
    throw @"
helm not found.

Install Helm 3.10+: winget install --id Helm.Helm -e --source winget
"@
  }
  Write-AapStep 'Helm installed via winget'
}

function Install-AapJq {
  if (Test-AapCommand 'jq') {
    return $true
  }

  if (-not (Test-AapCommand 'winget')) {
    Write-AapWarn 'jq not found and winget is unavailable'
    return $false
  }

  Write-Host 'Installing jq via winget (jqlang.jq)...'
  $wingetArgs = @(
    'install', '--id', 'jqlang.jq', '-e', '--source', 'winget',
    '--accept-package-agreements', '--accept-source-agreements',
    '--disable-interactivity'
  )

  $previousEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & winget @wingetArgs
    if ($LASTEXITCODE -ne 0) {
      Write-AapWarn "winget install jqlang.jq failed (exit $LASTEXITCODE)"
      return $false
    }
  } catch {
    Write-AapWarn "Could not install jq via winget: $($_.Exception.Message)"
    return $false
  } finally {
    $ErrorActionPreference = $previousEap
  }

  Update-AapSessionPath
  return (Test-AapCommand 'jq')
}

function Ensure-AapJq {
  if (Test-AapCommand 'jq') { return }

  Write-Host 'jq not found — installing via winget...'
  if (-not (Install-AapJq)) {
    throw @"
jq not found.

Install jq: winget install --id jqlang.jq -e --source winget
"@
  }
  Write-AapStep 'jq installed via winget'
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
    (Join-Path $Script:AapDemoConfigDir 'pull-secret.txt'),
    (Join-Path $Script:AapDemoConfigDir 'pull-secret.json'),
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
  $previousEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & $FilePath @ArgumentList 2>&1 | ForEach-Object {
      if ($_ -is [System.Management.Automation.ErrorRecord]) {
        $_.ToString()
      } else {
        $_
      }
    }
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousEap
  }
  return [PSCustomObject]@{
    ExitCode = $code
    Output   = ($output | Out-String).TrimEnd()
    Lines    = @($output)
  }
}

function Invoke-AapOc {
  param([Parameter(Mandatory)][string[]]$Args)
  Assert-AapCommand oc 'Install oc: winget install --id RedHat.OpenShift-Client -e --source winget'
  Initialize-AapKubeEnvironment
  $result = Invoke-AapExternal oc $Args
  if ($result.ExitCode -ne 0) {
    throw "oc failed ($($result.ExitCode)): $($result.Output)"
  }
  return $result
}

function Invoke-AapOcQuiet {
  param([Parameter(Mandatory)][string[]]$Args)
  Initialize-AapKubeEnvironment
  $result = Invoke-AapExternal oc $Args
  return $result.ExitCode
}

function Invoke-AapOcCapture {
  param([Parameter(Mandatory)][string[]]$Args)
  Initialize-AapKubeEnvironment
  return Invoke-AapExternal oc $Args
}

function Invoke-AapOcPatch {
  param(
    [Parameter(Mandatory)][string[]]$Args,
    [Parameter(Mandatory)][string]$Patch,
    [string]$PatchType = 'merge'
  )
  $temp = [System.IO.Path]::GetTempFileName()
  try {
    Set-Content -LiteralPath $temp -Value $Patch -Encoding ascii -NoNewline
    $patchArgs = @($Args + @("--type=$PatchType", '--patch-file', $temp))
    return Invoke-AapOc $patchArgs
  } finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-AapOcPatchQuiet {
  param(
    [Parameter(Mandatory)][string[]]$Args,
    [Parameter(Mandatory)][string]$Patch,
    [string]$PatchType = 'merge'
  )
  $temp = [System.IO.Path]::GetTempFileName()
  try {
    Set-Content -LiteralPath $temp -Value $Patch -Encoding ascii -NoNewline
    $patchArgs = @($Args + @("--type=$PatchType", '--patch-file', $temp))
    $result = Invoke-AapExternal oc $patchArgs
    return $result.ExitCode
  } finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
  }
}

function Get-AapCrcStatus {
  Assert-AapCommand crc 'Install OpenShift Local: https://console.redhat.com/openshift/create/local'
  $parsed = Get-AapCrcStatusJson
  if (-not $parsed) { return @{ crcStatus = 'Unknown' } }
  $prop = $parsed.PSObject.Properties['crcStatus']
  $status = if ($prop) { [string]$prop.Value } else { 'Unknown' }
  return @{ crcStatus = $status }
}

function Get-AapCrcStatusJson {
  Assert-AapCommand crc 'Install OpenShift Local: https://console.redhat.com/openshift/create/local'
  $raw = & crc status -o json 2>$null
  if (-not $raw) { return $null }
  try {
    return $raw | ConvertFrom-Json
  } catch {
    return $null
  }
}

function Write-AapCrcStartOutput {
  param([string[]]$Lines)

  $skipOcEnvBlock = $false
  foreach ($line in $Lines) {
    if ($line -match "Use the 'oc' command line interface") {
      $skipOcEnvBlock = $true
      continue
    }
    if ($skipOcEnvBlock) { continue }
    if ($line -match '@FOR /f|^\s*>\s*oc COMMAND|^\s*>\s*@') { continue }
    if ($line.Trim()) { Write-Host $line }
  }
}

function Invoke-AapCrcStart {
  param(
    [string]$PullSecretPath = $null
  )

  Assert-AapCommand crc 'Install OpenShift Local: https://console.redhat.com/openshift/create/local'

  $previousEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($PullSecretPath) {
      $output = @(& crc start -p $PullSecretPath 2>&1 | ForEach-Object { "$_" })
      if ($LASTEXITCODE -ne 0) {
        $output = @(Get-Content -LiteralPath $PullSecretPath -Raw |
          & crc start --pull-secret-file - 2>&1 | ForEach-Object { "$_" })
      }
    } else {
      $output = @(& crc start 2>&1 | ForEach-Object { "$_" })
    }

    if ($LASTEXITCODE -ne 0) {
      $output | ForEach-Object { Write-Host $_ }
      throw 'crc start failed'
    }

    Write-AapCrcStartOutput -Lines $output
    Initialize-AapKubeEnvironment
    $kube = Get-AapKubeconfigPath
    if ($kube) {
      Write-Host "  Kubeconfig: $kube"
    }
  } finally {
    $ErrorActionPreference = $previousEap
  }
}

function Invoke-AapCrcDelete {
  param(
    [switch]$Force
  )

  Assert-AapCommand crc 'Install OpenShift Local: https://console.redhat.com/openshift/create/local'

  $crc = Get-AapCrcStatus
  $state = [string]$crc.crcStatus

  if ($state -eq 'Running') {
    Write-AapStep 'Stopping cluster before delete...'
    Invoke-AapCrcStop -Quiet
    Start-Sleep -Seconds 3
  }

  $deleteArgs = @('delete')
  if ($Force) { $deleteArgs += '-f' }

  $previousEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = @(& crc @deleteArgs 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -eq 0) { return $true }

    $combined = ($output -join "`n")
    if ($combined -match 'invalid state') {
      Write-AapStep 'Cluster not fully stopped — retrying after crc stop...'
      Invoke-AapCrcStop -Quiet
      Start-Sleep -Seconds 5
      $output = @(& crc delete -f 2>&1 | ForEach-Object { "$_" })
      if ($LASTEXITCODE -eq 0) { return $true }
    }

    $output | ForEach-Object { if ($_.Trim()) { Write-Host $_ } }
    return $false
  } finally {
    $ErrorActionPreference = $previousEap
  }
}

function Invoke-AapCrcStop {
  param([switch]$Quiet)

  $previousEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = @(& crc stop 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
      if (-not $Quiet) { $output | ForEach-Object { Write-Host $_ } }
      return $false
    }
    if (-not $Quiet) {
      Write-AapStep 'CRC cluster stopped'
    }
    return $true
  } finally {
    $ErrorActionPreference = $previousEap
  }
}

function Get-AapCrcDiskUsagePercent {
  $parsed = Get-AapCrcStatusJson
  if (-not $parsed) { return 0 }
  $usage = 0
  if ($parsed.PSObject.Properties['diskUsage']) {
    $usage = [long]$parsed.diskUsage
  } elseif ($parsed.PSObject.Properties['diskUse']) {
    $usage = [long]$parsed.diskUse
  }
  $size = if ($parsed.PSObject.Properties['diskSize']) { [long]$parsed.diskSize } else { 0 }
  if ($size -gt 0) { return [int]($usage * 100 / $size) }
  return 0
}

function Get-AapCrcSshKey {
  Join-Path $env:USERPROFILE '.crc\machines\crc\id_ed25519'
}

function Invoke-AapCrcSsh {
  param(
    [Parameter(Mandatory)][string]$RemoteCommand,
    [switch]$AllowFailure
  )
  # Windows here-strings use CRLF; bash heredocs require LF-only terminators.
  $RemoteCommand = $RemoteCommand -replace "`r`n", "`n" -replace "`r", "`n"
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
  if (-not $AllowFailure -and $result.ExitCode -ne 0) {
    throw "ssh failed ($($result.ExitCode)): $($result.Output)"
  }
  return $result.Output
}

function Test-AapCrcSsh {
  param([Parameter(Mandatory)][string]$RemoteCommand)
  $RemoteCommand = $RemoteCommand -replace "`r`n", "`n" -replace "`r", "`n"
  $key = Get-AapCrcSshKey
  if (-not (Test-Path -LiteralPath $key)) {
    return $false
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
  return $result.ExitCode -eq 0
}

function Set-AapUtf8Content {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Value
  )
  $encoding = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

function Get-AapManifestPath {
  param([Parameter(Mandatory)][string]$RelativePath)
  Join-Path $Script:AapDemoRepoRoot $RelativePath
}

function Read-AapManifest {
  param([Parameter(Mandatory)][string]$RelativePath)
  $raw = Get-Content -LiteralPath (Get-AapManifestPath $RelativePath) -Raw
  return ($raw -replace "`r`n", "`n" -replace "`r", "`n")
}

function Get-AapDefaultStorageClass {
  $fallback = 'topolvm-provisioner'
  $result = Invoke-AapOcCapture @(
    'get', 'sc', '-o', 'jsonpath={.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}'
  )
  if ($result.ExitCode -ne 0) { return $fallback }
  $name = ($result.Output -split '\s+')[0].Trim()
  if ($name -match '^[A-Za-z0-9][A-Za-z0-9._-]*$') { return $name }
  return $fallback
}

function Get-AapServiceClusterIp {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Namespace
  )
  $result = Invoke-AapOcCapture @(
    'get', 'svc', $Name, '-n', $Namespace, '-o', 'jsonpath={.spec.clusterIP}'
  )
  if ($result.ExitCode -ne 0) {
    throw "Could not resolve ClusterIP for service/$Name in $Namespace`: $($result.Output)"
  }
  $ip = ($result.Output -split '\s+')[0].Trim()
  if (-not $ip) {
    throw "Could not resolve ClusterIP for service/$Name in $Namespace"
  }
  return $ip
}

function Format-AapYamlReplacementValue {
  param([AllowNull()][string]$Value)
  if (-not $Value) { return '' }
  $scalar = ($Value -split '[\r\n]', 2)[0].Trim()
  if ($scalar -match '[:#@`'']|\s') {
    return '"' + ($scalar -replace '\\', '\\' -replace '"', '\"') + '"'
  }
  return $scalar
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
  $content = Read-AapManifest $RelativePath
  foreach ($key in $Replacements.Keys) {
    $value = Format-AapYamlReplacementValue -Value ([string]$Replacements[$key])
    $content = [regex]::Replace(
      $content,
      [regex]::Escape($key),
      [System.Text.RegularExpressions.MatchEvaluator]{ $value }
    )
  }
  $temp = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.yaml')
  try {
    Set-AapUtf8Content -Path $temp -Value $content
    Invoke-AapOc @('apply', '-f', $temp) | Out-Null
  } finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
  }
}

function Grant-AapNamespaceSccs {
  param([Parameter(Mandatory)][string]$Namespace)
  Invoke-AapOc @('adm', 'policy', 'add-scc-to-group', 'anyuid', "system:serviceaccounts:$Namespace") | Out-Null
  Invoke-AapOc @('adm', 'policy', 'add-scc-to-group', 'privileged', "system:serviceaccounts:$Namespace") | Out-Null
}

function Install-AapOlmViaCrcVm {
  $sdkVersion = 'v1.38.0'
  $kubeConfig = '/var/lib/microshift/resources/kubeadmin/kubeconfig'
  $url = "https://github.com/operator-framework/operator-sdk/releases/download/$sdkVersion/operator-sdk_linux_amd64"
  $cmd = "curl -fsSL -o /tmp/operator-sdk $url && chmod +x /tmp/operator-sdk && sudo KUBECONFIG=$kubeConfig /tmp/operator-sdk olm install"
  Invoke-AapCrcSsh $cmd -AllowFailure | Out-Null
}

function Install-AapOlm {
  if ((Invoke-AapOcQuiet @('get', 'crd', 'subscriptions.operators.coreos.com')) -eq 0) {
    Write-AapStep 'OLM already installed'
    return
  }
  Write-AapStep 'Installing OLM...'
  if (Test-AapCommand 'operator-sdk') {
    $result = Invoke-AapExternal operator-sdk @('olm', 'install')
    if ($result.ExitCode -ne 0 -and (Invoke-AapOcQuiet @('get', 'crd', 'subscriptions.operators.coreos.com')) -ne 0) {
      throw "OLM install failed: $($result.Output)"
    }
  } else {
    Install-AapOlmViaCrcVm
    if ((Invoke-AapOcQuiet @('get', 'crd', 'subscriptions.operators.coreos.com')) -ne 0) {
      throw 'OLM install failed (operator-sdk ran on CRC VM but subscriptions CRD is missing)'
    }
  }
  Invoke-AapOcQuiet @('delete', 'catsrc', 'operatorhubio-catalog', '-n', 'olm') | Out-Null
  Write-AapStep 'OLM installed'
}

function Wait-AapCatalogSourceReady {
  param(
    [Parameter(Mandatory)][string]$Namespace,
    [int]$Attempts = 60
  )
  Write-Host '  Waiting for CatalogSource...'
  for ($i = 1; $i -le $Attempts; $i++) {
    $result = Invoke-AapOcCapture @(
      'get', 'catalogsource', 'redhat-operators', '-n', $Namespace,
      '-o', 'jsonpath={.status.connectionState.lastObservedState}'
    )
    $state = if ($result.ExitCode -eq 0) { $result.Output.Trim() } else { '' }
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
  $csv = $null
  for ($i = 1; $i -le $Attempts; $i++) {
    $result = Invoke-AapOcCapture @('get', 'csv', '-n', $Namespace, '--no-headers')
    if ($result.ExitCode -eq 0 -and $result.Output -notmatch '^No resources found') {
      $csv = $result.Lines |
        Where-Object { $_ -match '^aap-operator\.' } |
        ForEach-Object { ($_ -split '\s+')[0] } |
        Select-Object -First 1
      if ($csv) {
        Write-AapStep "Found CSV: $csv"
        break
      }
    }
    Write-Host "    attempt $i/$Attempts"
    Start-Sleep -Seconds 10
  }
  if (-not $csv) {
    throw 'CSV not found after timeout'
  }

  Write-Host '  Waiting for CSV to reach Succeeded phase...'
  if ((Invoke-AapOcQuiet @('wait', "--for=jsonpath={.status.phase}=Succeeded", "csv/$csv", '-n', $Namespace, '--timeout=600s')) -ne 0) {
    $phaseResult = Invoke-AapOcCapture @('get', 'csv', $csv, '-n', $Namespace, '-o', 'jsonpath={.status.phase}')
    $phase = if ($phaseResult.ExitCode -eq 0) { $phaseResult.Output.Trim() } else { 'unknown' }
    throw "CSV $csv did not reach Succeeded phase (current: $phase)"
  }
  return $csv
}

function Test-AapIsAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-AapIngressCaCertPath {
  Join-Path $Script:AapDemoConfigDir 'crc-ingress-ca.crt'
}

function Get-AapX509Thumbprint {
  param([Parameter(Mandatory)][string]$Path)
  $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($Path)
  return $cert.Thumbprint.ToUpperInvariant()
}

function Test-AapCertInRootStore {
  param(
    [Parameter(Mandatory)][string]$Thumbprint,
    [ValidateSet('CurrentUser', 'LocalMachine')]
    [string]$Location = 'CurrentUser'
  )
  $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', $Location)
  try {
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
    return [bool]($store.Certificates | Where-Object { $_.Thumbprint.ToUpperInvariant() -eq $Thumbprint })
  } catch {
    return $false
  } finally {
    $store.Close()
  }
}

function Remove-AapIngressCaCertificates {
  param(
    [ValidateSet('CurrentUser', 'LocalMachine')]
    [string]$Location = 'CurrentUser'
  )
  $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', $Location)
  try {
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    $stale = @($store.Certificates | Where-Object { $_.Subject -match 'CN=ingress-ca' })
    foreach ($cert in $stale) {
      [void]$store.Remove($cert)
    }
  } catch {
    # Access denied or read-only store — skip cleanup
  } finally {
    $store.Close()
  }
}

function Add-AapCertToRootStoreViaCertutil {
  param(
    [Parameter(Mandatory)][string]$Path,
    [ValidateSet('CurrentUser', 'LocalMachine')]
    [string]$Location = 'CurrentUser',
    [switch]$Elevated
  )
  $certutilArgs = if ($Location -eq 'CurrentUser') {
    @('-user', '-addstore', 'Root', $Path)
  } else {
    @('-addstore', 'Root', $Path)
  }

  if ($Elevated -and $Location -eq 'LocalMachine') {
    try {
      $proc = Start-Process -FilePath 'certutil.exe' -ArgumentList $certutilArgs -Verb RunAs -Wait -PassThru -WindowStyle Hidden
      return $proc.ExitCode -eq 0
    } catch {
      return $false
    }
  }

  $result = Invoke-AapExternal certutil.exe $certutilArgs
  return $result.ExitCode -eq 0
}

function Set-AapIngressCaEnv {
  param([Parameter(Mandatory)][string]$Path)
  $env:CURL_CA_BUNDLE = $Path
  $env:SSL_CERT_FILE = $Path
}

function Update-AapIngressCaFromCluster {
  param([Parameter(Mandatory)][string]$CaPath)

  $caPem = Invoke-AapCrcSsh 'sudo cat /var/lib/microshift/certs/ingress-ca/ca.crt' -AllowFailure
  if (-not $caPem -or $caPem -notmatch 'BEGIN CERTIFICATE') {
    return $false
  }

  $newContent = $caPem.Trim()
  $rotated = $true
  if (Test-Path -LiteralPath $CaPath) {
    try {
      $existing = (Get-Content -LiteralPath $CaPath -Raw).Trim()
      if ($existing -eq $newContent) {
        $rotated = $false
      }
    } catch {
      $rotated = $true
    }
  }

  New-Item -ItemType Directory -Force -Path $Script:AapDemoConfigDir | Out-Null
  Set-AapUtf8Content -Path $CaPath -Value $newContent

  if ($rotated) {
    Remove-AapIngressCaCertificates -Location 'CurrentUser'
    Remove-AapIngressCaCertificates -Location 'LocalMachine'
  }

  return $true
}

function Import-AapIngressCaCertificate {
  param([Parameter(Mandatory)][string]$Path)

  $thumbprint = Get-AapX509Thumbprint -Path $Path
  if (Test-AapCertInRootStore -Thumbprint $thumbprint -Location 'LocalMachine') {
    Write-AapStep 'Ingress CA already trusted (Windows system certificate store)'
    return
  }

  Remove-AapIngressCaCertificates -Location 'CurrentUser'
  Remove-AapIngressCaCertificates -Location 'LocalMachine'

  $userTrusted = Test-AapCertInRootStore -Thumbprint $thumbprint -Location 'CurrentUser'
  if (-not $userTrusted) {
    $userOk = $false
    try {
      $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'CurrentUser')
      $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
      $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($Path)
      $store.Add($cert)
      $store.Close()
      $userOk = $true
    } catch {
      $userOk = Add-AapCertToRootStoreViaCertutil -Path $Path -Location 'CurrentUser'
    }
    if ($userOk) {
      Write-AapStep 'Ingress CA trusted (Windows user certificate store)'
    } else {
      Write-AapWarn 'Could not import ingress CA to user certificate store'
    }
  }

  if (Test-AapIsAdministrator) {
    if (Add-AapCertToRootStoreViaCertutil -Path $Path -Location 'LocalMachine') {
      Write-AapStep 'Ingress CA trusted (Windows system certificate store)'
      Write-Host '  Fully quit Chrome or Edge (all windows), then reopen the route URL.'
    } else {
      Write-AapWarn 'Could not import ingress CA to system certificate store'
    }
    return
  }

  if (Add-AapCertToRootStoreViaCertutil -Path $Path -Location 'LocalMachine' -Elevated) {
    Write-AapStep 'Ingress CA trusted (Windows system certificate store)'
    Write-Host '  Fully quit Chrome or Edge (all windows), then reopen the route URL.'
    return
  }

  Write-AapWarn 'System trust skipped (UAC declined or unavailable). Fully quit Chrome/Edge and retry, or run aap-demo status from an elevated PowerShell.'
}

function Install-AapIngressCaTrust {
  if ($env:AAP_DEMO_TRUST_CA -eq 'false') { return }

  $caPath = Get-AapIngressCaCertPath
  try {
    Update-AapIngressCaFromCluster -CaPath $caPath | Out-Null
  } catch {
    Write-AapWarn "Could not fetch ingress CA from cluster: $($_.Exception.Message)"
  }

  if (-not (Test-Path -LiteralPath $caPath)) {
    Write-AapWarn 'Could not fetch ingress CA from cluster and no saved copy exists'
    return
  }

  try {
    $thumbprint = Get-AapX509Thumbprint -Path $caPath
  } catch {
    Write-AapWarn "Could not read ingress CA: $($_.Exception.Message)"
    return
  }

  if (Test-AapCertInRootStore -Thumbprint $thumbprint -Location 'LocalMachine') {
    Set-AapIngressCaEnv -Path $caPath
    return
  }

  Write-AapStep 'Trusting ingress CA for browser TLS...'
  Import-AapIngressCaCertificate -Path $caPath
  Set-AapIngressCaEnv -Path $caPath
}

function Get-AapExistingCrName {
  param([Parameter(Mandatory)][string]$Namespace)

  foreach ($resource in @('aap', 'ansibleautomationplatforms.aap.ansible.com')) {
    $result = Invoke-AapOcCapture @(
      'get', $resource, '-n', $Namespace,
      '-o', 'jsonpath={.items[0].metadata.name}'
    )
    if ($result.ExitCode -eq 0 -and $result.Output.Trim()) {
      return $result.Output.Trim()
    }
  }
  return $null
}

function Invoke-AapOcApplyFile {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Namespace
  )

  $result = Invoke-AapOcCapture @('apply', '-f', $Path, '-n', $Namespace)
  if ($result.ExitCode -eq 0) { return }

  if ($result.Output -match 'AlreadyExists') {
    Write-AapStep 'AAP CR already exists - applying server-side update'
    $ssa = Invoke-AapOcCapture @(
      'apply', '--server-side', '--force-conflicts', '-f', $Path, '-n', $Namespace
    )
    if ($ssa.ExitCode -eq 0) { return }

    Write-AapStep 'AAP CR already exists - continuing with current resource'
    return
  }

  throw "oc apply failed ($($result.ExitCode)): $($result.Output)"
}

function ConvertFrom-AapKubeBase64 {
  param([string]$Value)
  if (-not $Value) { return $null }
  $clean = ($Value -replace '\s', '')
  if (-not $clean) { return $null }
  return [Convert]::FromBase64String($clean)
}

function Get-AapOcConfigJson {
  param([Parameter(Mandatory)][string]$KubeConfig)
  $result = Invoke-AapOcConfig -KubeConfig $KubeConfig -Arguments @(
    'config', 'view', '--raw', '-o', 'json'
  )
  if ($result.ExitCode -ne 0) {
    throw 'Kubeconfig is invalid'
  }
  return ($result.Lines -join [Environment]::NewLine) | ConvertFrom-Json
}

function Test-AapOcHasListOutput {
  param($Result)
  if ($Result.ExitCode -ne 0 -or -not $Result.Output) { return $false }
  $lines = @($Result.Lines | Where-Object {
      $_.Trim() -and $_ -notmatch '^(No resources found|NAME\b)'
    })
  return $lines.Count -gt 0
}

function Get-AapOcFirstListName {
  param($Result)
  $line = @($Result.Lines | Where-Object {
      $_.Trim() -and $_ -notmatch '^(No resources found|NAME\b)'
    }) | Select-Object -First 1
  if (-not $line) { return $null }
  return ($line -split '\s+', 2)[0]
}

function Get-AapAdminPassword {
  param([Parameter(Mandatory)][string]$Namespace)

  $secretResult = Invoke-AapOcCapture @(
    'get', 'aap', '-n', $Namespace,
    '-o', 'jsonpath={.items[0].status.adminPasswordSecret}'
  )
  $secretNames = @()
  if ($secretResult.ExitCode -eq 0 -and $secretResult.Output.Trim()) {
    $secretNames += $secretResult.Output.Trim()
  }
  $secretNames += @(
    'aap-admin-password',
    'myaap-admin-password',
    'aap-controller-admin-password',
    'custom-admin-password'
  )

  foreach ($secretName in ($secretNames | Select-Object -Unique)) {
    $pwResult = Invoke-AapOcCapture @(
      'get', 'secret', $secretName, '-n', $Namespace,
      '-o', 'jsonpath={.data.password}'
    )
    if ($pwResult.ExitCode -eq 0 -and $pwResult.Output.Trim()) {
      return [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String($pwResult.Output.Trim())
      )
    }
  }
  return $null
}

function Get-AapAapSuccessful {
  param([Parameter(Mandatory)][string]$Namespace)

  $aapJsonResult = Invoke-AapOcCapture @('get', 'aap', '-n', $Namespace, '-o', 'json')
  if ($aapJsonResult.ExitCode -ne 0 -or -not $aapJsonResult.Output) {
    return $false
  }
  try {
    $aapObj = $aapJsonResult.Output | ConvertFrom-Json
    foreach ($item in @($aapObj.items)) {
      foreach ($cond in @($item.status.conditions)) {
        if ($cond.type -eq 'Successful' -and [string]$cond.status -eq 'True') {
          return $true
        }
      }
    }
  } catch {
    return $false
  }
  return $false
}

function Wait-AapUserContinue {
  param([int]$TimeoutSeconds = 10)
  Write-Host 'Press Ctrl+C to cancel, or press Enter to continue immediately...'
  Write-Host "Auto-continuing in $TimeoutSeconds seconds..."
  $end = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $end) {
    if ([Console]::KeyAvailable) {
      $null = [Console]::ReadKey($true)
      break
    }
    Start-Sleep -Milliseconds 200
  }
  Write-Host ''
}

function Get-AapAddonsList {
  $raw = Get-AapConfigValue 'ADDONS'
  if (-not $raw) { return @() }
  return @($raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Set-AapAddonsList {
  param([string[]]$Addons)
  $value = ($Addons | Where-Object { $_ }) -join ','
  if ($value) {
    Set-AapConfigValue 'ADDONS' $value
  } else {
    $path = Get-AapConfigPath
    if (Test-Path -LiteralPath $path) {
      $lines = Get-Content -LiteralPath $path | Where-Object { $_ -notmatch '^ADDONS=' }
      if ($lines) {
        Set-Content -LiteralPath $path -Value $lines -Encoding ascii
      } else {
        Remove-Item -LiteralPath $path -Force
      }
    }
  }
}

function Add-AapAddon {
  param([Parameter(Mandatory)][string]$Addon)
  $current = @(Get-AapAddonsList)
  if ($current -contains $Addon) { return }
  $current += $Addon
  Set-AapAddonsList $current
}

function Remove-AapAddon {
  param([Parameter(Mandatory)][string]$Addon)
  $current = @(Get-AapAddonsList) | Where-Object { $_ -ne $Addon }
  Set-AapAddonsList $current
}

function Invoke-AapOcConfig {
  param(
    [Parameter(Mandatory)][string]$KubeConfig,
    [Parameter(Mandatory)][string[]]$Arguments
  )
  $prev = $env:KUBECONFIG
  try {
    $env:KUBECONFIG = $KubeConfig
    $result = Invoke-AapExternal oc $Arguments
    return $result
  } finally {
    $env:KUBECONFIG = $prev
  }
}

function Invoke-AapPruneCrcImages {
  try {
    Write-Host ''
    Write-Host 'Pruning unused container images...'
    $output = Invoke-AapCrcSsh 'sudo crictl rmi --prune 2>&1' -AllowFailure
    if ($output -match '(?i)deleted') {
      Write-AapStep 'Pruned unused images'
    } else {
      Write-AapStep 'No unused images to prune'
    }
  } catch {
    Write-AapWarn "Image prune skipped: $($_.Exception.Message)"
  }
}

function Get-AapInstalledRepoRoot {
  $repoRoot = $Script:AapDemoRepoRoot
  $marker = Join-Path $Script:AapDemoConfigDir 'repo-path'
  if (Test-Path -LiteralPath $marker) {
    $repoRoot = (Get-Content -LiteralPath $marker -Raw).Trim()
  }
  if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'aap-demo.sh'))) {
    throw @"
aap-demo repo not found.

Run from the repo directory or install with:
  .\powershell\install.ps1
"@
  }
  return $repoRoot
}
