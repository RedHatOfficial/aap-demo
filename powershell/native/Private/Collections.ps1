# Collection authentication and integrated PAH remote configuration (Windows).

Set-StrictMode -Version Latest

function Get-AapGalaxyTokenFilePath {
  if ($env:GALAXY_TOKEN_FILE) { return $env:GALAXY_TOKEN_FILE }
  return Join-Path $Script:AapDemoConfigDir 'galaxy-token'
}

function Get-AapPahConfigFilePath {
  if ($env:PAH_CONFIG_FILE) { return $env:PAH_CONFIG_FILE }
  return Join-Path $Script:AapDemoConfigDir 'pah-config.yml'
}

function Get-AapYamlScalar {
  param(
    [Parameter(Mandatory)][string[]]$Lines,
    [Parameter(Mandatory)][string]$Key
  )

  foreach ($line in $Lines) {
    if ($line -match ('^\s*' + [regex]::Escape($Key) + '\s*:\s*(.+)$')) {
      return $Matches[1].Trim().Trim('"').Trim("'")
    }
  }
  return $null
}

function Get-AapGalaxyCredentials {
  $creds = [PSCustomObject]@{
    GalaxyToken = $null
    PahUrl      = $null
    PahToken    = $null
    PahUser     = $null
    PahPass     = $null
  }

  $tokenFile = Get-AapGalaxyTokenFilePath
  if (Test-Path -LiteralPath $tokenFile) {
    $creds.GalaxyToken = (Get-Content -LiteralPath $tokenFile -Raw).Trim()
  }

  $pahFile = Get-AapPahConfigFilePath
  if (Test-Path -LiteralPath $pahFile) {
    $lines = Get-Content -LiteralPath $pahFile
    $creds.PahUrl = Get-AapYamlScalar -Lines $lines -Key 'url'
    $creds.PahToken = Get-AapYamlScalar -Lines $lines -Key 'token'
    $creds.PahUser = Get-AapYamlScalar -Lines $lines -Key 'username'
    $creds.PahPass = Get-AapYamlScalar -Lines $lines -Key 'password'
  }

  return $creds
}

function Test-AapGalaxyTokenFormat {
  param(
    [AllowNull()][string]$Token,
    [switch]$Brief
  )

  if ([string]::IsNullOrWhiteSpace($Token)) {
    return $true
  }

  if ($Token.Length -lt 100) {
    if ($Brief) {
      Write-AapWarn "Invalid galaxy token format (too short: $($Token.Length) chars)"
    } else {
      Write-AapErr "Invalid galaxy token format (too short: $($Token.Length) chars)"
      Write-Host ''
      Write-Host 'Quick setup:'
      Write-Host '  aap-demo setup-pah    # Opens browser and prompts for token'
      Write-Host ''
      Write-Host 'Documentation: docs/collection-authentication.md'
    }
    return $false
  }

  return $true
}

function Test-AapPahConfigFormat {
  param([Parameter(Mandatory)]$Credentials)

  if ([string]::IsNullOrWhiteSpace($Credentials.PahUrl)) {
    return $true
  }

  if ($Credentials.PahUrl -notmatch '^https?://') {
    Write-AapErr "Invalid PAH URL format: $($Credentials.PahUrl)"
    Write-Host '  URL must start with http:// or https://'
    return $false
  }

  if ([string]::IsNullOrWhiteSpace($Credentials.PahToken) -and
      [string]::IsNullOrWhiteSpace($Credentials.PahUser)) {
    Write-AapErr 'PAH config missing authentication'
    Write-Host "  Provide either 'token' or 'username'/'password' in $((Get-AapPahConfigFilePath))"
    return $false
  }

  return $true
}

function Test-AapInteractivePrompt {
  if ($env:QUIET -eq 'true') { return $false }
  try {
    if (-not [Environment]::UserInteractive) { return $false }
    if ($Host.Name -ne 'ConsoleHost') { return $false }
    if ([Console]::IsInputRedirected) { return $false }
    return $true
  } catch {
    return $false
  }
}

