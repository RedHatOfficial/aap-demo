function Invoke-AapDemoDeploy {
  [CmdletBinding()]
  param(
    [string]$Namespace = $Script:AapDemoDefaultNamespace,
    [string]$Channel = $Script:AapDemoDefaultChannel,
    [string]$OcpVersion = $Script:AapDemoDefaultOcpVersion,
    [string]$CrName = 'minimal',
    [switch]$Force
  )

  Write-AapHeader 'aap-demo deploy'

  $crc = Get-AapCrcStatus
  if ([string]$crc.crcStatus -eq 'Stopped') {
    Write-AapStep 'Cluster stopped — starting CRC...'
    & crc start
    if ($LASTEXITCODE -ne 0) { throw 'crc start failed' }
  } elseif ([string]$crc.crcStatus -eq 'Unknown') {
    throw 'No cluster found. Run: aap-demo create'
  }

  Initialize-AapKubeEnvironment
  if ((Invoke-AapKubectlQuiet @('cluster-info')) -ne 0) {
    throw 'kubectl cannot connect to cluster'
  }

  Install-AapOlm

  if (-not $Force) {
    $existing = (& kubectl get aap -n $Namespace --no-headers 2>$null | Select-Object -First 1)
    if ($existing) {
      $name = ($existing -split '\s+')[0]
      Write-AapStep "AAP instance '$name' already exists in $Namespace"
      Write-Host '  Use -Force to redeploy or aap-demo status to check health'
      return
    }
  }

  Write-AapStep "Deploying AAP 2.7 to namespace $Namespace"
  Initialize-AapNamespace -Namespace $Namespace

  $catalog = Get-Content -LiteralPath (Get-AapManifestPath 'config/olm/catalogsource.yaml') -Raw
  $catalog = $catalog -replace 'namespace: aap-operator', "namespace: $Namespace"
  $catalog = $catalog -replace 'redhat-operator-index:v[0-9.]+', "redhat-operator-index:v$OcpVersion"
  $temp = [System.IO.Path]::GetTempFileName()
  Set-Content -LiteralPath $temp -Value $catalog -Encoding utf8NoBOM
  Invoke-AapKubectl @('apply', '-f', $temp) | Out-Null
  Remove-Item -LiteralPath $temp -Force

  Wait-AapCatalogSourceReady -Namespace $Namespace

  $og = Get-Content -LiteralPath (Get-AapManifestPath 'config/olm/operatorgroup.yaml') -Raw
  $og = $og -replace 'namespace: aap', "namespace: $Namespace"
  $og = $og -replace 'name: aap-og', "name: ${Namespace}-og"
  $og = $og -replace '- aap', "- $Namespace"
  $temp = [System.IO.Path]::GetTempFileName()
  Set-Content -LiteralPath $temp -Value $og -Encoding utf8NoBOM
  Invoke-AapKubectl @('apply', '-f', $temp) | Out-Null
  Remove-Item -LiteralPath $temp -Force

  $sub = Get-Content -LiteralPath (Get-AapManifestPath 'config/olm/subscription.yaml') -Raw
  $sub = $sub -replace 'namespace: aap', "namespace: $Namespace"
  $sub = $sub -replace 'channel: stable-2.7', "channel: $Channel"
  $temp = [System.IO.Path]::GetTempFileName()
  Set-Content -LiteralPath $temp -Value $sub -Encoding utf8NoBOM
  Invoke-AapKubectl @('apply', '-f', $temp) | Out-Null
  Remove-Item -LiteralPath $temp -Force

  $csv = Wait-AapCsv -Namespace $Namespace
  Write-AapStep "Operator CSV: $csv"

  $crPath = Get-AapManifestPath "config/crs/aap-$CrName.yaml"
  if (-not (Test-Path -LiteralPath $crPath)) {
    throw "CR template not found: aap-$CrName.yaml"
  }

  if ((Invoke-AapKubectlQuiet @('get', 'sc', 'nfs-local-rwx')) -eq 0) {
    Invoke-AapKubectl @('apply', '-f', $crPath, '-n', $Namespace) | Out-Null
  } else {
    Write-AapWarn 'nfs-local-rwx missing — applying CR with ReadWriteOnce fallback'
    $cr = Get-Content -LiteralPath $crPath -Raw
    $cr = $cr -replace 'file_storage_storage_class: nfs-local-rwx', '# file_storage_storage_class: (default)'
    $cr = $cr -replace 'file_storage_access_mode: ReadWriteMany', 'file_storage_access_mode: ReadWriteOnce'
    $temp = [System.IO.Path]::GetTempFileName()
    Set-Content -LiteralPath $temp -Value $cr -Encoding utf8NoBOM
    Invoke-AapKubectl @('apply', '-f', $temp, '-n', $Namespace) | Out-Null
    Remove-Item -LiteralPath $temp -Force
  }

  Write-AapStep 'AAP CR applied — reconciliation in progress'
  Write-Host ''
  Write-Host '  Monitor: aap-demo status'
  Write-Host '  Or:      aap-demo watch  (via Git Bash)'
  Write-Host ''
}

function Initialize-AapNamespace {
  param([Parameter(Mandatory)][string]$Namespace)

  Write-AapStep "Setting up namespace $Namespace"
  Invoke-AapKubectlQuiet @('create', 'namespace', $Namespace) | Out-Null
  Grant-AapNamespaceSccs -Namespace $Namespace
  Invoke-AapKubectl @(
    'label', 'namespace', $Namespace,
    'pod-security.kubernetes.io/enforce=privileged',
    'pod-security.kubernetes.io/audit=privileged',
    'pod-security.kubernetes.io/warn=privileged',
    '--overwrite'
  ) | Out-Null

  $pullSecret = Get-AapPullSecretPath
  if (-not $pullSecret) {
    Write-AapWarn 'No pull secret — image pulls may fail'
    return
  }

  Invoke-AapKubectlQuiet @('delete', 'secret', 'redhat-operators-pull-secret', '-n', $Namespace) | Out-Null
  Invoke-AapKubectl @(
    'create', 'secret', 'generic', 'redhat-operators-pull-secret',
    "--from-file=.dockerconfigjson=$pullSecret",
    '--type=kubernetes.io/dockerconfigjson',
    '-n', $Namespace
  ) | Out-Null

  $patch = '{"imagePullSecrets":[{"name":"redhat-operators-pull-secret"}]}'
  Invoke-AapKubectl @('patch', 'serviceaccount', 'default', '-n', $Namespace, '--type=merge', '-p', $patch) | Out-Null
}
