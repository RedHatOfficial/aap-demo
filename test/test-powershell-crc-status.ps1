Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'powershell/native/Private/Helpers.ps1')

function Fail {
  param([string]$Message)
  Write-Error $Message
}

$script:CrcStatusCalls = @()
function crc {
  $script:CrcStatusCalls += ,@($args)
  if ($args -join ' ' -eq 'status -o json') {
    Write-Error 'chmod C:\Users\adler\.crc\sockets: Access is denied.' -ErrorAction Continue
    $global:LASTEXITCODE = 1
    return
  }

  if ($args -join ' ' -eq 'status') {
    $global:LASTEXITCODE = 0
    @(
      'CRC VM:                  Running',
      'MicroShift:              Running (v4.22.0)',
      'RAM Usage:               12.16GB of 16.76GB'
    )
    return
  }

  Fail "Unexpected crc arguments: $($args -join ' ')"
}

$status = Get-AapCrcStatus
if ($status.crcStatus -ne 'Running') {
  Fail "Expected crcStatus Running from text fallback, got '$($status.crcStatus)'"
}

$usedTextFallback = $script:CrcStatusCalls | Where-Object { ($_ -join ' ') -eq 'status' }
if (-not $usedTextFallback) {
  Fail 'Expected Get-AapCrcStatus to fall back to plain crc status'
}

Write-Host 'PowerShell CRC status fallback test passed'