function Save-AapGalaxyTokenFile {
  param([Parameter(Mandatory)][string]$Token)

  $tokenFile = Get-AapGalaxyTokenFilePath
  $tokenDir = Split-Path -Parent $tokenFile
  New-Item -ItemType Directory -Force -Path $tokenDir | Out-Null
  Set-Content -LiteralPath $tokenFile -Value $Token.Trim() -NoNewline -Encoding ascii

  try {
    $acl = Get-Acl -LiteralPath $tokenFile
    $acl.SetAccessRuleProtection($true, $false)
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
      $identity, 'FullControl', 'Allow')
    $acl.SetAccessRule($rule)
    Set-Acl -LiteralPath $tokenFile -AclObject $acl
  } catch {
    Write-AapWarn 'Could not restrict token file permissions'
  }
}

function Open-AapGalaxyTokenPage {
  param([Parameter(Mandatory)][string]$TokenUrl)

  try {
    Start-Process $TokenUrl | Out-Null
    Write-Host 'Opening browser to Red Hat Automation Hub...'
  } catch {
    Write-Host 'Visit this URL in your browser:'
    Write-Host "  $TokenUrl"
  }
}

function Initialize-AapGalaxyToken {
  $tokenFile = Get-AapGalaxyTokenFilePath
  $tokenUrl = 'https://console.redhat.com/ansible/automation-hub/token'

  if (Test-Path -LiteralPath $tokenFile) {
    $existing = (Get-Content -LiteralPath $tokenFile -Raw).Trim()
    if (Test-AapGalaxyTokenFormat -Token $existing) {
      if (-not [string]::IsNullOrWhiteSpace($existing)) {
        return $existing
      }
    } elseif (Test-AapInteractivePrompt) {
      Write-AapWarn "Existing token at $tokenFile is invalid"
      $replace = Read-Host 'Replace token? [y/N]'
      if ($replace -notmatch '^[Yy]') {
        throw 'Invalid galaxy token'
      }
    } else {
      throw 'Invalid galaxy token'
    }
  }

  if (-not (Test-AapInteractivePrompt)) {
    Open-AapGalaxyTokenPage -TokenUrl $tokenUrl
    Write-Host ''
    Write-Host 'Run aap-demo setup-pah in an interactive PowerShell window to paste your token.'
    Write-Host 'Documentation: docs/collection-authentication.md'
    return $null
  }

  Open-AapGalaxyTokenPage -TokenUrl $tokenUrl
  Write-Host ''
  Write-Host 'Paste your Offline Token from the browser page.'
  Write-Host 'Press Enter on an empty line to cancel.'
  Write-Host ''

  while ($true) {
    $token = Read-Host 'Offline Token'
    if ([string]::IsNullOrWhiteSpace($token)) {
      throw 'Token entry cancelled'
    }

    $token = $token.Trim()
    if (Test-AapGalaxyTokenFormat -Token $token -Brief) {
      Save-AapGalaxyTokenFile -Token $token
      Write-AapStep "Token saved to $tokenFile"
      return $token
    }

    Write-Host 'Paste the full Offline Token (~1500 characters) and try again.'
    Write-Host ''
  }
}

function ConvertFrom-AapPulpJson {
  param([AllowNull()][string]$Raw)

  if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
  try {
    return ($Raw | ConvertFrom-Json)
  } catch {
    return $null
  }
}

function Get-AapPulpFirstHref {
  param($Data)

  if (-not $Data) { return $null }
  if ($Data.PSObject.Properties['results'] -and $Data.results -and @($Data.results).Count -gt 0) {
    return [string]$Data.results[0].pulp_href
  }
  if ($Data.PSObject.Properties['pulp_href'] -and $Data.pulp_href) {
    return [string]$Data.pulp_href
  }
  return $null
}

function Join-AapPulpUrl {
  param(
    [Parameter(Mandatory)][string]$ApiBase,
    [Parameter(Mandatory)][string]$Href
  )

  if ($Href -match '^https?://') { return $Href }
  if ($Href -match '^/api/galaxy/') {
    if ($ApiBase -match '^(https?://[^/]+)') {
      return "$($Matches[1])$Href"
    }
  }
  return "$ApiBase$Href"
}

