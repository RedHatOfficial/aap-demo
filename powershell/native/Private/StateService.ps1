# Native Windows state service: explicit cold CRC checkpoints and restore at
# user logon. Mirrors the Linux systemd state service (scripts/aap-demo-state.sh)
# within Hyper-V constraints:
#   * The CRC Hyper-V driver creates the VM with New-VM -Path <home>\.crc\machines\crc,
#     so Hyper-V owned configuration (Virtual Machines\*.vmcx/.vmgs/.vmrs) lives in
#     the machine directory. Those files are never copied or replaced; the VM
#     registration must be the same VM (same VMId) on restore.
#   * Only cold state is captured: crc stopped and VM Off. The VM is never forced off.
#   * No Export-VM/Import-VM/Remove-VMSavedState/TurnOff; disk files are copied
#     with SHA256 verification and swapped with a rollback journal.

$Script:AapStateVmName = 'crc'
$Script:AapStateTaskName = 'aap-demo-login-restore'
$Script:AapStateManifestVersion = 1
$Script:AapStateDefaultKeep = 1
$Script:AapStateCopyBufferBytes = 4MB
$Script:AapStateSpaceFactor = 1.1
$Script:AapStateVmOffWaitSeconds = 120
$Script:AapStateHyperVOwnedDirs = @('Virtual Machines', 'Snapshots', 'Planned Virtual Machines', 'UndoLog Configuration', 'Groups')
$Script:AapStateHyperVOwnedExtensions = @('.vmcx', '.vmrs', '.vmgs', '.vmid', '.vsv', '.bin')
$Script:AapStateAapDemoExcludes = @('operation.lock', 'logs')
$Script:AapStateOptionalFiles = @('.crc/crc.json', '.ansible/conf/env.yml', '.ansible/conf/.vaultpass.txt')
$Script:AapStateBackupNamePattern = '^state-\d{8}T\d{6}Z(-\d+)?$'

# ---------------------------------------------------------------------------
# Paths and configuration
# ---------------------------------------------------------------------------

function Test-AapStateTestMode { return ($env:AAP_DEMO_STATE_TEST -eq '1') }

function Get-AapStateRoot {
  if ((Test-AapStateTestMode) -and $env:AAP_DEMO_STATE_ROOT) { return $env:AAP_DEMO_STATE_ROOT }
  if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is not set; the native state service requires Windows' }
  return (Join-Path (Join-Path $env:LOCALAPPDATA 'aap-demo') 'state')
}

function Get-AapStateHome {
  if ((Test-AapStateTestMode) -and $env:AAP_DEMO_STATE_HOME) { return $env:AAP_DEMO_STATE_HOME }
  if (-not $env:USERPROFILE) { throw 'USERPROFILE is not set' }
  return $env:USERPROFILE
}

function Get-AapStateUser { return ([Environment]::UserDomainName + '\' + [Environment]::UserName) }

function Get-AapStateBackupsDir { return (Join-Path (Get-AapStateRoot) 'backups') }
function Get-AapStateConfigFile { return (Join-Path (Get-AapStateRoot) 'service.json') }
function Get-AapStateMarkerFile { return (Join-Path (Get-AapStateRoot) '.checkpoint-pending') }
function Get-AapStateJournalFile { return (Join-Path (Get-AapStateRoot) 'restore-journal.json') }
function Get-AapStateLastLoginFile { return (Join-Path (Get-AapStateRoot) 'last-login.json') }

function Assert-AapStateWindows {
  if (Test-AapStateTestMode) { return }
  if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'The native state service supports Windows with Hyper-V only. On Linux use the Bash CLI (aap-demo service ...).'
  }
}

function Join-AapStatePath {
  param([Parameter(Mandatory)][string]$Base, [Parameter(Mandatory)][string]$Relative)
  $parts = @($Relative -split '[\\/]' | Where-Object { $_ })
  $path = $Base
  foreach ($p in $parts) {
    if ($p -eq '..' -or $p -eq '.') { throw "Invalid relative path in state manifest: $Relative" }
    $path = Join-Path $path $p
  }
  return $path
}

function ConvertTo-AapStateRelative {
  param([Parameter(Mandatory)][string]$Base, [Parameter(Mandatory)][string]$Path)
  $b = [IO.Path]::GetFullPath($Base).TrimEnd('\', '/')
  $f = [IO.Path]::GetFullPath($Path)
  if (-not $f.StartsWith($b + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Path $Path is outside $Base"
  }
  return ($f.Substring($b.Length + 1) -replace '\\', '/')
}

function Write-AapStateTextAtomic {
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Content)
  $dir = Split-Path -Parent $Path
  [IO.Directory]::CreateDirectory($dir) | Out-Null
  $tmp = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
  $bytes = [Text.Encoding]::UTF8.GetBytes($Content)
  $fs = [IO.File]::Open($tmp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try {
    $fs.Write($bytes, 0, $bytes.Length)
    $fs.Flush($true)
  } finally {
    $fs.Dispose()
  }
  try {
    if ([IO.File]::Exists($Path)) {
      [IO.File]::Replace($tmp, $Path, [NullString]::Value)
    } else {
      [IO.File]::Move($tmp, $Path)
    }
  } catch {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    throw
  }
}

function Read-AapStateJsonFile {
  param([Parameter(Mandatory)][string]$Path)
  if (-not [IO.File]::Exists($Path)) { return $null }
  $text = [IO.File]::ReadAllText($Path)
  try {
    return ($text | ConvertFrom-Json)
  } catch {
    throw "Corrupt state file ${Path}: $($_.Exception.Message)"
  }
}

function Get-AapStateConfig { return (Read-AapStateJsonFile -Path (Get-AapStateConfigFile)) }

function Save-AapStateConfig {
  param([Parameter(Mandatory)][bool]$Enabled, [Parameter(Mandatory)][int]$Keep)
  $config = [ordered]@{
    version = 1
    enabled = $Enabled
    user    = Get-AapStateUser
    home    = Get-AapStateHome
    repo    = $Script:AapDemoRepoRoot
    keep    = $Keep
    task    = $Script:AapStateTaskName
    updated = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
  }
  Write-AapStateTextAtomic -Path (Get-AapStateConfigFile) -Content ($config | ConvertTo-Json)
}

function Get-AapStateKeep {
  $config = Get-AapStateConfig
  $keep = Get-AapJsonProp $config @('keep')
  if ($null -eq $keep) { return $Script:AapStateDefaultKeep }
  return [int]$keep
}

function ConvertTo-AapStateKeep {
  param([string]$Value)
  $n = 0
  if ($Value -notmatch '^\s*[+-]?[0-9]+\s*$' -or -not [int]::TryParse($Value.Trim(), [ref]$n)) {
    throw "--keep must be a positive integer (got '$Value')"
  }
  if ($n -lt 1) { throw "--keep must be a positive integer (got $n)" }
  return $n
}

function Test-AapStateServiceManaged {
  if ($env:AAP_DEMO_SERVICE_INTERNAL -eq '1') { return $false }
  try {
    $config = Get-AapStateConfig
  } catch {
    # A corrupt service.json must not silently disable the destructive guards.
    return $true
  }
  if (-not $config) { return $false }
  if ((Get-AapJsonProp $config @('enabled')) -ne $true) { return $false }
  if ([string](Get-AapJsonProp $config @('user')) -ne (Get-AapStateUser)) { return $false }
  return ([string](Get-AapJsonProp $config @('home')) -eq (Get-AapStateHome))
}

function Assert-AapStateNotManaged {
  param([Parameter(Mandatory)][string]$Operation)
  if (Test-AapStateServiceManaged) {
    throw "'$Operation' is refused while the native state service manages this cluster. Disable automatic state restore first: aap-demo service disable"
  }
}

# ---------------------------------------------------------------------------
# Seams (overridden by hermetic tests)
# ---------------------------------------------------------------------------

function Test-AapStateHyperVAccess {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  $hyperVAdmins = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-578')
  $admins = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
  return ($principal.IsInRole($hyperVAdmins) -or $principal.IsInRole($admins))
}

function Get-AapStateHyperVLayout {
  param([Parameter(Mandatory)][string]$HomePath)
  $layout = @{ Supported = $false; Reason = $null; VMName = $Script:AapStateVmName; VMId = $null; State = $null; Disks = @(); AutomaticStopAction = $null }
  if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    $layout.Reason = 'Hyper-V PowerShell module (Get-VM) is not available; enable the Hyper-V management tools'
    return $layout
  }
  if (-not (Test-AapStateHyperVAccess)) {
    $layout.Reason = "Current user is not in the 'Hyper-V Administrators' group (crc setup adds it; sign out and back in). Elevation is not used by the logon task."
    return $layout
  }
  try {
    $vm = Get-VM -Name $Script:AapStateVmName -ErrorAction Stop
  } catch {
    $layout.Reason = "Hyper-V VM '$($Script:AapStateVmName)' not found or not readable: $($_.Exception.Message)"
    return $layout
  }
  $layout.VMId = [string]$vm.Id
  $layout.State = [string]$vm.State
  $layout.AutomaticStopAction = [string]$vm.AutomaticStopAction
  $snapshots = @(Get-VMSnapshot -VM $vm -ErrorAction Stop)
  if ($snapshots.Count -gt 0) {
    $layout.Reason = "VM '$($Script:AapStateVmName)' has Hyper-V checkpoints; unsupported layout"
    return $layout
  }
  $machineDir = Join-AapStatePath -Base $HomePath -Relative '.crc/machines/crc'
  $disks = @()
  foreach ($drive in @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop)) {
    $path = [string]$drive.Path
    if (-not $path) {
      $layout.Reason = 'VM has a pass-through or empty disk drive; unsupported layout'
      return $layout
    }
    $vhd = Get-VHD -Path $path -ErrorAction Stop
    if ($vhd.ParentPath) {
      $layout.Reason = "Disk $path is a differencing disk; unsupported layout"
      return $layout
    }
    try {
      $rel = ConvertTo-AapStateRelative -Base $machineDir -Path $path
    } catch {
      $layout.Reason = "Disk $path is outside $machineDir; unsupported layout"
      return $layout
    }
    $disks += ".crc/machines/crc/$rel"
  }
  if ($disks.Count -eq 0) {
    $layout.Reason = 'VM has no virtual disks; unsupported layout'
    return $layout
  }
  $layout.Disks = @($disks | Sort-Object)
  $layout.Supported = $true
  return $layout
}

function Get-AapStateCrcStatus { return [string](Get-AapCrcStatus).crcStatus }
function Invoke-AapStateCrcStop { return (Invoke-AapCrcStop) }
function Invoke-AapStateClusterStart { Invoke-AapDemoStart }

function Get-AapStateFreeBytes {
  param([Parameter(Mandatory)][string]$Path)
  $full = [IO.Path]::GetFullPath($Path)
  $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($full))
  return [int64]$drive.AvailableFreeSpace
}

