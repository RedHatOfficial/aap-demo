function Invoke-AapDemoEnable {
  param(
    [string]$Addon = $null,
    [string]$Namespace = $Script:AapDemoDefaultNamespace
  )

  if (-not $Addon) {
    Write-Host 'Usage: aap-demo enable <addon>'
    Write-Host ''
    Write-Host 'Available addons:'
    $saved = @(Get-AapAddonsList)
    foreach ($a in $Script:AapAvailableAddons) {
      $status = 'available'
      if ($saved -contains $a) { $status = 'enabled' }
      elseif (-not (Test-Path -LiteralPath (Join-Path $Script:AapDemoRepoRoot "addons/$a"))) {
        $status = 'not found'
      }
      Write-Host ("  {0,-15} ({1})" -f $a, $status)
    }
    return
  }

  if ($Addon -notin $Script:AapAvailableAddons) {
    throw "Unknown addon: $Addon`nAvailable: $($Script:AapAvailableAddons -join ', ')"
  }

  Write-Host "Enabling addon: $Addon"
  Invoke-AapEnsureClusterReady
  Invoke-AapAddonEnable -Addon $Addon -Namespace $Namespace
  Add-AapAddon $Addon
  $addons = (Get-AapAddonsList) -join ','
  Write-AapStep "Saved to config: ADDONS=$addons"
}

function Invoke-AapDemoDisable {
  param(
    [string]$Addon = $null,
    [string]$Namespace = $Script:AapDemoDefaultNamespace
  )

  if (-not $Addon) {
    Write-Host 'Usage: aap-demo disable <addon>'
    Write-Host ''
    Write-Host "Available addons: $($Script:AapAvailableAddons -join ', ')"
    return
  }

  if ($Addon -notin $Script:AapAvailableAddons) {
    throw "Unknown addon: $Addon"
  }

  Write-Host "Disabling addon: $Addon"
  Invoke-AapEnsureClusterReady
  Invoke-AapAddonDisable -Addon $Addon -Namespace $Namespace
  Remove-AapAddon $Addon
  Write-AapStep 'Removed from config'
}

function Write-AapClusterSummary {
  param([string]$Namespace = $Script:AapDemoDefaultNamespace)

  Initialize-AapKubeEnvironment
  $ctxResult = Invoke-AapOcCapture @('config', 'current-context')
  $ctx = if ($ctxResult.ExitCode -eq 0) { $ctxResult.Output.Trim() } else { 'unknown' }

  $apiResult = Invoke-AapOcCapture @('cluster-info')
  $api = 'unknown'
  if ($apiResult.ExitCode -eq 0 -and $apiResult.Output) {
    $api = ($apiResult.Lines | Select-Object -First 1) -replace '.*is running at ', ''
  }

  $aapResult = Invoke-AapOcCapture @('get', 'aap', '-n', $Namespace, '--no-headers')
  $aapCount = 0
  if (Test-AapOcHasListOutput $aapResult) {
    $aapCount = @($aapResult.Lines | Where-Object {
        $_.Trim() -and $_ -notmatch '^(No resources found|NAME\b)'
      }).Count
  }

  Write-Host '  Infra:            crc'
  Write-Host "  Cluster Context:  $ctx"
  Write-Host "  API Server:       $api"
  Write-Host "  Namespace:        $Namespace"
  Write-Host "  AAP Instances:    $aapCount"
}

function Invoke-AapDemoStop {
  Write-Host ''
  Write-Host 'aap-demo stop - Stopping CRC cluster...' -ForegroundColor Cyan
  if (-not (Invoke-AapCrcStop)) {
    throw 'crc stop failed'
  }
  Write-Host 'To restart: aap-demo deploy'
}

function Invoke-AapDemoDestroy {
  [CmdletBinding()]
  param([switch]$Reset)

  Write-Host ''
  Write-Host 'aap-demo destroy - Deleting CRC cluster...' -ForegroundColor Cyan
  Write-Host ''
  Write-Host 'WARNING: This will DELETE the entire CRC cluster!' -ForegroundColor Red
  Write-Host ''
  Write-Host '  All cluster data will be PERMANENTLY DESTROYED'
  Write-Host '  All PVC storage will be LOST'
  Write-Host '  All deployed applications will be removed'
  Write-Host '  You will need to redeploy AAP from scratch'
  Write-Host ''
  Wait-AapUserContinue

  if (Invoke-AapCrcDelete -Force) {
    Write-AapStep 'CRC cluster deleted'
    if ($Reset) {
      $configPath = Get-AapConfigPath
      if (Test-Path -LiteralPath $configPath) {
        Remove-Item -LiteralPath $configPath -Force
      }
      Write-AapStep "Config reset - next deploy will re-prompt for preset"
    }
  } else {
    Write-AapErr 'CRC delete failed - config preserved'
    Write-Host ''
    Write-Host 'Try manually:'
    Write-Host '  crc stop'
    Write-Host '  crc delete -f'
    exit 1
  }
}