function Invoke-AapPulpCurl {
  param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$AdminPassword,
    [ValidateSet('GET', 'POST', 'PATCH')]
    [string]$Method = 'GET',
    [string]$Body = $null,
    [int]$TimeoutSeconds = 10
  )

  Set-AapIngressCaEnvFromSaved

  $curlArgs = @(
    '--ssl-no-revoke', '-sS', "--max-time", "$TimeoutSeconds",
    '-u', "admin:$AdminPassword",
    '-w', "`n__HTTP_CODE__:%{http_code}"
  )

  switch ($Method) {
    'POST' { $curlArgs += '-X', 'POST' }
    'PATCH' { $curlArgs += '-X', 'PATCH' }
  }

  $bodyFile = $null
  if ($Body) {
    $bodyFile = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($bodyFile, $Body, [System.Text.UTF8Encoding]::new($false))
    $curlArgs += '-H', 'Content-Type: application/json', '--data-binary', "@$bodyFile"
  }

  $curlArgs += $Url

  $previousEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = (& curl.exe @curlArgs 2>&1 | Out-String).Trim()
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousEap
    if ($bodyFile -and (Test-Path -LiteralPath $bodyFile)) {
      Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue
    }
  }

  $httpCode = 0
  $body = $output
  if ($output -match '__HTTP_CODE__:(?<code>\d+)\s*$') {
    $httpCode = [int]$Matches['code']
    $body = ($output -replace '(?s)\n?__HTTP_CODE__:\d+\s*$', '').Trim()
  }

  return [PSCustomObject]@{
    Body     = $body
    HttpCode = $httpCode
    ExitCode = $exitCode
    Ok       = ($httpCode -ge 200 -and $httpCode -lt 300)
  }
}

function Format-AapPulpErrorDetail {
  param(
    [int]$HttpCode,
    [AllowNull()][string]$ResponseBody
  )

  if ($HttpCode -in 502, 503, 504) {
    return "Hub returned HTTP $HttpCode (gateway or upstream error; re-run: aap-demo setup-pah)"
  }

  if ($ResponseBody -and $ResponseBody -notmatch '__HTTP_CODE__') {
    $err = ConvertFrom-AapPulpJson -Raw $ResponseBody
    if ($err -and $err.detail) {
      return [string]$err.detail
    }
    if ($ResponseBody.Length -le 200) {
      return $ResponseBody
    }
  }

  if ($HttpCode -gt 0) {
    return "Request failed (HTTP $HttpCode)"
  }

  return 'No response from hub API'
}

function Invoke-AapPulpMutatingWithRetry {
  param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$AdminPassword,
    [ValidateSet('POST', 'PATCH')]
    [string]$Method = 'POST',
    [Parameter(Mandatory)][string]$Body,
    [int]$MaxAttempts = 6,
    [int]$DelaySeconds = 8,
    [int]$TimeoutSeconds = 60
  )

  $result = $null
  for ($i = 1; $i -le $MaxAttempts; $i++) {
    $result = Invoke-AapPulpCurl -Url $Url -AdminPassword $AdminPassword -Method $Method `
      -Body $Body -TimeoutSeconds $TimeoutSeconds
    if ($result.Ok) { return $result }
    if ($Method -eq 'POST' -and $result.HttpCode -eq 400 -and $result.Body -match 'unique|already exists|must be unique') {
      return $result
    }
    if ($result.HttpCode -notin 502, 503, 504) { return $result }
    if ($i -lt $MaxAttempts) {
      Start-Sleep -Seconds $DelaySeconds
    }
  }
  return $result
}

function Invoke-AapPulpPostWithRetry {
  param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$AdminPassword,
    [Parameter(Mandatory)][string]$Body,
    [int]$MaxAttempts = 6,
    [int]$DelaySeconds = 8,
    [int]$TimeoutSeconds = 60
  )

  return Invoke-AapPulpMutatingWithRetry -Url $Url -AdminPassword $AdminPassword -Method 'POST' `
    -Body $Body -MaxAttempts $MaxAttempts -DelaySeconds $DelaySeconds -TimeoutSeconds $TimeoutSeconds
}

