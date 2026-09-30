function Get-AapApmeSetting {
  param([Parameter(Mandatory)][string]$Name, [string]$Default = '')
  $value = [Environment]::GetEnvironmentVariable($Name)
  if (-not $value) { $value = Get-AapConfigValue $Name }
  if (-not $value) { $value = $Default }
  return $value
}

function Get-AapApmeConfigDir { Join-Path $env:USERPROFILE '.aap-demo' }
function Get-AapApmeVarsPath { Join-Path (Get-AapApmeConfigDir) 'apme-eap-vars.yml' }
function Get-AapApmeGithubCredsPath { Join-Path (Get-AapApmeConfigDir) 'apme-eap-github-creds.yml' }

function Get-AapApmeGithubSettings {
  $settings = @{}
  foreach ($name in @('GITHUB_TOKEN', 'GITHUB_APP_ID', 'GITHUB_APP_CLIENT_ID', 'GITHUB_APP_CLIENT_SECRET', 'GITHUB_APP_PRIVATE_KEY_PATH', 'GITHUB_OAUTH_CLIENT_ID', 'GITHUB_OAUTH_CLIENT_SECRET')) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ($value) { $settings[$name] = $value }
  }
  $path = Get-AapApmeGithubCredsPath
  if (Test-Path -LiteralPath $path) {
    foreach ($line in Get-Content -LiteralPath $path) {
      if ($line -match '^\s*([a-z_]+)\s*:\s*["'']?(.*?)["'']?\s*$') {
        $key = $Matches[1].ToUpperInvariant()
        $value = $Matches[2].Trim()
        if (-not $settings.ContainsKey($key) -and $value) { $settings[$key] = $value }
      }
    }
  }
  if ($settings.ContainsKey('GITHUB_APP_PRIVATE_KEY_PATH') -and $settings['GITHUB_APP_PRIVATE_KEY_PATH'] -and $settings['GITHUB_APP_PRIVATE_KEY_PATH'].StartsWith('~')) {
    $settings['GITHUB_APP_PRIVATE_KEY_PATH'] = Join-Path $env:USERPROFILE $settings['GITHUB_APP_PRIVATE_KEY_PATH'].Substring(2)
  }
  return $settings
}

function Get-AapApmeClusterValue {
  param([Parameter(Mandatory)][string[]]$Arguments)
  $result = Invoke-AapKubectlNative -Arguments $Arguments -AllowFailure
  if ($result.Success) { return $result.Stdout.Trim() }
  return ''
}

function Ensure-AapApmeRegistry {
  $existing = Invoke-AapKubectlNative -Arguments @('get', 'deployment', 'registry', '-n', 'aap-demo-registry') -AllowFailure
  if (-not $existing.Success) {
    Write-Host 'Deploying the local OCI registry required by APME...'
    $manifest = Read-AapManifest 'addons/registry/registry.yaml'
    $temp = [IO.Path]::GetTempFileName()
    try {
      Set-AapUtf8Content -Path $temp -Value $manifest
      Invoke-AapKubectlNative -Arguments @('apply', '-f', $temp) | Out-Null
    } finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
  }
  Invoke-AapKubectlNative -Arguments @('wait', '--for=condition=Available', 'deployment/registry', '-n', 'aap-demo-registry', '--timeout=180s') | Out-Null
  Write-AapStep 'Local OCI registry is available'
}

