# Native PowerShell implementation of the portal Helm addon.

$Script:AapPortalState = @{
  AapNamespace         = $null
  PortalNamespace      = 'redhat-rhaap-portal'
  PortalDir            = (Join-Path $env:USERPROFILE '.aap-demo\portal')
  ReleaseName          = 'redhat-rhaap-portal'
  ChartRepo            = 'openshift-helm-charts/redhat-rhaap-portal'
  DefaultPluginVersion = '2.2'
  OAuthAppName         = 'ansible-automation-portal'
  IsArmCluster         = $false
  IsMicroshift         = $false
  HelmWasUpgrade         = $false
  AapRoute             = $null
  AdminPass            = $null
  OrgId                = $null
  OrgName              = $null
  OAuthAppId           = $null
  ClientId             = $null
  ClientSecret         = $null
  ApiToken             = $null
  ClusterBaseUrl       = $null
  AapHostUrl           = $null
  PortalRoute          = $null
}

function Get-AapPortalHelmExe {
  if (Get-Command helm.exe -ErrorAction SilentlyContinue) { return 'helm.exe' }
  if (Get-Command helm -ErrorAction SilentlyContinue) { return 'helm' }
  throw 'helm not found'
}

function Get-AapPortalJqExe {
  if (Get-Command jq.exe -ErrorAction SilentlyContinue) { return 'jq.exe' }
  if (Get-Command jq -ErrorAction SilentlyContinue) { return 'jq' }
  throw 'jq not found'
}

function Invoke-AapPortalHelm {
  param([Parameter(Mandatory)][string[]]$ArgumentList)
  return Invoke-AapExternal (Get-AapPortalHelmExe) $ArgumentList
}

function Invoke-AapPortalJq {
  param(
    [Parameter(Mandatory)][string]$Filter,
    [string]$InputJson = $null,
    [hashtable]$Args = @{}
  )
  $jq = Get-AapPortalJqExe
  $jqArgs = if ($null -ne $InputJson) { @('-r', $Filter) } else { @($Filter) }
  foreach ($key in $Args.Keys) {
    $jqArgs += @('--arg', $key, [string]$Args[$key])
  }
  if ($null -ne $InputJson) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $output = $InputJson | & $jq @jqArgs 2>&1
      $code = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $prev
    }
    return [PSCustomObject]@{
      ExitCode = $code
      Output   = ($output | Out-String).TrimEnd()
    }
  }
  return Invoke-AapExternal $jq $jqArgs
}

function Invoke-AapPortalCurl {
  param(
    [string]$Method = 'GET',
    [Parameter(Mandatory)][string]$Url,
    [string]$User = $null,
    [string]$Body = $null,
    [int]$MaxTime = 0
  )
  $bodyFile = $null
  $args = @('-k', '-s', '-S')
  if ($User) { $args += @('-u', $User) }
  if ($Method -ne 'GET') { $args += @('-X', $Method) }
  if ($MaxTime -gt 0) { $args += @('--max-time', [string]$MaxTime) }
  if ($Body) {
    $bodyFile = [System.IO.Path]::GetTempFileName()
    Set-AapUtf8Content -Path $bodyFile -Value $Body
    $args += @('--data-binary', "@$bodyFile")
  }
  $args += @('-H', 'Content-Type: application/json', $Url, '-w', "`nHTTP_CODE:%{http_code}")
  try {
    $result = Invoke-AapExternal curl.exe $args
    $output = $result.Output
    $httpCode = $null
    if ($output -match '(?s)(.*)\r?\nHTTP_CODE:(\d+)\s*$') {
      $output = $Matches[1].TrimEnd()
      $httpCode = $Matches[2]
    }
    return [PSCustomObject]@{
      ExitCode = $result.ExitCode
      Output   = $output
      HttpCode = $httpCode
      Lines    = $result.Lines
    }
  } finally {
    if ($bodyFile) {
      Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue
    }
  }
}

function Test-AapPortalCurlSuccess {
  param(
    [Parameter(Mandatory)]$Result,
    [string[]]$AllowedHttpCodes = @()
  )
  if ($Result.ExitCode -ne 0) { return $false }
  if (-not $Result.HttpCode) { return $true }
  if ($AllowedHttpCodes.Count -gt 0) {
    return $Result.HttpCode -in $AllowedHttpCodes
  }
  return $Result.HttpCode -match '^2'
}

function Get-AapPortalOAuthAppByName {
  param(
    [Parameter(Mandatory)][string]$Route,
    [Parameter(Mandatory)][string]$User,
    [Parameter(Mandatory)][string]$AppName
  )
  $encodedName = [uri]::EscapeDataString($AppName)
  $result = Invoke-AapPortalCurl -Url "https://$Route/api/gateway/v1/applications/?name=$encodedName" -User $User
  if (-not (Test-AapPortalCurlSuccess -Result $result)) { return $null }
  $count = [int](Invoke-AapPortalJq -Filter '.count // 0' -InputJson $result.Output).Output
  if ($count -le 0) { return $null }
  return @{
    Id       = (Invoke-AapPortalJq -Filter '.results[0].id' -InputJson $result.Output).Output.Trim()
    ClientId = (Invoke-AapPortalJq -Filter '.results[0].client_id' -InputJson $result.Output).Output.Trim()
  }
}