function Copy-AapStateAcl {
  param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
  # Hyper-V grants the VM's virtual account (NT VIRTUAL MACHINE\<VMId>) access
  # on attached disks; the restored file must carry the same DACL.
  $sddl = (Get-Acl -LiteralPath $Source).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
  $acl = Get-Acl -LiteralPath $Destination
  $acl.SetSecurityDescriptorSddlForm($sddl, [Security.AccessControl.AccessControlSections]::Access)
  Set-Acl -LiteralPath $Destination -AclObject $acl
}

# ---------------------------------------------------------------------------
# Scope enumeration
# ---------------------------------------------------------------------------

function Test-AapStateHyperVOwned {
  param([Parameter(Mandatory)][string]$RelativePath)
  $parts = @($RelativePath -split '/')
  foreach ($p in $parts) {
    if ($Script:AapStateHyperVOwnedDirs -contains $p) { return $true }
  }
  $ext = [IO.Path]::GetExtension($RelativePath).ToLowerInvariant()
  return ($Script:AapStateHyperVOwnedExtensions -contains $ext)
}

function Test-AapStateAapDemoExcluded {
  param([Parameter(Mandatory)][string]$Name)
  if ($Script:AapStateAapDemoExcludes -contains $Name) { return $true }
  if ($Name -like '.aap-restore-*') { return $true }
  foreach ($pattern in @('*.log', '*.sock', '*.pid', '*.tmp-*')) {
    if ($Name -like $pattern) { return $true }
  }
  return $false
}

function Get-AapStateTreeItems {
  param([Parameter(Mandatory)][string]$HomePath, [Parameter(Mandatory)][string]$Root)
  $result = @{ Files = @(); Dirs = @() }
  $rootItem = Get-Item -LiteralPath $Root -Force
  if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw "Unsupported layout: $Root is a symbolic link, junction or mount point"
  }
  if (-not $rootItem.PSIsContainer) {
    $result.Files += $rootItem
    return $result
  }
  $result.Dirs += $rootItem
  foreach ($item in @(Get-ChildItem -LiteralPath $Root -Force -Recurse)) {
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      throw "Unsupported layout: $($item.FullName) is a symbolic link, junction or mount point"
    }
    if ($item.PSIsContainer) { $result.Dirs += $item } else { $result.Files += $item }
  }
  return $result
}

