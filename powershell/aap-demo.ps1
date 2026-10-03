#Requires -Version 5.1

<#

.SYNOPSIS

  aap-demo CLI for Windows (PowerShell).



.DESCRIPTION

  PowerShell is the Windows entrypoint and delegates supported commands to the
  repository Bash CLI through Git for Windows.

#>

[CmdletBinding()]

param(

  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]

  [string[]]$Arguments

)



Set-StrictMode -Version Latest

$ErrorActionPreference = 'Stop'



$ModuleRoot = Join-Path $PSScriptRoot 'native'

$AapDemoModule = Import-Module (Join-Path $ModuleRoot 'AapDemo.psm1') -Force -PassThru

$WindowsBlockedAddons = @(
  'apme', 'apme-eap', 'fleet', 'local-cache',
  'product-demos-base', 'product-demo-linux', 'product-demo-windows',
  'product-demo-network', 'product-demo-cloud', 'product-demo-openshift',
  'product-demo-satellite'
)

function Assert-AapWindowsAddonPolicy {
  param([string[]]$CliArguments)

  $commandIndex = -1
  for ($i = 0; $i -lt $CliArguments.Count; $i++) {
    if ($CliArguments[$i].ToLowerInvariant() -in @('enable', 'disable', 'fleet')) {
      $commandIndex = $i
      break
    }
  }
  if ($commandIndex -lt 0) { return }
  if ($CliArguments[$commandIndex].ToLowerInvariant() -eq 'fleet') {
    throw "Addon 'fleet' is not available through the Windows wrapper. Use the supported Bash/Linux workflow for this addon."
  }
  if ($commandIndex + 1 -ge $CliArguments.Count) { return }
  $addon = $CliArguments[$commandIndex + 1].ToLowerInvariant()
  if ($WindowsBlockedAddons -contains $addon) {
    throw "Addon '$addon' is not available through the Windows wrapper. Use the supported Bash/Linux workflow for this addon."
  }
}

function Invoke-AapWindowsBashCli {
  param([Parameter(Mandatory)][string[]]$CliArguments)

  $deployCommands = @('deploy', 'deploy-all', 'redeploy', 'redeploy-all')
  $demoAddons = @(
    'ao', 'product-demos', 'product-demos-base',
    'product-demo-linux', 'product-demo-windows', 'product-demo-network',
    'product-demo-cloud', 'product-demo-openshift', 'product-demo-satellite'
  )
  $isDemoEnable = $CliArguments.Count -ge 2 -and
    $CliArguments[0].ToLowerInvariant() -eq 'enable' -and
    $demoAddons -contains $CliArguments[1].ToLowerInvariant()
  if ($isDemoEnable -or @($CliArguments | Where-Object {
      $deployCommands -contains $_.ToLowerInvariant()
    }).Count -gt 0) {
    Assert-AapWindowsDeployPrerequisites
  }

  $interactiveCommands = @(
    'create', 'deploy', 'deploy-all', 'redeploy', 'redeploy-all',
    'setup', 'enable', 'disable', 'wire', 'repair', 'start', 'stop',
    'destroy', 'clean', 'update', 'idle', 'ssh'
  )
  $interactive = @($CliArguments | Where-Object {
      $interactiveCommands -contains $_.ToLowerInvariant()
    }).Count -gt 0
  $result = Invoke-AapGitBashCli -Arguments $CliArguments -Interactive:$interactive
  if ($result.Success) {
    $trustCommands = @('deploy', 'deploy-all', 'redeploy', 'redeploy-all', 'repair', 'start')
    if ($CliArguments | Where-Object { $trustCommands -contains $_.ToLowerInvariant() }) {
      try { & $AapDemoModule { Install-AapIngressCaTrust } } catch {
        Write-Warning "Could not update Windows ingress CA trust: $($_.Exception.Message)"
      }
    }
    exit 0
  }
  $detail = if ($result.Stderr) { $result.Stderr.Trim() } else { $result.Stdout.Trim() }
  Write-Error "Git Bash CLI failed (exit $($result.ExitCode)): $detail"
  $exitCode = [int]$result.ExitCode
  if ($exitCode -le 0) { $exitCode = 1 }
  exit $exitCode
}

if (-not $Arguments -or $Arguments.Count -eq 0 -or
    $Arguments[0].ToLowerInvariant() -in @('help', '--help', '-h')) {
  Get-AapDemoHelp
  exit 0
}

try {
  Assert-AapWindowsAddonPolicy -CliArguments $Arguments
  Invoke-AapWindowsBashCli -CliArguments $Arguments
} catch {
  Write-Error $_.Exception.Message
  exit 1
}

# The legacy native dispatcher below remains available for module-level
# development and future migration, but the Windows launcher exits through the
# single Git Bash path above.



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
    SkipCache    = $false
    RefreshCatalog = $false
    PurgeData    = $false
    PurgeCreds   = $false

    Positional   = [System.Collections.Generic.List[string]]::new()

  }



  foreach ($arg in @($Rest)) {

    switch -Regex ($arg) {

      '^-Force$|^--force$' { $parsed.Force = $true; continue }

      '^--reset$' { $parsed.Reset = $true; continue }

      '^--ai$' { $parsed.Ai = $true; continue }
      '^--skip-cache$' { $parsed.SkipCache = $true; continue }
      '^--refresh-catalog$' { $parsed.RefreshCatalog = $true; continue }
      '^--purge-data$' { $parsed.PurgeData = $true; continue }
      '^--purge-creds$' { $parsed.PurgeCreds = $true; continue }

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

    'status' { Invoke-AapDemoStatus }

    'version' { Invoke-AapDemoVersion }

    '--version' { Invoke-AapDemoVersion }

    '-v' { Invoke-AapDemoVersion }

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

    'start' { Invoke-AapDemoStart }

    'wire' { Invoke-AapDemoWire }

    'destroy' { Invoke-AapDemoDestroy -Reset:$cli.Reset -SkipCache:$cli.SkipCache }

    'clean' {

      $params = @{}

      if ($cli.Namespace) { $params.Namespace = $cli.Namespace }

      Invoke-AapDemoClean @params

    }

    'repair' { Invoke-AapDemoRepair }

    'setup' { Invoke-AapDemoSetup }

    'setup-pah' {
      $params = @{}
      if ($cli.Namespace) { $params.Namespace = $cli.Namespace }
      Invoke-AapDemoSetupPah @params
    }

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
      $addonArgs = @($cli.Positional | Select-Object -Skip 1)
      if ($cli.Force) { $addonArgs += '--force' }
      if ($cli.RefreshCatalog) { $addonArgs += '--refresh-catalog' }
      if ($cli.PurgeData) { $addonArgs += '--purge-data' }
      if ($cli.PurgeCreds) { $addonArgs += '--purge-creds' }
      if ($addonArgs.Count -gt 0) { $params.AddonArgs = $addonArgs }
      Invoke-AapDemoEnable @params

    }

    'disable' {

      $addon = if ($cli.Positional.Count -gt 0) { $cli.Positional[0] } else { $null }

      $params = @{}
      if ($addon) { $params.Addon = $addon }
      if ($cli.Namespace) { $params.Namespace = $cli.Namespace }
      $addonArgs = @($cli.Positional | Select-Object -Skip 1)
      if ($cli.Force) { $addonArgs += '--force' }
      if ($cli.PurgeData) { $addonArgs += '--purge-data' }
      if ($cli.PurgeCreds) { $addonArgs += '--purge-creds' }
      if ($addonArgs.Count -gt 0) { $params.AddonArgs = $addonArgs }
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