function Invoke-AapApmeApi {
  param(
    [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method,
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$Token,
    [string]$Body = $null,
    [int]$MaxTime = 120
  )
  $args = @('-k', '-s', '-S', '--max-time', [string]$MaxTime, '-X', $Method,
    '-H', "Authorization: Bearer $Token", '-H', 'Content-Type: application/json')
  $bodyFile = $null
  if ($Body) {
    $bodyFile = [IO.Path]::GetTempFileName()
    Set-AapUtf8Content -Path $bodyFile -Value $Body
    $args += @('--data-binary', "@$bodyFile")
  }
  $args += @($Url, '-w', "`nHTTP_CODE:%{http_code}")
  try {
    $result = Invoke-AapExternal curl.exe $args
    $output = $result.Output
    $httpCode = '000'
    if ($output -match '(?s)(.*)\r?\nHTTP_CODE:(\d+)\s*$') {
      $output = $Matches[1].TrimEnd()
      $httpCode = $Matches[2]
    }
    return [PSCustomObject]@{ ExitCode = $result.ExitCode; HttpCode = $httpCode; Output = $output }
  } finally {
    if ($bodyFile) { Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue }
  }
}

function Invoke-AapApmeApiJson {
  param(
    [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method,
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$Token,
    [hashtable]$Body = $null,
    [int[]]$AllowedCodes = @(200, 201, 202, 204)
  )
  $bodyText = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 30 -Compress } else { $null }
  $response = Invoke-AapApmeApi -Method $Method -Url $Url -Token $Token -Body $bodyText
  if ($response.ExitCode -ne 0 -or [int]$response.HttpCode -notin $AllowedCodes) {
    $detail = if ($response.Output) { $response.Output } else { 'no response body' }
    throw "AAP API $Method $Url failed (HTTP $($response.HttpCode)): $detail"
  }
  if (-not $response.Output) { return $null }
  try { return $response.Output | ConvertFrom-Json } catch { throw "AAP API returned invalid JSON for $Method ${Url}: $($response.Output)" }
}

function Get-AapApmeGatewayToken {
  $secret = Invoke-AapKubectlNative -Arguments @('get', 'secret', 'aap-api-token', '-n', $Script:AapDemoDefaultNamespace, '-o', 'json') -AllowFailure
  if ($secret.Success -and $secret.Stdout) {
    try {
      $data = $secret.Stdout | ConvertFrom-Json
      if ($data.data.token) {
        $token = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$data.data.token))
        if ($token) { return $token }
      }
    } catch { Write-AapWarn 'Existing APME AAP token secret could not be read; creating a new token.' }
  }

  $route = Get-AapApmeClusterValue -Arguments @('get', 'route', 'aap', '-n', $Script:AapDemoDefaultNamespace, '-o', 'jsonpath={.spec.host}')
  if (-not $route) { throw 'AAP route not found. Deploy AAP before enabling apme-eap.' }
  $password = Get-AapAdminPassword -Namespace $Script:AapDemoDefaultNamespace
  if (-not $password) { throw 'AAP admin password secret not found.' }
  $tokenResult = Invoke-AapPortalCurl -Method POST -Url "https://$route/api/gateway/v1/tokens/" `
    -User "admin:$password" -Body (@{ description = 'aap-demo APME addon API access'; scope = 'write' } | ConvertTo-Json -Compress)
  if ($tokenResult.ExitCode -ne 0 -or [int]$tokenResult.HttpCode -notin @(200, 201)) { throw "Failed to create AAP API token (HTTP $($tokenResult.HttpCode)): $($tokenResult.Output)" }
  $tokenJson = $tokenResult.Output | ConvertFrom-Json
  if (-not $tokenJson.token) { throw 'AAP token response did not contain a token.' }

  $secretBody = @{
    apiVersion = 'v1'; kind = 'Secret'
    metadata = @{ name = 'aap-api-token'; namespace = $Script:AapDemoDefaultNamespace }
    type = 'Opaque'; stringData = @{ token = [string]$tokenJson.token }
  } | ConvertTo-Json -Depth 10 -Compress
  $temp = [IO.Path]::GetTempFileName()
  try { Set-AapUtf8Content -Path $temp -Value $secretBody; Invoke-AapKubectlNative -Arguments @('apply', '-f', $temp) | Out-Null } finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
  return [string]$tokenJson.token
}

function Get-AapApmeOpenShiftToken {
  $token = Get-AapApmeClusterValue -Arguments @('create', 'token', 'aap-apme-deployer', '-n', $Script:AapDemoDefaultNamespace)
  if ($token) { return $token }
  $sa = @{ apiVersion = 'v1'; kind = 'ServiceAccount'; metadata = @{ name = 'aap-apme-deployer'; namespace = $Script:AapDemoDefaultNamespace } } | ConvertTo-Json -Depth 10 -Compress
  $binding = @{ apiVersion = 'rbac.authorization.k8s.io/v1'; kind = 'ClusterRoleBinding'; metadata = @{ name = 'aap-apme-deployer' }; roleRef = @{ apiGroup = 'rbac.authorization.k8s.io'; kind = 'ClusterRole'; name = 'cluster-admin' }; subjects = @(@{ kind = 'ServiceAccount'; name = 'aap-apme-deployer'; namespace = $Script:AapDemoDefaultNamespace }) } | ConvertTo-Json -Depth 10 -Compress
  foreach ($body in @($sa, $binding)) {
    $temp = [IO.Path]::GetTempFileName()
    try { Set-AapUtf8Content -Path $temp -Value $body; Invoke-AapKubectlNative -Arguments @('apply', '-f', $temp) | Out-Null } finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
  }
  $token = Get-AapApmeClusterValue -Arguments @('create', 'token', 'aap-apme-deployer', '-n', $Script:AapDemoDefaultNamespace)
  if (-not $token) { throw 'Could not create a service-account token for the AAP APME job.' }
  return $token
}

function Get-AapApmeProjectSource {
  $url = Get-AapApmeSetting -Name 'APME_AAP_PROJECT_URL'
  if (-not $url) { $url = 'https://github.com/RedHatOfficial/aap-demo.git' }
  $branch = Get-AapApmeSetting -Name 'APME_AAP_PROJECT_BRANCH' -Default 'main'
  return @{ url = $url; branch = $branch }
}

function Ensure-AapApmeResources {
  param([Parameter(Mandatory)][string]$Route, [Parameter(Mandatory)][string]$Token)
  $base = "https://$Route/api/controller/v2"
  $orgs = Invoke-AapApmeApiJson -Method GET -Url "$base/organizations/?name=Default" -Token $Token
  if (-not $orgs.results -or @($orgs.results).Count -eq 0) { throw 'AAP Default organization was not found.' }
  $orgId = [int]$orgs.results[0].id

  $source = Get-AapApmeProjectSource
  $projects = Invoke-AapApmeApiJson -Method GET -Url "$base/projects/?name=aap-demo-apme" -Token $Token
  if ($projects.results -and @($projects.results).Count -gt 0) {
    $projectId = [int]$projects.results[0].id
    Invoke-AapApmeApiJson -Method PATCH -Url "$base/projects/$projectId/" -Token $Token -Body @{ name = 'aap-demo-apme'; organization = $orgId; scm_type = 'git'; scm_url = $source.url; scm_branch = $source.branch; scm_update_on_launch = $true; scm_clean = $true } | Out-Null
  } else {
    $project = Invoke-AapApmeApiJson -Method POST -Url "$base/projects/" -Token $Token -Body @{ name = 'aap-demo-apme'; description = 'APME deployment playbooks from aap-demo'; organization = $orgId; scm_type = 'git'; scm_url = $source.url; scm_branch = $source.branch; scm_update_on_launch = $true; scm_clean = $true }
    $projectId = [int]$project.id
  }
  $sync = Invoke-AapApmeApi -Method POST -Url "$base/projects/$projectId/update/" -Token $Token
  if ([int]$sync.HttpCode -notin @(200, 201, 202)) { throw "AAP project sync failed (HTTP $($sync.HttpCode)): $($sync.Output)" }
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Seconds 2
    $status = Invoke-AapApmeApiJson -Method GET -Url "$base/projects/$projectId/" -Token $Token
    if ($status.status -in @('successful', 'failed', 'error')) {
      if ($status.status -ne 'successful') { throw "AAP project sync failed with status $($status.status)." }
      break
    }
  }

  $inventories = Invoke-AapApmeApiJson -Method GET -Url "$base/inventories/?name=localhost" -Token $Token
  if ($inventories.results -and @($inventories.results).Count -gt 0) { $inventoryId = [int]$inventories.results[0].id }
  else { $inventoryId = [int](Invoke-AapApmeApiJson -Method POST -Url "$base/inventories/" -Token $Token -Body @{ name = 'localhost'; description = 'Localhost inventory for APME deployment'; organization = $orgId }).id }
  $hosts = Invoke-AapApmeApiJson -Method GET -Url "$base/hosts/?name=localhost&inventory=$inventoryId" -Token $Token
  if (-not $hosts.results -or @($hosts.results).Count -eq 0) {
    try {
      Invoke-AapApmeApiJson -Method POST -Url "$base/hosts/" -Token $Token -Body @{ name = 'localhost'; inventory = $inventoryId; variables = "ansible_connection: local`n" } | Out-Null
    } catch {
      if ($_.Exception.Message -match 'License is missing') {
        Write-AapWarn 'AAP is unlicensed, so the inventory host could not be created; the localhost play will use Ansible implicit localhost.'
      } else { throw }
    }
  }

  $templates = Invoke-AapApmeApiJson -Method GET -Url "$base/job_templates/?name=Deploy%20APME" -Token $Token
  $templateBody = @{ name = 'Deploy APME'; description = 'Deploy APME portal in AAP'; job_type = 'run'; inventory = $inventoryId; project = $projectId; playbook = 'addons/apme-eap/playbooks/deploy_apme_portal.yml'; ask_variables_on_launch = $true; verbosity = 1 }
  if ($templates.results -and @($templates.results).Count -gt 0) { $templateId = [int]$templates.results[0].id; Invoke-AapApmeApiJson -Method PATCH -Url "$base/job_templates/$templateId/" -Token $Token -Body $templateBody | Out-Null }
  else { $templateId = [int](Invoke-AapApmeApiJson -Method POST -Url "$base/job_templates/" -Token $Token -Body $templateBody).id }
  return [pscustomobject]@{ Base = $base; TemplateId = $templateId }
}

