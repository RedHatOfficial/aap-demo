# Native "aap-demo start": resume an existing CRC cluster and wait for core
# and enabled-addon readiness. Mirrors includes/demo-start.sh and
# includes/crc-storage.sh.

$Script:AapStartPollSeconds = 5

function Get-AapJsonProp {
  param($Object, [string[]]$Path)
  $current = $Object
  foreach ($name in $Path) {
    if ($null -eq $current) { return $null }
    if ($current -is [System.Collections.IDictionary]) {
      if (-not $current.Contains($name)) { return $null }
      $current = $current[$name]
      continue
    }
    $prop = $current.PSObject.Properties[$name]
    if (-not $prop) { return $null }
    $current = $prop.Value
  }
  return $current
}

function Get-AapStartTimeoutSeconds {
  $raw = $env:AAP_START_TIMEOUT
  if (-not $raw) { return 600 }
  $value = 0
  if (-not [int]::TryParse($raw, [ref]$value) -or $value -le 0 -or $raw -notmatch '^[0-9]+$') {
    throw "AAP_START_TIMEOUT must be a positive integer number of seconds (got '$raw')"
  }
  return $value
}

function ConvertFrom-AapJsonText {
  param([string]$Text)
  if (-not $Text) { return $null }
  try { return ($Text | ConvertFrom-Json) } catch { return $null }
}

function Test-AapNodesReadyJson {
  param($Nodes)
  $items = @(Get-AapJsonProp $Nodes @('items'))
  $items = @($items | Where-Object { $null -ne $_ })
  if ($items.Count -eq 0) { return $false }
  foreach ($node in $items) {
    $ready = @(@(Get-AapJsonProp $node @('status', 'conditions')) | Where-Object {
        $_ -and (Get-AapJsonProp $_ @('type')) -eq 'Ready' -and (Get-AapJsonProp $_ @('status')) -eq 'True'
      })
    if ($ready.Count -eq 0) { return $false }
  }
  return $true
}

function Test-AapCorefileHasRewrite {
  param([string]$Corefile)
  if (-not $Corefile) { return $false }
  return ($Corefile -match 'rewrite' -and $Corefile -match '127\.0\.0\.1\.nip\.io')
}

function Test-AapConditionComplete {
  param([string]$Successful, [string]$Running, [string]$SuccessfulReason, [string]$Failure)
  if ($Failure -eq 'True') { return $false }
  if ($Successful -eq 'True') { return $true }
  return ($Successful -eq 'False' -and $Running -eq 'True' -and $SuccessfulReason -eq 'Successful')
}

function Test-AapAllAapCompleteJson {
  param($AapList)
  $items = @(@(Get-AapJsonProp $AapList @('items')) | Where-Object { $null -ne $_ })
  if ($items.Count -eq 0) { return $false }
  foreach ($item in $items) {
    $successful = $null; $running = $null; $reason = $null; $failure = $null
    foreach ($cond in @(Get-AapJsonProp $item @('status', 'conditions'))) {
      if (-not $cond) { continue }
      switch ([string](Get-AapJsonProp $cond @('type'))) {
        'Successful' {
          $successful = [string](Get-AapJsonProp $cond @('status'))
          $reason = [string](Get-AapJsonProp $cond @('reason'))
        }
        'Running' { $running = [string](Get-AapJsonProp $cond @('status')) }
        'Failure' { $failure = [string](Get-AapJsonProp $cond @('status')) }
      }
    }
    if (-not (Test-AapConditionComplete $successful $running $reason $failure)) { return $false }
  }
  return $true
}

function Test-AapActivePodsReadyJson {
  param($Pods)
  foreach ($pod in @(@(Get-AapJsonProp $Pods @('items')) | Where-Object { $null -ne $_ })) {
    $phase = [string](Get-AapJsonProp $pod @('status', 'phase'))
    if ($phase -eq 'Succeeded' -or $phase -eq 'Failed') { continue }
    if ($phase -ne 'Running') { return $false }
    $ready = @(@(Get-AapJsonProp $pod @('status', 'conditions')) | Where-Object {
        $_ -and (Get-AapJsonProp $_ @('type')) -eq 'Ready' -and (Get-AapJsonProp $_ @('status')) -eq 'True'
      })
    if ($ready.Count -eq 0) { return $false }
  }
  return $true
}

function Get-AapJsonInt {
  param($Object, [string[]]$Path, [int]$Default = 0)
  $value = Get-AapJsonProp $Object $Path
  if ($null -eq $value -or "$value" -eq '') { return $Default }
  return [int]$value
}