function Remove-AapPortalOAuthAppFromAap {
  param(
    [Parameter(Mandatory)][string]$Route,
    [Parameter(Mandatory)][string]$User,
    [Parameter(Mandatory)][string]$AppId
  )
  $deleteResult = Invoke-AapPortalCurl -Method DELETE `
    -Url "https://$Route/api/gateway/v1/applications/$AppId/" -User $User
  if (-not (Test-AapPortalCurlSuccess -Result $deleteResult -AllowedHttpCodes @('200', '202', '204'))) {
    throw "Failed to delete OAuth application (ID: $AppId, HTTP $($deleteResult.HttpCode)): $($deleteResult.Output)"
  }
  $remaining = Get-AapPortalOAuthAppByName -Route $Route -User $User -AppName $Script:AapPortalState.OAuthAppName
  if ($remaining -and [string]$remaining.Id -eq [string]$AppId) {
    throw "OAuth application (ID: $AppId) still exists after delete"
  }
}

function New-AapPortalOAuthAppBody {
  param(
    [Parameter(Mandatory)][string]$AppName,
    [Parameter(Mandatory)][string]$OrgId
  )
  $org = [int]$OrgId
  $nameJson = ConvertTo-Json -InputObject $AppName -Compress
  return (
    '{"name":' + $nameJson +
    ',"organization":' + $org +
    ',"authorization_grant_type":"authorization-code"' +
    ',"client_type":"confidential"' +
    ',"redirect_uris":"https://example.com"}'
  )
}

function Invoke-AapPortalOAuthAppCreate {
  param(
    [Parameter(Mandatory)][string]$Route,
    [Parameter(Mandatory)][string]$User,
    [Parameter(Mandatory)][string]$AppName,
    [Parameter(Mandatory)][string]$OrgId
  )
  $body = New-AapPortalOAuthAppBody -AppName $AppName -OrgId $OrgId
  $oauthResult = Invoke-AapPortalCurl -Method POST -Url "https://$Route/api/gateway/v1/applications/" `
    -User $User -Body $body
  if (Test-AapPortalCurlSuccess -Result $oauthResult) {
    return $oauthResult
  }
  if ($oauthResult.Output -match 'unique set') {
    $existing = Get-AapPortalOAuthAppByName -Route $Route -User $User -AppName $AppName
    if ($existing) {
      Write-Host 'OAuth app already exists - removing and retrying...'
      Remove-AapPortalOAuthAppFromAap -Route $Route -User $User -AppId $existing.Id
      $oauthResult = Invoke-AapPortalCurl -Method POST -Url "https://$Route/api/gateway/v1/applications/" `
        -User $User -Body $body
    }
  }
  if (-not (Test-AapPortalCurlSuccess -Result $oauthResult)) {
    $detail = if ($oauthResult.Output) { $oauthResult.Output } else { '(no response body)' }
    throw "Failed to create OAuth application (HTTP $($oauthResult.HttpCode)): $detail"
  }
  return $oauthResult
}

function Initialize-AapPortalDir {
  $dir = $Script:AapPortalState.PortalDir
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

function Get-AapPortalRouteHost {
  param([string]$AapNamespace = $Script:AapDemoDefaultNamespace)

  $portalNs = $Script:AapPortalState.PortalNamespace
  foreach ($ns in @($portalNs, $AapNamespace)) {
    $result = Invoke-AapOcCapture @(
      'get', 'route', 'redhat-rhaap-portal', '-n', $ns, '-o', 'jsonpath={.spec.host}'
    )
    if ($result.ExitCode -ne 0) { continue }
    $routeHost = $result.Output.Trim()
    if ($routeHost -and $routeHost -notmatch '\s' -and $routeHost -notmatch ':') {
      return $routeHost
    }
  }
  return $null
}

function Test-AapPortalHelmRelease {
  param([Parameter(Mandatory)][string]$Namespace)
  $result = Invoke-AapPortalHelm @('list', '-n', $Namespace)
  if ($result.ExitCode -ne 0) { return $false }
  $name = [regex]::Escape($Script:AapPortalState.ReleaseName)
  return $result.Output -match "(?m)^$name\s"
}

function Clear-AapPortalNamespace {
  param([Parameter(Mandatory)][string]$Namespace)

  $release = $Script:AapPortalState.ReleaseName
  if (Test-AapPortalHelmRelease -Namespace $Namespace) {
    Write-Host "Uninstalling Helm release: $release (namespace: $Namespace)"
    Invoke-AapPortalHelm @('uninstall', $release, '-n', $Namespace) | Out-Null
  }

  Invoke-AapOcQuiet @('delete', 'secret', "$release-dynamic-plugins-registry-auth", '-n', $Namespace) | Out-Null
  Invoke-AapOcQuiet @('delete', 'secret', 'secrets-rhaap-portal', '-n', $Namespace) | Out-Null
}

function Test-AapPortalPrerequisites {
  param([Parameter(Mandatory)][string]$Namespace)

  Write-Host 'Checking prerequisites...'

  if ((Invoke-AapOcQuiet @('cluster-info')) -ne 0) {
    throw @"
Cannot connect to Kubernetes cluster.
Ensure oc is configured and cluster is accessible.
"@
  }

  Resolve-AapPortalProfile
  Test-AapPortalLocalArchitecture

  if ((Invoke-AapOcQuiet @('get', 'route', 'aap', '-n', $Namespace)) -ne 0) {
    throw @"
AAP not deployed in namespace: $Namespace
Run 'aap-demo deploy' first.
"@
  }

  Ensure-AapHelm
  $verResult = Invoke-AapPortalHelm @('version', '--short')
  if ($verResult.ExitCode -ne 0) {
    throw 'Could not determine Helm version'
  }
  if ($verResult.Output -match 'v(\d+)\.(\d+)') {
    $major = [int]$Matches[1]
    $minor = [int]$Matches[2]
    if ($major -lt 3 -or ($major -eq 3 -and $minor -lt 10)) {
      throw "Helm version 3.10+ required (found: $($Matches[0]))"
    }
  }

  Ensure-AapJq
  Write-AapStep 'Prerequisites met'
}

function Resolve-AapPortalProfile {
  $portalArch = $env:PORTAL_ARCH
  $clusterArch = $null

  if ($portalArch) {
    switch -Regex ($portalArch) {
      '^(arm|arm64|aarch64)$' { $clusterArch = 'arm64' }
      '^(x86|amd64|x86_64)$' { $clusterArch = 'amd64' }
      default { throw "Unknown PORTAL_ARCH: $portalArch (use arm or x86)" }
    }
  } else {
    $archResult = Invoke-AapOcCapture @(
      'get', 'nodes', '-o', 'jsonpath={.items[0].status.nodeInfo.architecture}'
    )
    if ($archResult.ExitCode -eq 0 -and $archResult.Output.Trim()) {
      $clusterArch = $archResult.Output.Trim()
    }
  }

  if (-not $clusterArch) {
    Write-AapWarn 'Could not detect cluster architecture; defaulting to x86 profile'
    $Script:AapPortalState.IsArmCluster = $false
    return
  }

  Write-AapStep "Cluster architecture: $clusterArch"
  if ($clusterArch -in @('arm64', 'aarch64')) {
    $Script:AapPortalState.IsArmCluster = $true
    Write-AapStep 'Using ARM profile (upstream community RHDH images)'
  } else {
    $Script:AapPortalState.IsArmCluster = $false
    Write-AapStep 'Using x86 profile (Red Hat RHDH images)'
  }
}

function Test-AapPortalLocalArchitecture {
  $localArch = $env:PROCESSOR_ARCHITECTURE
  $isLocalArm = $localArch -match 'ARM|AARCH64'

  if ($Script:AapPortalState.IsArmCluster) {
    if ($isLocalArm) {
      Write-AapStep 'Local machine is ARM — matches cluster'
    } else {
      Write-Host '  Local machine is x86 — deploying to ARM cluster via KUBECONFIG'
    }
    return
  }

  if ($isLocalArm) {
    Write-Host '  Local machine is ARM (Apple Silicon) — cluster is x86_64'
    Write-Host '  Deploy to an ARM cluster (e.g. CRC on Apple Silicon) with: aap-demo enable portal'
    Write-Host ''
  }
}

function Clear-AapPortalLegacyInstall {
  param([Parameter(Mandatory)][string]$Namespace)

  $portalNs = $Script:AapPortalState.PortalNamespace
  if ($Namespace -eq $portalNs) { return }

  if (Test-AapPortalHelmRelease -Namespace $Namespace) {
    Write-Host "Migrating portal from $Namespace to $portalNs..."
    Clear-AapPortalNamespace -Namespace $Namespace
  }
}

function Copy-AapPortalPullSecret {
  param(
    [Parameter(Mandatory)][string]$AapNamespace,
    [Parameter(Mandatory)][string]$PortalNamespace
  )

  if ((Invoke-AapOcQuiet @('get', 'secret', 'redhat-operators-pull-secret', '-n', $AapNamespace)) -ne 0) {
    return
  }

  Initialize-AapPortalDir
  $pullSecretPath = Join-Path $Script:AapPortalState.PortalDir 'pull-secret.json'
  $b64Result = Invoke-AapOcCapture @(
    'get', 'secret', 'redhat-operators-pull-secret', '-n', $AapNamespace,
    '-o', 'jsonpath={.data.\.dockerconfigjson}'
  )
  if ($b64Result.ExitCode -ne 0 -or -not $b64Result.Output.Trim()) { return }

  $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64Result.Output.Trim()))
  Set-AapUtf8Content -Path $pullSecretPath -Value $decoded

  Invoke-AapOcQuiet @('delete', 'secret', 'redhat-operators-pull-secret', '-n', $PortalNamespace) | Out-Null
  Invoke-AapOc @(
    'create', 'secret', 'generic', 'redhat-operators-pull-secret',
    "--from-file=.dockerconfigjson=$pullSecretPath",
    '--type=kubernetes.io/dockerconfigjson',
    '-n', $PortalNamespace
  ) | Out-Null

  $saResult = Invoke-AapOcCapture @(
    'get', 'serviceaccount', 'default', '-n', $PortalNamespace,
    '-o', 'jsonpath={.imagePullSecrets[*].name}'
  )
  $existing = if ($saResult.ExitCode -eq 0) { $saResult.Output.Trim() -split '\s+' } else { @() }
  if ($existing -contains 'redhat-operators-pull-secret') { return }

  $names = @($existing + 'redhat-operators-pull-secret' | Where-Object { $_ } | Sort-Object -Unique)
  $patch = (@{ imagePullSecrets = @($names | ForEach-Object { @{ name = $_ } }) } | ConvertTo-Json -Compress)
  Invoke-AapOcPatch @('patch', 'serviceaccount', 'default', '-n', $PortalNamespace) -Patch $patch | Out-Null
}

function Initialize-AapPortalNamespace {
  param(
    [Parameter(Mandatory)][string]$AapNamespace,
    [Parameter(Mandatory)][string]$PortalNamespace
  )

  Write-Host "Setting up portal namespace: $PortalNamespace"
  Invoke-AapOcQuiet @('create', 'namespace', $PortalNamespace) | Out-Null
  Invoke-AapOc @(
    'label', 'namespace', $PortalNamespace,
    'pod-security.kubernetes.io/enforce=privileged',
    'pod-security.kubernetes.io/audit=privileged',
    'pod-security.kubernetes.io/warn=privileged',
    '--overwrite'
  ) | Out-Null

  Grant-AapNamespaceSccs -Namespace $PortalNamespace
  Copy-AapPortalPullSecret -AapNamespace $AapNamespace -PortalNamespace $PortalNamespace
  Write-AapStep 'Portal namespace ready'
}

function Get-AapPortalAapCredentials {
  param([Parameter(Mandatory)][string]$Namespace)

  Write-Host 'Fetching AAP credentials...'

  $routeResult = Invoke-AapOcCapture @('get', 'route', 'aap', '-n', $Namespace, '-o', 'jsonpath={.spec.host}')
  if ($routeResult.ExitCode -ne 0 -or -not $routeResult.Output.Trim()) {
    throw 'Failed to get AAP route'
  }
  $Script:AapPortalState.AapRoute = $routeResult.Output.Trim()

  $adminPass = Get-AapAdminPassword -Namespace $Namespace
  if (-not $adminPass) {
    throw 'Failed to get AAP admin password'
  }
  $Script:AapPortalState.AdminPass = $adminPass

  $ping = Invoke-AapPortalCurl -Url "https://$($Script:AapPortalState.AapRoute)/api/gateway/v1/ping/" `
    -User "admin:$adminPass" -MaxTime 10
  if ($ping.ExitCode -ne 0) {
    throw "Cannot reach AAP at https://$($Script:AapPortalState.AapRoute)"
  }

  Write-AapStep "AAP accessible at: $($Script:AapPortalState.AapRoute)"
}

function Select-AapPortalOrganization {
  Write-Host 'Selecting AAP organization...'

  $route = $Script:AapPortalState.AapRoute
  $user = "admin:$($Script:AapPortalState.AdminPass)"
  $orgsResult = Invoke-AapPortalCurl -Url "https://$route/api/gateway/v1/organizations/" -User $user
  if ($orgsResult.ExitCode -ne 0) {
    throw 'Failed to list AAP organizations'
  }

  $countResult = Invoke-AapPortalJq -Filter '.count // 0' -InputJson $orgsResult.Output
  $orgCount = [int]$countResult.Output

  if ($orgCount -eq 0) {
    Write-Host 'Creating default organization...'
    $body = '{"name": "Default", "description": "Default organization for portal"}'
    $createResult = Invoke-AapPortalCurl -Method POST -Url "https://$route/api/gateway/v1/organizations/" `
      -User $user -Body $body
    if ($createResult.ExitCode -ne 0) {
      throw 'Failed to create default organization'
    }
    $Script:AapPortalState.OrgId = (Invoke-AapPortalJq -Filter '.id' -InputJson $createResult.Output).Output.Trim()
    $Script:AapPortalState.OrgName = 'Default'
  } else {
    $Script:AapPortalState.OrgId = (Invoke-AapPortalJq -Filter '.results[0].id' -InputJson $orgsResult.Output).Output.Trim()
    $Script:AapPortalState.OrgName = (Invoke-AapPortalJq -Filter '.results[0].name' -InputJson $orgsResult.Output).Output.Trim()
  }

  if (-not $Script:AapPortalState.OrgId -or $Script:AapPortalState.OrgId -eq 'null') {
    throw 'Failed to get/create organization'
  }

  Write-AapStep "Using organization: $($Script:AapPortalState.OrgName) (ID: $($Script:AapPortalState.OrgId))"
}

function New-AapPortalOAuthApp {
  Write-Host 'Creating OAuth application in AAP...'

  Initialize-AapPortalDir
  $oauthFile = Join-Path $Script:AapPortalState.PortalDir 'oauth_credentials.json'
  $route = $Script:AapPortalState.AapRoute
  $user = "admin:$($Script:AapPortalState.AdminPass)"
  $appName = $Script:AapPortalState.OAuthAppName

  $existing = Get-AapPortalOAuthAppByName -Route $route -User $user -AppName $appName
  if ($existing) {
    $Script:AapPortalState.OAuthAppId = $existing.Id
    $Script:AapPortalState.ClientId = $existing.ClientId
    $Script:AapPortalState.ClientSecret = ''

    if (Test-Path -LiteralPath $oauthFile) {
      $saved = Get-Content -LiteralPath $oauthFile -Raw | ConvertFrom-Json
      if ($saved.oauth_app_id -eq $Script:AapPortalState.OAuthAppId -and $saved.client_secret) {
        $Script:AapPortalState.ClientSecret = [string]$saved.client_secret
        Write-Host 'Using saved OAuth client secret for existing app...'
      }
    }

    if (-not $Script:AapPortalState.ClientSecret) {
      Write-Host 'OAuth app exists but client secret unavailable - recreating...'
      Remove-AapPortalOAuthAppFromAap -Route $route -User $user -AppId $Script:AapPortalState.OAuthAppId
      $existing = $null
    } else {
      Write-Host 'OAuth app already exists, using existing...'
    }
  }

  if (-not $existing) {
    $oauthResult = Invoke-AapPortalOAuthAppCreate -Route $route -User $user -AppName $appName `
      -OrgId $Script:AapPortalState.OrgId
    $Script:AapPortalState.OAuthAppId = (Invoke-AapPortalJq -Filter '.id' -InputJson $oauthResult.Output).Output.Trim()
    $Script:AapPortalState.ClientId = (Invoke-AapPortalJq -Filter '.client_id' -InputJson $oauthResult.Output).Output.Trim()
    $Script:AapPortalState.ClientSecret = (Invoke-AapPortalJq -Filter '.client_secret' -InputJson $oauthResult.Output).Output.Trim()
  }

  if (-not $Script:AapPortalState.ClientId -or $Script:AapPortalState.ClientId -eq 'null') {
    throw 'Failed to create OAuth application: missing client_id in AAP response'
  }
  if (-not $Script:AapPortalState.ClientSecret -or $Script:AapPortalState.ClientSecret -eq 'null') {
    throw 'Failed to obtain OAuth client secret'
  }

  $credJson = (@{
    oauth_app_id  = $Script:AapPortalState.OAuthAppId
    client_id     = $Script:AapPortalState.ClientId
    client_secret = $Script:AapPortalState.ClientSecret
  } | ConvertTo-Json -Compress)
  Set-AapUtf8Content -Path $oauthFile -Value $credJson
  Set-AapUtf8Content -Path (Join-Path $Script:AapPortalState.PortalDir 'oauth_app_id') -Value $Script:AapPortalState.OAuthAppId

  Write-AapStep "OAuth app ready (ID: $($Script:AapPortalState.OAuthAppId))"
}

function Enable-AapPortalOAuthTokens {
  Write-Host 'Enabling OAuth token creation for external users...'

  $route = $Script:AapPortalState.AapRoute
  $user = "admin:$($Script:AapPortalState.AdminPass)"
  $settingsResult = Invoke-AapPortalCurl -Url "https://$route/api/gateway/v1/settings/" -User $user
  if ($settingsResult.ExitCode -ne 0) {
    throw 'Failed to read AAP settings'
  }

  $current = (Invoke-AapPortalJq -Filter '.ALLOW_OAUTH2_FOR_EXTERNAL_USERS // false' -InputJson $settingsResult.Output).Output.Trim()
  if ($current -eq 'true') {
    Write-AapStep 'OAuth tokens already enabled'
    return
  }

  Invoke-AapPortalCurl -Method PATCH -Url "https://$route/api/gateway/v1/settings/" `
    -User $user -Body '{"ALLOW_OAUTH2_FOR_EXTERNAL_USERS": true}' | Out-Null
  Write-AapStep 'OAuth tokens enabled'
}

function New-AapPortalApiToken {
  Write-Host 'Generating AAP API token...'

  $route = $Script:AapPortalState.AapRoute
  $user = "admin:$($Script:AapPortalState.AdminPass)"
  $body = (@{
    description = 'Portal backend catalog access'
    scope       = 'read'
    application = [int]$Script:AapPortalState.OAuthAppId
  } | ConvertTo-Json -Compress)

  $tokenResult = Invoke-AapPortalCurl -Method POST -Url "https://$route/api/gateway/v1/tokens/" `
    -User $user -Body $body
  if ($tokenResult.ExitCode -ne 0) {
    throw 'Failed to generate API token'
  }

  $Script:AapPortalState.ApiToken = (Invoke-AapPortalJq -Filter '.token' -InputJson $tokenResult.Output).Output.Trim()
  if (-not $Script:AapPortalState.ApiToken -or $Script:AapPortalState.ApiToken -eq 'null') {
    throw 'Failed to generate API token'
  }

  Write-AapStep 'API token generated'
}

function Set-AapPortalRegistryAuthFile {
  param(
    [Parameter(Mandatory)][string]$SourceJson,
    [Parameter(Mandatory)][string]$AuthPath
  )

  $raw = $SourceJson.TrimStart([char]0xFEFF).Trim()
  if (-not $raw) { return $false }

  try {
    $config = $raw | ConvertFrom-Json
  } catch {
    return $false
  }

  if (-not $config.auths) { return $false }

  $entry = $config.auths.'registry.redhat.io'
  if (-not $entry) {
    $connect = $config.auths.'registry.connect.redhat.com'
    if ($connect) {
      $config.auths | Add-Member -NotePropertyName 'registry.redhat.io' -NotePropertyValue $connect -Force
      $entry = $connect
    }
  }

  if (-not $entry) { return $false }

  if (-not $entry.auth) {
    if ($entry.username -and $null -ne $entry.password) {
      $token = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes("$($entry.username):$($entry.password)")
      )
      $entry | Add-Member -NotePropertyName 'auth' -NotePropertyValue $token -Force
    }
  }

  if (-not $entry.auth) { return $false }

  Set-AapUtf8Content -Path $AuthPath -Value ($config | ConvertTo-Json -Compress -Depth 10)
  return $true
}

function Import-AapPortalRegistryAuthFromFile {
  param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$AuthPath
  )
  if (-not (Test-Path -LiteralPath $SourcePath)) { return $false }
  try {
    $raw = Get-Content -LiteralPath $SourcePath -Raw
    return (Set-AapPortalRegistryAuthFile -SourceJson $raw -AuthPath $AuthPath)
  } catch {
    return $false
  }
}