function New-AapApmeExtraVars {
  param(
    [Parameter(Mandatory)][string]$Route,
    [Parameter(Mandatory)][string]$AapToken,
    [Parameter(Mandatory)][string]$OpenShiftToken
  )
  $domain = Get-AapClusterAppsDomain -Namespace $Script:AapDemoDefaultNamespace
  $github = Get-AapApmeGithubSettings
  $vars = @{
    openshift_api_url = 'https://kubernetes.default.svc:443'; openshift_project_name = 'apme'; openshift_cluster_domain = $domain; openshift_validate_certs = $false; openshift_token = $OpenShiftToken
    aap_host = "https://$Route"; aap_token = $AapToken; aap_organization = 'Default'
    portal_helm_chart_repo = 'openshift-helm-charts'; portal_helm_chart_repo_url = 'https://charts.openshift.io/'; portal_helm_chart_name = 'redhat-rhaap-portal'; portal_helm_chart_version = '2.2.3'; portal_helm_release_name = 'redhat-rhaap-portal'; portal_helm_install_timeout = 1800
    apme_helm_chart_repo = 'apme'; apme_helm_chart_repo_url = 'https://ansible.github.io/apme'; apme_helm_chart_name = 'apme'; apme_helm_chart_version = ''; apme_helm_chart_fallback_version = '0.1.8'; apme_helm_release_name = 'apme'
    # The AAP execution pod reaches the registry by service DNS; using the
    # route hostname would resolve nip.io to localhost inside the cluster.
    oci_registry = 'registry.aap-demo-registry.svc.cluster.local:5000/apme'; oci_registry_internal = 'registry.aap-demo-registry.svc.cluster.local:5000/apme'
    aap_apme_prerequisites_oauth_application_name = 'APME Portal OAuth'; skip_plugin_push = ((Get-AapApmeSetting -Name 'APME_SKIP_PLUGIN_PUSH' -Default 'false') -in @('1', 'true')); apme_oci_push_force = $false; apme_pah_run_setup_pah = $true; apme_pah_seed_apme_galaxy_servers = $true; apme_pah_collections_enabled = 'auto'; apme_pah_aap_namespace = 'aap-operator'
  }
  if ($github.ContainsKey('GITHUB_TOKEN') -and $github['GITHUB_TOKEN']) { $vars.configure_github_secrets = $true; $vars.github_token = $github['GITHUB_TOKEN']; foreach ($key in @('GITHUB_OAUTH_CLIENT_ID', 'GITHUB_OAUTH_CLIENT_SECRET', 'GITHUB_APP_ID', 'GITHUB_APP_CLIENT_ID', 'GITHUB_APP_CLIENT_SECRET')) { if ($github.ContainsKey($key) -and $github[$key]) { $vars[$key.ToLowerInvariant()] = $github[$key] } } }
  else { $vars.configure_github_secrets = $false }
  return $vars
}