function Test-AapWorkloadsReadyJson {
  param($Workloads, $Pods)
  $items = @(@(Get-AapJsonProp $Workloads @('items')) | Where-Object {
      $null -ne $_ -and -not (Get-AapJsonProp $_ @('metadata', 'deletionTimestamp'))
    })
  if ($items.Count -eq 0) { return $false }
  $anyDesired = $false
  foreach ($w in $items) {
    $kind = [string](Get-AapJsonProp $w @('kind'))
    if ($kind -eq 'DaemonSet') {
      $desired = Get-AapJsonInt $w @('status', 'desiredNumberScheduled') 0
    } else {
      $desired = Get-AapJsonInt $w @('spec', 'replicas') 1
    }
    if ($desired -gt 0) { $anyDesired = $true }
    $generation = Get-AapJsonInt $w @('metadata', 'generation') 0
    $observed = Get-AapJsonInt $w @('status', 'observedGeneration') 0
    if ($observed -lt $generation) { return $false }
    if ($kind -eq 'DaemonSet') {
      if ((Get-AapJsonInt $w @('status', 'numberReady') 0) -ne $desired) { return $false }
      if ((Get-AapJsonInt $w @('status', 'updatedNumberScheduled') 0) -ne $desired) { return $false }
    } else {
      if ((Get-AapJsonInt $w @('status', 'readyReplicas') 0) -ne $desired) { return $false }
      if ($kind -eq 'Deployment') {
        if ((Get-AapJsonInt $w @('status', 'updatedReplicas') 0) -ne $desired) { return $false }
        if ((Get-AapJsonInt $w @('status', 'availableReplicas') 0) -ne $desired) { return $false }
      }
    }
  }
  if (-not $anyDesired) { return $false }
  return (Test-AapActivePodsReadyJson $Pods)
}

function Get-AapStartJson {
  param([Parameter(Mandatory)][string[]]$OcArgs)
  $result = Invoke-AapOcCapture $OcArgs
  if ($result.ExitCode -ne 0) { return $null }
  return (ConvertFrom-AapJsonText $result.Output)
}

function Wait-AapStartCondition {
  param(
    [Parameter(Mandatory)][string]$Description,
    [Parameter(Mandatory)][scriptblock]$Condition,
    [Parameter(Mandatory)][datetime]$Deadline
  )
  Write-Host "  Waiting for $Description..."
  while ($true) {
    $ok = $false
    try { $ok = [bool](& $Condition) } catch { $ok = $false }
    if ($ok) {
      Write-AapStep "$Description ready"
      return $true
    }
    if ((Get-Date) -ge $Deadline) { return $false }
    Start-Sleep -Seconds $Script:AapStartPollSeconds
  }
}

function Write-AapStartNamespaceDiagnostics {
  param([Parameter(Mandatory)][string]$Namespace)
  Write-Host ''
  Write-Host "  Workloads in ${Namespace}:"
  $r = Invoke-AapOcCapture @('get', 'deploy,sts,ds,pods', '-n', $Namespace, '-o', 'wide')
  if ($r.Output) { $r.Lines | ForEach-Object { Write-Host "    $_" } }
  $pods = Get-AapStartJson @('get', 'pods', '-n', $Namespace, '-o', 'json')
  foreach ($pod in @(@(Get-AapJsonProp $pods @('items')) | Where-Object { $null -ne $_ })) {
    foreach ($cond in @(Get-AapJsonProp $pod @('status', 'conditions'))) {
      if ($cond -and (Get-AapJsonProp $cond @('type')) -eq 'PodScheduled' -and (Get-AapJsonProp $cond @('status')) -eq 'False') {
        Write-Host "    Unschedulable $(Get-AapJsonProp $pod @('metadata', 'name')): $(Get-AapJsonProp $cond @('message'))"
      }
    }
  }
  $events = Invoke-AapOcCapture @('get', 'events', '-n', $Namespace, '--sort-by=.lastTimestamp')
  if ($events.Output) {
    Write-Host '  Recent events:'
    @($events.Lines) | Select-Object -Last 15 | ForEach-Object { Write-Host "    $_" }
  }
  Write-Host ''
  Write-Host "  Check 'aap-demo diagnose'; resolve storage, image-pull or resource shortages, then retry 'aap-demo start'."
}