function Import-AapPortalRegistryAuthFromSecret {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Namespace,
    [Parameter(Mandatory)][string]$AuthPath
  )
  if ((Invoke-AapOcQuiet @('get', 'secret', $Name, '-n', $Namespace)) -ne 0) { return $false }
  $b64Result = Invoke-AapOcCapture @(
    'get', 'secret', $Name, '-n', $Namespace,
    '-o', 'jsonpath={.data.\.dockerconfigjson}'
  )
  if ($b64Result.ExitCode -ne 0 -or -not $b64Result.Output.Trim()) { return $false }
  try {
    $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64Result.Output.Trim()))
    return (Set-AapPortalRegistryAuthFile -SourceJson $decoded -AuthPath $AuthPath)
  } catch {
    return $false
  }
}

function Get-AapPortalRegistryCredentials {
  Write-Host 'Configuring registry credentials...'
  Initialize-AapPortalDir
  $authPath = Join-Path $Script:AapPortalState.PortalDir 'auth.json'
  $portalNs = $Script:AapPortalState.PortalNamespace
  $aapNs = $Script:AapPortalState.AapNamespace

  $fileSources = @(
    @{ Label = 'local pull secret'; Path = (Get-AapPullSecretPath) },
    @{ Label = 'portal pull secret cache'; Path = (Join-Path $Script:AapPortalState.PortalDir 'pull-secret.json') }
  )
  foreach ($src in $fileSources) {
    if (-not $src.Path) { continue }
    if (Import-AapPortalRegistryAuthFromFile -SourcePath $src.Path -AuthPath $authPath) {
      Write-AapStep "Using registry.redhat.io credentials from $($src.Label)"
      return
    }
  }

  $secretSources = @(
    @{ Label = 'cluster pull secret'; Name = 'pull-secret'; Namespace = 'openshift-config' },
    @{ Label = 'AAP namespace pull secret'; Name = 'redhat-operators-pull-secret'; Namespace = $aapNs },
    @{ Label = 'portal namespace pull secret'; Name = 'redhat-operators-pull-secret'; Namespace = $portalNs }
  )
  foreach ($src in $secretSources) {
    if (Import-AapPortalRegistryAuthFromSecret -Name $src.Name -Namespace $src.Namespace -AuthPath $authPath) {
      Write-AapStep "Using registry.redhat.io credentials from $($src.Label)"
      return
    }
  }

  if ($env:REGISTRY_USERNAME -and $env:REGISTRY_PASSWORD) {
    $authString = [Convert]::ToBase64String(
      [Text.Encoding]::UTF8.GetBytes("$($env:REGISTRY_USERNAME):$($env:REGISTRY_PASSWORD)")
    )
    $authJson = (@{
      auths = @{
        'registry.redhat.io' = @{ auth = $authString }
      }
    } | ConvertTo-Json -Compress)
    Set-AapUtf8Content -Path $authPath -Value $authJson
    Write-AapStep 'Using registry credentials from environment'
    return
  }

  throw @"
Registry credentials not found in pull secret.
Save your Red Hat pull secret to $($Script:AapDemoConfigDir)\pull-secret.txt and run 'aap-demo deploy' before 'aap-demo enable portal'.
"@
}