function Invoke-AapPulpRequest {
  param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$AdminPassword,
    [ValidateSet('GET', 'POST', 'PATCH')]
    [string]$Method = 'GET',
    [string]$Body = $null
  )

  $result = Invoke-AapPulpCurl -Url $Url -AdminPassword $AdminPassword -Method $Method -Body $Body
  if ($result.ExitCode -ne 0 -and [string]::IsNullOrWhiteSpace($result.Body)) {
    return [PSCustomObject]@{
      Body     = $null
      HttpCode = $result.HttpCode
      ExitCode = $result.ExitCode
      Ok       = $false
    }
  }
  return $result
}

function Get-AapPulpApiAvailability {
  param(
    [Parameter(Mandatory)][string]$ApiBase,
    [Parameter(Mandatory)][string]$AdminPassword,
    [Parameter(Mandatory)][string]$Namespace,
    [Parameter(Mandatory)][string]$AapRoute
  )

  $statusUrl = "$ApiBase/status/"
  $result = Invoke-AapPulpCurl -Url $statusUrl -AdminPassword $AdminPassword
  $json = ConvertFrom-AapPulpJson -Raw $result.Body

  if ($result.Ok -and $json) {
    return [PSCustomObject]@{
      Available = $true
      Reason    = 'Pulp API responding'
      HttpCode  = $result.HttpCode
      ApiUrl    = "https://${AapRoute}/api/galaxy/pulp/api/v3/"
    }
  }

  $reason = switch ($true) {
    (-not (Get-AapAapSuccessful -Namespace $Namespace)) {
      'AAP deployment not complete - run: aap-demo watch'
    }
    ($result.HttpCode -eq 401) {
      'Authentication failed - admin credentials may not be ready yet'
    }
    ($result.HttpCode -in 502, 503, 504) {
      'Hub is still starting (gateway returned an upstream error)'
    }
    ($result.HttpCode -eq 404) {
      'Pulp API endpoint not found - hub component may not be deployed yet'
    }
    ($result.HttpCode -eq 0 -or $result.ExitCode -in 7, 28) {
      'Cannot connect to hub API - hub pod may still be starting'
    }
    default {
      if ($result.Body -and $result.Body.Length -lt 200) {
        "Unexpected response (HTTP $($result.HttpCode)): $($result.Body)"
      } else {
        "Unexpected response (HTTP $($result.HttpCode))"
      }
    }
  }

  return [PSCustomObject]@{
    Available = $false
    Reason    = $reason
    HttpCode  = $result.HttpCode
    ApiUrl    = "https://${AapRoute}/api/galaxy/pulp/api/v3/"
  }
}

