#Requires -Version 5.1
# Hermetic regression tests for the native Windows PowerShell CLI:
# static parsing, dispatcher wiring, start readiness logic, operation lock and
# the cold checkpoint/restore state service. No VM, crc, oc, Hyper-V or
# Task Scheduler is touched; all state lives under test/.native-state-tmp.
#
# Run: pwsh -NoProfile -File test/test-windows-platform.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$PsRoot = Join-Path $RepoRoot 'powershell'
$Private = Join-Path (Join-Path $PsRoot 'native') 'Private'
$TmpRoot = Join-Path $PSScriptRoot '.native-state-tmp'

$Script:Passed = 0
$Script:Failed = 0

function Pass([string]$Name) { $Script:Passed++; Write-Host "  PASS  $Name" }
function Fail([string]$Name, [string]$Detail) { $Script:Failed++; Write-Host "  FAIL  $Name :: $Detail" -ForegroundColor Red }

function Assert-True {
  param([string]$Name, $Condition, [string]$Detail = 'expected true')
  if ($Condition) { Pass $Name } else { Fail $Name $Detail }
}

function Assert-Equal {
  param([string]$Name, $Expected, $Actual)
  if ($Expected -eq $Actual) { Pass $Name } else { Fail $Name "expected '$Expected', got '$Actual'" }
}

function Assert-Throws {
  param([string]$Name, [scriptblock]$Block, [string]$Like = '*')
  try {
    & $Block | Out-Null
    Fail $Name 'expected an exception'
  } catch {
    if ($_.Exception.Message -like $Like) { Pass $Name } else { Fail $Name "unexpected message: $($_.Exception.Message)" }
  }
}

function Invoke-Case {
  param([string]$Name, [scriptblock]$Block)
  try { & $Block } catch { Fail $Name "unexpected exception: $($_.Exception.Message)" }
}

Write-Host 'Native Windows PowerShell platform tests'

