# Addons listed in `aap-demo enable` (matches bash AVAILABLE_ADDONS).
$Script:AapAvailableAddons = @(
  'mcp-server', 'portal', 'setup-pah', 'ao', 'apme-eap', 'local-cache',
  'product-demos', 'product-demo-satellite'
)

# Implemented natively in PowerShell (no Git Bash).
$Script:AapNativeAddons = @('mcp-server', 'portal', 'setup-pah')

function Get-AapBashDelegatedAddons {
  $addonsDir = Join-Path $Script:AapDemoRepoRoot 'addons'
  if (-not (Test-Path -LiteralPath $addonsDir)) { return @() }

  return @(
    Get-ChildItem -LiteralPath $addonsDir -Directory |
      Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'deploy.sh') } |
      ForEach-Object { $_.Name } |
      Where-Object { $_ -notin $Script:AapNativeAddons }
  )
}

function Test-AapAddonExists {
  param([Parameter(Mandatory)][string]$Addon)

  if ($Addon -in $Script:AapNativeAddons) { return $true }

  $deploySh = Join-Path $Script:AapDemoRepoRoot "addons/$Addon/deploy.sh"
  return Test-Path -LiteralPath $deploySh
}

function Test-AapAddonUsesBash {
  param([Parameter(Mandatory)][string]$Addon)
  return ($Addon -notin $Script:AapNativeAddons) -and (Test-AapAddonExists -Addon $Addon)
}

function Assert-AapBashAvailable {
  param([string]$Addon = $null)

  if (Get-Command bash -ErrorAction SilentlyContinue) { return }

  $bashAddons = Get-AapBashDelegatedAddons
  $addonList = if ($bashAddons.Count -gt 0) { $bashAddons -join ', ' } else { '(see addons/ in repo)' }
  $prefix = if ($Addon) { "Addon '$Addon'" } else { 'This command' }

  throw @"
$prefix requires Git Bash (bash on PATH).

Install Git for Windows:
  winget install --id Git.Git -e --source winget

Then open a new PowerShell window.

Bash-delegated addons: $addonList
Also requires bash: aap-demo test
"@
}

function Initialize-AapBashAddonEnvironment {
  Sync-AapKubeconfig -Quiet
  Initialize-AapKubeEnvironment

  $kube = Get-AapKubeconfigPath
  if ($kube) { $env:KUBECONFIG = $kube }

  $shimDir = Join-Path $Script:AapDemoConfigDir 'bin'
  New-Item -ItemType Directory -Force -Path $shimDir | Out-Null

  $kubectlBash = Join-Path $shimDir 'kubectl'
  $kubectlContent = @'
#!/usr/bin/env bash
exec oc "$@"
'@
  if (-not (Test-Path -LiteralPath $kubectlBash) -or
      (Get-Content -LiteralPath $kubectlBash -Raw) -ne $kubectlContent) {
    Set-Content -LiteralPath $kubectlBash -Value $kubectlContent -Encoding ascii -NoNewline
  }

    $kubectlCmd = Join-Path $shimDir 'kubectl.cmd'
  if (-not (Test-Path -LiteralPath $kubectlCmd)) {
    Set-Content -LiteralPath $kubectlCmd -Value "@echo off`r`noc %*" -Encoding ascii
  }

  if ($env:Path -notlike "*$shimDir*") {
    $env:Path = "$shimDir;$env:Path"
  }
}

function Invoke-AapAddonDeployScript {
  param(
    [Parameter(Mandatory)][string]$Addon,
    [string[]]$ScriptArgs = @()
  )

  Assert-AapBashAvailable -Addon $Addon

  $deploySh = Join-Path $Script:AapDemoRepoRoot "addons/$Addon/deploy.sh"
  if (-not (Test-Path -LiteralPath $deploySh)) {
    throw "Addon '$Addon' has no deploy.sh"
  }

  Initialize-AapBashAddonEnvironment

  $bash = Get-Command bash -ErrorAction Stop
  & $bash.Source $deploySh @ScriptArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Addon '$Addon' deploy failed (exit code: $LASTEXITCODE)"
  }
}

function Invoke-AapEnsureClusterReady {
  Invoke-AapEnsureCluster
  Set-AapIngressCaEnvFromSaved
}