function New-AapPortalRegistrySecret {
  param([Parameter(Mandatory)][string]$PortalNamespace)

  Write-Host 'Creating registry secret in OpenShift...'
  $release = $Script:AapPortalState.ReleaseName
  $authPath = Join-Path $Script:AapPortalState.PortalDir 'auth.json'

  Invoke-AapOcQuiet @('delete', 'secret', "$release-dynamic-plugins-registry-auth", '-n', $PortalNamespace) | Out-Null
  Invoke-AapOc @(
    'create', 'secret', 'generic', "$release-dynamic-plugins-registry-auth",
    "--from-file=auth.json=$authPath",
    '-n', $PortalNamespace
  ) | Out-Null

  Write-AapStep 'Registry secret created'
}

function Get-AapPortalClusterInfo {
  Write-Host 'Getting cluster information...'

  $domainResult = Invoke-AapOcCapture @(
    'get', 'ingresses.config/cluster', '-o', 'jsonpath={.spec.domain}', '--request-timeout=5s'
  )
  $clusterBase = if ($domainResult.ExitCode -eq 0) { $domainResult.Output.Trim() } else { '' }

  if (-not $clusterBase) {
    $Script:AapPortalState.IsMicroshift = $true
    $aapRoute = $Script:AapPortalState.AapRoute
    $aapNs = $Script:AapPortalState.AapNamespace
    if ($aapRoute -match "^aap-${aapNs}\.(.+)$") {
      $clusterBase = $Matches[1]
    }
  } else {
    $Script:AapPortalState.IsMicroshift = $false
  }

  if (-not $clusterBase) {
    throw 'Failed to get cluster base URL'
  }

  $Script:AapPortalState.ClusterBaseUrl = $clusterBase
  Write-AapStep "Cluster base URL: $clusterBase"
}