# ---------------------------------------------------------------------------
# Static parsing
# ---------------------------------------------------------------------------
$files = @(Get-ChildItem -LiteralPath $PsRoot -Recurse -File -Include '*.ps1', '*.psm1') + @(Get-Item -LiteralPath $PSCommandPath)
foreach ($f in $files) {
  $tokens = $null; $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
  $rel = $f.FullName.Substring($RepoRoot.Length + 1)
  if ($errors -and $errors.Count -gt 0) { Fail "parse $rel" (($errors | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ') } else { Pass "parse $rel" }
}

foreach ($name in @('OperationLock.ps1', 'Start.ps1', 'StateService.ps1', 'Dashboard.ps1')) {
  $text = [IO.File]::ReadAllText((Join-Path $Private $name))
  Assert-True "PS 5.1 syntax $name (no ?? or ?.)" (-not ($text -match '\?\?|\?\.')) 'null-coalescing operators are PowerShell 7 only'
  Assert-True "ASCII $name" (-not ($text -match '[^\x00-\x7F]')) 'non-ASCII characters break Windows PowerShell 5.1 without a BOM'
}

# ---------------------------------------------------------------------------
# Dispatcher and module wiring
# ---------------------------------------------------------------------------
$dispatcher = [IO.File]::ReadAllText((Join-Path $PsRoot 'aap-demo.ps1'))
Assert-True 'dispatcher start case' ($dispatcher -match "'start'\s*\{\s*Invoke-AapDemoStartCommand")
Assert-True 'dispatcher restart case' ($dispatcher -match "'restart'\s*\{\s*Invoke-AapDemoRestart")
Assert-True 'dispatcher stop uses state-aware stop' ($dispatcher -match "'stop'\s*\{\s*Invoke-AapDemoStopCommand")
Assert-True 'dispatcher service case' ($dispatcher -match 'Invoke-AapDemoService -Arguments')
Assert-True 'dispatcher guards destructive commands' ($dispatcher -match "'create', 'destroy', 'redeploy-all'" -and $dispatcher -match 'Assert-AapStateNotManaged')
Assert-True 'dispatcher takes operation lock' ($dispatcher -match 'Enter-AapOperationLock' -and $dispatcher -match 'finally')
$commands = [IO.File]::ReadAllText((Join-Path $Private 'Commands.ps1'))
Assert-True 'maintenance uninstall guarded' ($commands -match "Assert-AapStateNotManaged -Operation 'maintenance uninstall --apply'")
Assert-Equal 'single Write-AapClusterSummary definition' 1 ([regex]::Matches($commands, '(?m)^function Write-AapClusterSummary\b').Count)
Assert-True 'redeploy function defined' ($commands -match '(?m)^function Invoke-AapDemoRedeploy\b')

$psm1 = [IO.File]::ReadAllText((Join-Path (Join-Path $PsRoot 'native') 'AapDemo.psm1'))
foreach ($fn in @('Invoke-AapDemoStart', 'Invoke-AapDemoStartCommand', 'Invoke-AapDemoStopCommand', 'Invoke-AapDemoRestart', 'Invoke-AapDemoService', 'Enter-AapOperationLock', 'Exit-AapOperationLock', 'Assert-AapStateNotManaged')) {
  Assert-True "module exports $fn" ($psm1 -match "'$fn'")
}
foreach ($src in @('OperationLock.ps1', 'Start.ps1', 'StateService.ps1')) {
  Assert-True "module loads $src" ($psm1 -match [regex]::Escape("'$src'"))
}
# Every exported function must be defined somewhere in Private.
$allPrivate = (Get-ChildItem -LiteralPath $Private -Filter '*.ps1' | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
$exportBlock = [regex]::Match($psm1, 'Export-ModuleMember -Function @\(([\s\S]*?)\)').Groups[1].Value
foreach ($m in [regex]::Matches($exportBlock, "'([A-Za-z-]+)'")) {
  $fn = $m.Groups[1].Value
  Assert-True "exported $fn defined" ($allPrivate -match "(?m)^function $([regex]::Escape($fn))\b")
}

# ---------------------------------------------------------------------------
# Load native units with hermetic stubs
# ---------------------------------------------------------------------------
if (Test-Path -LiteralPath $TmpRoot) { Remove-Item -LiteralPath $TmpRoot -Recurse -Force }
[IO.Directory]::CreateDirectory($TmpRoot) | Out-Null

$savedEnv = @{}
foreach ($k in @('AAP_DEMO_STATE_TEST', 'AAP_DEMO_STATE_ROOT', 'AAP_DEMO_STATE_HOME', 'AAP_DEMO_LOCK_TOKEN', 'AAP_DEMO_DISABLE_LOCK', 'AAP_DEMO_SERVICE_INTERNAL', 'AAP_START_TIMEOUT')) {
  $savedEnv[$k] = [Environment]::GetEnvironmentVariable($k)
  [Environment]::SetEnvironmentVariable($k, $null)
}

function Write-AapStep { param([string]$Message) }
function Write-AapWarn { param([string]$Message) }
function Write-AapErr { param([string]$Message) }
function Invoke-AapDemoAutoDashboard { }

$Script:AapDemoRepoRoot = $RepoRoot
$Script:AapDemoConfigDir = Join-Path $TmpRoot 'config'

. (Join-Path $Private 'Start.ps1')
. (Join-Path $Private 'OperationLock.ps1')
. (Join-Path $Private 'StateService.ps1')

try {
  # -------------------------------------------------------------------------
  # Start readiness logic
  # -------------------------------------------------------------------------
  Invoke-Case 'readiness json' {
    $nodes = '{"items":[{"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}' | ConvertFrom-Json
    Assert-True 'nodes ready' (Test-AapNodesReadyJson $nodes)
    $nodesBad = '{"items":[{"status":{"conditions":[{"type":"Ready","status":"False"}]}}]}' | ConvertFrom-Json
    Assert-True 'nodes not ready' (-not (Test-AapNodesReadyJson $nodesBad))
    Assert-True 'no nodes not ready' (-not (Test-AapNodesReadyJson ('{"items":[]}' | ConvertFrom-Json)))

    Assert-True 'corefile rewrite' (Test-AapCorefileHasRewrite "rewrite name regex (.*)\.apps-crc\.testing 127.0.0.1.nip.io")
    Assert-True 'corefile missing rewrite' (-not (Test-AapCorefileHasRewrite 'forward . /etc/resolv.conf'))

    Assert-True 'condition successful' (Test-AapConditionComplete 'True' '' '' '')
    Assert-True 'condition running+reason' (Test-AapConditionComplete 'False' 'True' 'Successful' '')
    Assert-True 'condition failure' (-not (Test-AapConditionComplete 'True' '' '' 'True'))
    Assert-True 'condition pending' (-not (Test-AapConditionComplete 'False' 'True' 'Running' ''))

    $aapOk = '{"items":[{"status":{"conditions":[{"type":"Successful","status":"True","reason":"Successful"},{"type":"Running","status":"False"}]}}]}' | ConvertFrom-Json
    $aapBad = '{"items":[{"status":{"conditions":[{"type":"Successful","status":"True"},{"type":"Failure","status":"True"}]}}]}' | ConvertFrom-Json
    Assert-True 'aap complete' (Test-AapAllAapCompleteJson $aapOk)
    Assert-True 'aap failure not complete' (-not (Test-AapAllAapCompleteJson $aapBad))
    Assert-True 'no aap not complete' (-not (Test-AapAllAapCompleteJson ('{"items":[]}' | ConvertFrom-Json)))

    $podsOk = '{"items":[{"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}},{"status":{"phase":"Succeeded"}}]}' | ConvertFrom-Json
    $podsBad = '{"items":[{"status":{"phase":"Pending"}}]}' | ConvertFrom-Json
    Assert-True 'pods ready' (Test-AapActivePodsReadyJson $podsOk)
    Assert-True 'pods pending' (-not (Test-AapActivePodsReadyJson $podsBad))

    $wlOk = '{"items":[{"kind":"Deployment","metadata":{"generation":2},"spec":{"replicas":1},"status":{"observedGeneration":2,"readyReplicas":1,"updatedReplicas":1,"availableReplicas":1}},{"kind":"StatefulSet","metadata":{"generation":1},"spec":{"replicas":1},"status":{"observedGeneration":1,"readyReplicas":1}}]}' | ConvertFrom-Json
    $wlIdle = '{"items":[{"kind":"Deployment","metadata":{"generation":1},"spec":{"replicas":0},"status":{"observedGeneration":1}}]}' | ConvertFrom-Json
    $wlStale = '{"items":[{"kind":"Deployment","metadata":{"generation":3},"spec":{"replicas":1},"status":{"observedGeneration":2,"readyReplicas":1,"updatedReplicas":1,"availableReplicas":1}}]}' | ConvertFrom-Json
    Assert-True 'workloads ready' (Test-AapWorkloadsReadyJson $wlOk $podsOk)
    Assert-True 'workloads all idle not ready' (-not (Test-AapWorkloadsReadyJson $wlIdle $podsOk))
    Assert-True 'workloads stale generation' (-not (Test-AapWorkloadsReadyJson $wlStale $podsOk))
    Assert-True 'workloads bad pods' (-not (Test-AapWorkloadsReadyJson $wlOk $podsBad))

    Assert-Equal 'start timeout default' 600 (Get-AapStartTimeoutSeconds)
    $env:AAP_START_TIMEOUT = '45'
    Assert-Equal 'start timeout override' 45 (Get-AapStartTimeoutSeconds)
    $env:AAP_START_TIMEOUT = 'abc'
    Assert-Throws 'start timeout invalid' { Get-AapStartTimeoutSeconds } '*positive integer*'
    $env:AAP_START_TIMEOUT = $null

    $dict = [ordered]@{ a = @{ b = 3 } }
    Assert-Equal 'json prop dictionary' 3 (Get-AapJsonProp $dict @('a', 'b'))
    Assert-Equal 'json prop missing' $null (Get-AapJsonProp $dict @('x', 'y'))
  }

  # -------------------------------------------------------------------------
  # Operation lock
  # -------------------------------------------------------------------------
  Invoke-Case 'operation lock' {
    $lockDir = Join-Path $Script:AapDemoConfigDir 'operation.lock'
    $owner = Join-Path $lockDir 'owner'
    $t1 = Enter-AapOperationLock -Command 'test'
    Assert-True 'lock acquired' ($t1 -and (Test-Path -LiteralPath $owner))
    Assert-Equal 'lock token exported' $t1 $env:AAP_DEMO_LOCK_TOKEN
    $t2 = Enter-AapOperationLock -Command 'nested'
    Assert-Equal 'lock re-entrant returns null' $null $t2
    Exit-AapOperationLock -Token $t2
    Assert-True 'nested exit keeps lock' (Test-Path -LiteralPath $owner)
    Exit-AapOperationLock -Token $t1
    Assert-True 'lock released' (-not (Test-Path -LiteralPath $lockDir))
    Assert-Equal 'lock token cleared' $null $env:AAP_DEMO_LOCK_TOKEN

    # Contention: live owner (this process) with a foreign token.
    [IO.Directory]::CreateDirectory($lockDir) | Out-Null
    [IO.File]::WriteAllText($owner, "pid=$PID`ntoken=othertoken`ncommand=deploy`nstarted=now`n")
    $saved = $Script:AapLockAcquireTimeoutSeconds
    $Script:AapLockAcquireTimeoutSeconds = 1
    Assert-Throws 'lock contention fails' { Enter-AapOperationLock -Command 'stop' } "*Another aap-demo operation is running*'deploy'*"
    $Script:AapLockAcquireTimeoutSeconds = $saved

    # Stale owner (dead pid) is reclaimed.
    [IO.File]::WriteAllText($owner, "pid=999999999`ntoken=stale`ncommand=create`nstarted=then`n")
    $t3 = Enter-AapOperationLock -Command 'start'
    Assert-True 'stale lock reclaimed' ($t3 -and ([IO.File]::ReadAllText($owner) -match "token=$t3"))
    Exit-AapOperationLock -Token $t3

    $env:AAP_DEMO_DISABLE_LOCK = 'true'
    Assert-Equal 'lock disabled' $null (Enter-AapOperationLock -Command 'x')
    $env:AAP_DEMO_DISABLE_LOCK = $null
  }

  # -------------------------------------------------------------------------
  # State service fixtures
  # -------------------------------------------------------------------------
  $env:AAP_DEMO_STATE_TEST = '1'
  $env:AAP_DEMO_STATE_ROOT = Join-Path $TmpRoot 'state'
  $homePath = Join-Path $TmpRoot 'home'
  $env:AAP_DEMO_STATE_HOME = $homePath

  $Script:Fake = @{
    CrcStatus = 'Stopped'; VmState = 'Off'; VMId = 'vm-1111'; Supported = $true; Reason = $null
    StopResult = $true; StopCalls = 0; StartCalls = 0; FreeBytes = [int64]1TB; MoveFailAt = 0; MoveCalls = 0
  }

  function Get-AapStateHyperVLayout {
    param([Parameter(Mandatory)][string]$HomePath)
    return @{ Supported = $Script:Fake.Supported; Reason = $Script:Fake.Reason; VMName = 'crc'; VMId = $Script:Fake.VMId; State = $Script:Fake.VmState; Disks = @('.crc/machines/crc/crc.vhdx'); AutomaticStopAction = 'ShutDown' }
  }
  function Get-AapStateCrcStatus { return $Script:Fake.CrcStatus }
  function Invoke-AapStateCrcStop {
    $Script:Fake.StopCalls++
    if ($Script:Fake.StopResult) { $Script:Fake.CrcStatus = 'Stopped'; $Script:Fake.VmState = 'Off' }
    return $Script:Fake.StopResult
  }
  function Invoke-AapStateClusterStart { $Script:Fake.StartCalls++ }
  function Invoke-AapDemoStart { $Script:Fake.StartCalls++ }
  function Invoke-AapDemoStop { $Script:Fake.StopCalls++ }
  function Get-AapStateFreeBytes { param([string]$Path) return $Script:Fake.FreeBytes }
  function Copy-AapStateAcl { param([string]$Source, [string]$Destination) }
  function Move-AapStatePath {
    param([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To)
    $Script:Fake.MoveCalls++
    if ($Script:Fake.MoveFailAt -gt 0 -and $Script:Fake.MoveCalls -eq $Script:Fake.MoveFailAt) { throw 'simulated move failure' }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $To)) | Out-Null
    [IO.File]::Move($From, $To)
  }

  function Write-Fixture([string]$Rel, [string]$Content) {
    $p = Join-AapStatePath -Base $homePath -Relative $Rel
    [IO.Directory]::CreateDirectory((Split-Path -Parent $p)) | Out-Null
    [IO.File]::WriteAllText($p, $Content)
  }
  function Read-Fixture([string]$Rel) { return [IO.File]::ReadAllText((Join-AapStatePath -Base $homePath -Relative $Rel)) }
  function Test-Fixture([string]$Rel) { return [IO.File]::Exists((Join-AapStatePath -Base $homePath -Relative $Rel)) }

  Write-Fixture '.crc/machines/crc/crc.vhdx' 'disk-v1'
  Write-Fixture '.crc/machines/crc/config.json' '{"Driver":{"BundleName":"crc_microshift_hyperv_4.18.2_amd64.crcbundle"}}'
  Write-Fixture '.crc/machines/crc/kubeconfig' 'kube-v1'
  Write-Fixture '.crc/machines/crc/Virtual Machines/ABC.vmcx' 'hyperv-owned'
  Write-Fixture '.crc/machines/crc/ABC.vmgs' 'hyperv-owned'
  Write-Fixture '.crc/crc.json' '{}'
  Write-Fixture '.crc/cache/crc_microshift_hyperv_4.18.2_amd64/marker' 'bundle'
  Write-Fixture '.aap-demo/config' 'PRESET=minimal'
  Write-Fixture '.aap-demo/pull-secret.txt' 'secret'
  Write-Fixture '.aap-demo/operation.lock/owner' 'pid=1'
  Write-Fixture '.aap-demo/debug.log' 'log'
  Write-Fixture '.ansible/conf/env.yml' 'vault-data'

  Invoke-Case 'scope' {
    $scope = Get-AapStateLiveScope -HomePath $homePath
    $keys = @($scope.Files.Keys)
    Assert-True 'scope includes disk' ($keys -contains '.crc/machines/crc/crc.vhdx')
    Assert-True 'scope includes credentials' ($keys -contains '.ansible/conf/env.yml' -and $keys -contains '.aap-demo/pull-secret.txt')
    Assert-True 'scope excludes vmcx dir' (-not ($keys | Where-Object { $_ -like '*Virtual Machines*' }))
    Assert-True 'scope excludes vmgs' (-not ($keys -contains '.crc/machines/crc/ABC.vmgs'))
    Assert-True 'scope excludes lock and logs' (-not ($keys | Where-Object { $_ -like '.aap-demo/operation.lock*' -or $_ -like '*.log' }))
    Assert-True 'scope excludes cache' (-not ($keys | Where-Object { $_ -like '.crc/cache/*' }))
    Assert-Equal 'bundle name parsed' 'crc_microshift_hyperv_4.18.2_amd64.crcbundle' (Get-AapStateBundleName -HomePath $homePath)
    Assert-Throws 'path traversal refused' { Join-AapStatePath -Base $homePath -Relative '../x' } '*Invalid relative path*'
  }

  Invoke-Case 'keep parsing' {
    Assert-Equal 'keep default arg' $null (Get-AapStateServiceKeepArg -Arguments @())
    Assert-Equal 'keep space' 3 (Get-AapStateServiceKeepArg -Arguments @('--keep', '3'))
    Assert-Equal 'keep equals' 2 (Get-AapStateServiceKeepArg -Arguments @('--keep=2'))
    Assert-Throws 'keep zero' { Get-AapStateServiceKeepArg -Arguments @('--keep', '0') } '*positive integer*'
    Assert-Throws 'keep negative' { ConvertTo-AapStateKeep '-3' } '*positive integer*'
    Assert-Throws 'keep negative arg' { Get-AapStateServiceKeepArg -Arguments @('--keep=-1') } '*positive integer*'
    Assert-Equal 'keep above 20 accepted' 21 (ConvertTo-AapStateKeep '21')
    Assert-Equal 'keep large accepted' 500 (Get-AapStateServiceKeepArg -Arguments @('--keep', '500'))
    Assert-Throws 'keep overflow' { ConvertTo-AapStateKeep '99999999999' } '*positive integer*'
    Assert-Throws 'keep decimal' { ConvertTo-AapStateKeep '1.5' } '*positive integer*'
    Assert-Throws 'keep non-numeric' { ConvertTo-AapStateKeep 'x' } '*integer*'
    Assert-Throws 'keep missing value' { Get-AapStateServiceKeepArg -Arguments @('--keep') } '*requires a value*'
    Assert-Throws 'unknown option' { Get-AapStateServiceKeepArg -Arguments @('--bogus') } '*Unknown service option*'
  }

  Invoke-Case 'managed guard' {
    Assert-True 'not managed without config' (-not (Test-AapStateServiceManaged))
    Assert-Equal 'unmanaged start uses plain start' 0 $Script:Fake.StartCalls
    Invoke-AapDemoStartCommand
    Assert-Equal 'unmanaged start called' 1 $Script:Fake.StartCalls
    Save-AapStateConfig -Enabled $true -Keep 1
    Assert-True 'managed with config' (Test-AapStateServiceManaged)
    Assert-Throws 'destroy refused while managed' { Assert-AapStateNotManaged -Operation 'destroy' } '*aap-demo service disable*'
    $env:AAP_DEMO_SERVICE_INTERNAL = '1'
    Assert-True 'internal bypass' (-not (Test-AapStateServiceManaged))
    $env:AAP_DEMO_SERVICE_INTERNAL = $null
    [IO.File]::WriteAllText((Get-AapStateConfigFile), '{corrupt')
    Assert-True 'corrupt config treated as managed' (Test-AapStateServiceManaged)
    Save-AapStateConfig -Enabled $true -Keep 1
  }

  Invoke-Case 'backup refusals' {
    $Script:Fake.CrcStatus = 'Running'
    Assert-Throws 'backup refused while running' { New-AapStateBackup } '*CRC is running*'
    $Script:Fake.CrcStatus = 'Stopped'
    $Script:Fake.VmState = 'Saved'
    Assert-Throws 'backup refused saved vm' { New-AapStateBackup } "*'Saved', not Off*"
    $Script:Fake.VmState = 'Off'
    $Script:Fake.Supported = $false; $Script:Fake.Reason = 'VM has Hyper-V checkpoints'
    Assert-Throws 'backup refused unsupported layout' { New-AapStateBackup } '*Unsupported Hyper-V layout*checkpoints*'
    $Script:Fake.Supported = $true; $Script:Fake.Reason = $null
    $Script:Fake.FreeBytes = [int64]1
    Assert-Throws 'backup refused no space' { New-AapStateBackup } '*Not enough free space*'
    $Script:Fake.FreeBytes = [int64]1TB
    Assert-Equal 'no partial backup left' 0 @(Get-AapStateBackupNames).Count
    Assert-True 'no staging left' (-not @(Get-ChildItem -LiteralPath (Get-AapStateBackupsDir) -Force | Where-Object { $_.Name -like '.incomplete-*' }))
  }

  $first = $null
  Invoke-Case 'backup create and verify' {
    $Script:Fake.CrcStatus = 'Running'; $Script:Fake.VmState = 'Running'
    $first = Invoke-AapStateManagedStop -Command 'stop'
    Set-Variable -Name first -Value $first -Scope 2
    Assert-Equal 'managed stop stopped crc' 1 $Script:Fake.StopCalls
    Assert-True 'backup named' ($first -match $Script:AapStateBackupNamePattern)
    Assert-Equal 'latest pointer' $first (Get-AapStateLatestName)
    Assert-True 'marker cleared' (-not (Test-AapStateMarker))
    $dir = Join-Path (Get-AapStateBackupsDir) $first
    $m = Test-AapStateBackup -BackupDir $dir -Full
    Assert-Equal 'manifest vmId' 'vm-1111' $m.vmId
    $paths = @($m.files | ForEach-Object { $_.path })
    Assert-True 'manifest has disk' ($paths -contains '.crc/machines/crc/crc.vhdx')
    Assert-True 'manifest excludes vmcx' (-not ($paths | Where-Object { $_ -like '*.vmcx' -or $_ -like '*.vmgs' }))
    Assert-True 'payload has no vmcx' (-not (Test-Path -LiteralPath (Join-Path $dir 'payload/.crc/machines/crc/Virtual Machines')))
  }

  Invoke-Case 'corruption detection' {
    $Script:Fake.CrcStatus = 'Stopped'; $Script:Fake.VmState = 'Off'
    Start-Sleep -Milliseconds 1100
    $copy = New-AapStateBackup
    $dir = Join-Path (Get-AapStateBackupsDir) $copy
    $disk = Join-Path $dir 'payload/.crc/machines/crc/crc.vhdx'
    [IO.File]::WriteAllText($disk, 'disk-vX')
    Assert-Throws 'payload flip detected' { Test-AapStateBackup -BackupDir $dir -Full } '*checksum mismatch*'
    [IO.File]::WriteAllText((Join-Path $dir 'payload/extra.bin'), 'x')
    [IO.File]::WriteAllText($disk, 'disk-v1')
    Assert-Throws 'extra payload file detected' { Test-AapStateBackup -BackupDir $dir -Full } '*unexpected file*'
    Remove-Item -LiteralPath (Join-Path $dir 'COMPLETE')
    Assert-Throws 'missing COMPLETE detected' { Test-AapStateBackup -BackupDir $dir } '*missing COMPLETE*'
    [IO.File]::AppendAllText((Join-Path $dir 'SHA256SUMS'), 'x')
    [IO.File]::WriteAllText((Join-Path $dir 'COMPLETE'), "manifest=bad`nsums=bad`n")
    Assert-Throws 'manifest checksum detected' { Test-AapStateBackup -BackupDir $dir } '*checksum mismatch*'
    Remove-AapStateBackupDir -Name $copy
    [IO.File]::WriteAllText((Join-Path (Get-AapStateBackupsDir) 'latest'), "$first`n")
    Assert-Throws 'unsafe remove refused' { Remove-AapStateBackupDir -Name '../state' } '*Refusing*'
  }

  Invoke-Case 'retention' {
    Start-Sleep -Milliseconds 1100
    $b2 = New-AapStateBackup
    Assert-Equal 'keep 1 keeps only latest' 1 @(Get-AapStateBackupNames).Count
    Assert-Equal 'keep 1 latest kept' $b2 (Get-AapStateLatestName)
    Save-AapStateConfig -Enabled $true -Keep 2
    Start-Sleep -Milliseconds 1100
    $b3 = New-AapStateBackup
    Assert-Equal 'keep 2 keeps two' 2 @(Get-AapStateBackupNames).Count
    Start-Sleep -Milliseconds 1100
    $b4 = New-AapStateBackup
    $names = @(Get-AapStateBackupNames)
    Assert-True 'keep 2 prunes oldest' ($names.Count -eq 2 -and $names -contains $b3 -and $names -contains $b4)
    [IO.Directory]::CreateDirectory((Join-Path (Get-AapStateBackupsDir) '.incomplete-20200101T000000Z-dead')) | Out-Null
    Invoke-AapDemoService -Arguments @('retention', '1')
    Assert-Equal 'retention 1 prunes' 1 @(Get-AapStateBackupNames).Count
    Assert-Equal 'latest survives prune' $b4 (Get-AapStateLatestName)
    Assert-True 'stale staging removed' (-not @(Get-ChildItem -LiteralPath (Get-AapStateBackupsDir) -Force | Where-Object { $_.Name -like '.incomplete-*' }))
    Invoke-AapDemoService -Arguments @('verify')
    Pass 'service verify latest'
  }

  Invoke-Case 'restore' {
    $latest = Get-AapStateLatestName
    Assert-Equal 'fast path no restore' $false (Restore-AapStateBackup -Name $latest)
    Write-Fixture '.crc/machines/crc/crc.vhdx' 'disk-v2-newer'
    Write-Fixture '.aap-demo/new-file' 'extra'
    Remove-Item -LiteralPath (Join-AapStatePath -Base $homePath -Relative '.crc/machines/crc/kubeconfig')
    Assert-Equal 'restore performed' $true (Restore-AapStateBackup -Name $latest)
    Assert-Equal 'disk restored' 'disk-v1' (Read-Fixture '.crc/machines/crc/crc.vhdx')
    Assert-Equal 'missing file restored' 'kube-v1' (Read-Fixture '.crc/machines/crc/kubeconfig')
    Assert-True 'extra file removed' (-not (Test-Fixture '.aap-demo/new-file'))
    Assert-Equal 'hyper-v owned untouched' 'hyperv-owned' (Read-Fixture '.crc/machines/crc/Virtual Machines/ABC.vmcx')
    Assert-Equal 'excluded lock untouched' 'pid=1' (Read-Fixture '.aap-demo/operation.lock/owner')
    Assert-True 'journal removed' (-not [IO.File]::Exists((Get-AapStateJournalFile)))
    Assert-True 'restore dir removed' (-not @(Get-ChildItem -LiteralPath $homePath -Force | Where-Object { $_.Name -like '.aap-restore-*' }))
  }

  Invoke-Case 'restore rollback' {
    $latest = Get-AapStateLatestName
    Write-Fixture '.crc/machines/crc/crc.vhdx' 'disk-v3-live'
    Write-Fixture '.aap-demo/new-file' 'extra'
    $Script:Fake.MoveCalls = 0
    $Script:Fake.MoveFailAt = 4
    Assert-Throws 'restore failure surfaced' { Restore-AapStateBackup -Name $latest } '*failed and was rolled back*simulated move failure*'
    $Script:Fake.MoveFailAt = 0
    Assert-Equal 'rollback kept live disk' 'disk-v3-live' (Read-Fixture '.crc/machines/crc/crc.vhdx')
    Assert-Equal 'rollback kept extra file' 'extra' (Read-Fixture '.aap-demo/new-file')
    Assert-Equal 'rollback kept kubeconfig' 'kube-v1' (Read-Fixture '.crc/machines/crc/kubeconfig')
    Assert-True 'rollback removed journal' (-not [IO.File]::Exists((Get-AapStateJournalFile)))
    Assert-True 'rollback removed restore dir' (-not @(Get-ChildItem -LiteralPath $homePath -Force | Where-Object { $_.Name -like '.aap-restore-*' }))
  }

  Invoke-Case 'journal recovery' {
    # Simulate a crash mid-swap: the disk was moved to prev and the staged copy installed.
    $token = ('a' * 32)
    $root = Join-Path $homePath ".aap-restore-$token"
    $prev = Join-AapStatePath -Base (Join-Path $root 'prev') -Relative '.crc/machines/crc/crc.vhdx'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $prev)) | Out-Null
    Move-Item -LiteralPath (Join-AapStatePath -Base $homePath -Relative '.crc/machines/crc/crc.vhdx') -Destination $prev
    Write-Fixture '.crc/machines/crc/crc.vhdx' 'half-restored'
    $extraPrev = Join-AapStatePath -Base (Join-Path $root 'prev') -Relative '.aap-demo/new-file'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $extraPrev)) | Out-Null
    Move-Item -LiteralPath (Join-AapStatePath -Base $homePath -Relative '.aap-demo/new-file') -Destination $extraPrev
    $ops = @(
      [ordered]@{ path = '.crc/machines/crc/crc.vhdx'; hadCurrent = $true; hasStage = $true },
      [ordered]@{ path = '.crc/machines/crc/kubeconfig'; hadCurrent = $true; hasStage = $true },
      [ordered]@{ path = '.aap-demo/new-file'; hadCurrent = $true; hasStage = $false }
    )
    Write-AapStateJournal -HomePath $homePath -Token $token -Phase 'swapping' -Ops $ops
    Invoke-AapStateJournalRecovery
    Assert-Equal 'journal rollback disk' 'disk-v3-live' (Read-Fixture '.crc/machines/crc/crc.vhdx')
    Assert-Equal 'journal rollback extra' 'extra' (Read-Fixture '.aap-demo/new-file')
    Assert-Equal 'journal rollback untouched file' 'kube-v1' (Read-Fixture '.crc/machines/crc/kubeconfig')
    Assert-True 'journal cleared' (-not [IO.File]::Exists((Get-AapStateJournalFile)))
    Assert-True 'journal restore dir cleared' (-not (Test-Path -LiteralPath $root))
    [IO.File]::WriteAllText((Get-AapStateJournalFile), '{"home":"x","token":"bad","phase":"swapping"}')
    Assert-Throws 'corrupt journal refused' { Invoke-AapStateJournalRecovery } '*Corrupt restore journal*'
    Remove-Item -LiteralPath (Get-AapStateJournalFile)
  }

  Invoke-Case 'restore refusals' {
    $latest = Get-AapStateLatestName
    $Script:Fake.VMId = 'vm-2222'
    Assert-Throws 'recreated vm refused' { Restore-AapStateBackup -Name $latest } '*VMId changed*'
    $Script:Fake.VMId = 'vm-1111'
    $Script:Fake.VmState = 'Paused'
    Assert-Throws 'paused vm refused' { Restore-AapStateBackup -Name $latest } "*'Paused', not Off*"
    $Script:Fake.VmState = 'Off'
    $cache = Join-AapStatePath -Base $homePath -Relative '.crc/cache/crc_microshift_hyperv_4.18.2_amd64'
    Rename-Item -LiteralPath $cache -NewName 'moved'
    Assert-Throws 'missing bundle refused' { Restore-AapStateBackup -Name $latest } '*not in .crc\cache*'
    Rename-Item -LiteralPath (Join-Path (Split-Path -Parent $cache) 'moved') -NewName 'crc_microshift_hyperv_4.18.2_amd64'
    Assert-Equal 'live disk untouched by refusals' 'disk-v3-live' (Read-Fixture '.crc/machines/crc/crc.vhdx')
    Assert-Throws 'invalid restore name' { Invoke-AapDemoService -Arguments @('restore', '../x') } '*Invalid checkpoint name*'
  }

  Invoke-Case 'recover and start' {
    $Script:Fake.StartCalls = 0
    $Script:Fake.CrcStatus = 'Stopped'; $Script:Fake.VmState = 'Off'
    Invoke-AapDemoStartCommand
    Assert-Equal 'managed start restored disk' 'disk-v1' (Read-Fixture '.crc/machines/crc/crc.vhdx')
    Assert-Equal 'managed start started cluster' 1 $Script:Fake.StartCalls
    $Script:Fake.VmState = 'Running'
    Write-Fixture '.crc/machines/crc/crc.vhdx' 'running-disk'
    Invoke-AapStateRecoverAndStart
    Assert-Equal 'running vm not restored' 'running-disk' (Read-Fixture '.crc/machines/crc/crc.vhdx')
    $Script:Fake.VmState = 'Saved'
    Assert-Throws 'saved vm refused at login' { Invoke-AapStateRecoverAndStart } "*'Saved'*never forced off*"
    $Script:Fake.VmState = 'Off'
    Write-Fixture '.crc/machines/crc/crc.vhdx' 'disk-v1'
  }

  Invoke-Case 'failed checkpoint blocks restore' {
    $Script:Fake.CrcStatus = 'Running'; $Script:Fake.VmState = 'Running'
    $Script:Fake.StopResult = $false
    $before = Get-AapStateLatestName
    Assert-Throws 'managed stop failure surfaced' { Invoke-AapDemoStopCommand } '*crc stop failed*pending marker*'
    Assert-True 'marker kept after failure' (Test-AapStateMarker)
    Assert-Equal 'latest unchanged after failure' $before (Get-AapStateLatestName)
    $Script:Fake.StopResult = $true
    $Script:Fake.CrcStatus = 'Stopped'; $Script:Fake.VmState = 'Off'
    Write-Fixture '.crc/machines/crc/crc.vhdx' 'disk-newer-than-backup'
    $Script:Fake.StartCalls = 0
    Assert-Throws 'start refused with pending marker' { Invoke-AapDemoStartCommand } '*last checkpoint did not complete*'
    Assert-Equal 'newer disk not overwritten' 'disk-newer-than-backup' (Read-Fixture '.crc/machines/crc/crc.vhdx')
    Assert-Equal 'cluster not started' 0 $Script:Fake.StartCalls
    Assert-Throws 'service restore refused with marker' { Invoke-AapDemoService -Arguments @('restore') } '*checkpoint is pending*'
    Invoke-AapDemoService -Arguments @('backup')
    Assert-True 'service backup clears marker' (-not (Test-AapStateMarker))
    Assert-True 'new latest after backup' ((Get-AapStateLatestName) -ne $before)
  }

  Invoke-Case 'restart managed' {
    $Script:Fake.CrcStatus = 'Running'; $Script:Fake.VmState = 'Running'
    $Script:Fake.StartCalls = 0; $Script:Fake.StopCalls = 0
    Invoke-AapDemoRestart
    Assert-Equal 'restart stopped once' 1 $Script:Fake.StopCalls
    Assert-Equal 'restart started once' 1 $Script:Fake.StartCalls
    Assert-Equal 'restart keeps current disk' 'disk-newer-than-backup' (Read-Fixture '.crc/machines/crc/crc.vhdx')
  }

  Invoke-Case 'login start and disable' {
    $Script:DashboardCalls = 0
    function Invoke-AapDemoAutoDashboard {
      Assert-Equal 'login dashboard after cluster readiness' 1 $Script:Fake.StartCalls
      $Script:DashboardCalls++
    }
    $Script:Fake.CrcStatus = 'Stopped'; $Script:Fake.VmState = 'Off'
    $Script:Fake.StartCalls = 0
    function Start-Transcript { param([string]$LiteralPath, [switch]$Force) }
    function Stop-Transcript { }
    Invoke-AapDemoService -Arguments @('login-start')
    $env:AAP_DEMO_SERVICE_INTERNAL = $null
    $last = Read-AapStateJsonFile -Path (Get-AapStateLastLoginFile)
    Assert-Equal 'login-start result' 'success' $last.result
    Assert-Equal 'login-start started' 1 $Script:Fake.StartCalls
    Assert-Equal 'login-start opens dashboard' 1 $Script:DashboardCalls
    Assert-True 'login-start released lock' (-not (Test-Path -LiteralPath (Join-Path $Script:AapDemoConfigDir 'operation.lock')))

    $Script:Fake.VmState = 'Saved'
    Assert-Throws 'login-start failure surfaced' { Invoke-AapDemoService -Arguments @('login-start') } "*'Saved'*"
    $env:AAP_DEMO_SERVICE_INTERNAL = $null
    $last = Read-AapStateJsonFile -Path (Get-AapStateLastLoginFile)
    Assert-Equal 'login-start failure recorded' 'failed' $last.result
    Assert-Equal 'failed restore does not open dashboard' 1 $Script:DashboardCalls
    $Script:Fake.VmState = 'Off'

    function Get-ScheduledTask { param([string]$TaskName) return $null }
    Invoke-AapDemoService -Arguments @('disable')
    Assert-True 'disabled not managed' (-not (Test-AapStateServiceManaged))
    $Script:Fake.StartCalls = 0
    Invoke-AapDemoService -Arguments @('login-start')
    $env:AAP_DEMO_SERVICE_INTERNAL = $null
    Assert-Equal 'disabled login-start is a no-op' 0 $Script:Fake.StartCalls
    Assert-Equal 'disabled login does not open dashboard' 1 $Script:DashboardCalls
    Assert-Throws 'backup requires enabled service' { Invoke-AapDemoService -Arguments @('backup') } '*not enabled*'
    Assert-Throws 'unknown service command' { Invoke-AapDemoService -Arguments @('bogus') } '*Unknown service command*'
  }

  Invoke-Case 'git bash selection' {
    . (Join-Path $Private 'Addons.ps1')
    $gb = Join-Path $TmpRoot 'gitbash'
    $gitRoot = Join-Path $gb 'Git'
    $gitExe = Join-Path (Join-Path $gitRoot 'cmd') 'git.exe'
    $bashExe = Join-Path $gitRoot 'bin\bash.exe'
    $winDir = Join-Path $gb 'Windows'
    $wslBash = Join-Path $winDir 'System32\bash.exe'
    foreach ($f in @($gitExe, $bashExe, $wslBash)) {
      [IO.Directory]::CreateDirectory((Split-Path -Parent $f)) | Out-Null
      [IO.File]::WriteAllText($f, '')
    }
    Assert-Equal 'bash derived from git.exe' $bashExe (Resolve-AapGitBashPath -GitCommandPaths @($gitExe) -WindowsDir $winDir)
    Assert-Equal 'bash from install root' $bashExe (Resolve-AapGitBashPath -InstallRoots @((Join-Path $gb 'missing'), $gitRoot) -WindowsDir $winDir)
    Assert-Equal 'no git means no bash' $null (Resolve-AapGitBashPath -GitCommandPaths @() -InstallRoots @((Join-Path $gb 'missing')) -WindowsDir $winDir)
    Assert-True 'System32 bash is WSL' (Test-AapWslBashPath -Path 'C:\Windows\System32\bash.exe' -WindowsDir 'C:\Windows')
    Assert-True 'WindowsApps bash is WSL' (Test-AapWslBashPath -Path 'C:\Users\u\AppData\Local\Microsoft\WindowsApps\bash.exe' -WindowsDir 'C:\Windows')
    Assert-True 'Git bash is not WSL' (-not (Test-AapWslBashPath -Path 'C:\Program Files\Git\bin\bash.exe' -WindowsDir 'C:\Windows'))
    Assert-Throws 'WSL override refused' { Resolve-AapGitBashPath -Override $wslBash -GitCommandPaths @($gitExe) -WindowsDir $winDir } '*WSL bash*'
    Assert-Throws 'missing override refused' { Resolve-AapGitBashPath -Override (Join-Path $gb 'nope.exe') -WindowsDir $winDir } '*does not exist*'
    Assert-Equal 'valid override wins' $bashExe (Resolve-AapGitBashPath -Override $bashExe -WindowsDir $winDir)
    $addonsSrc = [IO.File]::ReadAllText((Join-Path $Private 'Addons.ps1'))
    Assert-True 'addons never use PATH bash' ($addonsSrc -notmatch 'Get-Command bash')
  }

  Invoke-Case 'startup storage policy' {
    $gib = [int64]1073741824
    $sd = Join-Path $TmpRoot 'storage'
    [IO.Directory]::CreateDirectory($sd) | Out-Null
    $machine = Join-Path $sd 'config.json'
    $pendingFile = Get-AapStoragePendingPath
    $Script:St = $null
    function Reset-St {
      param([int64]$CapacityBytes, [string[]]$Df, [int64]$GrowTo = 0, [bool]$StopOk = $true, [int64]$Free = [int64]::MaxValue, [int]$SetExit = 0)
      $Script:St = [PSCustomObject]@{ Df = [System.Collections.Queue]::new([object[]]$Df); GrowTo = $GrowTo; StopOk = $StopOk; Free = $Free
        SetExit = $SetExit; Sets = New-Object System.Collections.ArrayList; Config = @{}; Stops = 0; Starts = 0 }
      if ($CapacityBytes -gt 0) { [IO.File]::WriteAllText($machine, "{""Driver"":{""DiskCapacity"":$CapacityBytes,""BundleName"":""b.crcbundle""}}") }
      elseif (Test-Path -LiteralPath $machine) { Remove-Item -LiteralPath $machine -Force }
      if (Test-Path -LiteralPath $pendingFile) { Remove-Item -LiteralPath $pendingFile -Force }
    }
    function DfOut([int64]$Total, [int64]$Used) { "Filesystem 1024-blocks Used Available Capacity Mounted on`n/dev/vda4 $Total $Used $($Total - $Used) 0% /var" }
    function Get-AapStorageMachineConfigPath { $machine }
    function Get-AapStorageHostFreeBytes { param([string]$Path) $Script:St.Free }
    function Invoke-AapCrcSsh { param([string]$RemoteCommand, [switch]$AllowFailure)
      if ($Script:St.Df.Count -eq 0) { throw 'ssh failed' }
      $Script:St.Df.Dequeue() }
    function Invoke-AapExternal { param($Exe, $Args2)
      [void]$Script:St.Sets.Add((@($Exe) + @($Args2)) -join ' ')
      [PSCustomObject]@{ ExitCode = $Script:St.SetExit; Output = 'boom'; Lines = @() } }
    function Set-AapConfigValue { param([string]$Key, [string]$Value) $Script:St.Config[$Key] = $Value }
    function Invoke-AapCrcStop { param([switch]$Quiet) $Script:St.Stops++; $Script:St.StopOk }
    function Invoke-AapCrcStart { $Script:St.Starts++
      if ($Script:St.GrowTo -gt 0) { [IO.File]::WriteAllText($machine, "{""Driver"":{""DiskCapacity"":$($Script:St.GrowTo)}}") } }
    function Initialize-AapKubeEnvironment { }
    $savedCrcDisk = $env:CRC_DISK

    # Pure helpers and boundaries
    Assert-Equal 'target 100 GiB -> 120' 120 (Get-AapStorageGrowthTarget -ActualBytes (100 * $gib))
    Assert-Equal 'target 31 GiB -> 38 (ceil 37.2)' 38 (Get-AapStorageGrowthTarget -ActualBytes (31 * $gib))
    Assert-Equal 'target 1 byte -> 1' 1 (Get-AapStorageGrowthTarget -ActualBytes 1)
    Assert-True '89.99% is not full' (-not (Test-AapStorageFull ([PSCustomObject]@{ TotalKiB = 10000; UsedKiB = 8999 })))
    Assert-True 'exactly 90% is full' (Test-AapStorageFull ([PSCustomObject]@{ TotalKiB = 10000; UsedKiB = 9000 }))
    Assert-Equal 'df parse total' 1000 (ConvertFrom-AapDfOutput -Text (DfOut 1000 10)).TotalKiB
    Assert-Equal 'df used>total rejected' $null (ConvertFrom-AapDfOutput -Text "h`n/dev/x 10 20 0 0% /var")
    Assert-Equal 'df garbage rejected' $null (ConvertFrom-AapDfOutput -Text "h`n/dev/x a b c d /var")
    Assert-Equal 'df zero total rejected' $null (ConvertFrom-AapDfOutput -Text "h`n/dev/x 0 0 0 0% /var")
    [IO.File]::WriteAllText($machine, '{"Driver":{"VMDriver":{"DiskCapacity":5368709120}}}')
    Assert-Equal 'nested VMDriver DiskCapacity' ([int64]5368709120) (Get-AapStorageDiskCapacity -Path $machine)
    [IO.File]::WriteAllText($machine, '{"Driver":{"DiskCapacity":"big"}}')
    Assert-Equal 'string DiskCapacity rejected' $null (Get-AapStorageDiskCapacity -Path $machine)
    [IO.File]::WriteAllText($machine, '{"Driver":{"DiskCapacity":-5}}')
    Assert-Equal 'negative DiskCapacity rejected' $null (Get-AapStorageDiskCapacity -Path $machine)

    # Below threshold: no resize, no stop
    Reset-St -CapacityBytes (31 * $gib) -Df @((DfOut 10000 8999))
    Invoke-AapStartStorage *> $null
    Assert-Equal '89% no stop' 0 $Script:St.Stops
    Assert-Equal '89% no config set' 0 $Script:St.Sets.Count
    Assert-True '89% no pending' (-not (Test-Path -LiteralPath $pendingFile))

    # SSH failure is surfaced, not success
    Reset-St -CapacityBytes (31 * $gib) -Df @()
    Assert-Throws 'df failure surfaced' { Invoke-AapStartStorage *> $null } '*Could not check CRC disk usage*'

    # Exactly 90%: grow, graceful restart, verify, clear pending
    Reset-St -CapacityBytes (31 * $gib) -Df @((DfOut 10000 9000), (DfOut 12000 9000)) -GrowTo (38 * $gib)
    Invoke-AapStartStorage *> $null
    Assert-Equal '90% sets disk-size 38' 'crc config set disk-size 38' $Script:St.Sets[0]
    Assert-Equal '90% persists CRC_DISK' '38' $Script:St.Config['CRC_DISK']
    Assert-Equal '90% exports CRC_DISK' '38' $env:CRC_DISK
    Assert-Equal '90% one graceful stop' 1 $Script:St.Stops
    Assert-Equal '90% one start' 1 $Script:St.Starts
    Assert-True '90% pending cleared after verify' (-not (Test-Path -LiteralPath $pendingFile))

    # Missing driver metadata: explicit error at resize time, nothing changed
    Reset-St -CapacityBytes 0 -Df @((DfOut 10000 9500))
    Assert-Throws 'missing DiskCapacity explicit' { Invoke-AapStartStorage *> $null } '*Cannot determine the existing CRC disk capacity*'
    Assert-Equal 'missing DiskCapacity no stop' 0 $Script:St.Stops
    Assert-True 'missing DiskCapacity no pending' (-not (Test-Path -LiteralPath $pendingFile))

    # Host space check: exact delta passes the check, one byte less fails
    Reset-St -CapacityBytes (100 * $gib) -Df @((DfOut 10000 9500)) -Free (20 * $gib - 1)
    Assert-Throws 'insufficient host space' { Invoke-AapStartStorage *> $null } '*Not enough host disk space to grow CRC to 120 GiB*'
    Assert-Equal 'insufficient space no config set' 0 $Script:St.Sets.Count
    Assert-True 'insufficient space no pending' (-not (Test-Path -LiteralPath $pendingFile))
    Reset-St -CapacityBytes (100 * $gib) -Df @((DfOut 10000 9500), (DfOut 12000 9500)) -Free (20 * $gib) -GrowTo (120 * $gib)
    Invoke-AapStartStorage *> $null
    Assert-Equal 'exact host space proceeds' 1 $Script:St.Stops

    # Graceful stop failure: no force, target kept for retry
    Reset-St -CapacityBytes (31 * $gib) -Df @((DfOut 10000 9500)) -StopOk $false
    Assert-Throws 'stop failure surfaced' { Invoke-AapStartStorage *> $null } '*no forced power-off*'
    Assert-Equal 'stop failure no start' 0 $Script:St.Starts
    Assert-Equal 'stop failure keeps pending' '10000 38' ([IO.File]::ReadAllText($pendingFile).Trim())

    # Retry the persisted target even though DiskCapacity metadata has changed
    $Script:St.Df = [System.Collections.Queue]::new([object[]]@((DfOut 10000 9500), (DfOut 12000 9500)))
    $Script:St.StopOk = $true; $Script:St.GrowTo = 38 * $gib
    [IO.File]::WriteAllText($machine, "{""Driver"":{""DiskCapacity"":$(50 * $gib)}}")
    $Script:St.Sets.Clear()
    Invoke-AapStartStorage *> $null
    Assert-Equal 'retry uses pending target' 'crc config set disk-size 38' $Script:St.Sets[0]
    Assert-True 'retry success clears pending' (-not (Test-Path -LiteralPath $pendingFile))

    # Verification failure (disk not grown) keeps pending
    Reset-St -CapacityBytes (31 * $gib) -Df @((DfOut 10000 9500), (DfOut 10000 9500)) -GrowTo 0
    Assert-Throws 'verification failure surfaced' { Invoke-AapStartStorage *> $null } '*target is preserved for retry*'
    Assert-Equal 'verification failure keeps pending' '10000 38' ([IO.File]::ReadAllText($pendingFile).Trim())
    # Grown but still >= 90% keeps pending
    Reset-St -CapacityBytes (31 * $gib) -Df @((DfOut 10000 9500), (DfOut 12000 10800)) -GrowTo (38 * $gib)
    Assert-Throws 'still full after growth surfaced' { Invoke-AapStartStorage *> $null } '*usage remains at least 90%*'
    Assert-True 'still full keeps pending' (Test-Path -LiteralPath $pendingFile)
    # Post-verification SSH failure keeps pending
    Reset-St -CapacityBytes (31 * $gib) -Df @((DfOut 10000 9500)) -GrowTo (38 * $gib)
    Assert-Throws 'post-resize df failure surfaced' { Invoke-AapStartStorage *> $null } '*preserved for retry*'
    Assert-True 'post-resize df failure keeps pending' (Test-Path -LiteralPath $pendingFile)

    # Pending already satisfied (grew externally) is cleared without restart
    Reset-St -CapacityBytes (38 * $gib) -Df @((DfOut 12000 5000))
    Write-AapStoragePending -Path $pendingFile -BeforeKiB 10000 -TargetGiB 38
    Invoke-AapStartStorage *> $null
    Assert-True 'satisfied pending cleared' (-not (Test-Path -LiteralPath $pendingFile))
    Assert-Equal 'satisfied pending no stop' 0 $Script:St.Stops

    # Invalid pending file is an explicit error
    Reset-St -CapacityBytes (38 * $gib) -Df @((DfOut 12000 5000))
    [IO.File]::WriteAllText($pendingFile, "0 abc`n")
    Assert-Throws 'invalid pending refused' { Invoke-AapStartStorage *> $null } '*Invalid pending CRC storage resize*'
    Remove-Item -LiteralPath $pendingFile -Force

    # crc config set failure surfaces before any stop
    Reset-St -CapacityBytes (31 * $gib) -Df @((DfOut 10000 9500)) -SetExit 1
    Assert-Throws 'config set failure surfaced' { Invoke-AapStartStorage *> $null } '*crc config set disk-size 38 failed*'
    Assert-Equal 'config set failure no stop' 0 $Script:St.Stops
    Assert-True 'config set failure keeps pending' (Test-Path -LiteralPath $pendingFile)
    Remove-Item -LiteralPath $pendingFile -Force

    $startSrc = [IO.File]::ReadAllText((Join-Path $Private 'Start.ps1'))
    Assert-True 'start runs storage policy after kube init' ($startSrc -match 'Initialize-AapKubeEnvironment\s*\r?\n\s*Invoke-AapStartStorage')
    Assert-True 'storage never forces poweroff' ($startSrc -notmatch 'Stop-VM|TurnOff|--force')
    $env:CRC_DISK = $savedCrcDisk
  }

  Invoke-Case 'install' {
    function Register-ScheduledTask { throw 'Access is denied' }
    function New-ScheduledTaskAction { param($Execute, $Argument) return 'a' }
    function New-ScheduledTaskTrigger { param([switch]$AtLogOn, $User) return 't' }
    function New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) return 'p' }
    function New-ScheduledTaskSettingsSet { param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, [switch]$StartWhenAvailable, $ExecutionTimeLimit, $MultipleInstances) return 's' }
    Assert-Throws 'task registration error explicit' { Invoke-AapDemoService -Arguments @('install', '--keep', '2') } "*Failed to register scheduled task 'aap-demo-login-restore'*Access is denied*"
    Assert-True 'failed install leaves service disabled' (-not (Test-AapStateServiceManaged))
    $Script:Fake.Supported = $false; $Script:Fake.Reason = "Current user is not in the 'Hyper-V Administrators' group"
    Assert-Throws 'install prerequisite surfaced' { Invoke-AapDemoService -Arguments @('install') } '*Cannot install the state service*Hyper-V Administrators*'
    $Script:Fake.Supported = $true; $Script:Fake.Reason = $null
    $Script:Registered = $null
    function Register-ScheduledTask { param($TaskName, $Action, $Trigger, $Principal, $Settings, $Description, [switch]$Force) $Script:Registered = $TaskName }
    Invoke-AapDemoService -Arguments @('install', '--keep=3')
    Assert-Equal 'task registered' 'aap-demo-login-restore' $Script:Registered
    Assert-True 'install enables service' (Test-AapStateServiceManaged)
    Assert-Equal 'install keep saved' 3 (Get-AapStateKeep)
    $spec = Get-AapStateTaskAction
    Assert-True 'task action runs login-start' ($spec.Argument -match 'aap-demo\.ps1" service login-start$' -and $spec.Argument -match '-NonInteractive')
  }
} finally {
  foreach ($k in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $savedEnv[$k]) }
  if (Test-Path -LiteralPath $TmpRoot) { Remove-Item -LiteralPath $TmpRoot -Recurse -Force }
}

Write-Host ''
Write-Host "Passed: $($Script:Passed)  Failed: $($Script:Failed)"
if ($Script:Failed -gt 0) { exit 1 }
exit 0