function Invoke-AapDeployMcpServerAddon {
  param(
    [string]$Namespace = $Script:AapDemoDefaultNamespace
  )

  $csvResult = Invoke-AapOcCapture @('get', 'csv', '-n', $Namespace, '--no-headers')
  if (-not (Test-AapOcHasListOutput $csvResult) -or ($csvResult.Output -notmatch 'aap-operator')) {
    Write-AapWarn "AAP operator not found in namespace '$Namespace'"
    Write-Host '  Deploy AAP first: aap-demo deploy'
    Write-Host '  Proceeding anyway (CR will reconcile once operator is ready)...'
  }

  if ((Invoke-AapOcQuiet @('get', 'crd', 'ansiblemcpservers.mcpserver.ansible.com')) -ne 0) {
    Write-AapWarn 'AnsibleMCPServer CRD not found (requires AAP operator 2.6+)'
    Write-Host '  Proceeding anyway (CR will be applied once CRD is available)...'
  }

  if ((Invoke-AapOcQuiet @('get', 'secret', 'redhat-operators-pull-secret', '-n', $Namespace)) -ne 0) {
    Write-AapWarn "Pull secret 'redhat-operators-pull-secret' not found in $Namespace"
    Write-Host '  MCP server pod may fail to pull images without it'
  }

  Write-Host 'Deploying AAP MCP Server...'

  $manifest = Read-AapManifest 'addons/mcp-server/mcp-server.yaml'
  $manifest = $manifest -replace '(?m)^  namespace: aap-operator$', "  namespace: $Namespace"
  $manifest = $manifest -replace 'aap-mcp-aap-operator', "aap-mcp-$Namespace"
  $manifest = $manifest -replace 'aap-aap-operator', "aap-$Namespace"

  $temp = [System.IO.Path]::GetTempFileName()
  try {
    Set-AapUtf8Content -Path $temp -Value $manifest
    Invoke-AapOc @('apply', '-f', $temp) | Out-Null
  } finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
  }

  $mcpRoute = "aap-mcp-$Namespace.apps.127.0.0.1.nip.io"
  $aapRoute = "aap-$Namespace.apps.127.0.0.1.nip.io"
  Write-AapStep 'AAP MCP Server deployed'
  Write-Host ''
  Write-Host "  MCP Endpoint: https://$mcpRoute/mcp"
  Write-Host "  AAP Instance: https://$aapRoute"
  Write-Host ''
  Write-Host "  Status:  oc get ansiblemcpserver -n $Namespace"
  Write-Host "  Logs:    oc logs -n $Namespace -l app.kubernetes.io/name=aap-mcp-server"
  Write-Host ''
  Write-Host '  Connect your MCP client to:'
  Write-Host "    https://$mcpRoute/mcp"
  Write-Host ''
}

function Invoke-AapRemoveMcpServerAddon {
  param(
    [string]$Namespace = $Script:AapDemoDefaultNamespace
  )

  Write-Host 'Removing AAP MCP Server...'
  Invoke-AapOcQuiet @(
    'delete', 'ansiblemcpserver', 'aap-mcp-server', '-n', $Namespace, '--timeout=60s'
  ) | Out-Null
  Write-AapStep 'MCP Server removed'
}

function Invoke-AapAddonEnable {
  param(
    [Parameter(Mandatory)][string]$Addon,
    [string]$Namespace = $Script:AapDemoDefaultNamespace,
    [string[]]$ScriptArgs = @()
  )

  switch ($Addon) {
    'mcp-server' { Invoke-AapDeployMcpServerAddon -Namespace $Namespace }
    'portal' { Invoke-AapDeployPortalAddon -Namespace $Namespace }
    'setup-pah' { Invoke-AapDemoSetupPah -Namespace $Namespace }
    default { Invoke-AapAddonDeployScript -Addon $Addon -ScriptArgs $ScriptArgs }
  }
}

function Get-AapMcpServerRouteHost {
  param([string]$Namespace = $Script:AapDemoDefaultNamespace)

  $result = Invoke-AapOcCapture @(
    'get', 'ansiblemcpserver', 'aap-mcp-server', '-n', $Namespace,
    '-o', 'jsonpath={.spec.route_host}'
  )
  if ($result.ExitCode -ne 0) { return $null }
  $routeHost = $result.Output.Trim()
  if ($routeHost -and $routeHost -notmatch '\s' -and $routeHost -notmatch ':') {
    return $routeHost
  }
  return $null
}

function Get-AapAddonEnableCommand {
  param([Parameter(Mandatory)][string]$Addon)
  return "aap-demo enable $Addon"
}

function Get-AapAddonStatusLabel {
  param(
    [Parameter(Mandatory)][string]$Addon,
    [string]$Namespace = $Script:AapDemoDefaultNamespace,
    [Parameter(Mandatory)][bool]$Enabled
  )

  if (-not $Enabled) { return 'disabled' }

  switch ($Addon) {
    'mcp-server' {
      $mcpHost = Get-AapMcpServerRouteHost -Namespace $Namespace
      if ($mcpHost) { return "https://$mcpHost/mcp" }
      return 'not-deployed'
    }
    'portal' {
      $portalHost = Get-AapPortalRouteHost -AapNamespace $Namespace
      if ($portalHost) { return "https://$portalHost" }
      return 'not-deployed'
    }
    'ao' {
      $aoNs = 'automation-orchestrator'
      $routeResult = Invoke-AapOcCapture @(
        'get', 'routes', '-n', $aoNs,
        '-o', 'jsonpath={.items[0].spec.host}'
      )
      if ($routeResult.ExitCode -eq 0 -and $routeResult.Output.Trim()) {
        return "https://$($routeResult.Output.Trim())"
      }
      if ((Invoke-AapOcQuiet @('get', 'namespace', $aoNs)) -eq 0) { return 'deployed' }
      return 'not-deployed'
    }
    default { return $null }
  }
}

function Invoke-AapAddonDisable {
  param(
    [Parameter(Mandatory)][string]$Addon,
    [string]$Namespace = $Script:AapDemoDefaultNamespace,
    [string[]]$ScriptArgs = @()
  )

  switch ($Addon) {
    'mcp-server' { Invoke-AapRemoveMcpServerAddon -Namespace $Namespace }
    'portal' { Invoke-AapRemovePortalAddon -Namespace $Namespace }
    'setup-pah' {
      Write-AapWarn 'setup-pah has no cluster resources to remove (credentials remain in ~/.aap-demo/)'
    }
    default { Invoke-AapAddonDeployScript -Addon $Addon -ScriptArgs (@('--delete') + $ScriptArgs) }
  }
}