function Get-AapPortalAapHostUrl {
  if ($Script:AapPortalState.IsMicroshift) {
    return "http://$($Script:AapPortalState.AapRoute)"
  }
  return "https://$($Script:AapPortalState.AapRoute)"
}

function New-AapPortalAapSecrets {
  param([Parameter(Mandatory)][string]$PortalNamespace)

  Write-Host 'Creating AAP credentials secret...'
  $Script:AapPortalState.AapHostUrl = Get-AapPortalAapHostUrl

  Invoke-AapOcQuiet @('delete', 'secret', 'secrets-rhaap-portal', '-n', $PortalNamespace) | Out-Null
  Invoke-AapOc @(
    'create', 'secret', 'generic', 'secrets-rhaap-portal',
    '-n', $PortalNamespace,
    "--from-literal=aap-host-url=$($Script:AapPortalState.AapHostUrl)",
    "--from-literal=oauth-client-id=$($Script:AapPortalState.ClientId)",
    "--from-literal=oauth-client-secret=$($Script:AapPortalState.ClientSecret)",
    "--from-literal=aap-token=$($Script:AapPortalState.ApiToken)"
  ) | Out-Null

  Write-AapStep 'AAP credentials secret created'
  Write-AapStep "AAP host URL: $($Script:AapPortalState.AapHostUrl)"
}

function Get-AapPortalSslValuesYaml {
  if (-not $Script:AapPortalState.IsMicroshift) { return '' }

  if ($Script:AapPortalState.IsArmCluster) {
    return @"
        ansible:
          rhaap:
            checkSSL: false
        auth:
          providers:
            rhaap:
              'production':
                checkSSL: false
"@
  }

  return @"
      ansible:
        rhaap:
          checkSSL: false
      auth:
        providers:
          rhaap:
            'production':
              checkSSL: false
"@
}

function Write-AapPortalHelmValuesFile {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Content
  )
  $normalized = ($Content -replace "`r`n", "`n" -replace "`r", "`n").TrimEnd() + "`n"
  Set-AapUtf8Content -Path $Path -Value $normalized
}

