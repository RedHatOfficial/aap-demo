function Invoke-AapApplyAapCr {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Namespace,
    [string]$CrName = 'minimal',
    [string]$PublicUrl = $null,
    [switch]$Force
  )

  $crPath = Get-AapManifestPath "config/crs/aap-$CrName.yaml"
  if (-not (Test-Path -LiteralPath $crPath)) {
    throw "CR template not found: aap-$CrName.yaml"
  }

  $existingName = Get-AapExistingCrName -Namespace $Namespace
  if ($existingName -and $Force) {
    Write-AapStep "Deleting existing AAP CR: $existingName"
    Invoke-AapOcQuiet @('delete', 'aap', $existingName, '-n', $Namespace, '--timeout=60s') | Out-Null
    for ($i = 1; $i -le 30; $i++) {
      if (-not (Get-AapExistingCrName -Namespace $Namespace)) { break }
      Start-Sleep -Seconds 2
    }
  }

  if ($CrName -match 'noingress') {
    if (-not $PublicUrl) {
      throw @"
PUBLIC_URL required for noingress CR.

  aap-demo deploy-aap CR=minimal-noingress PUBLIC_URL=https://aap.apps.example.com
"@
    }
    Write-AapStep "Applying CR $CrName with PUBLIC_URL=$PublicUrl"
    $cr = Get-Content -LiteralPath $crPath -Raw
    $cr = $cr -replace '__PUBLIC_BASE_URL__', $PublicUrl
    $temp = [System.IO.Path]::GetTempFileName()
    try {
      Set-AapUtf8Content -Path $temp -Value $cr
      Invoke-AapOcApplyFile -Path $temp -Namespace $Namespace
    } finally {
      Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
    return
  }

  Write-AapStep "Applying CR: $CrName"
  if ((Invoke-AapOcQuiet @('get', 'sc', 'nfs-local-rwx')) -eq 0) {
    Invoke-AapOcApplyFile -Path $crPath -Namespace $Namespace
  } else {
    Write-AapWarn 'nfs-local-rwx missing - applying CR with ReadWriteOnce fallback'
    $cr = Get-Content -LiteralPath $crPath -Raw
    $cr = $cr -replace 'file_storage_storage_class: nfs-local-rwx', '# file_storage_storage_class: (default)'
    $cr = $cr -replace 'file_storage_access_mode: ReadWriteMany', 'file_storage_access_mode: ReadWriteOnce'
    $temp = [System.IO.Path]::GetTempFileName()
    try {
      Set-AapUtf8Content -Path $temp -Value $cr
      Invoke-AapOcApplyFile -Path $temp -Namespace $Namespace
    } finally {
      Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
  }
}

function Invoke-AapDemoDeploy {
  [CmdletBinding()]
  param(
    [string]$Namespace = $Script:AapDemoDefaultNamespace,
    [string]$Channel = $Script:AapDemoDefaultChannel,
    [string]$OcpVersion = $Script:AapDemoDefaultOcpVersion,
    [string]$CrName = 'minimal',
    [switch]$Force,
    [switch]$OperatorOnly
  )

  Write-AapHeader 'aap-demo deploy'

  Invoke-AapEnsureCluster -CreateIfMissing

  Install-AapIngressCaTrust

  Install-AapOlm

  if (-not $Force -and -not $OperatorOnly) {
    $existingName = Get-AapExistingCrName -Namespace $Namespace
    if ($existingName) {
      Write-AapStep ('AAP instance ''{0}'' already exists in {1} - watching progress' -f $existingName, $Namespace)
      Write-Host ''
      Invoke-AapDemoWatch -Namespace $Namespace
      return
    }
  }

  Write-AapStep "Deploying AAP 2.7 to namespace $Namespace"
  Initialize-AapNamespace -Namespace $Namespace

  $catalog = Read-AapManifest 'config/olm/catalogsource.yaml'
  $catalog = $catalog -replace 'namespace: aap-operator', "namespace: $Namespace"
  $catalog = $catalog -replace 'redhat-operator-index:v[0-9.]+', "redhat-operator-index:v$OcpVersion"
  $temp = [System.IO.Path]::GetTempFileName()
  Set-AapUtf8Content -Path $temp -Value $catalog
  Invoke-AapOc @('apply', '-f', $temp) | Out-Null
  Remove-Item -LiteralPath $temp -Force

  Wait-AapCatalogSourceReady -Namespace $Namespace

  $og = Read-AapManifest 'config/olm/operatorgroup.yaml'
  $og = $og -replace '(?m)^  namespace: aap$', "  namespace: $Namespace"
  $og = $og -replace 'name: aap-og', "name: ${Namespace}-og"
  $og = $og -replace '(?m)^    - aap$', "    - $Namespace"
  $temp = [System.IO.Path]::GetTempFileName()
  Set-AapUtf8Content -Path $temp -Value $og
  Invoke-AapOc @('apply', '-f', $temp) | Out-Null
  Remove-Item -LiteralPath $temp -Force

  $sub = Read-AapManifest 'config/olm/subscription.yaml'
  $sub = $sub -replace '(?m)^  namespace: aap$', "  namespace: $Namespace"
  $sub = $sub -replace 'sourceNamespace: aap-operator', "sourceNamespace: $Namespace"
  $sub = $sub -replace 'channel: stable-2.7', "channel: $Channel"
  $temp = [System.IO.Path]::GetTempFileName()
  Set-AapUtf8Content -Path $temp -Value $sub
  Invoke-AapOc @('apply', '-f', $temp) | Out-Null
  Remove-Item -LiteralPath $temp -Force

  $csv = Wait-AapCsv -Namespace $Namespace
  Write-AapStep "Operator CSV: $csv"

  if ($OperatorOnly) {
    Write-AapStep 'Operator deployed (no AAP CR)'
    Write-Host ''
    Write-Host '  Deploy AAP instance: aap-demo deploy-aap'
    Write-Host ''
    return
  }

  Invoke-AapApplyAapCr -Namespace $Namespace -CrName $CrName -Force:$Force

  Write-AapStep 'AAP CR applied - reconciliation in progress'
  Write-Host ''
  Write-Host '  Monitor: aap-demo watch'
  Write-Host '  Or:      aap-demo status'
  Write-Host ''
}

function Initialize-AapNamespace {
  param([Parameter(Mandatory)][string]$Namespace)

  Write-AapStep "Setting up namespace $Namespace"
  Invoke-AapOcQuiet @('create', 'namespace', $Namespace) | Out-Null
  Grant-AapNamespaceSccs -Namespace $Namespace
  Invoke-AapOc @(
    'label', 'namespace', $Namespace,
    'pod-security.kubernetes.io/enforce=privileged',
    'pod-security.kubernetes.io/audit=privileged',
    'pod-security.kubernetes.io/warn=privileged',
    '--overwrite'
  ) | Out-Null

  $pullSecret = Get-AapPullSecretPath
  if (-not $pullSecret) {
    Write-AapWarn 'No pull secret - image pulls may fail'
    return
  }

  Invoke-AapOcQuiet @('delete', 'secret', 'redhat-operators-pull-secret', '-n', $Namespace) | Out-Null
  Invoke-AapOc @(
    'create', 'secret', 'generic', 'redhat-operators-pull-secret',
    "--from-file=.dockerconfigjson=$pullSecret",
    '--type=kubernetes.io/dockerconfigjson',
    '-n', $Namespace
  ) | Out-Null

  $patch = (@{ imagePullSecrets = @(@{ name = 'redhat-operators-pull-secret' }) } | ConvertTo-Json -Compress)
  Invoke-AapOcPatch @('patch', 'serviceaccount', 'default', '-n', $Namespace) -Patch $patch | Out-Null
}