function Invoke-AapDemoClean {
  [CmdletBinding()]
  param(
    [string]$Namespace = $Script:AapDemoDefaultNamespace,
    [switch]$Quiet
  )

  Initialize-AapKubeEnvironment

  Write-Host ''
  Write-Host 'aap-demo clean - Removing AAP operator deployment...' -ForegroundColor Cyan
  Write-Host ''
  Write-Host 'WARNING: AAP CLEANUP - DESTRUCTIVE OPERATION!' -ForegroundColor Red
  Write-Host ''
  Write-AapClusterSummary -Namespace $Namespace
  Write-Host ''

  $aapResult = Invoke-AapOcCapture @('get', 'aap', '-n', $Namespace, '--no-headers')
  if (Test-AapOcHasListOutput $aapResult) {
    Write-Host '  AAP resources that will be DELETED:'
    $aapResult.Lines | Where-Object {
      $_.Trim() -and $_ -notmatch '^(No resources found|NAME\b)'
    } | ForEach-Object {
      $name = ($_ -split '\s+')[0]
      Write-Host "    - $name"
    }
    Write-Host ''
  }

  Write-Host "This will DELETE the namespace '$Namespace' and all resources within it!"
  Write-Host ''

  if (-not $Quiet) {
    Wait-AapUserContinue
  }

  $nsExists = (Invoke-AapOcQuiet @('get', 'namespace', $Namespace)) -eq 0
  if (-not $nsExists) {
    Write-Host "Namespace $Namespace not found - nothing to clean"
    return
  }

  if (Test-AapCommand 'operator-sdk') {
    Write-Host '  Cleaning up OLM resources...'
    $sdkResult = Invoke-AapExternal operator-sdk @(
      'cleanup', 'ansible-automation-platform-operator', '-n', $Namespace
    )
    $sdkResult | Out-Null
    Invoke-AapOcQuiet @('scale', 'deploy', 'catalog-operator', 'olm-operator', '-n', 'olm', '--replicas=1') | Out-Null
  }

  $aapCrs = Invoke-AapOcCapture @('get', 'aap', '-n', $Namespace, '--no-headers', '-o', 'name')
  if ($aapCrs.ExitCode -eq 0 -and $aapCrs.Output) {
    foreach ($cr in $aapCrs.Lines) {
      Write-Host '  Removing owner references from children...'
      $patch = (@{ spec = @{ remove_owner_references_from_children = $true } } | ConvertTo-Json -Compress)
      Invoke-AapOcPatch @('patch', $cr, '-n', $Namespace) -Patch $patch | Out-Null
      Start-Sleep -Seconds 3
      Write-Host '  Deleting AAP CR...'
      Invoke-AapOcQuiet @('delete', $cr, '-n', $Namespace, '--timeout=30s') | Out-Null
    }
  }

  Write-Host "Deleting namespace $Namespace..."
  Invoke-AapOcQuiet @('delete', 'namespace', $Namespace, '--timeout=60s') | Out-Null
  Write-AapStep 'AAP operator deployment removed'
  Invoke-AapPruneCrcImages
}

function Invoke-AapDemoRepair {
  Write-Host ''
  Write-Host 'aap-demo repair - Refreshing cluster access and TLS trust...' -ForegroundColor Cyan
  Write-Host ''
  Sync-AapKubeconfig -Quiet
  Install-AapIngressCaTrust
  Write-Host ''
  Write-Host 'If Chrome/Edge still shows a certificate warning:'
  Write-Host '  1. Run this command from an elevated PowerShell'
  Write-Host '  2. Fully quit the browser (all windows), then reopen the AAP URL'
  Write-Host '  3. Clear HSTS for 127.0.0.1.nip.io at chrome://net-internals/#hsts'
  Write-Host ''
}