function New-AapPortalHelmValues {
  $valuesPath = Join-Path $Script:AapPortalState.PortalDir 'values.yaml'
  $sslValues = Get-AapPortalSslValuesYaml
  $clusterBase = $Script:AapPortalState.ClusterBaseUrl
  $pluginVersion = $Script:AapPortalState.DefaultPluginVersion

  if ($Script:AapPortalState.IsArmCluster) {
    $values = @"
redhat-developer-hub:
  global:
    clusterRouterBase: $clusterBase
    pluginMode: oci
    imageTagInfo: "$pluginVersion"
  upstream:
    backstage:
      image:
        registry: quay.io
        repository: rhdh-community/rhdh
        tag: "1.10"
      appConfig:
$sslValues
        dynamicPlugins:
          frontend:
            default.main-menu-items:
              menuItems:
                default.home:
                  title: Home
    postgresql:
      image:
        registry: registry.redhat.io
        repository: rhel9/postgresql-15
        tag: "9.8-1782419742"
"@
    Write-AapPortalHelmValuesFile -Path $valuesPath -Content $values
    Write-AapStep 'Helm values created (ARM profile)'
    Write-Host '  RHDH hub: quay.io/rhdh-community/rhdh:1.10'
    Write-Host '  PostgreSQL: registry.redhat.io/rhel9/postgresql-15:9.8-1782419742'
    return
  }

  $values = @"
global:
  clusterRouterBase: $clusterBase
  pluginMode: oci
  imageTagInfo: "$pluginVersion"

upstream:
  backstage:
    appConfig:
$sslValues
    dynamicPlugins:
      frontend:
        default.main-menu-items:
          menuItems:
            default.home:
              title: Home
            default.catalog:
              title: Catalog
            default.create:
              title: Create
            default.apis:
              title: APIs
            default.learning-path:
              title: Learning Paths
            default.my-group:
              title: My Group
"@
  Write-AapPortalHelmValuesFile -Path $valuesPath -Content $values
  Write-AapStep 'Helm values created (x86 profile)'
}

function Install-AapPortalHelmChart {
  param([Parameter(Mandatory)][string]$PortalNamespace)

  Write-Host 'Installing Helm chart...'
  $Script:AapPortalState.HelmWasUpgrade = $false
  $release = $Script:AapPortalState.ReleaseName
  $valuesPath = Join-Path $Script:AapPortalState.PortalDir 'values.yaml'

  $repoList = Invoke-AapPortalHelm @('repo', 'list')
  if ($repoList.ExitCode -eq 0 -and $repoList.Output -notmatch 'openshift-helm-charts') {
    Write-Host 'Adding OpenShift Helm Charts repository...'
    Invoke-AapPortalHelm @('repo', 'add', 'openshift-helm-charts', 'https://charts.openshift.io/') | Out-Null
  } elseif ($repoList.ExitCode -ne 0) {
    Write-Host 'Adding OpenShift Helm Charts repository...'
    Invoke-AapPortalHelm @('repo', 'add', 'openshift-helm-charts', 'https://charts.openshift.io/') | Out-Null
  }

  Invoke-AapPortalHelm @('repo', 'update') | Out-Null

  if ($Script:AapPortalState.IsArmCluster) {
    Invoke-AapOcQuiet @(
      'delete', 'configmap', "$release-dynamic-plugins", '-n', $PortalNamespace, '--ignore-not-found'
    ) | Out-Null
  }

  if (Test-AapPortalHelmRelease -Namespace $PortalNamespace) {
    Write-Host 'Upgrading existing Helm release...'
    $Script:AapPortalState.HelmWasUpgrade = $true
    $result = Invoke-AapPortalHelm @(
      'upgrade', $release, $Script:AapPortalState.ChartRepo,
      '-n', $PortalNamespace, '-f', $valuesPath, '--hide-notes'
    )
  } else {
    Write-Host 'Installing Helm release...'
    $result = Invoke-AapPortalHelm @(
      'install', $release, $Script:AapPortalState.ChartRepo,
      '-n', $PortalNamespace, '-f', $valuesPath, '--hide-notes'
    )
  }

  if ($result.ExitCode -ne 0) {
    throw "Helm install failed: $($result.Output)"
  }

  Write-AapStep 'Helm chart installed'
}

function Update-AapPortalQuayPluginPatch {
  param([Parameter(Mandatory)][string]$PortalNamespace)

  Write-Host 'Patching dynamic-plugins configmap...'
  $release = $Script:AapPortalState.ReleaseName
  $cm = "$release-dynamic-plugins"

  $cmResult = Invoke-AapOcCapture @(
    'get', 'cm', $cm, '-n', $PortalNamespace, '-o', 'jsonpath={.data.dynamic-plugins\.yaml}'
  )
  $pluginsYaml = if ($cmResult.ExitCode -eq 0) { $cmResult.Output } else { '' }

  if (-not $pluginsYaml) {
    Write-AapWarn 'dynamic-plugins configmap not found or empty'
    return
  }

  if ($pluginsYaml -notmatch 'ansible-automation-platform') {
    Write-AapWarn 'AAP OCI plugins missing from dynamic-plugins configmap'
    return
  }

  if ($pluginsYaml -match '(?ms)- disabled: true\r?\n\s+package: \./dynamic-plugins/dist/backstage-community-plugin-scaffolder-backend-module-quay-dynamic') {
    Write-AapStep 'Quay plugin override already present'
    return
  }

  $lines = @($pluginsYaml -split "`r?`n")
  $filtered = [System.Collections.Generic.List[string]]::new()
  $skipNextDisabled = $false
  foreach ($line in $lines) {
    if ($line -match 'scaffolder-backend-module-quay-dynamic') {
      $skipNextDisabled = $true
      continue
    }
    if ($skipNextDisabled -and $line -match '^\s+- disabled: true$') {
      $skipNextDisabled = $false
      continue
    }
    $skipNextDisabled = $false
    [void]$filtered.Add($line)
  }
  [void]$filtered.Add('- disabled: true')
  [void]$filtered.Add('  package: ./dynamic-plugins/dist/backstage-community-plugin-scaffolder-backend-module-quay-dynamic')
  $newYaml = ($filtered -join "`n")

  $tempFile = [System.IO.Path]::GetTempFileName()
  try {
    Set-AapUtf8Content -Path $tempFile -Value $newYaml
    $dryRun = Invoke-AapOcCapture @(
      'create', 'configmap', $cm,
      "--from-file=dynamic-plugins.yaml=$tempFile",
      '-n', $PortalNamespace, '--dry-run=client', '-o', 'yaml'
    )
    if ($dryRun.ExitCode -ne 0) {
      Write-AapWarn "Failed to render configmap patch: $($dryRun.Output)"
      return
    }
    $applyTemp = [System.IO.Path]::GetTempFileName()
    try {
      Set-AapUtf8Content -Path $applyTemp -Value $dryRun.Output
      Invoke-AapOc @('apply', '-f', $applyTemp) | Out-Null
    } finally {
      Remove-Item -LiteralPath $applyTemp -Force -ErrorAction SilentlyContinue
    }
  } finally {
    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
  }

  Write-AapStep 'Disabled broken quay scaffolder plugin (preserving AAP OCI plugins)'
}

