#Requires -Version 5.1
# Hermetic tests: no CRC, browser, Hyper-V or scheduled task access.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Private = Join-Path $RepoRoot 'powershell/native/Private'
. (Join-Path $Private 'Start.ps1')
. (Join-Path $Private 'Dashboard.ps1')

function Assert-Equal($Expected, $Actual) {
  if ($Expected -cne $Actual) { throw "Expected '$Expected', got '$Actual'" }
}
function Assert-Throws([scriptblock]$Block, [string]$Message) {
  try { & $Block; throw 'Expected exception' } catch {
    if ($_.Exception.Message -notlike $Message) { throw }
  }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('aap-windows-dashboard-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tmp) | Out-Null
$saved = @{}
foreach ($key in @('AAP_DEMO_SKIP_BOOT_RECOVERY', 'AAP_DEMO_DASHBOARD_AUTOSTART', 'AAP_DASHBOARD_TEST_LOG', 'AAP_DASHBOARD_TEST_FAIL')) {
  $saved[$key] = [Environment]::GetEnvironmentVariable($key)
  [Environment]::SetEnvironmentVariable($key, $null)
}
try {
  $Script:AapAvailableAddons = @('mcp-server', 'portal')
  function Get-AapAddonsList { return @('mcp-server') }
  function Get-AapCrcStatus { return @{ crcStatus = $Script:CrcState } }
  $Script:CrcState = 'Stopped'
  $inventory = Get-AapDemoDashboardInventory
  Assert-Equal 'stopped' $inventory.cluster.state
  Assert-Equal 0 $inventory.pods.Count
  Assert-Equal 2 $inventory.supported_addons.Count

  function Invoke-AapOcCapture {
    param([Parameter(Mandatory)][string[]]$Args)
    $json = switch ($Args[0..1] -join ' ') {
      'version -o' { '{"serverVersion":{"gitVersion":"v1.30.1"}}' }
      'get nodes' { '{"items":[{"status":{"nodeInfo":{"osImage":"RHEL 9.6"}}}]}' }
      'get pods' {
        '{"items":[{"metadata":{"name":"mcp","namespace":"aap-operator"},"spec":{"containers":[{}]},"status":{"phase":"Running","containerStatuses":[{"ready":true}]}},{"metadata":{"name":"waiting","namespace":"pending"},"spec":{"containers":[{}]},"status":{"phase":"Pending"}},{"metadata":{"name":"system","namespace":"openshift-dns"},"status":{"phase":"Running"}},{"metadata":{"name":"job","namespace":"aap-operator"},"status":{"phase":"Succeeded"}}]}'
      }
      'get route' { '{"items":[{"metadata":{"name":"aap","namespace":"aap-operator"},"spec":{"host":"aap.test"},"status":{"ingress":[{"conditions":[{"type":"Admitted","status":"True"}]}]}}]}' }
      default { throw "Unexpected oc args: $Args" }
    }
    return @{ ExitCode = 0; Output = $json }
  }
  $Script:CrcState = 'Running'
  $inventory = Get-AapDemoDashboardInventory
  Assert-Equal 'v1.30.1' $inventory.cluster.kubernetes_version
  Assert-Equal 'RHEL 9.6' $inventory.cluster.vm.guest_os
  Assert-Equal 2 $inventory.pods.Count
  Assert-Equal 1 $inventory.pods[0].ready_containers
  Assert-Equal 1 $inventory.pods[1].total_containers
  Assert-Equal $true ($inventory.namespaces | Where-Object { $_.name -eq 'aap-operator' }).ready
  Assert-Equal $false ($inventory.namespaces | Where-Object { $_.name -eq 'pending' }).ready
  Assert-Equal $true $inventory.routes[0].admitted
  Assert-Equal 'https://aap.test' $inventory.routes[0].url
  $roundTrip = $inventory | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json
  Assert-Equal 0 $roundTrip.fleet.Count
  Assert-Equal 'mcp-server' $roundTrip.addons[0]

  function Invoke-AapOcCapture { param([Parameter(Mandatory)][string[]]$Args) return @{ ExitCode = 1; Output = 'Access denied' } }
  Assert-Throws { Get-AapDemoDashboardInventory } '*Cannot collect dashboard status*Access denied*'
  function Get-AapCrcStatus { return $null }
  Assert-Throws { Get-AapDemoDashboardInventory } '*CRC did not return a status*'
  Write-Host 'PASS: native JSON inventory, readiness, missing containers and explicit collection errors'

  & {
    $Script:Calls = @()
    function Invoke-AapDemoService { param([string[]]$Arguments) $Script:Calls += $Arguments -join ' ' }
    Initialize-AapDemoRecovery
    Assert-Equal 'install' ($Script:Calls -join ',')
    $env:AAP_DEMO_SKIP_BOOT_RECOVERY = 'true'
    Initialize-AapDemoRecovery
    Assert-Equal 1 $Script:Calls.Count
    $env:AAP_DEMO_SKIP_BOOT_RECOVERY = $null
    function Invoke-AapDemoService { throw 'Task registration denied' }
    Assert-Throws { Initialize-AapDemoRecovery } '*Task registration denied*'
    function Invoke-AapDemoDashboard { $Script:Calls += 'dashboard' }
    Invoke-AapDemoAutoDashboard
    Assert-Equal 'install,dashboard' ($Script:Calls -join ',')
    $env:AAP_DEMO_DASHBOARD_AUTOSTART = 'false'
    Invoke-AapDemoAutoDashboard
    Assert-Equal 2 $Script:Calls.Count
    $env:AAP_DEMO_DASHBOARD_AUTOSTART = $null
    function Invoke-AapDemoDashboard { throw 'Python unavailable' }
    function Write-AapWarn { param($Message) $Script:Warning = $Message }
    Invoke-AapDemoAutoDashboard
    Assert-Equal $true ($Script:Warning -like '*Python unavailable*')
  }
  Write-Host 'PASS: recovery opt-out and failures; dashboard opt-out and visible warnings'

  & {
    $Script:AapDemoRepoRoot = Join-Path $tmp 'launcher checkout'
    $serverDir = Join-Path $Script:AapDemoRepoRoot 'dashboard'
    [IO.Directory]::CreateDirectory($serverDir) | Out-Null
    $server = Join-Path $serverDir 'server.py'
    Set-Content -LiteralPath $server -Encoding ascii -Value @'
import json
import sys
print(json.dumps(sys.argv[1:]))
'@
    $arguments = Invoke-AapDemoDashboard -NoOpen | ConvertFrom-Json
    Assert-Equal '--repo-root' $arguments[0]
    Assert-Equal $Script:AapDemoRepoRoot $arguments[1]
    Assert-Equal '--background' $arguments[2]
    Assert-Equal '--no-open' $arguments[3]
    $arguments = Invoke-AapDemoDashboard | ConvertFrom-Json
    Assert-Equal 3 $arguments.Count
    Set-Content -LiteralPath $server -Encoding ascii -Value 'import sys; sys.exit(2)'
    Assert-Throws { Invoke-AapDemoDashboard -NoOpen } '*Dashboard failed to start (exit 2)*'
    function Get-Command { param($Name, $CommandType, $ErrorAction) return $null }
    Assert-Throws { Invoke-AapDemoDashboard } '*Dashboard requires Python 3.10+*'
  }
  Write-Host 'PASS: Python launcher arguments, paths with spaces, no-open and startup errors'

  # Run the real dispatcher with a fake module, including paths containing spaces.
  $cliRoot = Join-Path $tmp 'fake checkout'
  [IO.Directory]::CreateDirectory((Join-Path $cliRoot 'native')) | Out-Null
  Copy-Item -LiteralPath (Join-Path $RepoRoot 'powershell/aap-demo.ps1') -Destination $cliRoot
  $module = @'
function Record($Text) { Add-Content -LiteralPath $env:AAP_DASHBOARD_TEST_LOG -Value $Text }
function Assert-AapStateNotManaged { param($Operation) }
function Enter-AapOperationLock { param($Command) Record 'lock'; return 'test-token' }
function Exit-AapOperationLock { param($Token) Record 'unlock' }
function Invoke-AapDemoCreate { Record 'create' }
function Initialize-AapDemoRecovery { Record 'install'; if ($env:AAP_DASHBOARD_TEST_FAIL -eq 'install') { throw 'Install failed' } }
function Invoke-AapDemoStartCommand { Record 'start'; if ($env:AAP_DASHBOARD_TEST_FAIL -eq 'start') { throw 'Start failed' } }
function Invoke-AapDemoRestart { Record 'restart' }
function Invoke-AapDemoAutoDashboard { Record 'auto-dashboard' }
function Invoke-AapDemoDashboard { param([switch]$NoOpen) Record "dashboard no-open=$NoOpen" }
function Get-AapDemoDashboardInventory { return @{ cluster = @{ state = 'running' }; pods = @() } }
Export-ModuleMember -Function *
'@
  Set-Content -LiteralPath (Join-Path $cliRoot 'native/AapDemo.psm1') -Value $module -Encoding ascii
  $env:AAP_DASHBOARD_TEST_LOG = Join-Path $tmp 'dispatch.log'
  $exe = (Get-Process -Id $PID).Path
  foreach ($case in @(
    @{ Args = @('create'); Expected = 'lock,create,install,unlock,auto-dashboard' },
    @{ Args = @('start'); Expected = 'lock,start,unlock,auto-dashboard' },
    @{ Args = @('restart'); Expected = 'lock,restart,unlock,auto-dashboard' },
    @{ Args = @('dashboard', '--no-open'); Expected = 'dashboard no-open=True,unlock' }
  )) {
    [IO.File]::WriteAllText($env:AAP_DASHBOARD_TEST_LOG, '')
    & $exe -NoProfile -File (Join-Path $cliRoot 'aap-demo.ps1') @($case.Args) | Out-Null
    Assert-Equal 0 $LASTEXITCODE
    Assert-Equal $case.Expected ((Get-Content -LiteralPath $env:AAP_DASHBOARD_TEST_LOG) -join ',')
  }
  $json = & $exe -NoProfile -File (Join-Path $cliRoot 'aap-demo.ps1') status --json
  Assert-Equal 0 $LASTEXITCODE
  Assert-Equal 'running' ($json | ConvertFrom-Json).cluster.state
  foreach ($failure in @('install', 'start')) {
    [IO.File]::WriteAllText($env:AAP_DASHBOARD_TEST_LOG, '')
    $env:AAP_DASHBOARD_TEST_FAIL = $failure
    $command = if ($failure -eq 'install') { 'create' } else { 'start' }
    & $exe -NoProfile -File (Join-Path $cliRoot 'aap-demo.ps1') $command | Out-Null
    Assert-Equal 1 $LASTEXITCODE
    Assert-Equal $false ((Get-Content -LiteralPath $env:AAP_DASHBOARD_TEST_LOG) -contains 'auto-dashboard')
  }
  $env:AAP_DASHBOARD_TEST_FAIL = $null
  foreach ($argsList in @(@('start', '--no-open'), @('start', '--json'), @('status', '--json', '--show-secrets'), @('create', '--full-demo'))) {
    & $exe -NoProfile -File (Join-Path $cliRoot 'aap-demo.ps1') @argsList | Out-Null
    Assert-Equal 1 $LASTEXITCODE
  }
  Write-Host 'PASS: dispatcher lifecycle order, lock release, JSON, failure paths and flag validation'
} finally {
  foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
  Remove-Item -LiteralPath $tmp -Recurse -Force
}