function Invoke-AapDemoSetup {
  Write-Host "CRC setup is handled during 'aap-demo create'"
}

function Invoke-AapDemoSsh {
  $key = Get-AapCrcSshKey
  if (-not (Test-Path -LiteralPath $key)) {
    throw "CRC SSH key not found: $key`nRun: aap-demo create"
  }
  $nullHost = if ($env:OS -match 'Windows') { 'NUL' } else { '/dev/null' }
  & ssh -p 2222 -i $key -o StrictHostKeyChecking=no -o "UserKnownHostsFile=$nullHost" core@127.0.0.1
  exit $LASTEXITCODE
}

function Invoke-AapDemoKubeconfig {
  Write-Host ''
  Write-Host 'aap-demo kubeconfig - Syncing local aap-demo kubeconfig...' -ForegroundColor Cyan
  Write-Host ''

  Sync-AapKubeconfig

  Write-Host ''
  Write-Host '  oc now connects to OpenShift Local cluster.'
  Write-Host '  Context: aap-demo'
}

function Invoke-AapDemoIdle {
  [CmdletBinding()]
  param(
    [string]$Value = $null,
    [string]$Namespace = $Script:AapDemoDefaultNamespace
  )

  Initialize-AapKubeEnvironment

  $nameResult = Invoke-AapOcCapture @(
    'get', 'aap', '-n', $Namespace, '-o', 'jsonpath={.items[0].metadata.name}'
  )
  $aapName = if ($nameResult.ExitCode -eq 0) { $nameResult.Output.Trim() } else { '' }
  if (-not $aapName) {
    throw "No AAP instance found in namespace $Namespace"
  }

  $currentResult = Invoke-AapOcCapture @(
    'get', 'aap', $aapName, '-n', $Namespace, '-o', 'jsonpath={.spec.idle_aap}'
  )
  $current = if ($currentResult.ExitCode -eq 0) { $currentResult.Output.Trim() } else { '' }

  if (-not $Value) {
    if ($current -eq 'true') {
      Write-Host "AAP '$aapName' is idle (scaled down)"
      Write-Host '  Resume with: aap-demo idle false'
    } else {
      Write-Host "AAP '$aapName' is running"
      Write-Host '  Scale down with: aap-demo idle true'
    }
    return
  }

  switch ($Value.ToLowerInvariant()) {
    'true' {
      if ($current -eq 'true') {
        Write-Host "AAP '$aapName' is already idle"
        return
      }
      Write-Host ''
      Write-Host 'aap-demo idle true - Scaling down AAP deployment...' -ForegroundColor Cyan
      $patch = (@{ spec = @{ idle_aap = $true } } | ConvertTo-Json -Compress)
      Invoke-AapOcPatch @('patch', 'aap', $aapName, '-n', $Namespace) -Patch $patch | Out-Null
      Write-AapStep "AAP '$aapName' set to idle"
      Write-Host '  The operator will scale down AAP components (this may take a minute)'
      Write-Host '  Operator pods, metrics service, and enabled addons may still show Running'
      Write-Host '  Resume with: aap-demo idle false'
    }
    'false' {
      if ($current -ne 'true') {
        Write-Host "AAP '$aapName' is already running"
        return
      }
      Write-Host ''
      Write-Host 'aap-demo idle false - Scaling up AAP deployment...' -ForegroundColor Cyan
      $patch = (@{ spec = @{ idle_aap = $false } } | ConvertTo-Json -Compress)
      Invoke-AapOcPatch @('patch', 'aap', $aapName, '-n', $Namespace) -Patch $patch | Out-Null
      Write-AapStep "AAP '$aapName' waking up"
      Write-Host '  Monitor with: aap-demo watch'
    }
    default {
      throw 'Usage: aap-demo idle [true|false]'
    }
  }
}

function Invoke-AapDemoConfig {
  param([string]$Key = $null, [string]$Value = $null)

  New-Item -ItemType Directory -Force -Path $Script:AapDemoConfigDir | Out-Null
  $path = Get-AapConfigPath

  if (-not $Key) {
    if (Test-Path -LiteralPath $path) {
      Get-Content -LiteralPath $path | ForEach-Object { Write-Host $_ }
    } else {
      Write-Host '(no config)'
    }
    return
  }

  if (-not $Value) {
    $existing = Get-AapConfigValue $Key
    if ($existing) {
      Write-Host "$Key=$existing"
    } else {
      Write-Host '(not set)'
    }
    return
  }

  Set-AapConfigValue $Key $Value
  Write-AapStep "Set $Key=$Value"
}

