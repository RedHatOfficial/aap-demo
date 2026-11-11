function Invoke-AapDemoDashboard {
  [CmdletBinding()]
  param([switch]$NoOpen)

  $server = Join-Path $Script:AapDemoRepoRoot 'dashboard/server.py'
  if (-not (Test-Path -LiteralPath $server -PathType Leaf)) { throw "Dashboard server not found: $server" }
  $python = $null
  foreach ($name in @('python', 'python3', 'py')) {
    $candidate = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $candidate) { continue }
    $prefix = @()
    if ($name -eq 'py') { $prefix = @('-3') }
    & $candidate.Source @prefix -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>$null
    if ($LASTEXITCODE -eq 0) { $python = $candidate.Source; break }
  }
  if (-not $python) { throw 'Dashboard requires Python 3.10+ on PATH (python, python3 or py -3)' }
  $serverArgs = @($prefix) + @($server, '--repo-root', $Script:AapDemoRepoRoot, '--background')
  if ($NoOpen) { $serverArgs += '--no-open' }
  & $python @serverArgs
  if ($LASTEXITCODE -ne 0) { throw "Dashboard failed to start (exit $LASTEXITCODE); see ~/.aap-demo/dashboard.log" }
}

function Invoke-AapDemoAutoDashboard {
  if ($env:AAP_DEMO_DASHBOARD_AUTOSTART -eq 'false') { return }
  try { Invoke-AapDemoDashboard } catch {
    Write-AapWarn "Dashboard could not start: $($_.Exception.Message). Retry: aap-demo dashboard"
  }
}

function Initialize-AapDemoRecovery {
  if ($env:AAP_DEMO_SKIP_BOOT_RECOVERY -eq 'true') { return }
  # The dispatcher already holds the operation lock; do not launch a second CLI.
  Invoke-AapDemoService -Arguments @('install')
}

function Get-AapDashboardResource {
  param([string[]]$Arguments)
  $result = Invoke-AapOcCapture -Args $Arguments
  if ($result.ExitCode -ne 0) { throw "Cannot collect dashboard status: oc $($Arguments -join ' '): $($result.Output)" }
  return ($result.Output | ConvertFrom-Json)
}

function Get-AapDemoDashboardInventory {
  $crc = Get-AapCrcStatus
  if ($null -eq $crc -or -not (Get-AapJsonProp $crc @('crcStatus'))) { throw 'Cannot collect dashboard status: CRC did not return a status' }
  $state = ([string]$crc.crcStatus).ToLowerInvariant()
  $inventory = [ordered]@{
    schema_version = 1
    host = @{ os = [Environment]::OSVersion.VersionString; architecture = $env:PROCESSOR_ARCHITECTURE }
    cluster = @{ name = 'crc'; state = $state; kubernetes_version = 'unknown'; vm = @{} }
    addons = @(Get-AapAddonsList)
    supported_addons = @($Script:AapAvailableAddons)
    namespaces = @()
    pods = @()
    routes = @()
    fleet = @()
  }
  if ($state -ne 'running') { return $inventory }

  $version = Get-AapDashboardResource @('version', '-o', 'json')
  $inventory.cluster.kubernetes_version = Get-AapJsonProp $version @('serverVersion', 'gitVersion')
  $nodes = Get-AapDashboardResource @('get', 'nodes', '-o', 'json')
  $nodeItems = @(Get-AapJsonProp $nodes @('items'))
  if ($nodeItems.Count -gt 0 -and $null -ne $nodeItems[0]) {
    $inventory.cluster.vm.guest_os = Get-AapJsonProp $nodeItems[0] @('status', 'nodeInfo', 'osImage')
  }
  $pods = Get-AapDashboardResource @('get', 'pods', '-A', '-o', 'json')
  $inventory.pods = @(
    foreach ($pod in @(Get-AapJsonProp $pods @('items'))) {
      if ($null -eq $pod) { continue }
      $namespace = [string](Get-AapJsonProp $pod @('metadata', 'namespace'))
      $phase = [string](Get-AapJsonProp $pod @('status', 'phase'))
      if ($namespace -match '^(openshift-|kube-)' -or $namespace -in @('default', 'olm') -or $phase -eq 'Succeeded') { continue }
      $containers = @(@(Get-AapJsonProp $pod @('status', 'containerStatuses')) | Where-Object { $null -ne $_ })
      @{
        namespace = $namespace
        name = Get-AapJsonProp $pod @('metadata', 'name')
        phase = $phase
        ready_containers = @($containers | Where-Object { (Get-AapJsonProp $_ @('ready')) -eq $true }).Count
        total_containers = @(@(Get-AapJsonProp $pod @('spec', 'containers')) | Where-Object { $null -ne $_ }).Count
      }
    }
  )
  $inventory.namespaces = @(
    foreach ($group in @($inventory.pods | Group-Object namespace)) {
      $ready = @($group.Group | Where-Object { $_.phase -eq 'Running' -and $_.ready_containers -eq $_.total_containers }).Count
      @{
        name = $group.Name
        running_pods = @($group.Group | Where-Object { $_.phase -eq 'Running' }).Count
        total_pods = $group.Count
        ready = $ready -eq $group.Count
      }
    }
  )
  $routes = Get-AapDashboardResource @('get', 'route', '-A', '-o', 'json')
  $inventory.routes = @(
    foreach ($route in @(Get-AapJsonProp $routes @('items'))) {
      if ($null -eq $route) { continue }
      $namespace = [string](Get-AapJsonProp $route @('metadata', 'namespace'))
      if ($namespace -match '^(openshift-|kube-)') { continue }
      $hostName = [string](Get-AapJsonProp $route @('spec', 'host'))
      $admitted = $false
      foreach ($ingress in @(Get-AapJsonProp $route @('status', 'ingress'))) {
        foreach ($condition in @(Get-AapJsonProp $ingress @('conditions'))) {
          if ((Get-AapJsonProp $condition @('type')) -eq 'Admitted' -and (Get-AapJsonProp $condition @('status')) -eq 'True') { $admitted = $true }
        }
      }
      @{
        namespace = $namespace
        name = Get-AapJsonProp $route @('metadata', 'name')
        host = $hostName
        url = "https://$hostName"
        admitted = $admitted
      }
    }
  )
  return $inventory
}