function Reset-AapPortalDynamicPluginsPvc {
  param([Parameter(Mandatory)][string]$PortalNamespace)

  Write-Host 'Resetting dynamic-plugins PVC for clean plugin install...'
  $pvcResult = Invoke-AapOcCapture @('get', 'pvc', '-n', $PortalNamespace, '-o', 'name')
  if ($pvcResult.ExitCode -ne 0) { return }

  foreach ($line in $pvcResult.Lines) {
    $pvcName = $line.Trim()
    if ($pvcName -match 'dynamic-plugins') {
      Invoke-AapOcQuiet @('delete', $pvcName, '-n', $PortalNamespace, '--timeout=120s') | Out-Null
    }
  }
}

function Restart-AapPortalDeployment {
  param([Parameter(Mandatory)][string]$PortalNamespace)

  Write-Host 'Restarting portal to apply credential updates...'
  $release = $Script:AapPortalState.ReleaseName
  if ((Invoke-AapOcQuiet @('rollout', 'restart', "deployment/$release", '-n', $PortalNamespace)) -ne 0) {
    Write-AapWarn 'Failed to restart portal deployment'
    return
  }
  Write-AapStep 'Portal deployment restarted'
}

function Wait-AapPortalDeployment {
  param([Parameter(Mandatory)][string]$PortalNamespace)

  Write-Host 'Waiting for portal deployment to be ready...'
  $release = $Script:AapPortalState.ReleaseName
  $status = Invoke-AapOcCapture @(
    'rollout', 'status', "deployment/$release", '-n', $PortalNamespace, '--timeout=600s'
  )
  if ($status.ExitCode -ne 0) {
    Write-AapWarn 'Deployment taking longer than expected'
    Write-Host "Check status with: oc get pods -n $PortalNamespace"
    Write-Host 'Proceeding anyway...'
  } else {
    Write-AapStep 'Deployment ready'
  }
}

function Update-AapPortalAapRouteHostAlias {
  param(
    [Parameter(Mandatory)][string]$AapNamespace,
    [Parameter(Mandatory)][string]$PortalNamespace
  )

  if (-not $Script:AapPortalState.IsMicroshift) { return }

  Write-Host 'Configuring AAP route host alias for in-pod OAuth token exchange...'
  $release = $Script:AapPortalState.ReleaseName
  $aapRoute = $Script:AapPortalState.AapRoute

  $ipResult = Invoke-AapOcCapture @('get', 'svc', 'aap', '-n', $AapNamespace, '-o', 'jsonpath={.spec.clusterIP}')
  $aapIp = if ($ipResult.ExitCode -eq 0) { $ipResult.Output.Trim() } else { '' }
  if (-not $aapIp) {
    Write-AapWarn 'Could not resolve AAP service ClusterIP; skipping host alias'
    return
  }

  $currentResult = Invoke-AapOcCapture @(
    'get', 'deployment', $release, '-n', $PortalNamespace,
    '-o', "jsonpath={.spec.template.spec.hostAliases[?(@.hostnames[0]=='$aapRoute')].ip}"
  )
  $currentIp = if ($currentResult.ExitCode -eq 0) { $currentResult.Output.Trim() } else { '' }

  if ($currentIp -eq $aapIp) {
    Write-AapStep "AAP route host alias already configured ($aapRoute → $aapIp)"
    return
  }

  $patch = (@{
    spec = @{
      template = @{
        spec = @{
          hostAliases = @(
            @{ ip = $aapIp; hostnames = @($aapRoute) }
          )
        }
      }
    }
  } | ConvertTo-Json -Depth 6 -Compress)
  Invoke-AapOcPatch @('patch', 'deployment', $release, '-n', $PortalNamespace) -Patch $patch | Out-Null

  $rollout = Invoke-AapOcCapture @(
    'rollout', 'status', "deployment/$release", '-n', $PortalNamespace, '--timeout=600s'
  )
  if ($rollout.ExitCode -ne 0) {
    Write-AapWarn 'Portal rollout after host alias patch is still in progress'
  }

  Write-AapStep "AAP route host alias: $aapRoute → $aapIp"
}

function Update-AapPortalOAuthRedirect {
  Write-Host 'Updating OAuth redirect URI...'

  $portalNs = $Script:AapPortalState.PortalNamespace
  $release = $Script:AapPortalState.ReleaseName
  $routeResult = Invoke-AapOcCapture @(
    'get', 'route', $release, '-n', $portalNs, '-o', 'jsonpath={.spec.host}'
  )
  if ($routeResult.ExitCode -ne 0 -or -not $routeResult.Output.Trim()) {
    Write-AapWarn 'Failed to get portal route'
    Write-Host 'OAuth redirect URI not updated - may need manual fix'
    return
  }

  $Script:AapPortalState.PortalRoute = $routeResult.Output.Trim()
  $redirectUri = "https://$($Script:AapPortalState.PortalRoute)/api/auth/rhaap/handler/frame"
  $route = $Script:AapPortalState.AapRoute
  $user = "admin:$($Script:AapPortalState.AdminPass)"
  $body = (@{ redirect_uris = $redirectUri } | ConvertTo-Json -Compress)

  Invoke-AapPortalCurl -Method PATCH `
    -Url "https://$route/api/gateway/v1/applications/$($Script:AapPortalState.OAuthAppId)/" `
    -User $user -Body $body | Out-Null

  Write-AapStep "OAuth redirect URI updated: $redirectUri"
}

function Test-AapPortalAapHostUrl {
  param([Parameter(Mandatory)][string]$PortalNamespace)

  Write-Host 'Verifying AAP host URL in portal pod...'
  $release = $Script:AapPortalState.ReleaseName
  $result = Invoke-AapOcCapture @(
    'exec', "deployment/$release", '-c', 'backstage-backend', '-n', $PortalNamespace, '--',
    'printenv', 'AAP_HOST_URL'
  )
  $aapHostUrl = if ($result.ExitCode -eq 0) { $result.Output.Trim() } else { '' }

  if (-not $aapHostUrl) {
    Write-AapWarn 'Could not read AAP_HOST_URL from portal pod'
    return $false
  }

  if ($aapHostUrl -match '\.svc') {
    Write-Host "  ERROR Portal is configured with in-cluster AAP URL: $aapHostUrl" -ForegroundColor Red
    Write-Host '  Browser OAuth redirects require the external AAP route hostname.'
    Write-Host '  Re-run: aap-demo enable portal'
    return $false
  }

  if ($Script:AapPortalState.IsMicroshift -and $aapHostUrl -match '^https://') {
    Write-Host "  ERROR Portal AAP URL uses HTTPS on MicroShift: $aapHostUrl" -ForegroundColor Red
    Write-Host '  In-cluster OAuth token exchange requires http://<aap-route> on CRC/MicroShift.'
    Write-Host '  Re-run: aap-demo enable portal'
    return $false
  }

  Write-AapStep "AAP host URL: $aapHostUrl"
  return $true
}