function Invoke-AapApmeAddonNative {
  param([string[]]$ScriptArgs = @(), [string]$Namespace = 'apme')
  $action = if ($ScriptArgs.Count -gt 0) { $ScriptArgs[0].ToLowerInvariant() } else { 'deploy' }
  $varsPath = Get-AapApmeVarsPath
  if ($action -in @('--delete', 'delete', 'remove')) {
    Write-Host 'Removing APME...'
    Invoke-AapKubectlNative -Arguments @('delete', 'namespace', $Namespace, '--ignore-not-found', '--wait=false') -AllowFailure | Out-Null
    Remove-Item -LiteralPath $varsPath -Force -ErrorAction SilentlyContinue
    if (($ScriptArgs -contains '--purge-creds') -or (Get-AapApmeSetting -Name 'APME_PURGE_CREDS' -Default 'false') -in @('1', 'true')) { Remove-Item -LiteralPath (Get-AapApmeGithubCredsPath) -Force -ErrorAction SilentlyContinue }
    Write-AapStep 'APME removed'
    return
  }
  Write-Host 'Preparing AAP resources for APME...'
  $route = Get-AapApmeClusterValue -Arguments @('get', 'route', 'aap', '-n', $Script:AapDemoDefaultNamespace, '-o', 'jsonpath={.spec.host}')
  if (-not $route) { throw 'AAP route not found. Deploy AAP before enabling apme-eap.' }
  Ensure-AapApmeRegistry
  $aapToken = Get-AapApmeGatewayToken
  $resources = Ensure-AapApmeResources -Route $route -Token $aapToken
  $extraVars = New-AapApmeExtraVars -Route $route -AapToken $aapToken -OpenShiftToken (Get-AapApmeOpenShiftToken)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $varsPath) | Out-Null
  Set-AapUtf8Content -Path $varsPath -Value (($extraVars | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
  Write-Host 'Launching APME deployment in AAP...'
  try {
    $launch = Invoke-AapApmeApiJson -Method POST -Url "$($resources.Base)/job_templates/$($resources.TemplateId)/launch/" -Token $aapToken -Body @{ extra_vars = ($extraVars | ConvertTo-Json -Depth 30 -Compress) } -AllowedCodes @(201, 202)
  } catch {
    if ($_.Exception.Message -match 'License is missing') { throw 'AAP APME launch requires an active AAP controller license. Install or apply the AAP license, then retry apme-eap.' }
    throw
  }
  if (-not $launch.id) { throw 'AAP did not return an APME job ID.' }
  $jobId = [int]$launch.id
  Write-Host "  AAP job: https://$route/#/jobs/playbook/$jobId/output"
  for ($i = 0; $i -lt 360; $i++) {
    Start-Sleep -Seconds 5
    $job = Invoke-AapApmeApiJson -Method GET -Url "$($resources.Base)/jobs/$jobId/" -Token $aapToken
    if ($job.status -in @('successful', 'failed', 'error', 'canceled')) {
      if ($job.status -ne 'successful') { throw "APME AAP job $jobId finished with status '$($job.status)'. See https://$route/#/jobs/playbook/$jobId/output" }
      break
    }
  }
  $portalRoute = Get-AapApmeClusterValue -Arguments @('get', 'route', 'redhat-rhaap-portal', '-n', $Namespace, '-o', 'jsonpath={.spec.host}')
  Write-AapStep 'APME deployed by AAP'
  if ($portalRoute) { Write-Host "  URL: https://$portalRoute" }
  Write-Host '  Username: admin'
  Write-Host "  AAP job: https://$route/#/jobs/playbook/$jobId/output"
}