function Invoke-AapDemoUpdate {
  $repoRoot = Get-AapInstalledRepoRoot
  Push-Location $repoRoot
  try {
    Write-AapStep 'Pulling latest code...'
    & git pull
    if ($LASTEXITCODE -ne 0) { throw 'git pull failed' }
    $install = Join-Path $repoRoot 'powershell\install.ps1'
    Write-AapStep 'Reinstalling launcher...'
    & $install
    if ($LASTEXITCODE -ne 0) { throw 'install.ps1 failed' }
    Write-AapStep 'Update complete'
  } finally {
    Pop-Location
  }
}

function Invoke-AapDemoRedhatStatus {
  Write-Host ''
  Write-Host 'aap-demo redhat-status - Checking Red Hat service status...' -ForegroundColor Cyan
  Write-Host ''

  $rssUrl = 'https://status.redhat.com/history.rss'
  try {
    $rss = (Invoke-WebRequest -Uri $rssUrl -TimeoutSec 10 -UseBasicParsing).Content
  } catch {
    throw "Unable to fetch status from $rssUrl"
  }

  Write-Host 'Active Incidents:'
  Write-Host '================='
  $found = $false
  $items = $rss -split '<item>' | Select-Object -Skip 1
  foreach ($item in $items) {
    if ($item -match '(?i)Resolved|Completed') { continue }
    if ($item -notmatch '(?i)registry|quay|rhsso|login|\b403\b|authentication') { continue }

    $title = $null
    $link = $null
    $status = $null
    if ($item -match "<title>([^<]+)</title>") {
      $title = $Matches[1] -replace "&amp;", "&" -replace "&lt;", "<" -replace "&gt;", ">"
    }
    if ($item -match "<(link|guid)>([^<]+)<") {
      $link = $Matches[2]
    }
    if ($item -match '(Investigating|Identified|Monitoring|In progress|Update)') {
      $status = $Matches[1]
    }
    if ($title) {
      $found = $true
      Write-Host ''
      Write-Host "  WARN $title" -ForegroundColor Yellow
      if ($status) { Write-Host "    Status: $status" }
      if ($link) { Write-Host "    Details: $link" }
    }
  }

  if (-not $found) {
    Write-Host '  OK No active registry-related incidents' -ForegroundColor Green
  }
  Write-Host ''
  Write-Host 'Full status: https://status.redhat.com'
}