function Test-AapPortalOAuthClient {
  param([Parameter(Mandatory)][string]$PortalNamespace)

  Write-Host 'Verifying OAuth client credentials...'
  $release = $Script:AapPortalState.ReleaseName
  $aapHostUrl = $Script:AapPortalState.AapHostUrl
  $portalRoute = $Script:AapPortalState.PortalRoute

  $script = @"
AUTH=`$(printf '%s:%s' "`$OAUTH_CLIENT_ID" "`$OAUTH_CLIENT_SECRET" | base64 -w0)
curl -s -o /dev/null -w '%{http_code}' -X POST '${aapHostUrl}/o/token/' \
  -H "Authorization: Basic `$AUTH" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=authorization_code&code=invalid&redirect_uri=https://${portalRoute}/api/auth/rhaap/handler/frame'
"@

  $result = Invoke-AapOcCapture @(
    'exec', "deployment/$release", '-c', 'backstage-backend', '-n', $PortalNamespace, '--',
    'sh', '-c', $script
  )
  $httpCode = if ($result.ExitCode -eq 0) { $result.Output.Trim() } else { '000' }

  if ($httpCode -eq '000') {
    Write-Host "  ERROR Portal pod cannot reach AAP token endpoint at ${aapHostUrl}/o/token/" -ForegroundColor Red
    Write-Host '  On CRC/MicroShift, nip.io resolves to 127.0.0.1 inside pods.'
    Write-Host '  Re-run: aap-demo enable portal'
    return $false
  }

  if ($httpCode -eq '401') {
    Write-Host '  ERROR OAuth client credentials rejected by AAP (invalid_client)' -ForegroundColor Red
    Write-Host '  Re-run: aap-demo enable portal'
    return $false
  }

  Write-AapStep "OAuth client credentials accepted by AAP (HTTP $httpCode)"
  return $true
}

function Show-AapPortalSuccess {
  param([Parameter(Mandatory)][string]$Namespace)

  Write-Host ''
  Write-Host ('=' * 60)
  Write-AapStep 'Portal addon enabled successfully!'
  Write-Host ('=' * 60)
  Write-Host ''
  Write-Host "Portal URL: https://$($Script:AapPortalState.PortalRoute)"
  if ($Script:AapPortalState.IsArmCluster) {
    Write-Host 'Profile: ARM (quay.io/rhdh-community/rhdh:1.10)'
  } else {
    Write-Host 'Profile: x86 (Red Hat RHDH hub image from chart)'
  }
  Write-Host ''
  Write-Host 'Next steps:'
  Write-Host '1. Open the portal URL in your browser'
  Write-Host "2. Click 'Sign In'"
  Write-Host '3. Authenticate with AAP credentials (admin / <aap-admin-password>)'
  Write-Host '4. Browse AAP job templates in the catalog'
  Write-Host ''
  Write-Host 'Check status: aap-demo status portal'
  Write-Host 'Disable: aap-demo disable portal'
  Write-Host ''

  $adminPassword = Get-AapAdminPassword -Namespace $Namespace
  if ($adminPassword) {
    Write-Host '  Credentials:'
    Write-Host '    Username: admin'
    Write-Host "    Password: $adminPassword"
    Write-Host ''
    Write-Host '  Sign in with these AAP credentials when the portal prompts you.'
    Write-Host ''
  }
}

function Invoke-AapDeployPortalAddon {
  param(
    [string]$Namespace = $Script:AapDemoDefaultNamespace
  )

  $Script:AapPortalState.AapNamespace = $Namespace
  $portalNs = $Script:AapPortalState.PortalNamespace

  Test-AapPortalPrerequisites -Namespace $Namespace
  Clear-AapPortalLegacyInstall -Namespace $Namespace
  Initialize-AapPortalNamespace -AapNamespace $Namespace -PortalNamespace $portalNs
  Get-AapPortalAapCredentials -Namespace $Namespace
  Select-AapPortalOrganization
  New-AapPortalOAuthApp
  Enable-AapPortalOAuthTokens
  New-AapPortalApiToken
  Get-AapPortalRegistryCredentials
  New-AapPortalRegistrySecret -PortalNamespace $portalNs
  Get-AapPortalClusterInfo
  New-AapPortalAapSecrets -PortalNamespace $portalNs
  New-AapPortalHelmValues
  Install-AapPortalHelmChart -PortalNamespace $portalNs

  if ($Script:AapPortalState.IsArmCluster) {
    Update-AapPortalQuayPluginPatch -PortalNamespace $portalNs
    Reset-AapPortalDynamicPluginsPvc -PortalNamespace $portalNs
    Restart-AapPortalDeployment -PortalNamespace $portalNs
  } elseif ($Script:AapPortalState.HelmWasUpgrade) {
    Restart-AapPortalDeployment -PortalNamespace $portalNs
  }

  Wait-AapPortalDeployment -PortalNamespace $portalNs
  Update-AapPortalAapRouteHostAlias -AapNamespace $Namespace -PortalNamespace $portalNs
  Update-AapPortalOAuthRedirect

  if (-not (Test-AapPortalAapHostUrl -PortalNamespace $portalNs)) {
    Write-AapWarn 'AAP host URL verification failed (portal may still work)'
  }
  if (-not (Test-AapPortalOAuthClient -PortalNamespace $portalNs)) {
    Write-AapWarn 'OAuth client verification failed (portal may still work)'
  }

  Show-AapPortalSuccess -Namespace $Namespace
}

function Invoke-AapRemovePortalAddon {
  param(
    [string]$Namespace = $Script:AapDemoDefaultNamespace
  )

  $portalNs = $Script:AapPortalState.PortalNamespace
  $portalDir = $Script:AapPortalState.PortalDir
  $release = $Script:AapPortalState.ReleaseName

  Write-Host 'Disabling portal addon...'

  Clear-AapPortalNamespace -Namespace $portalNs
  if ($Namespace -ne $portalNs) {
    Clear-AapPortalNamespace -Namespace $Namespace
  }

  $oauthAppIdPath = Join-Path $portalDir 'oauth_app_id'
  if (Test-Path -LiteralPath $oauthAppIdPath) {
    $appId = (Get-Content -LiteralPath $oauthAppIdPath -Raw).Trim()
    $routeResult = Invoke-AapOcCapture @('get', 'route', 'aap', '-n', $Namespace, '-o', 'jsonpath={.spec.host}')
    $aapRoute = if ($routeResult.ExitCode -eq 0) { $routeResult.Output.Trim() } else { '' }
    $adminPass = Get-AapAdminPassword -Namespace $Namespace

    if ($aapRoute -and $adminPass -and $appId) {
      Write-Host "Deleting OAuth application (ID: $appId) from AAP"
      Invoke-AapPortalCurl -Method DELETE `
        -Url "https://$aapRoute/api/gateway/v1/applications/$appId/" `
        -User "admin:$adminPass" | Out-Null
    }
  }

  Invoke-AapOcQuiet @('delete', 'namespace', $portalNs, '--timeout=120s') | Out-Null

  if (Test-Path -LiteralPath $portalDir) {
    Remove-Item -LiteralPath $portalDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  Write-AapStep 'Portal addon disabled'
}