function Write-AapPulpCreateFailureHint {
  param(
    [Parameter(Mandatory)][string]$ApiBase,
    [Parameter(Mandatory)][string]$AdminPassword,
    [Parameter(Mandatory)][string]$Namespace,
    [Parameter(Mandatory)][string]$AapRoute,
    [ValidateSet('create', 'update', 'link', 'sync')]
    [string]$Operation = 'create',
    [int]$HttpCode = 0,
    [AllowNull()][string]$ResponseBody = $null
  )

  $availability = Get-AapPulpApiAvailability -ApiBase $ApiBase -AdminPassword $AdminPassword `
    -Namespace $Namespace -AapRoute $AapRoute

  Write-Host ''
  if (-not $availability.Available) {
    Write-AapWarn "AAP galaxy API not available at $($availability.ApiUrl)"
    Write-Host "    $($availability.Reason)"
    Write-Host '    Re-run when ready: aap-demo setup-pah'
    return
  }

  $operationLabel = switch ($Operation) {
    'update' { 'remote update failed' }
    'link'   { 'repository link failed' }
    'sync'   { 'repository sync failed' }
    default  { 'remote create failed' }
  }
  Write-Host "    Pulp API is reachable; $operationLabel" -ForegroundColor Yellow
  $detail = Format-AapPulpErrorDetail -HttpCode $HttpCode -ResponseBody $ResponseBody
  Write-Host "    $detail"
}

function Get-AapPulpResourceHref {
  param(
    [string]$ApiBase = '',
    [Parameter(Mandatory)][string]$AdminPassword,
    [Parameter(Mandatory)][string]$ResourceUrl,
    [string]$Name = $null
  )

  $url = if ($Name) { "${ResourceUrl}?name=${Name}" } else { $ResourceUrl }
  $result = Invoke-AapPulpRequest -Url $url -AdminPassword $AdminPassword
  if (-not $result.Ok) { return $null }
  return Get-AapPulpFirstHref -Data (ConvertFrom-AapPulpJson -Raw $result.Body)
}

function Wait-AapPulpTask {
  param(
    [Parameter(Mandatory)][string]$ApiBase,
    [Parameter(Mandatory)][string]$AdminPassword,
    [Parameter(Mandatory)][string]$TaskHref
  )

  for ($i = 1; $i -le 10; $i++) {
    Start-Sleep -Seconds 1
    $taskUrl = Join-AapPulpUrl -ApiBase $ApiBase -Href $TaskHref
    $result = Invoke-AapPulpRequest -Url $taskUrl -AdminPassword $AdminPassword
    if (-not $result.Ok) { continue }
    $task = ConvertFrom-AapPulpJson -Raw $result.Body
    if ($task -and [string]$task.state -eq 'completed') {
      return $true
    }
  }
  return $false
}

function Update-AapPulpRemoteToken {
  param(
    [Parameter(Mandatory)][string]$ApiBase,
    [Parameter(Mandatory)][string]$AdminPassword,
    [Parameter(Mandatory)][string]$RemoteHref,
    [Parameter(Mandatory)][string]$Token
  )

  $patchBody = (@{ token = $Token } | ConvertTo-Json -Compress)
  $patchUrl = Join-AapPulpUrl -ApiBase $ApiBase -Href $RemoteHref
  $patchResult = Invoke-AapPulpMutatingWithRetry -Url $patchUrl -AdminPassword $AdminPassword `
    -Method 'PATCH' -Body $patchBody
  if (-not $patchResult.Ok) {
    return $patchResult
  }

  $patchData = ConvertFrom-AapPulpJson -Raw $patchResult.Body
  if ($patchData -and $patchData.task) {
    Wait-AapPulpTask -ApiBase $ApiBase -AdminPassword $AdminPassword -TaskHref ([string]$patchData.task) | Out-Null
  }
  return $patchResult
}