function Invoke-AapDemoMustGather {
  param([string]$DestDir = $null)

  Write-Host ''
  Write-Host 'aap-demo must-gather - Collecting diagnostic information...' -ForegroundColor Cyan
  Write-Host ''

  $namespace = $Script:AapDemoDefaultNamespace
  if (-not $DestDir) {
    $DestDir = "must-gather.local.{0:yyyyMMddHHmmss}" -f (Get-Date)
  }

  Initialize-AapKubeEnvironment
  $aapImage = 'registry.redhat.io/ansible-automation-platform-26/aap-must-gather-rhel9:latest'
  $demoDir = Join-Path $DestDir 'aap-demo'
  New-Item -ItemType Directory -Force -Path $demoDir | Out-Null

  Write-Host "Output directory: $DestDir"
  Write-Host ''
  Write-Host 'Collecting aap-demo diagnostics...'

  $configPath = Get-AapConfigPath
  if (Test-Path -LiteralPath $configPath) {
    Copy-Item -LiteralPath $configPath -Destination (Join-Path $demoDir 'config') -Force
  }
  & crc status *> (Join-Path $demoDir 'crc-status.txt')
  & crc version *> (Join-Path $demoDir 'crc-version.txt')

  $dumps = @{
    'storageclasses.yaml' = @('get', 'sc', '-o', 'yaml')
    'pvcs.yaml'           = @('get', 'pvc', '-n', $namespace, '-o', 'yaml')
    'pods.txt'            = @('get', 'pods', '-n', $namespace, '-o', 'wide')
    'events.txt'          = @('get', 'events', '-n', $namespace, "--sort-by=.lastTimestamp")
    'aap-cr.yaml'         = @('get', 'aap', '-n', $namespace, '-o', 'yaml')
    'nfs-pods.txt'        = @('get', 'pods', '-n', 'nfs-storage', '-o', 'wide')
    'coredns-config.yaml' = @('get', 'configmap', '-n', 'openshift-dns', 'dns-default', '-o', 'yaml')
  }
  foreach ($entry in $dumps.GetEnumerator()) {
    $result = Invoke-AapOcCapture $entry.Value
    if ($result.ExitCode -eq 0) {
      Set-Content -LiteralPath (Join-Path $demoDir $entry.Key) -Value $result.Output -Encoding utf8
    }
  }

  $sccPath = Join-Path $demoDir 'scc-bindings.txt'
  $scc = @(
    "=== ClusterRoleBindings (SCC grants) for $namespace ==="
    (Invoke-AapOcCapture @('get', 'clusterrolebinding', '-o', 'wide')).Output |
      Where-Object { $_ -match "scc:.*($namespace|system:serviceaccounts:$namespace)" }
    ''
    "=== RoleBindings in $namespace ==="
    (Invoke-AapOcCapture @('get', 'rolebinding', '-n', $namespace, '-o', 'wide')).Output
  )
  Set-Content -LiteralPath $sccPath -Value $scc -Encoding utf8
  Write-AapStep 'aap-demo diagnostics collected'
  Write-Host ''

  Write-Host 'Running AAP must-gather...'
  Write-Host '  This may take several minutes.'
  Write-Host ''
  $mg = Invoke-AapExternal oc @('adm', 'must-gather', "--image=$aapImage", "--dest-dir=$DestDir")
  $mg.Lines | ForEach-Object { Write-Host "  $_" }

  Write-Host ''
  if ($mg.ExitCode -eq 0) {
    Write-AapStep "Must-gather complete: $DestDir"
  } else {
    Write-AapWarn "AAP must-gather failed (exit code: $($mg.ExitCode))"
    Write-Host '  aap-demo diagnostics were still collected successfully.'
  }

  Write-Host ''
  Write-Host 'Contents:'
  Get-ChildItem -LiteralPath $DestDir | ForEach-Object { Write-Host "  $($_.Name)" }
  Write-Host ''
  Write-Host "To share: tar czf must-gather.tar.gz $DestDir"
}

function Write-AapClusterSummary {
  [CmdletBinding()]
  param(
    [string]$Namespace = $Script:AapDemoDefaultNamespace,
    [string]$Channel = $Script:AapDemoDefaultChannel,
    [string]$OcpVersion = $Script:AapDemoDefaultOcpVersion,
    [string]$CrName = 'minimal',
    [switch]$Force
  )

  $crc = Get-AapCrcStatus
  if ([string]$crc.crcStatus -eq 'Stopped') {
    Invoke-AapCrcStart
  } elseif ([string]$crc.crcStatus -eq 'Unknown') {
    throw 'No cluster found. Run: aap-demo create'
  }

  Invoke-AapDemoClean -Namespace $Namespace
  Start-Sleep -Seconds 2
  Write-Host ''
  Write-Host 'Redeploying AAP...'
  Write-Host ''
  Invoke-AapDemoDeploy -Namespace $Namespace -Channel $Channel -OcpVersion $OcpVersion -CrName $CrName -Force:$Force
}

function Invoke-AapDemoRedeployAll {
  [CmdletBinding()]
  param(
    [string]$Namespace = $Script:AapDemoDefaultNamespace,
    [string]$Channel = $Script:AapDemoDefaultChannel,
    [string]$OcpVersion = $Script:AapDemoDefaultOcpVersion,
    [string]$CrName = 'minimal',
    [switch]$Force
  )

  Invoke-AapDemoDestroy
  Start-Sleep -Seconds 2
  Invoke-AapDemoCreate
  Invoke-AapDemoDeploy -Namespace $Namespace -Channel $Channel -OcpVersion $OcpVersion -CrName $CrName -Force:$Force
}

function Invoke-AapDemoDeployAap {
  [CmdletBinding()]
  param(
    [string]$Namespace = $Script:AapDemoDefaultNamespace,
    [string]$CrName = 'minimal',
    [string]$PublicUrl = $null
  )

  Initialize-AapKubeEnvironment
  Set-AapIngressCaEnvFromSaved
  Invoke-AapApplyAapCr -Namespace $Namespace -CrName $CrName -PublicUrl $PublicUrl
  Invoke-AapDemoWatch -Namespace $Namespace
}
