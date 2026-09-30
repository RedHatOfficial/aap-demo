function Get-AapAoWireListItems {
  param([Parameter(Mandatory)]$Payload)
  if (-not $Payload) { return @() }
  if ($Payload.PSObject.Properties['resources']) { return @($Payload.resources) }
  if ($Payload.PSObject.Properties['results']) { return @($Payload.results) }
  return @()
}

function Get-AapAoRouteHost {
  param([string]$Namespace = 'automation-orchestrator')
  $result = Invoke-AapKubectlNative -Arguments @('get', 'route', '-n', $Namespace, '-o', 'jsonpath={.items[0].spec.host}') -AllowFailure
  if ($result.Success -and $result.Stdout.Trim()) { return $result.Stdout.Trim() }
  return $null
}

function Get-AapAoAdminPassword {
  param([string]$Namespace = 'automation-orchestrator')
  $secretResult = Invoke-AapKubectlNative -Arguments @('get', 'secret', 'automation-orchestrator-initial-admin-password', '-n', $Namespace, '-o', 'json') -AllowFailure
  $secret = if ($secretResult.Success -and $secretResult.Stdout) { $secretResult.Stdout | ConvertFrom-Json } else { $null }
  if (-not $secret) {
    $secrets = Get-AapKubectlJson -Arguments @('get', 'secret', '-n', $Namespace)
    $secret = @($secrets.items) | Where-Object { $_.metadata.name -match 'admin-password' } | Select-Object -First 1
  }
  if (-not $secret -or -not $secret.data.password) { return $null }
  return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$secret.data.password))
}

function Invoke-AapAoWireHttp {
  param(
    [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method,
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Token,
    [AllowNull()][object]$Body = $null,
    [Parameter(Mandatory)][string]$Route
  )

  $bodyText = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 30 -Compress } else { $null }
  $result = Invoke-AapPortalCurl -Method $Method -Url ("https://{0}/api/v1{1}" -f $Route, $Path) -Body $bodyText
  if ($result.ExitCode -ne 0 -or -not $result.HttpCode -or [int]$result.HttpCode -lt 200 -or [int]$result.HttpCode -ge 300) {
    $detail = if ($result.Output) { $result.Output } else { 'empty response' }
    throw "AO API $Method $Path failed (HTTP $($result.HttpCode)): $detail"
  }
  if (-not $result.Output) { return $null }
  try { return $result.Output | ConvertFrom-Json } catch { return $result.Output }
}

function Get-AapAoWireToken {
  param([Parameter(Mandatory)][string]$Route, [string]$Namespace = 'automation-orchestrator')
  $password = Get-AapAoAdminPassword -Namespace $Namespace
  if (-not $password) { throw "AO admin password is not available in $Namespace" }
  $body = @{ username = 'admin'; password = $password } | ConvertTo-Json -Compress
  $result = Invoke-AapPortalCurl -Method POST -Url "https://$Route/api/v1/auth/login" -Body $body
  if ($result.ExitCode -ne 0 -or [int]$result.HttpCode -lt 200 -or [int]$result.HttpCode -ge 300) {
    throw "AO login failed (HTTP $($result.HttpCode)): $($result.Output)"
  }
  $payload = $result.Output | ConvertFrom-Json
  if (-not $payload.access_token) { throw 'AO login response did not contain access_token' }
  return [string]$payload.access_token
}

function Get-AapAoDefaultProjectId {
  param([Parameter(Mandatory)][string]$Route, [Parameter(Mandatory)][string]$Token)
  $payload = Invoke-AapAoWireHttp -Method GET -Path '/projects?limit=100&is_default=true' -Route $Route -Token $Token
  $project = @(Get-AapAoWireListItems -Payload $payload) | Where-Object { $_.is_default -eq $true } | Select-Object -First 1
  if (-not $project) {
    $payload = Invoke-AapAoWireHttp -Method GET -Path '/projects?limit=100' -Route $Route -Token $Token
    $project = @(Get-AapAoWireListItems -Payload $payload) | Select-Object -First 1
  }
  if (-not $project) { throw 'AO has no project available for addon wiring' }
  return [string]$project.id
}

