$Script:AapAvailableAddons = @('mcp-server', 'portal')

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
    [string]$Namespace = $Script:AapDemoDefaultNamespace
  )

  switch ($Addon) {
    'mcp-server' { Invoke-AapDeployMcpServerAddon -Namespace $Namespace }
    'portal' { Invoke-AapDeployPortalAddon -Namespace $Namespace }
    default { throw "Unknown addon: $Addon`nAvailable: $($Script:AapAvailableAddons -join ', ')" }
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
    default { return $null }
  }
}

function Invoke-AapAddonDisable {
  param(
    [Parameter(Mandatory)][string]$Addon,
    [string]$Namespace = $Script:AapDemoDefaultNamespace
  )

  switch ($Addon) {
    'mcp-server' { Invoke-AapRemoveMcpServerAddon -Namespace $Namespace }
    'portal' { Invoke-AapRemovePortalAddon -Namespace $Namespace }
    default { throw "Unknown addon: $Addon" }
  }
}