function Wait-AapStartNamespace {
  param([Parameter(Mandatory)][string]$Namespace, [Parameter(Mandatory)][datetime]$Deadline)
  $ok = Wait-AapStartCondition -Description "namespace $Namespace" -Deadline $Deadline -Condition {
    $workloads = Get-AapStartJson @('get', 'deploy,sts,ds', '-n', $Namespace, '-o', 'json')
    $pods = Get-AapStartJson @('get', 'pods', '-n', $Namespace, '-o', 'json')
    if (-not $workloads -or -not $pods) { return $false }
    Test-AapWorkloadsReadyJson $workloads $pods
  }
  if (-not $ok) {
    Write-AapStartNamespaceDiagnostics -Namespace $Namespace
    throw "Namespace $Namespace did not become ready before AAP_START_TIMEOUT"
  }
}

function Get-AapStartExistingNamespaces {
  $r = Invoke-AapOcCapture @('get', 'namespaces', '-o', 'jsonpath={.items[*].metadata.name}')
  if ($r.ExitCode -ne 0) { throw "Cannot list namespaces: $($r.Output)" }
  return @(([string]$r.Output) -split '\s+' | Where-Object { $_ })
}

function Get-AapStartAddonNamespaces {
  param([string[]]$Addons)
  $result = @()
  foreach ($addon in @($Addons)) {
    switch ($addon) {
      'ao' {
        $result += 'cnpg-system'
        if ($env:AO_NAMESPACE) { $result += $env:AO_NAMESPACE } else { $result += 'automation-orchestrator' }
      }
      'ollama' { $result += 'aap-demo-ollama' }
      'portal' { if ($env:PORTAL_NAMESPACE) { $result += $env:PORTAL_NAMESPACE } else { $result += 'redhat-rhaap-portal' } }
      'portal-operator' { $result += 'automation-portal' }
      'apme-eap' { $result += 'apme' }
    }
  }
  return @($result | Select-Object -Unique)
}

function Invoke-AapStartGatewayPing {
  param([Parameter(Mandatory)][string]$Url)
  $params = @{ Uri = $Url; UseBasicParsing = $true; TimeoutSec = 10; ErrorAction = 'Stop' }
  if ($PSVersionTable.PSVersion.Major -ge 7) {
    $params.SkipCertificateCheck = $true
    $resp = Invoke-WebRequest @params
    return ([int]$resp.StatusCode -eq 200)
  }
  $previous = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
  try {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    $resp = Invoke-WebRequest @params
    return ([int]$resp.StatusCode -eq 200)
  } finally {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $previous
  }
}

# ---------------------------------------------------------------------------
# Startup storage policy (mirrors includes/crc-storage.sh): when the CRC guest
# /var filesystem is >= 90% used, grow the VM disk to ceil(actual * 1.2) GiB,
# stop gracefully, start again and verify. One pending target is persisted so
# a failed attempt is retried with the same, larger size.
# ---------------------------------------------------------------------------
$Script:AapStorageGiB = [int64]1073741824

function Get-AapStorageMachineConfigPath {
  return (Join-Path $env:USERPROFILE '.crc\machines\crc\config.json')
}

function Get-AapStoragePendingPath {
  return (Join-Path $Script:AapDemoConfigDir 'storage-growth.pending')
}

function ConvertFrom-AapDfOutput {
  param([string]$Text)
  $lines = @(([string]$Text) -split "`r?`n" | Where-Object { $_.Trim() })
  if ($lines.Count -lt 2) { return $null }
  $fields = @($lines[1].Trim() -split '\s+')
  if ($fields.Count -lt 4) { return $null }
  $total = [int64]0; $used = [int64]0; $avail = [int64]0
  if ($fields[1] -notmatch '^[0-9]+$' -or $fields[2] -notmatch '^[0-9]+$' -or $fields[3] -notmatch '^[0-9]+$') { return $null }
  if (-not [int64]::TryParse($fields[1], [ref]$total) -or -not [int64]::TryParse($fields[2], [ref]$used) -or
    -not [int64]::TryParse($fields[3], [ref]$avail)) { return $null }
  if ($total -le 0 -or $used -gt $total -or $avail -gt $total) { return $null }
  return [PSCustomObject]@{ TotalKiB = $total; UsedKiB = $used; AvailableKiB = $avail }
}

function Get-AapStorageFilesystem {
  $out = $null
  try { $out = Invoke-AapCrcSsh -RemoteCommand 'df -Pk /var' } catch { return $null }
  return (ConvertFrom-AapDfOutput -Text $out)
}