function Get-AapAoCredentialType {
  param([Parameter(Mandatory)][string]$Route, [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Name)
  $payload = Invoke-AapAoWireHttp -Method GET -Path '/credential_types?limit=100' -Route $Route -Token $Token
  return @(Get-AapAoWireListItems -Payload $payload) | Where-Object { $_.name -eq $Name } | Select-Object -First 1
}

function Get-AapAoCredential {
  param([Parameter(Mandatory)][string]$Route, [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$ProjectId)
  $encoded = [uri]::EscapeDataString($Name)
  $payload = Invoke-AapAoWireHttp -Method GET -Path "/credentials?name=$encoded&limit=100" -Route $Route -Token $Token
  return @(Get-AapAoWireListItems -Payload $payload) | Where-Object {
    $_.name -eq $Name -and ([string]$_.project_id -eq [string]$ProjectId)
  } | Select-Object -First 1
}

function Ensure-AapAoCredential {
  param(
    [Parameter(Mandatory)][string]$Route,
    [Parameter(Mandatory)][string]$Token,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$TypeName,
    [Parameter(Mandatory)][hashtable]$Inputs,
    [Parameter(Mandatory)][string]$ProjectId
  )
  $type = Get-AapAoCredentialType -Route $Route -Token $Token -Name $TypeName
  if (-not $type) { throw "AO credential type not found: $TypeName" }
  $current = Get-AapAoCredential -Route $Route -Token $Token -Name $Name -ProjectId $ProjectId
  $payload = @{
    name = $Name
    description = 'Auto-wired by aap-demo'
    credential_type_id = [string]$type.id
    inputs = $Inputs
  }
  if ($current) {
    $updated = Invoke-AapAoWireHttp -Method PATCH -Path "/projects/$ProjectId/credentials/$($current.id)" -Route $Route -Token $Token -Body @{
      name = $Name; description = 'Auto-wired by aap-demo'; inputs = $Inputs
    }
    return [string]$current.id
  }
  $created = Invoke-AapAoWireHttp -Method POST -Path "/projects/$ProjectId/credentials" -Route $Route -Token $Token -Body $payload
  if (-not $created.id) { throw "AO credential creation returned no id: $Name" }
  return [string]$created.id
}

function Get-AapAoIntegration {
  param([Parameter(Mandatory)][string]$Route, [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Name)
  $payload = Invoke-AapAoWireHttp -Method GET -Path '/integrations?limit=100' -Route $Route -Token $Token
  return @(Get-AapAoWireListItems -Payload $payload) | Where-Object { $_.name -eq $Name } | Select-Object -First 1
}

function Ensure-AapAoIntegration {
  param(
    [Parameter(Mandatory)][string]$Route,
    [Parameter(Mandatory)][string]$Token,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Type,
    [Parameter(Mandatory)][hashtable]$Configuration,
    [Parameter(Mandatory)][string]$CredentialId,
    [switch]$DiscoverTools
  )
  $current = Get-AapAoIntegration -Route $Route -Token $Token -Name $Name
  $payload = @{
    name = $Name
    description = 'Auto-wired by aap-demo'
    configuration = $Configuration
    management_credential_id = $CredentialId
    enabled = $true
    scope = 'global'
  }
  if ($current) {
    $id = [string]$current.id
    Invoke-AapAoWireHttp -Method PATCH -Path "/integrations/$id" -Route $Route -Token $Token -Body $payload | Out-Null
  } else {
    $payload.integration_type = $Type
    if ($DiscoverTools) {
      try {
        $discovery = Invoke-AapAoWireHttp -Method POST -Path '/integrations/discover' -Route $Route -Token $Token -Body @{
          integration_type = $Type; configuration = $Configuration; credential_id = $CredentialId
        }
        if ($discovery.discovered_tools) { $payload.discovered_tools = @($discovery.discovered_tools | ForEach-Object { @{ name = $_.name; description = $_.description; enabled = $true } }) }
      } catch { Write-AapWarn "MCP tool discovery skipped: $($_.Exception.Message)" }
    }
    $created = Invoke-AapAoWireHttp -Method POST -Path '/integrations' -Route $Route -Token $Token -Body $payload
    if (-not $created.id) { throw "AO integration creation returned no id: $Name" }
    $id = [string]$created.id
  }
  try {
    Invoke-AapAoWireHttp -Method POST -Path "/integrations/$id/validate" -Route $Route -Token $Token -Body @{
      integration_type = $Type; configuration = $Configuration; credential_id = $CredentialId
    } | Out-Null
  } catch { Write-AapWarn "AO integration validation skipped for $Name`: $($_.Exception.Message)" }
  return $id
}

function Invoke-AapAoRefreshAndSelectModel {
  param([Parameter(Mandatory)][string]$Route, [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$IntegrationId, [Parameter(Mandatory)][string]$Model)
  Invoke-AapAoWireHttp -Method POST -Path "/integrations/$IntegrationId/refresh" -Route $Route -Token $Token -Body @{} | Out-Null
  $payload = Invoke-AapAoWireHttp -Method GET -Path "/integrations/$IntegrationId/models?limit=100" -Route $Route -Token $Token
  $entry = @(Get-AapAoWireListItems -Payload $payload) | Where-Object { $_.model_id -eq $Model } | Select-Object -First 1
  if (-not $entry) { throw "AO model not found after refresh: $Model" }
  Invoke-AapAoWireHttp -Method PATCH -Path "/integrations/$IntegrationId/models/$($entry.id)" -Route $Route -Token $Token -Body @{ is_default = $true } | Out-Null
  return [string]$entry.id
}

function Get-AapGatewayToken {
  param([Parameter(Mandatory)][string]$Route)
  $secretResult = Invoke-AapKubectlNative -Arguments @('get', 'secret', 'aap-admin-password', '-n', $Script:AapDemoDefaultNamespace, '-o', 'json') -AllowFailure
  $secret = if ($secretResult.Success -and $secretResult.Stdout) { $secretResult.Stdout | ConvertFrom-Json } else { $null }
  $password = if ($secret -and $secret.data.password) {
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$secret.data.password))
  } else { $null }
  if (-not $password) { throw 'AAP admin password is not available' }
  $body = @{ description = 'aap-demo AO integration'; scope = 'write' } | ConvertTo-Json -Compress
  $result = Invoke-AapPortalCurl -Method POST -Url "https://$Route/api/gateway/v1/tokens/" -User "admin`:$password" -Body $body
  if ($result.ExitCode -ne 0 -or [int]$result.HttpCode -lt 200 -or [int]$result.HttpCode -ge 300) { throw "AAP gateway token request failed (HTTP $($result.HttpCode))" }
  $payload = $result.Output | ConvertFrom-Json
  if (-not $payload.token) { throw 'AAP gateway token response did not contain token' }
  return [string]$payload.token
}

function Get-AapAoRouteHostForWire { Get-AapAoRouteHost -Namespace 'automation-orchestrator' }

function Get-AapPythonExecutable {
  $python = Get-Command python.exe -ErrorAction SilentlyContinue
  if (-not $python) { $python = Get-Command py.exe -ErrorAction SilentlyContinue }
  return $python
}

function Invoke-AapAoDemoProvision {
  param(
    [Parameter(Mandatory)][string]$AapRoute,
    [Parameter(Mandatory)][string]$AapToken,
    [Parameter(Mandatory)][string]$AoRoute,
    [Parameter(Mandatory)][string]$AoToken,
    [Parameter(Mandatory)][string]$AapCredentialId,
    [Parameter(Mandatory)][string]$AapIntegrationId,
    [string]$AgentCredentialId,
    [string]$AgentIntegrationId,
    [string]$AgentModelId
  )
  $python = Get-AapPythonExecutable
  if (-not $python) { Write-AapWarn 'AAP demo provisioning skipped: Python is not installed' ; return }
  $scriptPath = Join-Path $Script:AapDemoRepoRoot 'addons/ao/scripts/provision-aap-demos.py'
  $args = @(
    $scriptPath, '--route', $AapRoute, '--token', $AapToken,
    '--ao-api-url', "https://$AoRoute/api/v1", '--ao-api-host', $AoRoute, '--ao-token', $AoToken,
    '--ao-credential-id', $AapCredentialId, '--ao-integration-id', $AapIntegrationId,
    '--control-repository', 'https://github.com/RedHatOfficial/aap-demo.git', '--control-branch', 'main'
  )
  if ($AgentCredentialId -and $AgentIntegrationId -and $AgentModelId) {
    $args += @('--ao-agent-credential-id', $AgentCredentialId, '--ao-agent-integration-id', $AgentIntegrationId, '--ao-agent-model-id', $AgentModelId)
  }
  $result = Invoke-AapNativeProcess -FilePath $python.Source -ArgumentList $args
  if (-not $result.Success) { Write-AapWarn "AAP demo provisioning failed: $($result.Stderr.Trim())" }
}

function Invoke-AapAoDemoSync {
  param(
    [Parameter(Mandatory)][string]$AoRoute,
    [Parameter(Mandatory)][string]$AoToken,
    [Parameter(Mandatory)][string]$AapCredentialId,
    [Parameter(Mandatory)][string]$AapIntegrationId,
    [string]$McpCredentialId,
    [string]$McpIntegrationId,
    [string]$AgentCredentialId,
    [string]$AgentIntegrationId,
    [string]$AgentModelId
  )
  $python = Get-AapPythonExecutable
  if (-not $python) { Write-AapWarn 'AO demo synchronization skipped: Python is not installed' ; return }

  $scriptPath = Join-Path $Script:AapDemoRepoRoot 'addons/ao/scripts/import-demos.py'
  $args = @($scriptPath, '--route', $AoRoute, '--token', $AoToken, '--aap-credential-id', $AapCredentialId, '--aap-integration-id', $AapIntegrationId)
  if ($McpCredentialId -and $McpIntegrationId) { $args += @('--mcp-credential-id', $McpCredentialId, '--mcp-integration-id', $McpIntegrationId) }
  if ($AgentCredentialId -and $AgentIntegrationId -and $AgentModelId) { $args += @('--agent-credential-id', $AgentCredentialId, '--agent-integration-id', $AgentIntegrationId, '--agent-model-id', $AgentModelId) }
  $result = Invoke-AapNativeProcess -FilePath $python.Source -ArgumentList $args
  if (-not $result.Success) { Write-AapWarn "AO demo synchronization failed: $($result.Stderr.Trim())" }
}

function Invoke-AapAoWire {
  [CmdletBinding()]
  param([switch]$Quiet)
  $aoRoute = Get-AapAoRouteHostForWire
  if (-not $aoRoute) { if (-not $Quiet) { Write-AapWarn 'AO route not ready; wiring skipped' }; return }
  $aapRouteResult = Invoke-AapKubectlNative -Arguments @('get', 'route', 'aap', '-n', $Script:AapDemoDefaultNamespace, '-o', 'jsonpath={.spec.host}') -AllowFailure
  if (-not $aapRouteResult.Success -or -not $aapRouteResult.Stdout.Trim()) { Write-AapWarn 'AAP route not ready; wiring skipped'; return }
  $aapRoute = $aapRouteResult.Stdout.Trim()

  $aoToken = Get-AapAoWireToken -Route $aoRoute
  $projectId = Get-AapAoDefaultProjectId -Route $aoRoute -Token $aoToken
  $aapToken = Get-AapGatewayToken -Route $aapRoute
  $aapCredentialId = Ensure-AapAoCredential -Route $aoRoute -Token $aoToken -Name 'aap-demo AAP Token' -TypeName 'Ansible Automation Platform' -Inputs @{ oauth_token = $aapToken } -ProjectId $projectId
  $aapIntegrationId = Ensure-AapAoIntegration -Route $aoRoute -Token $aoToken -Name 'aap-demo AAP' -Type 'ansible_automation_platform' -Configuration @{ integration_type = 'ansible_automation_platform'; base_url = "https://$aapRoute"; allow_http = $true; insecure_skip_tls_verify = $true } -CredentialId $aapCredentialId

  $mcpDeployment = Invoke-AapKubectlNative -Arguments @('get', 'deployment', 'aap-mcp-server', '-n', $Script:AapDemoDefaultNamespace) -AllowFailure
  $mcpCredentialId = $null; $mcpIntegrationId = $null
  if ($mcpDeployment.Success) {
    $mcpRouteResult = Invoke-AapKubectlNative -Arguments @('get', 'route', '-n', $Script:AapDemoDefaultNamespace, '-o', 'jsonpath={.items[*].spec.host}') -AllowFailure
    $mcpHost = if ($mcpRouteResult.Success) { ($mcpRouteResult.Stdout -split '\s+' | Where-Object { $_ -match 'mcp' } | Select-Object -First 1) } else { $null }
    if ($mcpHost) {
      $mcpCredentialId = Ensure-AapAoCredential -Route $aoRoute -Token $aoToken -Name 'aap-demo MCP Token' -TypeName 'HTTP Bearer Token' -Inputs @{ token = $aapToken } -ProjectId $projectId
      $mcpIntegrationId = Ensure-AapAoIntegration -Route $aoRoute -Token $aoToken -Name 'aap-demo MCP Server' -Type 'mcp_server' -Configuration @{ integration_type = 'mcp_server'; base_url = "https://$mcpHost/mcp"; allow_http = $true; insecure_skip_tls_verify = $true } -CredentialId $mcpCredentialId -DiscoverTools
    }
  }

  $agentCredentialId = $null; $agentIntegrationId = $null; $agentModelId = $null
  $provider = $env:AO_LLM_PROVIDER
  if (-not $provider) { $provider = Get-AapConfigValue 'AO_LLM_PROVIDER' }
  if (-not $provider) { $provider = 'ollama' }
  $ollamaRouteResult = Invoke-AapKubectlNative -Arguments @('get', 'route', 'ollama', '-n', 'aap-demo-ollama', '-o', 'jsonpath={.spec.host}') -AllowFailure
  if ($provider -eq 'ollama' -and $ollamaRouteResult.Success -and $ollamaRouteResult.Stdout.Trim()) {
    $ollamaHost = $ollamaRouteResult.Stdout.Trim()
    $agentCredentialId = Ensure-AapAoCredential -Route $aoRoute -Token $aoToken -Name 'aap-demo Ollama' -TypeName 'LLM Provider' -Inputs @{ api_key = 'ollama' } -ProjectId $projectId
    $agentIntegrationId = Ensure-AapAoIntegration -Route $aoRoute -Token $aoToken -Name 'aap-demo Ollama' -Type 'llm_provider' -Configuration @{ integration_type = 'llm_provider'; provider_hint = 'custom'; base_url = "https://$ollamaHost/v1"; allow_http = $true; insecure_skip_tls_verify = $true } -CredentialId $agentCredentialId
    $model = if ($env:OLLAMA_MODEL) { $env:OLLAMA_MODEL } else { 'qwen2.5:3b' }
    $agentModelId = Invoke-AapAoRefreshAndSelectModel -Route $aoRoute -Token $aoToken -IntegrationId $agentIntegrationId -Model $model
  }

  Set-AapAoLocalAccess -Namespace 'automation-orchestrator'
  $importDemos = Get-AapAoSetting -Name 'AO_IMPORT_DEMOS' -Default '1'
  if ($importDemos -ne '0') {
    Invoke-AapAoDemoProvision -AapRoute $aapRoute -AapToken $aapToken -AoRoute $aoRoute -AoToken $aoToken -AapCredentialId $aapCredentialId -AapIntegrationId $aapIntegrationId -AgentCredentialId $agentCredentialId -AgentIntegrationId $agentIntegrationId -AgentModelId $agentModelId
    Invoke-AapAoDemoSync -AoRoute $aoRoute -AoToken $aoToken -AapCredentialId $aapCredentialId -AapIntegrationId $aapIntegrationId -McpCredentialId $mcpCredentialId -McpIntegrationId $mcpIntegrationId -AgentCredentialId $agentCredentialId -AgentIntegrationId $agentIntegrationId -AgentModelId $agentModelId
  }
  if (-not $Quiet) { Write-AapStep 'AO integrations and demo synchronization complete' }
}
