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
    } else {
      Write-AapWarn 'Could not import ingress CA to system certificate store'
    }
    return
  }

  if (Add-AapCertToRootStoreViaCertutil -Path $Path -Location 'LocalMachine' -Elevated) {
    Write-AapStep 'Ingress CA trusted (Windows system certificate store)'
    return
  }

  Write-AapWarn 'System trust skipped (UAC declined or unavailable). Fully quit Chrome/Edge and retry, or run aap-demo status from an elevated PowerShell.'
}

function Install-AapIngressCaTrust {
  if ($env:AAP_DEMO_TRUST_CA -eq 'false') { return }

  $caPath = Get-AapIngressCaCertPath
  if (Test-Path -LiteralPath $caPath) {
    try {
      $thumbprint = Get-AapX509Thumbprint -Path $caPath
      if (Test-AapCertInRootStore -Thumbprint $thumbprint -Location 'LocalMachine') {
        $env:CURL_CA_BUNDLE = $caPath
        $env:SSL_CERT_FILE = $caPath
        return
      }
      if (Test-AapCertInRootStore -Thumbprint $thumbprint -Location 'CurrentUser') {
        Import-AapIngressCaCertificate -Path $caPath
        $env:CURL_CA_BUNDLE = $caPath
        $env:SSL_CERT_FILE = $caPath
        return
      }
    } catch {
      Write-AapWarn "Could not verify saved ingress CA: $($_.Exception.Message)"
    }
  }

  Write-AapStep 'Trusting ingress CA...'
  try {
    $caPem = Invoke-AapCrcSsh 'sudo cat /var/lib/microshift/certs/ingress-ca/ca.crt' -AllowFailure
    if (-not $caPem -or $caPem -notmatch 'BEGIN CERTIFICATE') {
      Write-AapWarn 'Could not fetch ingress CA from cluster'
      if (Test-Path -LiteralPath $caPath) {
        Import-AapIngressCaCertificate -Path $caPath
      }
      return
    }

    New-Item -ItemType Directory -Force -Path $Script:AapDemoConfigDir | Out-Null
    Set-AapUtf8Content -Path $caPath -Value $caPem.Trim()
    Import-AapIngressCaCertificate -Path $caPath
    $env:CURL_CA_BUNDLE = $caPath
    $env:SSL_CERT_FILE = $caPath
  } catch {
    Write-AapWarn "Could not trust ingress CA: $($_.Exception.Message)"
  }
}

function Find-AapGitBash {
  $candidates = @(
    (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

  if (@($candidates).Count -eq 0) {
    throw @"
Git Bash not found.

Install Git for Windows: https://git-scm.com/download/win
Required for this command (not yet implemented in PowerShell).
"@
  }
  return @($candidates)[0]
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

function Invoke-AapBashCli {
  param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
  )

  $Arguments = @($Arguments)
  $repoRoot = Get-AapInstalledRepoRoot
  $bashExe = Find-AapGitBash

  $env:HOME = $env:USERPROFILE

  if ((Test-Path -LiteralPath $Script:AapDemoUserBin) -and ($env:Path -notlike "*$Script:AapDemoUserBin*")) {
    $env:Path = "$Script:AapDemoUserBin;$env:Path"
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
}
