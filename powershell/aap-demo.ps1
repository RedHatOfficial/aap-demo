#Requires -Version 5.1

<#

.SYNOPSIS

  aap-demo CLI for Windows (PowerShell).



.DESCRIPTION

  All commands run natively in PowerShell.

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



function Get-AapParsedCliArgs {

  param([string[]]$Rest)



  $parsed = @{

    Namespace    = $null

    Channel      = $null

    OcpVersion   = $null

    CrName       = 'minimal'

    PublicUrl    = $null

    Force        = $false

    Reset        = $false

    Ai           = $false

    OperatorOnly = $false

    Positional   = [System.Collections.Generic.List[string]]::new()

  }



  foreach ($arg in @($Rest)) {

    switch -Regex ($arg) {

      '^-Force$|^--force$' { $parsed.Force = $true; continue }

      '^--reset$' { $parsed.Reset = $true; continue }

      '^--ai$' { $parsed.Ai = $true; continue }

      '^-Namespace=(.+)$' { $parsed.Namespace = $Matches[1]; continue }

      '^-Channel=(.+)$' { $parsed.Channel = $Matches[1]; continue }

      '^-OcpVersion=(.+)$' { $parsed.OcpVersion = $Matches[1]; continue }

      '^CR=(.+)$' { $parsed.CrName = $Matches[1]; continue }

      '^PUBLIC_URL=(.+)$' { $parsed.PublicUrl = $Matches[1]; continue }

      '^NAMESPACE=(.+)$' { $parsed.Namespace = $Matches[1]; continue }

      '^AAP_OCP_VERSION=(.+)$' { $parsed.OcpVersion = $Matches[1]; continue }

      default { $parsed.Positional.Add($arg) | Out-Null }

    }

  }

  return $parsed

}



function Invoke-AapDeployParams {

  param($Parsed)



  $params = @{}

  if ($Parsed.Namespace) { $params.Namespace = $Parsed.Namespace }

  if ($Parsed.Channel) { $params.Channel = $Parsed.Channel }

  if ($Parsed.OcpVersion) { $params.OcpVersion = $Parsed.OcpVersion }

  if ($Parsed.CrName) { $params.CrName = $Parsed.CrName }

  if ($Parsed.Force) { $params.Force = $true }

  if ($Parsed.OperatorOnly) { $params.OperatorOnly = $true }

  return $params

}



if (-not $Arguments -or $Arguments.Count -eq 0) {

  Get-AapDemoHelp

  exit 0

}



$command = $Arguments[0].ToLowerInvariant()

$rest = @()

if ($Arguments.Count -gt 1) {

  $rest = $Arguments[1..($Arguments.Count - 1)]

}

$cli = Get-AapParsedCliArgs -Rest $rest



try {

  switch ($command) {

    'create' { Invoke-AapDemoCreate }

    'deploy' {
      $deployParams = Invoke-AapDeployParams $cli
      Invoke-AapDemoDeploy @deployParams
    }

    'deploy-all' {
      $deployParams = Invoke-AapDeployParams $cli
      Invoke-AapDemoDeploy @deployParams
    }

    'deploy-operator' {

      $cli.OperatorOnly = $true

      $deployParams = Invoke-AapDeployParams $cli

      Invoke-AapDemoDeploy @deployParams

    }

    'deploy-aap' {

      $params = @{ CrName = $cli.CrName }

      if ($cli.Namespace) { $params.Namespace = $cli.Namespace }

      if ($cli.PublicUrl) { $params.PublicUrl = $cli.PublicUrl }

      Invoke-AapDemoDeployAap @params

    }

    'status' { Invoke-AapDemoStatus }

    'diagnose' {

      $params = @{}

      if ($cli.Namespace) { $params.Namespace = $cli.Namespace }

      if ($cli.Ai) { $params.Ai = $true }

      Invoke-AapDemoDiagnose @params

    }

    'watch' {

      $params = @{}

      if ($cli.Namespace) { $params.Namespace = $cli.Namespace }

      Invoke-AapDemoWatch @params

    }

    'stop' { Invoke-AapDemoStop }

    'destroy' { Invoke-AapDemoDestroy -Reset:$cli.Reset }

    'clean' {

      $params = @{}

      if ($cli.Namespace) { $params.Namespace = $cli.Namespace }

      Invoke-AapDemoClean @params

    }

    'repair' { Invoke-AapDemoRepair }

    'setup' { Invoke-AapDemoSetup }

    'ssh' { Invoke-AapDemoSsh }

    'kubeconfig' { Invoke-AapDemoKubeconfig }

    'idle' {

      $params = @{}

      if ($cli.Namespace) { $params.Namespace = $cli.Namespace }

      if ($cli.Positional.Count -gt 0) { $params.Value = $cli.Positional[0] }

      Invoke-AapDemoIdle @params

    }

    'config' {

      $key = if ($cli.Positional.Count -gt 0) { $cli.Positional[0] } else { $null }

      $val = if ($cli.Positional.Count -gt 1) { $cli.Positional[1] } else { $null }

      Invoke-AapDemoConfig -Key $key -Value $val

    }

    'update' { Invoke-AapDemoUpdate }

    'redhat-status' { Invoke-AapDemoRedhatStatus }

    'rh-status' { Invoke-AapDemoRedhatStatus }

    'must-gather' {

      $dest = if ($cli.Positional.Count -gt 0) { $cli.Positional[0] } else { $null }

      Invoke-AapDemoMustGather -DestDir $dest

    }

    'enable' {

      $addon = if ($cli.Positional.Count -gt 0) { $cli.Positional[0] } else { $null }

      $params = @{}
      if ($addon) { $params.Addon = $addon }
      if ($cli.Namespace) { $params.Namespace = $cli.Namespace }
      Invoke-AapDemoEnable @params

    }

    'disable' {

      $addon = if ($cli.Positional.Count -gt 0) { $cli.Positional[0] } else { $null }

      $params = @{}
      if ($addon) { $params.Addon = $addon }
      if ($cli.Namespace) { $params.Namespace = $cli.Namespace }
      Invoke-AapDemoDisable @params

    }

    'redeploy' {
      $deployParams = Invoke-AapDeployParams $cli
      Invoke-AapDemoRedeploy @deployParams
    }

    'redeploy-all' {
      $deployParams = Invoke-AapDeployParams $cli
      Invoke-AapDemoRedeployAll @deployParams
    }

    { $_ -in @('help', '--help', '-h') } { Get-AapDemoHelp }

    default {

      Write-Host "Unknown command: $($Arguments[0])"

      Write-Host "Run 'aap-demo help' for usage"

      exit 1

    }

  }

} catch {

  Write-Host "  ERROR $($_.Exception.Message)" -ForegroundColor Red

  exit 1

}

