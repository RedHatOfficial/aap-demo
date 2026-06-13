#Requires -Version 5.1
<#
.SYNOPSIS
  aap-demo CLI for Windows (PowerShell).

.DESCRIPTION
  Core commands (create, deploy, status, diagnose) run in PowerShell.
  All other commands delegate to aap-demo.sh via Git Bash.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Arguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ModuleRoot = Join-Path $PSScriptRoot 'native'
Import-Module (Join-Path $ModuleRoot 'AapDemo.psm1') -Force

if (-not $Arguments -or $Arguments.Count -eq 0) {
  Get-AapDemoHelp
  exit 0
}

$command = $Arguments[0]
$rest = @()
if ($Arguments.Count -gt 1) {
  $rest = $Arguments[1..($Arguments.Count - 1)]
}

switch ($command.ToLowerInvariant()) {
  'create' {
    Invoke-AapDemoCreate
  }
  'deploy' {
    $params = @{}
    if ($rest -contains '-Force' -or $rest -contains '--force') {
      $params.Force = $true
    }
    foreach ($arg in $rest) {
      if ($arg -match '^-Namespace=(.+)$') { $params.Namespace = $Matches[1] }
      elseif ($arg -match '^-Channel=(.+)$') { $params.Channel = $Matches[1] }
    }
    Invoke-AapDemoDeploy @params
  }
  'status' {
    Invoke-AapDemoStatus
  }
  'diagnose' {
    $params = @{}
    if ($rest -contains '--ai') { $params.Ai = $true }
    Invoke-AapDemoDiagnose @params
  }
  { $_ -in @('help', '--help', '-h') } {
    Get-AapDemoHelp
  }
  default {
    Invoke-AapBashCli @Arguments
  }
}