function Test-AapStorageFull {
  param([Parameter(Mandatory)]$Fs)
  return (([int64]$Fs.UsedKiB * 100) -ge ([int64]$Fs.TotalKiB * 90))
}

function Get-AapStorageDiskCapacity {
  param([string]$Path = (Get-AapStorageMachineConfigPath))
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  $json = $null
  try { $json = [IO.File]::ReadAllText($Path) | ConvertFrom-Json } catch { return $null }
  $candidates = New-Object System.Collections.ArrayList
  $driver = $null
  if ($json -and $json.PSObject.Properties['Driver']) { $driver = $json.Driver }
  if ($driver -and $driver.PSObject.Properties['DiskCapacity']) { [void]$candidates.Add($driver.DiskCapacity) }
  if ($driver -and $driver.PSObject.Properties['VMDriver'] -and $driver.VMDriver -and
    $driver.VMDriver.PSObject.Properties['DiskCapacity']) { [void]$candidates.Add($driver.VMDriver.DiskCapacity) }
  foreach ($candidate in $candidates) {
    if ($null -eq $candidate -or $candidate -is [string] -or $candidate -is [bool]) { continue }
    if (-not ($candidate -is [ValueType])) { continue }
    $d = [decimal]0
    try { $d = [decimal]$candidate } catch { continue }
    if ($d -gt 0 -and $d -eq [decimal]::Floor($d) -and $d -le [decimal][int64]::MaxValue) { return [int64]$d }
  }
  return $null
}

function Get-AapStorageGrowthTarget {
  param([Parameter(Mandatory)][int64]$ActualBytes)
  return [int64][decimal]::Ceiling(([decimal]$ActualBytes * 120) / ([decimal]$Script:AapStorageGiB * 100))
}

function Get-AapStorageHostFreeBytes {
  param([Parameter(Mandatory)][string]$Path)
  $full = [IO.Path]::GetFullPath($Path)
  return [int64](New-Object IO.DriveInfo([IO.Path]::GetPathRoot($full))).AvailableFreeSpace
}

function Read-AapStoragePending {
  param([Parameter(Mandatory)][string]$Path)
  $text = ([IO.File]::ReadAllText($Path)).Trim()
  if ($text -notmatch '^([1-9][0-9]*) ([1-9][0-9]*)$') { throw "Invalid pending CRC storage resize: $Path" }
  $before = [int64]0; $target = [int64]0
  if (-not [int64]::TryParse($Matches[1], [ref]$before) -or -not [int64]::TryParse($Matches[2], [ref]$target)) {
    throw "Invalid pending CRC storage resize: $Path"
  }
  return [PSCustomObject]@{ BeforeKiB = $before; TargetGiB = $target }
}

