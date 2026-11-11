# Cross-process operation lock shared by all native mutating commands.
# Layout matches includes/operation-lock.sh: <config>\operation.lock\owner
# with pid=, token=, command=, started= lines. Re-entrant for child
# processes through AAP_DEMO_LOCK_TOKEN.

$Script:AapLockAcquireTimeoutSeconds = 30
$Script:AapLockHeldToken = $null

function Get-AapOperationLockDir {
  return (Join-Path $Script:AapDemoConfigDir 'operation.lock')
}

function Read-AapOperationLockOwner {
  param([Parameter(Mandatory)][string]$OwnerPath)
  $info = @{}
  try {
    foreach ($line in [System.IO.File]::ReadAllLines($OwnerPath)) {
      $idx = $line.IndexOf('=')
      if ($idx -gt 0) { $info[$line.Substring(0, $idx)] = $line.Substring($idx + 1) }
    }
  } catch {
    return $null
  }
  return $info
}

function Get-AapProcessStartTicks {
  param([int]$ProcessId)
  try {
    $proc = Get-Process -Id $ProcessId -ErrorAction Stop
    return [string]$proc.StartTime.ToUniversalTime().Ticks
  } catch {
    return $null
  }
}

function Test-AapOperationLockOwnerAlive {
  param([hashtable]$Owner)
  if (-not $Owner -or -not $Owner.ContainsKey('pid')) { return $false }
  $ownerPid = 0
  if (-not [int]::TryParse([string]$Owner['pid'], [ref]$ownerPid) -or $ownerPid -le 0) { return $false }
  $ticks = Get-AapProcessStartTicks -ProcessId $ownerPid
  if (-not $ticks) {
    # Unix-style owners (WSL/Bash) cannot be probed from Windows; Get-Process
    # failing means the pid is not a live Windows process.
    return $false
  }
  if ($Owner.ContainsKey('pidstart') -and $Owner['pidstart'] -and $Owner['pidstart'] -ne $ticks) {
    return $false
  }
  return $true
}

function Enter-AapOperationLock {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Command)

  if ($env:AAP_DEMO_DISABLE_LOCK -eq 'true') { return $null }

  $lockDir = Get-AapOperationLockDir
  $ownerPath = Join-Path $lockDir 'owner'

  if ($env:AAP_DEMO_LOCK_TOKEN -and (Test-Path -LiteralPath $ownerPath)) {
    $existing = Read-AapOperationLockOwner -OwnerPath $ownerPath
    if ($existing -and $existing['token'] -eq $env:AAP_DEMO_LOCK_TOKEN) {
      return $null
    }
  }

  [System.IO.Directory]::CreateDirectory($Script:AapDemoConfigDir) | Out-Null
  $token = [guid]::NewGuid().ToString('N')
  $deadline = (Get-Date).AddSeconds($Script:AapLockAcquireTimeoutSeconds)
  while ($true) {
    [System.IO.Directory]::CreateDirectory($lockDir) | Out-Null
    $stream = $null
    try {
      $stream = [System.IO.File]::Open($ownerPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    } catch [System.IO.IOException] {
      $stream = $null
    } catch [System.UnauthorizedAccessException] {
      $stream = $null
    }
    if ($stream) {
      try {
        $content = "pid=$PID`ntoken=$token`ncommand=$Command`nstarted=$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))`npidstart=$(Get-AapProcessStartTicks -ProcessId $PID)`n"
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($content)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
      } finally {
        $stream.Dispose()
      }
      $env:AAP_DEMO_LOCK_TOKEN = $token
      $Script:AapLockHeldToken = $token
      return $token
    }

    if (Test-Path -LiteralPath $ownerPath) {
      $owner = Read-AapOperationLockOwner -OwnerPath $ownerPath
      if ($owner -and -not (Test-AapOperationLockOwnerAlive -Owner $owner)) {
        $recheck = Read-AapOperationLockOwner -OwnerPath $ownerPath
        if ($recheck -and $recheck['token'] -eq $owner['token']) {
          Write-AapWarn "Removing stale operation lock from '$($owner['command'])' (pid $($owner['pid']))"
          Remove-Item -LiteralPath $ownerPath -Force -ErrorAction SilentlyContinue
        }
        continue
      }
      if ((Get-Date) -ge $deadline) {
        $desc = 'another aap-demo operation'
        if ($owner) { $desc = "'$($owner['command'])' (pid $($owner['pid']), started $($owner['started']))" }
        throw "Another aap-demo operation is running: $desc. Wait for it to finish; if that process is gone, remove $lockDir"
      }
    } elseif ((Get-Date) -ge $deadline) {
      throw "Operation lock $lockDir has no owner file; remove it if no aap-demo command is running"
    }
    Start-Sleep -Milliseconds 500
  }
}

function Exit-AapOperationLock {
  param([string]$Token)
  if (-not $Token) { return }
  $lockDir = Get-AapOperationLockDir
  $ownerPath = Join-Path $lockDir 'owner'
  $owner = $null
  if (Test-Path -LiteralPath $ownerPath) {
    $owner = Read-AapOperationLockOwner -OwnerPath $ownerPath
  }
  if ($owner -and $owner['token'] -eq $Token) {
    Remove-Item -LiteralPath $ownerPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $lockDir -Force -ErrorAction SilentlyContinue
  }
  if ($env:AAP_DEMO_LOCK_TOKEN -eq $Token) {
    Remove-Item Env:\AAP_DEMO_LOCK_TOKEN -ErrorAction SilentlyContinue
  }
  if ($Script:AapLockHeldToken -eq $Token) { $Script:AapLockHeldToken = $null }
}