function Get-AapStateLiveScope {
  # Returns the managed live files and directories as home-relative paths.
  param([Parameter(Mandatory)][string]$HomePath)
  $files = [ordered]@{}
  $dirs = New-Object System.Collections.Generic.List[string]
  $addTree = {
    param($root, [scriptblock]$filter)
    $tree = Get-AapStateTreeItems -HomePath $HomePath -Root $root
    foreach ($d in $tree.Dirs) {
      $rel = ConvertTo-AapStateRelative -Base $HomePath -Path $d.FullName
      if (& $filter $rel) { $dirs.Add($rel) | Out-Null }
    }
    foreach ($f in $tree.Files) {
      $rel = ConvertTo-AapStateRelative -Base $HomePath -Path $f.FullName
      if (& $filter $rel) { $files[$rel] = $f }
    }
  }

  foreach ($parent in @('.crc', '.aap-demo', '.ansible', '.ansible/conf')) {
    $p = Join-AapStatePath -Base $HomePath -Relative $parent
    if ((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw "Unsupported layout: $p is a symbolic link, junction or mount point"
    }
  }

  $machines = Join-AapStatePath -Base $HomePath -Relative '.crc/machines'
  if (Test-Path -LiteralPath $machines) {
    & $addTree $machines { param($rel) -not (Test-AapStateHyperVOwned -RelativePath $rel) }
  }
  $aapDemo = Join-AapStatePath -Base $HomePath -Relative '.aap-demo'
  if (Test-Path -LiteralPath $aapDemo) {
    foreach ($child in @(Get-ChildItem -LiteralPath $aapDemo -Force)) {
      if (Test-AapStateAapDemoExcluded -Name $child.Name) { continue }
      & $addTree $child.FullName { param($rel) $true }
    }
  }
  foreach ($opt in $Script:AapStateOptionalFiles) {
    $p = Join-AapStatePath -Base $HomePath -Relative $opt
    if ([IO.File]::Exists($p)) { & $addTree $p { param($rel) $true } }
  }
  return @{ Files = $files; Dirs = @($dirs) }
}

function Get-AapStateBundleName {
  param([Parameter(Mandatory)][string]$HomePath)
  $configPath = Join-AapStatePath -Base $HomePath -Relative '.crc/machines/crc/config.json'
  if (-not [IO.File]::Exists($configPath)) { return $null }
  $json = Read-AapStateJsonFile -Path $configPath
  $stack = New-Object System.Collections.Stack
  $stack.Push($json)
  while ($stack.Count -gt 0) {
    $node = $stack.Pop()
    if ($null -eq $node -or $node -is [string] -or $node -is [ValueType]) { continue }
    if ($node -is [System.Collections.IEnumerable] -and -not ($node -is [System.Management.Automation.PSCustomObject])) {
      foreach ($n in $node) { $stack.Push($n) }
      continue
    }
    foreach ($prop in $node.PSObject.Properties) {
      if ($prop.Name -eq 'BundleName' -and $prop.Value -is [string] -and $prop.Value) { return [string]$prop.Value }
      $stack.Push($prop.Value)
    }
  }
  return $null
}

function Test-AapStateBundleCached {
  param([Parameter(Mandatory)][string]$HomePath, [Parameter(Mandatory)][string]$BundleName)
  $dirName = $BundleName -replace '\.crcbundle$', ''
  if ($dirName -notmatch '^[A-Za-z0-9._-]+$') { return $false }
  return (Test-Path -LiteralPath (Join-AapStatePath -Base $HomePath -Relative ".crc/cache/$dirName"))
}

# ---------------------------------------------------------------------------
# Hashing and copying
# ---------------------------------------------------------------------------

function ConvertTo-AapStateHex {
  param([byte[]]$Bytes)
  return (([BitConverter]::ToString($Bytes)) -replace '-', '').ToLowerInvariant()
}

function Get-AapStateFileSha256 {
  param([Parameter(Mandatory)][string]$Path)
  $sha = [Security.Cryptography.SHA256]::Create()
  $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  try {
    return (ConvertTo-AapStateHex $sha.ComputeHash($fs))
  } finally {
    $fs.Dispose()
    $sha.Dispose()
  }
}

function Copy-AapStateFileWithHash {
  param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
  [IO.Directory]::CreateDirectory((Split-Path -Parent $Destination)) | Out-Null
  $sha = [Security.Cryptography.SHA256]::Create()
  $in = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  try {
    $out = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
      $buffer = New-Object byte[] $Script:AapStateCopyBufferBytes
      while (($read = $in.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $sha.TransformBlock($buffer, 0, $read, $null, 0) | Out-Null
        $out.Write($buffer, 0, $read)
      }
      $sha.TransformFinalBlock((New-Object byte[] 0), 0, 0) | Out-Null
      $out.Flush($true)
    } finally {
      $out.Dispose()
    }
  } finally {
    $in.Dispose()
  }
  $hash = ConvertTo-AapStateHex $sha.Hash
  $sha.Dispose()
  [IO.File]::SetLastWriteTimeUtc($Destination, [IO.File]::GetLastWriteTimeUtc($Source))
  return $hash
}

function Get-AapStateStringSha256 {
  param([Parameter(Mandatory)][string]$Path)
  return (Get-AapStateFileSha256 -Path $Path)
}

# ---------------------------------------------------------------------------
# Layout checks
# ---------------------------------------------------------------------------

function Get-AapStateColdLayout {
  # Returns the Hyper-V layout after asserting crc is stopped and the VM is Off.
  param([Parameter(Mandatory)][string]$HomePath)
  $crcState = Get-AapStateCrcStatus
  if ($crcState -eq 'Running') { throw "CRC is running; stop it with 'aap-demo stop' before a cold checkpoint or restore" }
  if ($crcState -ne 'Stopped') { throw "CRC status is '$crcState'; a cold checkpoint/restore requires an existing stopped cluster" }
  $layout = Get-AapStateHyperVLayout -HomePath $HomePath
  if (-not $layout.Supported) { throw "Unsupported Hyper-V layout: $($layout.Reason)" }
  if ($layout.State -ne 'Off') {
    throw "Hyper-V VM '$($layout.VMName)' is '$($layout.State)', not Off. Saved/Paused states are not captured and the VM is never forced off; start it with 'crc start' and stop it with 'aap-demo stop'."
  }
  return $layout
}

function Wait-AapStateVmOff {
  param([Parameter(Mandatory)][string]$HomePath)
  $deadline = (Get-Date).AddSeconds($Script:AapStateVmOffWaitSeconds)
  while ($true) {
    $layout = Get-AapStateHyperVLayout -HomePath $HomePath
    if (-not $layout.Supported) { throw "Unsupported Hyper-V layout: $($layout.Reason)" }
    if ($layout.State -eq 'Off') { return }
    if ((Get-Date) -ge $deadline) {
      throw "Hyper-V VM '$($layout.VMName)' is still '$($layout.State)' after crc stop; the VM is never forced off. Investigate with 'crc status' and retry."
    }
    Start-Sleep -Seconds 2
  }
}

# ---------------------------------------------------------------------------
# Backups
# ---------------------------------------------------------------------------

function Get-AapStateLatestName {
  $latestFile = Join-Path (Get-AapStateBackupsDir) 'latest'
  if (-not [IO.File]::Exists($latestFile)) { return $null }
  $name = ([IO.File]::ReadAllText($latestFile)).Trim()
  if ($name -notmatch $Script:AapStateBackupNamePattern) { throw "Corrupt latest pointer in $latestFile" }
  if (-not (Test-Path -LiteralPath (Join-Path (Get-AapStateBackupsDir) $name))) {
    throw "Latest backup $name referenced by $latestFile is missing"
  }
  return $name
}

function Get-AapStateBackupNames {
  $dir = Get-AapStateBackupsDir
  if (-not (Test-Path -LiteralPath $dir)) { return @() }
  return @(Get-ChildItem -LiteralPath $dir -Directory -Force |
      Where-Object { $_.Name -match $Script:AapStateBackupNamePattern } |
      Sort-Object Name | ForEach-Object { $_.Name })
}

function Test-AapStateBackup {
  # Verifies completion markers, checksums and payload. Returns the manifest.
  param([Parameter(Mandatory)][string]$BackupDir, [switch]$Full)
  $complete = Join-Path $BackupDir 'COMPLETE'
  $manifestPath = Join-Path $BackupDir 'manifest.json'
  $sumsPath = Join-Path $BackupDir 'SHA256SUMS'
  foreach ($p in @($complete, $manifestPath, $sumsPath)) {
    if (-not [IO.File]::Exists($p)) { throw "Backup $BackupDir is incomplete: missing $(Split-Path -Leaf $p)" }
  }
  $marker = @{}
  foreach ($line in [IO.File]::ReadAllLines($complete)) {
    $idx = $line.IndexOf('=')
    if ($idx -gt 0) { $marker[$line.Substring(0, $idx)] = $line.Substring($idx + 1) }
  }
  if ($marker['manifest'] -ne (Get-AapStateFileSha256 -Path $manifestPath)) { throw "Backup $BackupDir manifest checksum mismatch" }
  if ($marker['sums'] -ne (Get-AapStateFileSha256 -Path $sumsPath)) { throw "Backup $BackupDir SHA256SUMS checksum mismatch" }
  $manifest = Read-AapStateJsonFile -Path $manifestPath
  if ((Get-AapJsonProp $manifest @('version')) -ne $Script:AapStateManifestVersion -or
      (Get-AapJsonProp $manifest @('platform')) -ne 'windows-hyperv') {
    throw "Backup $BackupDir has an unsupported manifest version/platform"
  }
  $payload = Join-Path $BackupDir 'payload'
  $expected = @{}
  foreach ($f in @(Get-AapJsonProp $manifest @('files'))) {
    if (-not $f) { continue }
    $rel = [string](Get-AapJsonProp $f @('path'))
    $expected[$rel.ToLowerInvariant()] = $true
    $path = Join-AapStatePath -Base $payload -Relative $rel
    if (-not [IO.File]::Exists($path)) { throw "Backup $BackupDir is missing payload file $rel" }
    if ((New-Object IO.FileInfo($path)).Length -ne [int64](Get-AapJsonProp $f @('size'))) {
      throw "Backup $BackupDir payload file $rel has the wrong size"
    }
    if ($Full -and (Get-AapStateFileSha256 -Path $path) -ne [string](Get-AapJsonProp $f @('sha256'))) {
      throw "Backup $BackupDir payload file $rel checksum mismatch"
    }
  }
  if ($Full -and (Test-Path -LiteralPath $payload)) {
    foreach ($item in @(Get-ChildItem -LiteralPath $payload -Force -Recurse -File)) {
      $rel = ConvertTo-AapStateRelative -Base $payload -Path $item.FullName
      if (-not $expected.ContainsKey($rel.ToLowerInvariant())) { throw "Backup $BackupDir contains unexpected file $rel" }
    }
  }
  return $manifest
}

function Remove-AapStateBackupDir {
  param([Parameter(Mandatory)][string]$Name)
  if ($Name -notmatch $Script:AapStateBackupNamePattern -and $Name -notmatch '^\.incomplete-[0-9A-Za-z-]+$') {
    throw "Refusing to remove unexpected backup path $Name"
  }
  $backups = [IO.Path]::GetFullPath((Get-AapStateBackupsDir))
  $path = [IO.Path]::GetFullPath((Join-Path $backups $Name))
  if ((Split-Path -Parent $path) -ne $backups) { throw "Refusing to remove $path outside $backups" }
  Remove-Item -LiteralPath $path -Recurse -Force
}

function Invoke-AapStatePrune {
  param([int]$Keep = (Get-AapStateKeep))
  $latest = Get-AapStateLatestName
  $names = @(Get-AapStateBackupNames | Sort-Object -Descending)
  # The latest pointer always counts toward retention and is never pruned.
  $kept = 0
  if ($latest) { $kept = 1 }
  foreach ($name in $names) {
    if ($name -eq $latest) { continue }
    if ($kept -lt $Keep) { $kept++; continue }
    Write-AapStep "Pruning old checkpoint $name"
    Remove-AapStateBackupDir -Name $name
  }
  $dir = Get-AapStateBackupsDir
  if (Test-Path -LiteralPath $dir) {
    foreach ($stale in @(Get-ChildItem -LiteralPath $dir -Directory -Force | Where-Object { $_.Name -like '.incomplete-*' })) {
      Remove-AapStateBackupDir -Name $stale.Name
    }
  }
}

function New-AapStateBackup {
  [CmdletBinding()]
  param()
  $homePath = Get-AapStateHome
  $layout = Get-AapStateColdLayout -HomePath $homePath
  $bundle = Get-AapStateBundleName -HomePath $homePath
  if (-not $bundle) {
    throw 'Unsupported layout: BundleName not found in .crc\machines\crc\config.json; cannot record the bundle required for restore'
  }
  $scope = Get-AapStateLiveScope -HomePath $homePath
  foreach ($disk in $layout.Disks) {
    if (-not $scope.Files.Contains($disk)) { throw "VM disk $disk is not inside the managed scope" }
  }
  $machineConfig = '.crc/machines/crc/config.json'
  if (-not $scope.Files.Contains($machineConfig)) { throw "Unsupported layout: $machineConfig is missing" }

  $total = [int64]0
  foreach ($entry in $scope.Files.GetEnumerator()) { $total += [int64]$entry.Value.Length }
  $backupsDir = Get-AapStateBackupsDir
  [IO.Directory]::CreateDirectory($backupsDir) | Out-Null
  $required = [int64]([double]$total * $Script:AapStateSpaceFactor)
  $free = [int64](Get-AapStateFreeBytes -Path $backupsDir)
  if ($free -lt $required) {
    throw "Not enough free space for a checkpoint in ${backupsDir}: need $([math]::Round($required / 1GB, 2)) GiB, have $([math]::Round($free / 1GB, 2)) GiB. Free space or lower retention."
  }

  $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
  $staging = Join-Path $backupsDir ".incomplete-$stamp-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
  [IO.Directory]::CreateDirectory($staging) | Out-Null
  try {
    $payload = Join-Path $staging 'payload'
    Write-AapStep "Saving cold checkpoint ($([math]::Round($total / 1GB, 2)) GiB)..."
    $fileRecords = @()
    $sums = New-Object System.Text.StringBuilder
    foreach ($entry in ($scope.Files.GetEnumerator() | Sort-Object Name)) {
      $rel = [string]$entry.Name
      $src = Join-AapStatePath -Base $homePath -Relative $rel
      $dst = Join-AapStatePath -Base $payload -Relative $rel
      $hash = Copy-AapStateFileWithHash -Source $src -Destination $dst
      $info = New-Object IO.FileInfo($src)
      $fileRecords += [ordered]@{ path = $rel; size = [int64]$info.Length; mtime = [int64]$info.LastWriteTimeUtc.Ticks; sha256 = $hash }
      [void]$sums.Append("$hash  payload/$rel`n")
    }
    foreach ($d in $scope.Dirs) { [IO.Directory]::CreateDirectory((Join-AapStatePath -Base $payload -Relative $d)) | Out-Null }
    $manifest = [ordered]@{
      version    = $Script:AapStateManifestVersion
      platform   = 'windows-hyperv'
      user       = Get-AapStateUser
      home       = $homePath
      created    = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
      vmName     = $layout.VMName
      vmId       = $layout.VMId
      disks      = @($layout.Disks)
      bundleName = $bundle
      dirs       = @($scope.Dirs | Sort-Object)
      files      = $fileRecords
      totalBytes = $total
    }
    Write-AapStateTextAtomic -Path (Join-Path $staging 'manifest.json') -Content ($manifest | ConvertTo-Json -Depth 6)
    Write-AapStateTextAtomic -Path (Join-Path $staging 'SHA256SUMS') -Content $sums.ToString()
    $complete = "manifest=$(Get-AapStateFileSha256 -Path (Join-Path $staging 'manifest.json'))`nsums=$(Get-AapStateFileSha256 -Path (Join-Path $staging 'SHA256SUMS'))`n"
    Write-AapStateTextAtomic -Path (Join-Path $staging 'COMPLETE') -Content $complete
    Write-AapStep 'Verifying checkpoint checksums...'
    Test-AapStateBackup -BackupDir $staging -Full | Out-Null

    $name = "state-$stamp"
    $n = 1
    while (Test-Path -LiteralPath (Join-Path $backupsDir $name)) { $name = "state-$stamp-$n"; $n++ }
    [IO.Directory]::Move($staging, (Join-Path $backupsDir $name))
    $staging = $null
    Write-AapStateTextAtomic -Path (Join-Path $backupsDir 'latest') -Content "$name`n"
  } finally {
    if ($staging -and (Test-Path -LiteralPath $staging)) {
      Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  Write-AapStep "Checkpoint saved: $name"
  Invoke-AapStatePrune
  return $name
}

# ---------------------------------------------------------------------------
# Restore with journal
# ---------------------------------------------------------------------------

function Test-AapStateLiveMatches {
  param([Parameter(Mandatory)][string]$HomePath, [Parameter(Mandatory)]$Manifest)
  $scope = Get-AapStateLiveScope -HomePath $HomePath
  $records = @(@(Get-AapJsonProp $Manifest @('files')) | Where-Object { $_ })
  $liveRequired = @($scope.Files.Keys | Where-Object { $Script:AapStateOptionalFiles -notcontains $_ })
  $manifestPaths = @{}
  foreach ($r in $records) { $manifestPaths[[string]$r.path] = $r }
  foreach ($rel in $liveRequired) { if (-not $manifestPaths.ContainsKey($rel)) { return $false } }
  foreach ($r in $records) {
    $rel = [string]$r.path
    if (-not $scope.Files.Contains($rel)) { return $false }
    $info = $scope.Files[$rel]
    if ([int64]$info.Length -ne [int64]$r.size) { return $false }
    if ([int64]$info.LastWriteTimeUtc.Ticks -ne [int64]$r.mtime) { return $false }
  }
  return $true
}

function Move-AapStatePath {
  param([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To)
  [IO.Directory]::CreateDirectory((Split-Path -Parent $To)) | Out-Null
  [IO.File]::Move($From, $To)
}

function Invoke-AapStateRollbackOps {
  param([Parameter(Mandatory)][string]$HomePath, [Parameter(Mandatory)][string]$Token, [object[]]$Ops = @())
  $restoreRoot = Join-Path $HomePath ".aap-restore-$Token"
  $list = @($Ops)
  for ($i = $list.Count - 1; $i -ge 0; $i--) {
    $op = $list[$i]
    $rel = [string](Get-AapJsonProp $op @('path'))
    $target = Join-AapStatePath -Base $HomePath -Relative $rel
    $stage = Join-AapStatePath -Base (Join-Path $restoreRoot 'stage') -Relative $rel
    $prev = Join-AapStatePath -Base (Join-Path $restoreRoot 'prev') -Relative $rel
    $hadCurrent = [bool](Get-AapJsonProp $op @('hadCurrent'))
    $hasStage = [bool](Get-AapJsonProp $op @('hasStage'))
    if ($hasStage -and [IO.File]::Exists($target) -and -not [IO.File]::Exists($stage)) {
      if ([IO.File]::Exists($prev) -or -not $hadCurrent) {
        Move-AapStatePath -From $target -To $stage
      }
    }
    if ($hadCurrent -and [IO.File]::Exists($prev) -and -not [IO.File]::Exists($target)) {
      Move-AapStatePath -From $prev -To $target
    }
  }
}

function Invoke-AapStateJournalRecovery {
  $journalPath = Get-AapStateJournalFile
  if (-not [IO.File]::Exists($journalPath)) { return }
  $journal = Read-AapStateJsonFile -Path $journalPath
  $homePath = [string](Get-AapJsonProp $journal @('home'))
  $token = [string](Get-AapJsonProp $journal @('token'))
  $phase = [string](Get-AapJsonProp $journal @('phase'))
  if (-not $homePath -or $token -notmatch '^[0-9a-f]{32}$') { throw "Corrupt restore journal $journalPath; inspect it manually" }
  $restoreRoot = Join-Path $homePath ".aap-restore-$token"
  if ($phase -eq 'swapping') {
    Write-AapWarn 'Interrupted restore detected; rolling back to the pre-restore files'
    try {
      Invoke-AapStateRollbackOps -HomePath $homePath -Token $token -Ops @(Get-AapJsonProp $journal @('ops'))
    } catch {
      throw "Rollback of interrupted restore failed; journal kept at ${journalPath} and files at ${restoreRoot}: $($_.Exception.Message)"
    }
  } elseif ($phase -ne 'staging' -and $phase -ne 'committed') {
    throw "Unknown restore journal phase '$phase' in $journalPath"
  }
  if (Test-Path -LiteralPath $restoreRoot) { Remove-Item -LiteralPath $restoreRoot -Recurse -Force }
  Remove-Item -LiteralPath $journalPath -Force
}

function Write-AapStateJournal {
  param([string]$HomePath, [string]$Token, [string]$Phase, $Ops)
  $opList = New-Object System.Collections.ArrayList
  foreach ($op in $Ops) { if ($null -ne $op) { [void]$opList.Add($op) } }
  $journal = [ordered]@{ home = $HomePath; token = $Token; phase = $Phase; ops = $opList.ToArray() }
  Write-AapStateTextAtomic -Path (Get-AapStateJournalFile) -Content ($journal | ConvertTo-Json -Depth 5)
}

function Restore-AapStateBackup {
  [CmdletBinding()]
  param([string]$Name)
  Invoke-AapStateJournalRecovery
  $homePath = Get-AapStateHome
  if (-not $Name) { $Name = Get-AapStateLatestName }
  if (-not $Name) { throw "No completed checkpoint exists; run 'aap-demo service backup'" }
  $backupDir = Join-Path (Get-AapStateBackupsDir) $Name
  $manifest = Test-AapStateBackup -BackupDir $backupDir

  if ([string](Get-AapJsonProp $manifest @('user')) -ne (Get-AapStateUser) -or
      [string](Get-AapJsonProp $manifest @('home')) -ne $homePath) {
    throw "Checkpoint $Name belongs to a different user or profile; refusing to restore"
  }
  $layout = Get-AapStateColdLayout -HomePath $homePath
  if ([string](Get-AapJsonProp $manifest @('vmId')) -ne $layout.VMId) {
    throw "Hyper-V VM '$($layout.VMName)' was recreated since checkpoint $Name (VMId changed). Disk-only restore into a different VM registration is unsupported; disable the service and recreate with 'aap-demo create'."
  }
  $manifestDisks = (@(Get-AapJsonProp $manifest @('disks')) | Sort-Object) -join '|'
  if ($manifestDisks -ne (@($layout.Disks) -join '|')) {
    throw "VM disk set changed since checkpoint $Name; unsupported layout for restore"
  }
  $bundle = [string](Get-AapJsonProp $manifest @('bundleName'))
  if (-not $bundle -or -not (Test-AapStateBundleCached -HomePath $homePath -BundleName $bundle)) {
    throw "CRC bundle '$bundle' recorded in checkpoint $Name is not in .crc\cache; run 'crc setup' with the matching CRC version before restoring"
  }

  if (Test-AapStateLiveMatches -HomePath $homePath -Manifest $manifest) {
    Write-AapStep "Live state already matches checkpoint $Name; restore not needed"
    return $false
  }

  $records = @(@(Get-AapJsonProp $manifest @('files')) | Where-Object { $_ })
  $total = [int64]0
  foreach ($r in $records) { $total += [int64]$r.size }
  $required = [int64]([double]$total * $Script:AapStateSpaceFactor)
  $free = [int64](Get-AapStateFreeBytes -Path $homePath)
  if ($free -lt $required) {
    throw "Not enough free space to stage restore in ${homePath}: need $([math]::Round($required / 1GB, 2)) GiB, have $([math]::Round($free / 1GB, 2)) GiB"
  }

  $token = [guid]::NewGuid().ToString('N')
  $restoreRoot = Join-Path $homePath ".aap-restore-$token"
  $stageRoot = Join-Path $restoreRoot 'stage'
  $payload = Join-Path $backupDir 'payload'
  Write-AapStateJournal -HomePath $homePath -Token $token -Phase 'staging' -Ops @()
  $ops = New-Object System.Collections.Generic.List[object]
  $swapStarted = $false
  try {
    Write-AapStep "Staging checkpoint $Name ($([math]::Round($total / 1GB, 2)) GiB)..."
    foreach ($r in $records) {
      $rel = [string]$r.path
      $staged = Join-AapStatePath -Base $stageRoot -Relative $rel
      $hash = Copy-AapStateFileWithHash -Source (Join-AapStatePath -Base $payload -Relative $rel) -Destination $staged
      if ($hash -ne [string]$r.sha256) { throw "Checkpoint $Name file $rel failed checksum verification during staging" }
      [IO.File]::SetLastWriteTimeUtc($staged, ([DateTime]::new([int64]$r.mtime, [DateTimeKind]::Utc)))
      $target = Join-AapStatePath -Base $homePath -Relative $rel
      $hadCurrent = [IO.File]::Exists($target)
      if ($hadCurrent) { Copy-AapStateAcl -Source $target -Destination $staged }
      $ops.Add([ordered]@{ path = $rel; hadCurrent = $hadCurrent; hasStage = $true }) | Out-Null
    }
    $live = Get-AapStateLiveScope -HomePath $homePath
    $restored = @{}
    foreach ($r in $records) { $restored[[string]$r.path] = $true }
    foreach ($rel in @($live.Files.Keys)) {
      if ($restored.ContainsKey($rel)) { continue }
      if ($Script:AapStateOptionalFiles -contains $rel) { continue }
      $ops.Add([ordered]@{ path = $rel; hadCurrent = $true; hasStage = $false }) | Out-Null
    }

    Write-AapStateJournal -HomePath $homePath -Token $token -Phase 'swapping' -Ops $ops
    $swapStarted = $true
    foreach ($op in $ops) {
      $target = Join-AapStatePath -Base $homePath -Relative $op.path
      $prev = Join-AapStatePath -Base (Join-Path $restoreRoot 'prev') -Relative $op.path
      if ($op.hadCurrent) { Move-AapStatePath -From $target -To $prev }
      if ($op.hasStage) { Move-AapStatePath -From (Join-AapStatePath -Base $stageRoot -Relative $op.path) -To $target }
    }
    foreach ($d in @(Get-AapJsonProp $manifest @('dirs'))) {
      if ($d) { [IO.Directory]::CreateDirectory((Join-AapStatePath -Base $homePath -Relative ([string]$d))) | Out-Null }
    }
    Write-AapStateJournal -HomePath $homePath -Token $token -Phase 'committed' -Ops $ops
  } catch {
    $failure = $_.Exception.Message
    if ($swapStarted) {
      try {
        Invoke-AapStateRollbackOps -HomePath $homePath -Token $token -Ops $ops.ToArray()
      } catch {
        throw "Restore failed ($failure) and rollback failed: $($_.Exception.Message). Journal kept at $(Get-AapStateJournalFile); files at $restoreRoot"
      }
    }
    if (Test-Path -LiteralPath $restoreRoot) { Remove-Item -LiteralPath $restoreRoot -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath (Get-AapStateJournalFile) -Force -ErrorAction SilentlyContinue
    throw "Restore of checkpoint $Name failed and was rolled back: $failure"
  }
  Invoke-AapStateJournalRecovery
  Write-AapStep "Checkpoint $Name restored"
  return $true
}

# ---------------------------------------------------------------------------
# Pending-checkpoint marker
# ---------------------------------------------------------------------------

function Set-AapStateMarker {
  param([string]$Command)
  Write-AapStateTextAtomic -Path (Get-AapStateMarkerFile) -Content "command=$Command`nstarted=$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))`n"
}

function Clear-AapStateMarker { Remove-Item -LiteralPath (Get-AapStateMarkerFile) -Force -ErrorAction SilentlyContinue }

function Test-AapStateMarker { return [IO.File]::Exists((Get-AapStateMarkerFile)) }

# ---------------------------------------------------------------------------
# Managed lifecycle
# ---------------------------------------------------------------------------

function Invoke-AapStateManagedStop {
  [CmdletBinding()]
  param([string]$Command = 'stop')
  Assert-AapStateWindows
  Invoke-AapStateJournalRecovery
  $homePath = Get-AapStateHome
  Set-AapStateMarker -Command $Command
  $crcState = Get-AapStateCrcStatus
  if ($crcState -eq 'Running') {
    Write-AapStep 'Stopping CRC gracefully...'
    if (-not (Invoke-AapStateCrcStop)) {
      throw "crc stop failed; no checkpoint was taken and the pending marker is kept. Retry 'aap-demo stop'."
    }
  } elseif ($crcState -ne 'Stopped') {
    throw "CRC status is '$crcState'; cannot take a cold checkpoint"
  }
  Wait-AapStateVmOff -HomePath $homePath
  $name = New-AapStateBackup
  Clear-AapStateMarker
  return $name
}

function Invoke-AapStateRecoverAndStart {
  [CmdletBinding()]
  param()
  Assert-AapStateWindows
  Invoke-AapStateJournalRecovery
  if (Test-AapStateMarker) {
    throw "The last checkpoint did not complete, so the newest backup is older than the cluster disk. Run 'aap-demo service backup' to save the current state (or 'aap-demo service disable' to stop managing it) before starting."
  }
  $homePath = Get-AapStateHome
  $layout = Get-AapStateHyperVLayout -HomePath $homePath
  if (-not $layout.Supported) { throw "Unsupported Hyper-V layout: $($layout.Reason)" }
  switch ($layout.State) {
    'Running' {
      Write-AapStep 'VM already running; no restore performed'
    }
    'Off' {
      $latest = Get-AapStateLatestName
      if (-not $latest) {
        Write-AapStep 'No checkpoint yet; saving the current cold state first'
        New-AapStateBackup | Out-Null
      } else {
        Restore-AapStateBackup -Name $latest | Out-Null
      }
    }
    default {
      throw "Hyper-V VM '$($layout.VMName)' is '$($layout.State)'; automatic restore only handles Off or Running. Resolve it with 'crc start' / 'crc stop' (the VM is never forced off)."
    }
  }
  Invoke-AapStateClusterStart
}

function Invoke-AapDemoStartCommand {
  if (Test-AapStateServiceManaged) { Invoke-AapStateRecoverAndStart } else { Invoke-AapDemoStart }
}

function Invoke-AapDemoStopCommand {
  if (Test-AapStateServiceManaged) {
    Write-Host ''
    Write-Host 'aap-demo stop - Stopping CRC and saving a cold checkpoint...' -ForegroundColor Cyan
    Invoke-AapStateManagedStop -Command 'stop' | Out-Null
    Write-Host 'To restart: aap-demo start'
  } else {
    Invoke-AapDemoStop
  }
}

function Invoke-AapDemoRestart {
  Write-Host ''
  Write-Host 'aap-demo restart' -ForegroundColor Cyan
  if (Test-AapStateServiceManaged) {
    Invoke-AapStateManagedStop -Command 'restart' | Out-Null
    Invoke-AapStateRecoverAndStart
  } else {
    if ((Get-AapStateCrcStatus) -eq 'Running') {
      if (-not (Invoke-AapCrcStop)) { throw 'crc stop failed' }
    }
    Invoke-AapDemoStart
  }
}

# ---------------------------------------------------------------------------
# Scheduled task (current user, at logon, no stored password)
# ---------------------------------------------------------------------------

function Get-AapStateTaskAction {
  $script = Join-Path (Join-Path $Script:AapDemoRepoRoot 'powershell') 'aap-demo.ps1'
  if (-not [IO.File]::Exists($script)) { throw "aap-demo.ps1 not found at $script" }
  return @{ Execute = 'powershell.exe'; Argument = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`" service login-start" }
}

function Register-AapStateTask {
  if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
    throw 'ScheduledTasks module is not available; cannot register the logon task'
  }
  $user = Get-AapStateUser
  $actionSpec = Get-AapStateTaskAction
  try {
    $action = New-ScheduledTaskAction -Execute $actionSpec.Execute -Argument $actionSpec.Argument
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 3) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $Script:AapStateTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'aap-demo: restore the last cold CRC checkpoint and start AAP at logon' -Force -ErrorAction Stop | Out-Null
  } catch {
    throw "Failed to register scheduled task '$($Script:AapStateTaskName)' for ${user}: $($_.Exception.Message)"
  }
}

function Unregister-AapStateTask {
  if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { return }
  $task = Get-ScheduledTask -TaskName $Script:AapStateTaskName -ErrorAction SilentlyContinue
  if (-not $task) { return }
  try {
    Unregister-ScheduledTask -TaskName $Script:AapStateTaskName -Confirm:$false -ErrorAction Stop
  } catch {
    throw "Failed to unregister scheduled task '$($Script:AapStateTaskName)': $($_.Exception.Message)"
  }
}

function Get-AapStateTaskSummary {
  if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { return 'ScheduledTasks module unavailable' }
  $task = Get-ScheduledTask -TaskName $Script:AapStateTaskName -ErrorAction SilentlyContinue
  if (-not $task) { return 'not registered' }
  $info = Get-ScheduledTaskInfo -TaskName $Script:AapStateTaskName -ErrorAction SilentlyContinue
  if (-not $info) { return "registered ($($task.State))" }
  return "registered ($($task.State)); last run $($info.LastRunTime), last result $($info.LastTaskResult)"
}

# ---------------------------------------------------------------------------
# Service CLI
# ---------------------------------------------------------------------------

function Write-AapStateLastLogin {
  param([string]$Result, [string]$Message, [string]$Log)
  $record = [ordered]@{ finished = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); result = $Result; message = $Message; log = $Log }
  try { Write-AapStateTextAtomic -Path (Get-AapStateLastLoginFile) -Content ($record | ConvertTo-Json) } catch { }
}

function Invoke-AapStateLoginStart {
  $env:AAP_DEMO_SERVICE_INTERNAL = '1'
  $config = $null
  try { $config = Get-AapStateConfig } catch { }
  if (-not $config -or (Get-AapJsonProp $config @('enabled')) -ne $true) { return }
  if ([string](Get-AapJsonProp $config @('user')) -ne (Get-AapStateUser)) { return }

  $logDir = Join-Path (Get-AapStateRoot) 'logs'
  [IO.Directory]::CreateDirectory($logDir) | Out-Null
  $log = Join-Path $logDir "login-start-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')).log"
  $transcript = $false
  try { Start-Transcript -LiteralPath $log -Force | Out-Null; $transcript = $true } catch { }
  $lockToken = $null
  try {
    $lockToken = Enter-AapOperationLock -Command 'service login-start'
    Invoke-AapStateRecoverAndStart
    Invoke-AapDemoAutoDashboard
    Write-AapStateLastLogin -Result 'success' -Message 'Checkpoint restored (or unchanged) and AAP ready' -Log $log
  } catch {
    Write-AapStateLastLogin -Result 'failed' -Message $_.Exception.Message -Log $log
    throw
  } finally {
    Exit-AapOperationLock -Token $lockToken
    if ($transcript) { try { Stop-Transcript | Out-Null } catch { } }
    @(Get-ChildItem -LiteralPath $logDir -Filter 'login-start-*.log' -File | Sort-Object Name -Descending | Select-Object -Skip 10) |
      ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
  }
}

function Get-AapStateServiceKeepArg {
  param([string[]]$Arguments)
  $keep = $null
  for ($i = 0; $i -lt $Arguments.Count; $i++) {
    $a = $Arguments[$i]
    if ($a -match '^--keep=(.*)$') { $keep = ConvertTo-AapStateKeep $Matches[1]; continue }
    if ($a -eq '--keep') {
      if ($i + 1 -ge $Arguments.Count) { throw '--keep requires a value' }
      $keep = ConvertTo-AapStateKeep $Arguments[$i + 1]
      $i++
      continue
    }
    throw "Unknown service option: $a"
  }
  return $keep
}

function Show-AapStateServiceStatus {
  $config = Get-AapStateConfig
  Write-Host ''
  Write-Host 'aap-demo service status' -ForegroundColor Cyan
  if (-not $config) {
    Write-Host '  State service:  not installed'
    Write-Host "  Install with:   aap-demo service install [--keep N]"
    return
  }
  $enabled = (Get-AapJsonProp $config @('enabled')) -eq $true
  Write-Host "  State service:  $(if ($enabled) { 'enabled' } else { 'disabled' })"
  Write-Host "  Owner:          $(Get-AapJsonProp $config @('user'))"
  Write-Host "  Retention:      $(Get-AapStateKeep)"
  Write-Host "  Logon task:     $(Get-AapStateTaskSummary)"
  Write-Host "  State root:     $(Get-AapStateRoot)"
  $latest = $null
  try { $latest = Get-AapStateLatestName } catch { Write-AapWarn $_.Exception.Message }
  Write-Host "  Latest backup:  $(if ($latest) { $latest } else { 'none' })"
  Write-Host "  Backups:        $(@(Get-AapStateBackupNames).Count)"
  if (Test-AapStateMarker) { Write-AapWarn "Checkpoint pending/failed; run 'aap-demo service backup'" }
  if ([IO.File]::Exists((Get-AapStateJournalFile))) { Write-AapWarn 'Interrupted restore journal present; the next state operation rolls it back' }
  $last = $null
  try { $last = Read-AapStateJsonFile -Path (Get-AapStateLastLoginFile) } catch { }
  if ($last) {
    Write-Host "  Last logon run: $(Get-AapJsonProp $last @('result')) at $(Get-AapJsonProp $last @('finished')) - $(Get-AapJsonProp $last @('message'))"
    Write-Host "  Logon log:      $(Get-AapJsonProp $last @('log'))"
  }
  $layout = Get-AapStateHyperVLayout -HomePath (Get-AapStateHome)
  if ($layout.Supported) {
    Write-Host "  Hyper-V VM:     $($layout.VMName) ($($layout.State))"
    if ($layout.AutomaticStopAction -eq 'Save') {
      Write-AapWarn "VM AutomaticStopAction is Save; saved VMs are refused by restore. Run: Set-VM -Name crc -AutomaticStopAction ShutDown"
    }
  } else {
    Write-AapWarn "Hyper-V layout: $($layout.Reason)"
  }
}

function Show-AapStateBackups {
  $latest = $null
  try { $latest = Get-AapStateLatestName } catch { Write-AapWarn $_.Exception.Message }
  $names = @(Get-AapStateBackupNames)
  if ($names.Count -eq 0) { Write-Host '  No checkpoints'; return }
  foreach ($name in $names) {
    $dir = Join-Path (Get-AapStateBackupsDir) $name
    $state = 'complete'
    $size = ''
    try {
      $m = Test-AapStateBackup -BackupDir $dir
      $size = "$([math]::Round([int64](Get-AapJsonProp $m @('totalBytes')) / 1GB, 2)) GiB"
    } catch {
      $state = "INVALID: $($_.Exception.Message)"
    }
    $mark = if ($name -eq $latest) { '*' } else { ' ' }
    Write-Host "  $mark $name  $size  $state"
  }
}

function Invoke-AapDemoService {
  [CmdletBinding()]
  param([string[]]$Arguments = @())
  $Arguments = @($Arguments | Where-Object { $null -ne $_ })
  $sub = if ($Arguments.Count -gt 0) { $Arguments[0] } else { 'status' }
  $rest = @(if ($Arguments.Count -gt 1) { $Arguments[1..($Arguments.Count - 1)] })

  switch ($sub) {
    'install' {
      Assert-AapStateWindows
      $keep = Get-AapStateServiceKeepArg -Arguments $rest
      if (-not $keep) { $keep = $Script:AapStateDefaultKeep }
      $layout = Get-AapStateHyperVLayout -HomePath (Get-AapStateHome)
      if (-not $layout.Supported) { throw "Cannot install the state service: $($layout.Reason)" }
      if ($layout.AutomaticStopAction -eq 'Save') {
        Write-AapWarn 'VM AutomaticStopAction is Save; restore refuses saved VMs. Run: Set-VM -Name crc -AutomaticStopAction ShutDown'
      }
      Register-AapStateTask
      try {
        Save-AapStateConfig -Enabled $true -Keep $keep
      } catch {
        try { Unregister-AapStateTask } catch { }
        throw
      }
      Write-AapStep "State service enabled (retention $keep, logon task '$($Script:AapStateTaskName)')"
      if (-not (Get-AapStateLatestName)) {
        Write-Host "  No checkpoint yet. 'aap-demo stop' or 'aap-demo service backup' saves the first one."
      }
    }
    'retention' {
      if ($rest.Count -ne 1) { throw 'Usage: aap-demo service retention N' }
      $keep = ConvertTo-AapStateKeep $rest[0]
      $config = Get-AapStateConfig
      if (-not $config) { throw "State service is not installed; run 'aap-demo service install --keep $keep'" }
      Save-AapStateConfig -Enabled ((Get-AapJsonProp $config @('enabled')) -eq $true) -Keep $keep
      Invoke-AapStatePrune -Keep $keep
      Write-AapStep "Retention set to $keep"
    }
    'status' { Show-AapStateServiceStatus }
    'backups' { Show-AapStateBackups }
    'backup' {
      if (-not (Test-AapStateServiceManaged)) { throw "State service is not enabled; run 'aap-demo service install' first" }
      Write-Host ''
      Write-Host 'aap-demo service backup - Stopping CRC and saving a cold checkpoint...' -ForegroundColor Cyan
      Invoke-AapStateManagedStop -Command 'service backup' | Out-Null
      Write-Host 'The cluster is stopped. Start it with: aap-demo start'
    }
    'restore' {
      Assert-AapStateWindows
      if (Test-AapStateMarker) { throw "A checkpoint is pending; run 'aap-demo service backup' before restoring" }
      $name = if ($rest.Count -gt 0) { $rest[0] } else { $null }
      if ($name -and $name -notmatch $Script:AapStateBackupNamePattern) { throw "Invalid checkpoint name '$name'" }
      Restore-AapStateBackup -Name $name | Out-Null
      Write-Host 'Cluster left stopped. Start it with: aap-demo start'
    }
    'verify' {
      $name = if ($rest.Count -gt 0) { $rest[0] } else { Get-AapStateLatestName }
      if (-not $name) { throw 'No checkpoint to verify' }
      if ($name -notmatch $Script:AapStateBackupNamePattern) { throw "Invalid checkpoint name '$name'" }
      Test-AapStateBackup -BackupDir (Join-Path (Get-AapStateBackupsDir) $name) -Full | Out-Null
      Write-AapStep "Checkpoint $name verified"
    }
    'disable' {
      Unregister-AapStateTask
      $config = Get-AapStateConfig
      if ($config) { Save-AapStateConfig -Enabled $false -Keep (Get-AapStateKeep) }
      if (Test-AapStateMarker) { Write-AapWarn "A failed checkpoint is still pending; re-enabling requires 'aap-demo service backup' before automatic restore" }
      Write-AapStep "State service disabled; checkpoints kept in $(Get-AapStateBackupsDir)"
    }
    'login-start' { Invoke-AapStateLoginStart }
    default { throw "Unknown service command '$sub'. Use: install [--keep N] | retention N | status | backups | backup | restore [NAME] | verify [NAME] | disable" }
  }
}