function Set-AapPulpCollectionRemote {
  param(
    [Parameter(Mandatory)][string]$ApiBase,
    [Parameter(Mandatory)][string]$AdminPassword,
    [Parameter(Mandatory)][string]$RemotesUrl,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$RemoteUrl,
    [Parameter(Mandatory)][string]$Token
  )

  $href = Get-AapPulpResourceHref -AdminPassword $AdminPassword -ResourceUrl $RemotesUrl -Name $Name
  if ($href) {
    return Update-AapPulpRemoteToken -ApiBase $ApiBase -AdminPassword $AdminPassword `
      -RemoteHref $href -Token $Token
  }

  $createBody = (@{
      name           = $Name
      url            = $RemoteUrl
      token          = $Token
      tls_validation = $true
    } | ConvertTo-Json -Compress)
  return Invoke-AapPulpPostWithRetry -Url $RemotesUrl -AdminPassword $AdminPassword -Body $createBody
}

function Set-AapPahRemotes {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Namespace,
    [Parameter(Mandatory)]$Credentials
  )

  Write-Host 'Configuring Private Automation Hub remotes...'

  $routeResult = Invoke-AapOcCapture @('get', 'route', 'aap', '-n', $Namespace, '-o', 'jsonpath={.spec.host}')
  $aapRoute = if ($routeResult.ExitCode -eq 0) { $routeResult.Output.Trim() } else { '' }
  if (-not $aapRoute) {
    throw 'AAP route not found'
  }

  $adminPass = Get-AapAdminPassword -Namespace $Namespace
  if (-not $adminPass) {
    throw 'Admin password not found'
  }

  $apiBase = "https://$aapRoute/api/galaxy/pulp/api/v3"
  $remotesUrl = "$apiBase/remotes/ansible/collection/"
  $reposUrl = "$apiBase/repositories/ansible/ansible/"

  $apiAvailability = Get-AapPulpApiAvailability -ApiBase $apiBase -AdminPassword $adminPass `
    -Namespace $Namespace -AapRoute $aapRoute
  if (-not $apiAvailability.Available) {
    Write-AapErr "AAP galaxy API not available at $($apiAvailability.ApiUrl)"
    Write-Host "  $($apiAvailability.Reason)"
    Write-Host '  Re-run when ready: aap-demo setup-pah'
    throw 'AAP galaxy API not available'
  }

  if ($Credentials.GalaxyToken) {
    $certifiedRemote = $null
    $validatedRemote = $null

    Write-Host -NoNewline '  Configuring rh-certified remote... '
    $certifiedResult = Set-AapPulpCollectionRemote -ApiBase $apiBase -AdminPassword $adminPass `
      -RemotesUrl $remotesUrl -Name 'rh-certified' `
      -RemoteUrl 'https://console.redhat.com/api/automation-hub/content/published/' `
      -Token $Credentials.GalaxyToken
    $certifiedRemote = Get-AapPulpResourceHref -AdminPassword $adminPass -ResourceUrl $remotesUrl -Name 'rh-certified'
    if (-not $certifiedRemote) {
      $certifiedRemote = Get-AapPulpFirstHref -Data (ConvertFrom-AapPulpJson -Raw $certifiedResult.Body)
    }
    if ($certifiedResult.Ok -and $certifiedRemote) {
      Write-Host 'OK' -ForegroundColor Green
    } else {
      Write-Host 'WARN (configure failed)' -ForegroundColor Yellow
      Write-AapPulpCreateFailureHint -ApiBase $apiBase -AdminPassword $adminPass `
        -Namespace $Namespace -AapRoute $aapRoute -Operation $(if ($certifiedRemote) { 'update' } else { 'create' }) `
        -HttpCode $certifiedResult.HttpCode -ResponseBody $certifiedResult.Body
    }

    Write-Host -NoNewline '  Configuring rh-validated remote... '
    $validatedResult = Set-AapPulpCollectionRemote -ApiBase $apiBase -AdminPassword $adminPass `
      -RemotesUrl $remotesUrl -Name 'rh-validated' `
      -RemoteUrl 'https://console.redhat.com/api/automation-hub/content/validated/' `
      -Token $Credentials.GalaxyToken
    $validatedRemote = Get-AapPulpResourceHref -AdminPassword $adminPass -ResourceUrl $remotesUrl -Name 'rh-validated'
    if (-not $validatedRemote) {
      $validatedRemote = Get-AapPulpFirstHref -Data (ConvertFrom-AapPulpJson -Raw $validatedResult.Body)
    }
    if ($validatedResult.Ok -and $validatedRemote) {
      Write-Host 'OK' -ForegroundColor Green
    } else {
      Write-Host 'WARN (configure failed)' -ForegroundColor Yellow
      Write-AapPulpCreateFailureHint -ApiBase $apiBase -AdminPassword $adminPass `
        -Namespace $Namespace -AapRoute $aapRoute -Operation $(if ($validatedRemote) { 'update' } else { 'create' }) `
        -HttpCode $validatedResult.HttpCode -ResponseBody $validatedResult.Body
    }

    if ($certifiedRemote) {
      Write-Host -NoNewline '  Linking rh-certified remote to repository... '
      $certifiedRepoHref = Get-AapPulpResourceHref -ApiBase $apiBase -AdminPassword $adminPass `
        -ResourceUrl $reposUrl -Name 'rh-certified'
      if ($certifiedRepoHref) {
        $linkBody = (@{ remote = $certifiedRemote } | ConvertTo-Json -Compress)
        $linkUrl = Join-AapPulpUrl -ApiBase $apiBase -Href $certifiedRepoHref
        $linkResult = Invoke-AapPulpMutatingWithRetry -Url $linkUrl -AdminPassword $adminPass `
          -Method 'PATCH' -Body $linkBody
        if ($linkResult.Ok) {
          Write-Host 'OK' -ForegroundColor Green
        } else {
          Write-Host 'WARN (link failed)' -ForegroundColor Yellow
          Write-AapPulpCreateFailureHint -ApiBase $apiBase -AdminPassword $adminPass `
            -Namespace $Namespace -AapRoute $aapRoute -Operation 'link' `
            -HttpCode $linkResult.HttpCode -ResponseBody $linkResult.Body
        }
      } else {
        Write-Host 'WARN (repository not found)' -ForegroundColor Yellow
      }
    }

    if ($validatedRemote) {
      Write-Host -NoNewline '  Linking validated remote to repository... '
      $validatedRepoHref = Get-AapPulpResourceHref -ApiBase $apiBase -AdminPassword $adminPass `
        -ResourceUrl $reposUrl -Name 'validated'
      if ($validatedRepoHref) {
        $linkBody = (@{ remote = $validatedRemote } | ConvertTo-Json -Compress)
        $linkUrl = Join-AapPulpUrl -ApiBase $apiBase -Href $validatedRepoHref
        $linkResult = Invoke-AapPulpMutatingWithRetry -Url $linkUrl -AdminPassword $adminPass `
          -Method 'PATCH' -Body $linkBody
        if ($linkResult.Ok) {
          Write-Host 'OK' -ForegroundColor Green
        } else {
          Write-Host 'WARN (link failed)' -ForegroundColor Yellow
          Write-AapPulpCreateFailureHint -ApiBase $apiBase -AdminPassword $adminPass `
            -Namespace $Namespace -AapRoute $aapRoute -Operation 'link' `
            -HttpCode $linkResult.HttpCode -ResponseBody $linkResult.Body
        }
      } else {
        Write-Host 'WARN (validated repository not found)' -ForegroundColor Yellow
      }
    }

    Write-Host -NoNewline '  Syncing rh-certified... '
    $certifiedRepoHref = Get-AapPulpResourceHref -ApiBase $apiBase -AdminPassword $adminPass `
      -ResourceUrl $reposUrl -Name 'rh-certified'
    if ($certifiedRepoHref) {
      $syncUrl = (Join-AapPulpUrl -ApiBase $apiBase -Href $certifiedRepoHref).TrimEnd('/') + '/sync/'
      $syncResult = Invoke-AapPulpMutatingWithRetry -Url $syncUrl -AdminPassword $adminPass `
        -Method 'POST' -Body '{"mirror":false}'
      if ($syncResult.Ok) {
        Write-Host 'OK (background)' -ForegroundColor Green
      } else {
        Write-Host 'WARN (sync failed)' -ForegroundColor Yellow
        Write-AapPulpCreateFailureHint -ApiBase $apiBase -AdminPassword $adminPass `
          -Namespace $Namespace -AapRoute $aapRoute -Operation 'sync' `
          -HttpCode $syncResult.HttpCode -ResponseBody $syncResult.Body
      }
    } else {
      Write-Host 'WARN (repository not found)' -ForegroundColor Yellow
    }

    if ($validatedRemote) {
      Write-Host -NoNewline '  Syncing validated... '
      $validatedRepoHref = Get-AapPulpResourceHref -ApiBase $apiBase -AdminPassword $adminPass `
        -ResourceUrl $reposUrl -Name 'validated'
      if ($validatedRepoHref) {
        $syncUrl = (Join-AapPulpUrl -ApiBase $apiBase -Href $validatedRepoHref).TrimEnd('/') + '/sync/'
        $syncResult = Invoke-AapPulpMutatingWithRetry -Url $syncUrl -AdminPassword $adminPass `
          -Method 'POST' -Body '{"mirror":false}'
        if ($syncResult.Ok) {
          Write-Host 'OK (background)' -ForegroundColor Green
        } else {
          Write-Host 'WARN (sync failed)' -ForegroundColor Yellow
          Write-AapPulpCreateFailureHint -ApiBase $apiBase -AdminPassword $adminPass `
            -Namespace $Namespace -AapRoute $aapRoute -Operation 'sync' `
            -HttpCode $syncResult.HttpCode -ResponseBody $syncResult.Body
        }
      } else {
        Write-Host 'WARN (validated repository not found)' -ForegroundColor Yellow
      }
    }
  } else {
    Write-AapWarn 'No galaxy token found, skipping console.redhat.com remotes'
  }

  if ($Credentials.PahUrl) {
    if (-not (Test-AapPahConfigFormat -Credentials $Credentials)) {
      Write-AapWarn 'Invalid PAH config, skipping external Private Automation Hub remote'
    } elseif ($Credentials.PahToken) {
      Write-Host -NoNewline '  Configuring Private Automation Hub remote... '
      $pahBody = (@{
          name           = 'external-pah'
          url            = $Credentials.PahUrl
          token          = $Credentials.PahToken
          tls_validation = $true
        } | ConvertTo-Json -Compress)
      $createResult = Invoke-AapPulpMutatingWithRetry -Url $remotesUrl -AdminPassword $adminPass `
        -Method 'POST' -Body $pahBody
      if ($createResult.Ok -and $createResult.Body -match 'pulp_href') {
        Write-Host 'OK' -ForegroundColor Green
      } else {
        Write-Host 'WARN (may already exist or invalid config)' -ForegroundColor Yellow
      }
    }
  }

  Write-AapStep 'PAH configuration complete'
}

function Write-AapSetupPahReminder {
  Write-Host ''
  Write-Host 'To configure Private Automation Hub remotes:'
  Write-Host '  aap-demo setup-pah'
  Write-Host ''
}

function Write-AapCollectionSourcesStatus {
  $creds = Get-AapGalaxyCredentials

  Write-Host ''
  Write-Host 'Collection Sources:'
  Write-Host '-------------------'

  if ($creds.PahUrl) {
    Write-Host ("  {0,-20} {1}" -f 'Private Hub:', $creds.PahUrl)
  }

  if ($creds.GalaxyToken) {
    Write-Host ("  {0,-20} {1}" -f 'Red Hat Certified:', 'console.redhat.com (authenticated)')
  } else {
    Write-Host ("  {0,-20} {1}" -f 'Red Hat Certified:', 'Not configured')
  }

  Write-Host ("  {0,-20} {1}" -f 'Community:', 'galaxy.ansible.com')
}

function Write-AapCollectionSourcesDiagnose {
  param(
    [scriptblock]$WritePass,
    [scriptblock]$WriteInfo
  )

  Write-Host 'Collection Sources:'

  $tokenFile = Get-AapGalaxyTokenFilePath
  if (Test-Path -LiteralPath $tokenFile) {
    & $WritePass 'console.redhat.com token present'
  } else {
    & $WriteInfo 'console.redhat.com token not configured'
    & $WriteInfo 'Get token from: https://console.redhat.com/ansible/automation-hub/token'
    & $WriteInfo 'Then run: aap-demo setup-pah'
  }

  $pahFile = Get-AapPahConfigFilePath
  if (Test-Path -LiteralPath $pahFile) {
    & $WritePass 'Private Automation Hub config present'
    $creds = Get-AapGalaxyCredentials
    if (-not (Test-AapPahConfigFormat -Credentials $creds)) {
      & $WriteInfo 'Fix pah-config.yml before running setup-pah'
    }
  } else {
    & $WriteInfo 'Private Automation Hub not configured (optional)'
  }

  Write-Host ''
}

function Invoke-AapDemoSetupPah {
  [CmdletBinding()]
  param(
    [string]$Namespace = $Script:AapDemoDefaultNamespace
  )

  Write-Host ''
  Write-Host 'Setting up Private Automation Hub...'
  Write-Host ''

  $galaxyToken = Initialize-AapGalaxyToken
  if (-not $galaxyToken) {
    return
  }

  $tokenFile = Get-AapGalaxyTokenFilePath
  Write-AapStep "Galaxy token configured at $tokenFile"
  Write-Host ''

  $creds = Get-AapGalaxyCredentials

  $crc = Get-AapCrcStatus
  if ([string]$crc.crcStatus -ne 'Running') {
    throw 'Cluster is not running - run: aap-demo deploy'
  }

  Initialize-AapKubeEnvironment
  Set-AapIngressCaEnvFromSaved

  if ((Invoke-AapOcQuiet @('cluster-info')) -ne 0) {
    throw 'oc cannot connect to cluster'
  }

  Write-Host 'Configuring AAP Private Automation Hub remotes...'
  Set-AapPahRemotes -Namespace $Namespace -Credentials $creds
}
