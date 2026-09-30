$Script:AapAvailableAddons = @(
  'mcp-server', 'portal', 'portal-operator', 'setup-pah', 'ao',
  'local-cache', 'product-demos', 'opa', 'ollama'
)

function Invoke-AapAddonDeployScript {
  param(
    [Parameter(Mandatory)][string]$Addon,
    [string[]]$ScriptArgs = @(),
    [string]$Namespace = $Script:AapDemoDefaultNamespace,
    [hashtable]$Environment = @{}
  )

  $isDelete = @($ScriptArgs) -contains '--delete'
  $forwardedArgs = @($ScriptArgs | Where-Object { $_ -ne '--delete' })
  $arguments = if ($isDelete) {
    @('disable', $Addon) + $forwardedArgs
  } else {
    @('enable', $Addon) + $forwardedArgs
  }

  $bashEnvironment = @{}
  foreach ($key in $Environment.Keys) { $bashEnvironment[$key] = $Environment[$key] }
  if (-not $bashEnvironment.ContainsKey('NAMESPACE') -and $Namespace) {
    $bashEnvironment.NAMESPACE = $Namespace
  }

  $result = Invoke-AapGitBash -Command './aap-demo.sh "$@"' -Arguments $arguments -Environment $bashEnvironment -Interactive
  if ($result.Stdout) { Write-Host $result.Stdout.TrimEnd() }
  if (-not $result.Success) {
    $detail = if ($result.Stderr) { $result.Stderr.Trim() } else { $result.Stdout.Trim() }
    throw "Git Bash addon '$Addon' failed (exit $($result.ExitCode)): $detail"
  }
  $Script:AapAddonDelegatedToBash = $true
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

  $Script:AapAddonDelegatedToBash = $false
  Invoke-AapAddonDeployScript -Addon $Addon -Namespace $Namespace -ScriptArgs $ScriptArgs
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
    'portal-operator' {
      $portalOperatorHost = Get-AapAddonRouteHost -Namespace 'automation-portal'
      if ($portalOperatorHost) { return "https://$portalOperatorHost" }
      return 'not-deployed'
    }
    'ao' {
      $aoHost = Get-AapAddonRouteHost -Namespace 'automation-orchestrator'
      if ($aoHost) { return "https://$aoHost" }
      return 'enabled'
    }
    'ollama' {
      $ollamaHost = Get-AapAddonRouteHost -Namespace 'aap-demo-ollama'
      if ($ollamaHost) { return "https://$ollamaHost" }
      return 'enabled'
    }
    default { return 'enabled' }
  }
}

function Get-AapAddonRouteHost {
  param([Parameter(Mandatory)][string]$Namespace)

  $result = Invoke-AapOcCapture @('get', 'route', '-n', $Namespace, '--no-headers')
  if ($result.ExitCode -ne 0) { return $null }
  foreach ($line in @($result.Lines)) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^No resources found') { continue }
    $cols = $line -split '\s+'
    if ($cols.Count -ge 2 -and $cols[1] -and $cols[1] -notmatch '^HOST') {
      return $cols[1]
    }
  }
  return $null
}

function Invoke-AapAddonDisable {
  param(
    [Parameter(Mandatory)][string]$Addon,
    [string]$Namespace = $Script:AapDemoDefaultNamespace,
    [string[]]$ScriptArgs = @()
  )

  $Script:AapAddonDelegatedToBash = $false
  Invoke-AapAddonDeployScript -Addon $Addon -Namespace $Namespace -ScriptArgs (@('--delete') + @($ScriptArgs))
}