function Write-AapStoragePending {
  param([Parameter(Mandatory)][string]$Path, [int64]$BeforeKiB, [int64]$TargetGiB)
  [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
  $tmp = "$Path.tmp"
  [IO.File]::WriteAllText($tmp, "$BeforeKiB $TargetGiB`n")
  Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Set-AapStorageCrcDiskSize {
  param([Parameter(Mandatory)][int64]$TargetGiB)
  $r = Invoke-AapExternal crc @('config', 'set', 'disk-size', "$TargetGiB")
  if ($r.ExitCode -ne 0) { throw "crc config set disk-size $TargetGiB failed: $($r.Output)" }
}

function Invoke-AapStorageRestart {
  if (-not (Invoke-AapCrcStop)) {
    throw "CRC could not stop gracefully; no forced power-off was attempted. Resolve the shutdown failure and retry 'aap-demo start'"
  }
  Invoke-AapCrcStart
  Initialize-AapKubeEnvironment
}

function Invoke-AapStartStorage {
  [CmdletBinding()]
  param()
  $fs = Get-AapStorageFilesystem
  if (-not $fs) { throw "Could not check CRC disk usage (df /var over SSH); check 'aap-demo ssh' before retrying" }
  $pct = [int][Math]::Floor(([decimal]$fs.UsedKiB * 100) / [decimal]$fs.TotalKiB)
  Write-Host "CRC filesystem: $pct% used; $([int64][Math]::Floor($fs.AvailableKiB / 1048576)) GiB available"

  $pending = Get-AapStoragePendingPath
  $hasPending = Test-Path -LiteralPath $pending -PathType Leaf
  if (-not $hasPending -and -not (Test-AapStorageFull $fs)) { return }

  if ($hasPending) {
    $p = Read-AapStoragePending -Path $pending
    if ($fs.TotalKiB -gt $p.BeforeKiB -and -not (Test-AapStorageFull $fs)) {
      Remove-Item -LiteralPath $pending -Force
      return
    }
    $before = $p.BeforeKiB; $target = $p.TargetGiB
    Write-Host "Retrying the pending CRC disk growth to $target GiB..."
  } else {
    $metadata = Get-AapStorageMachineConfigPath
    $actual = Get-AapStorageDiskCapacity -Path $metadata
    if ($null -eq $actual) {
      throw "Cannot determine the existing CRC disk capacity (Driver.DiskCapacity bytes) from $metadata; the disk was not resized"
    }
    $target = Get-AapStorageGrowthTarget -ActualBytes $actual
    $needed = ($target * $Script:AapStorageGiB) - $actual
    $free = Get-AapStorageHostFreeBytes -Path (Split-Path -Parent $metadata)
    if ($free -lt $needed) {
      throw "Not enough host disk space to grow CRC to $target GiB (need $needed bytes, $free free)"
    }
    $before = $fs.TotalKiB
    Write-AapStoragePending -Path $pending -BeforeKiB $before -TargetGiB $target
    Write-Host "CRC filesystem is at least 90% full; growing the VM disk by 20% to $target GiB."
  }

  # Persist the target before restarting; a retry must not request the old, smaller disk.
  Set-AapStorageCrcDiskSize -TargetGiB $target
  Set-AapConfigValue -Key 'CRC_DISK' -Value "$target"
  $env:CRC_DISK = "$target"

  Write-Host 'Stopping CRC briefly so CRC can grow its disk and root filesystem...'
  Invoke-AapStorageRestart

  $fs = Get-AapStorageFilesystem
  if (-not $fs) { throw 'Could not verify the CRC filesystem after disk growth; the target is preserved for retry' }
  $actual = Get-AapStorageDiskCapacity -Path (Get-AapStorageMachineConfigPath)
  if ($null -eq $actual -or $actual -lt ($target * $Script:AapStorageGiB) -or $fs.TotalKiB -le $before -or (Test-AapStorageFull $fs)) {
    throw 'CRC disk/filesystem growth was not completed or usage remains at least 90%; the target is preserved for retry'
  }
  Remove-Item -LiteralPath $pending -Force
  $pct = [int][Math]::Floor(([decimal]$fs.UsedKiB * 100) / [decimal]$fs.TotalKiB)
  Write-Host "CRC storage grown to $target GiB; filesystem usage is now $pct%"
}

function Invoke-AapDemoStart {
  [CmdletBinding()]
  param([string]$Namespace = $Script:AapDemoDefaultNamespace)

  Write-Host ''
  Write-Host 'aap-demo start - Starting cluster and waiting for AAP readiness...' -ForegroundColor Cyan
  $timeout = Get-AapStartTimeoutSeconds
  $deadline = (Get-Date).AddSeconds($timeout)

  $crc = Get-AapCrcStatus
  $state = [string]$crc.crcStatus
  if ($state -eq 'Unknown' -or -not $state) {
    throw "No CRC cluster found (status '$state'). Run: aap-demo create"
  }
  if ($state -ne 'Running') {
    Invoke-AapCrcStart
  } else {
    Write-AapStep 'CRC cluster already running'
  }
  Initialize-AapKubeEnvironment
  Invoke-AapStartStorage

  if (-not (Wait-AapStartCondition -Description 'Kubernetes API' -Deadline $deadline -Condition {
        (Invoke-AapOcCapture @('get', '--raw=/readyz', '--request-timeout=5s')).ExitCode -eq 0
      })) {
    throw 'Kubernetes API did not become ready before AAP_START_TIMEOUT'
  }
  if (-not (Wait-AapStartCondition -Description 'nodes' -Deadline $deadline -Condition {
        Test-AapNodesReadyJson (Get-AapStartJson @('get', 'nodes', '-o', 'json'))
      })) {
    throw 'Cluster nodes did not become Ready before AAP_START_TIMEOUT'
  }

  $cm = Get-AapStartJson @('get', 'configmap', 'dns-default', '-n', 'openshift-dns', '-o', 'json')
  if (-not (Test-AapCorefileHasRewrite ([string](Get-AapJsonProp $cm @('data', 'Corefile'))))) {
    Write-AapWarn 'CoreDNS nip.io rewrite missing; reapplying'
    Set-AapCoreDns -RouteDomain 'apps.127.0.0.1.nip.io'
    $cm = Get-AapStartJson @('get', 'configmap', 'dns-default', '-n', 'openshift-dns', '-o', 'json')
    if (-not (Test-AapCorefileHasRewrite ([string](Get-AapJsonProp $cm @('data', 'Corefile'))))) {
      throw 'CoreDNS rewrite for 127.0.0.1.nip.io could not be applied; check openshift-dns'
    }
  }
  Write-AapStep 'CoreDNS nip.io rewrite present'

  $existing = Get-AapStartExistingNamespaces
  foreach ($ns in @('openshift-ovn-kubernetes', 'kube-proxy', 'openshift-dns', 'openshift-service-ca',
      'openshift-ingress', 'openshift-storage', 'nfs-storage', 'olm', 'openshift-operator-lifecycle-manager')) {
    if ($existing -contains $ns) { Wait-AapStartNamespace -Namespace $ns -Deadline $deadline }
  }

  try {
    Install-AapIngressCaTrust -Quiet
  } catch {
    Write-AapWarn "Ingress CA trust refresh skipped: $($_.Exception.Message)"
  }

  $aap = Get-AapStartJson @('get', 'aap', '-n', $Namespace, '-o', 'json')
  $aapItems = @(@(Get-AapJsonProp $aap @('items')) | Where-Object { $null -ne $_ })
  if ($aapItems.Count -eq 0) {
    throw "No readable AAP deployment in $Namespace; run 'aap-demo deploy' first"
  }
  foreach ($item in $aapItems) {
    if ((Get-AapJsonProp $item @('spec', 'idle_aap')) -eq $true) {
      $name = [string](Get-AapJsonProp $item @('metadata', 'name'))
      Write-AapStep "Resuming idle AAP instance $name"
      Invoke-AapOcPatch -Args @('patch', 'aap', $name, '-n', $Namespace) -Patch '{"spec":{"idle_aap":false}}' | Out-Null
    }
  }

  $addons = @(Get-AapAddonsList)
  foreach ($addon in $addons) {
    $deployName = $null
    switch ($addon) { 'mcp-server' { $deployName = 'aap-mcp-server' } 'opa' { $deployName = 'opa' } }
    if (-not $deployName) { continue }
    if ((Invoke-AapOcCapture @('get', 'deployment', $deployName, '-n', $Namespace)).ExitCode -ne 0) {
      throw "Enabled addon '$addon' is missing; restore it with 'aap-demo enable $addon'"
    }
  }

  Wait-AapStartNamespace -Namespace $Namespace -Deadline $deadline

  if (-not (Wait-AapStartCondition -Description 'AAP custom resources' -Deadline $deadline -Condition {
        Test-AapAllAapCompleteJson (Get-AapStartJson @('get', 'aap', '-n', $Namespace, '-o', 'json'))
      })) {
    $yaml = Invoke-AapOcCapture @('get', 'aap', '-n', $Namespace, '-o', 'yaml')
    if ($yaml.Output) { Write-Host $yaml.Output }
    throw "AAP did not report complete before AAP_START_TIMEOUT; run 'aap-demo diagnose'"
  }

  $routeHost = $null
  $route = Invoke-AapOcCapture @('get', 'route', 'aap', '-n', $Namespace, '-o', 'jsonpath={.spec.host}')
  if ($route.ExitCode -eq 0 -and $route.Output) { $routeHost = $route.Output.Trim() }
  if (-not $routeHost) { throw "AAP route 'aap' not found in $Namespace" }
  $pingUrl = "https://$routeHost/api/gateway/v1/ping/"
  if (-not (Wait-AapStartCondition -Description 'AAP gateway' -Deadline $deadline -Condition {
        Invoke-AapStartGatewayPing -Url $pingUrl
      })) {
    throw "AAP gateway $pingUrl did not respond before AAP_START_TIMEOUT"
  }

  foreach ($ns in (Get-AapStartAddonNamespaces -Addons $addons)) {
    Wait-AapStartNamespace -Namespace $ns -Deadline $deadline
  }
  foreach ($addon in @($addons | Where-Object { $_ -in @('fleet', 'wire') })) {
    Write-AapWarn "Addon '$addon' is Linux-only; native PowerShell start does not manage it"
  }

  Write-Host ''
  Write-AapStep 'AAP is ready'
  Write-AapClusterSummary -Namespace $Namespace
}
