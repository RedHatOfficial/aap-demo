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

  if ($Body) {
    $curlArgs += '-H', 'Content-Type: application/json', '-d', $Body
  }

  $curlArgs += $Url

  $previousEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = (& curl.exe @curlArgs 2>&1 | Out-String).Trim()
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousEap
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
    return "Hub returned HTTP $HttpCode (temporary upstream error - hub may be busy; re-run: aap-demo setup-pah)"
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

function Invoke-AapPulpPostWithRetry {
  param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$AdminPassword,
    [Parameter(Mandatory)][string]$Body,
    [int]$MaxAttempts = 6,
    [int]$DelaySeconds = 8,
    [int]$TimeoutSeconds = 60
  )

  $result = $null
  for ($i = 1; $i -le $MaxAttempts; $i++) {
    $result = Invoke-AapPulpCurl -Url $Url -AdminPassword $AdminPassword -Method 'POST' `
      -Body $Body -TimeoutSeconds $TimeoutSeconds
    if ($result.Ok) { return $result }
    if ($result.HttpCode -eq 400 -and $result.Body -match 'unique|already exists|must be unique') {
      return $result
    }
    if ($result.HttpCode -notin 502, 503, 504) { return $result }
    if ($i -lt $MaxAttempts) {
      Start-Sleep -Seconds $DelaySeconds
    }
  }
  return $result
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
    return $null
  }
  return $result.Body
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

  Write-Host '    Pulp API is reachable; remote create failed' -ForegroundColor Yellow
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
  $raw = Invoke-AapPulpRequest -Url $url -AdminPassword $AdminPassword
  return Get-AapPulpFirstHref -Data (ConvertFrom-AapPulpJson -Raw $raw)
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
    $raw = Invoke-AapPulpRequest -Url $taskUrl -AdminPassword $AdminPassword
    $task = ConvertFrom-AapPulpJson -Raw $raw
    if ($task -and [string]$task.state -eq 'completed') {
      return $true
    }
  }
  return $false
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
    Write-Host -NoNewline '  Configuring rh-certified remote... '
    $certifiedRemote = Get-AapPulpResourceHref -ApiBase $apiBase -AdminPassword $adminPass `
      -ResourceUrl $remotesUrl -Name 'rh-certified'
    $certifiedCreateResult = $null

    if ($certifiedRemote) {
      $patchBody = (@{ token = $Credentials.GalaxyToken } | ConvertTo-Json -Compress)
      $patchUrl = Join-AapPulpUrl -ApiBase $apiBase -Href $certifiedRemote
      $patchRaw = Invoke-AapPulpRequest -Url $patchUrl -AdminPassword $adminPass -Method 'PATCH' -Body $patchBody
      $patchData = ConvertFrom-AapPulpJson -Raw $patchRaw
      if ($patchData -and $patchData.task) {
        Wait-AapPulpTask -ApiBase $apiBase -AdminPassword $adminPass -TaskHref ([string]$patchData.task) | Out-Null
      }
      Write-Host 'OK' -ForegroundColor Green
    } else {
      $createBody = (@{
          name           = 'rh-certified'
          url            = 'https://console.redhat.com/api/automation-hub/content/published/'
          token          = $Credentials.GalaxyToken
          tls_validation = $true
        } | ConvertTo-Json -Compress)
      $certifiedCreateResult = Invoke-AapPulpPostWithRetry -Url $remotesUrl -AdminPassword $adminPass -Body $createBody
      $certifiedRemote = Get-AapPulpFirstHref -Data (ConvertFrom-AapPulpJson -Raw $certifiedCreateResult.Body)

      if ($certifiedRemote) {
        Write-Host 'OK' -ForegroundColor Green
      } else {
        Write-Host 'WARN (create failed)' -ForegroundColor Yellow
        Write-AapPulpCreateFailureHint -ApiBase $apiBase -AdminPassword $adminPass `
          -Namespace $Namespace -AapRoute $aapRoute -HttpCode $certifiedCreateResult.HttpCode `
          -ResponseBody $certifiedCreateResult.Body
      }
    }

    if ($certifiedRemote) {
      $certifiedRepo = Get-AapPulpResourceHref -ApiBase $apiBase -AdminPassword $adminPass `
        -ResourceUrl $reposUrl -Name 'rh-certified'
      if ($certifiedRepo) {
        $linkBody = (@{ remote = $certifiedRemote } | ConvertTo-Json -Compress)
        $linkUrl = Join-AapPulpUrl -ApiBase $apiBase -Href $certifiedRepo
        Invoke-AapPulpRequest -Url $linkUrl -AdminPassword $adminPass -Method 'PATCH' -Body $linkBody | Out-Null
      }
    }

    Write-Host -NoNewline '  Syncing rh-certified... '
    $certifiedRepo = Get-AapPulpResourceHref -ApiBase $apiBase -AdminPassword $adminPass `
      -ResourceUrl $reposUrl -Name 'rh-certified'
    if ($certifiedRepo) {
      $syncUrl = (Join-AapPulpUrl -ApiBase $apiBase -Href $certifiedRepo).TrimEnd('/') + 'sync/'
      Invoke-AapPulpRequest -Url $syncUrl -AdminPassword $adminPass -Method 'POST' -Body '{"mirror":false}' | Out-Null
      Write-Host 'OK (background)' -ForegroundColor Green
    } else {
      Write-Host 'WARN (repository not found)' -ForegroundColor Yellow
    }

    Write-Host -NoNewline '  Configuring rh-validated remote... '
    $validatedRemote = Get-AapPulpResourceHref -ApiBase $apiBase -AdminPassword $adminPass `
      -ResourceUrl $remotesUrl -Name 'rh-validated'
    $validatedCreateResult = $null

    if ($validatedRemote) {
      $patchBody = (@{ token = $Credentials.GalaxyToken } | ConvertTo-Json -Compress)
      $patchUrl = Join-AapPulpUrl -ApiBase $apiBase -Href $validatedRemote
      $patchRaw = Invoke-AapPulpRequest -Url $patchUrl -AdminPassword $adminPass -Method 'PATCH' -Body $patchBody
      $patchData = ConvertFrom-AapPulpJson -Raw $patchRaw
      if ($patchData -and $patchData.task) {
        Wait-AapPulpTask -ApiBase $apiBase -AdminPassword $adminPass -TaskHref ([string]$patchData.task) | Out-Null
      }
      Write-Host 'OK' -ForegroundColor Green
    } else {
      $createBody = (@{
          name           = 'rh-validated'
          url            = 'https://console.redhat.com/api/automation-hub/content/validated/'
          token          = $Credentials.GalaxyToken
          tls_validation = $true
        } | ConvertTo-Json -Compress)
      $validatedCreateResult = Invoke-AapPulpCurl -Url $remotesUrl -AdminPassword $adminPass `
        -Method 'POST' -Body $createBody
      $validatedRemote = Get-AapPulpFirstHref -Data (ConvertFrom-AapPulpJson -Raw $validatedCreateResult.Body)

      if ($validatedRemote) {
        Write-Host 'OK' -ForegroundColor Green
      } else {
        Write-Host 'WARN (create failed)' -ForegroundColor Yellow
        Write-AapPulpCreateFailureHint -ApiBase $apiBase -AdminPassword $adminPass `
          -Namespace $Namespace -AapRoute $aapRoute -HttpCode $validatedCreateResult.HttpCode `
          -ResponseBody $validatedCreateResult.Body
      }
    }

    if ($validatedRemote) {
      Write-Host -NoNewline '  Linking validated remote to repository... '
      $validatedRepoHref = Get-AapPulpResourceHref -ApiBase $apiBase -AdminPassword $adminPass `
        -ResourceUrl $reposUrl -Name 'validated'
      if ($validatedRepoHref) {
        $linkBody = (@{ remote = $validatedRemote } | ConvertTo-Json -Compress)
        $linkUrl = Join-AapPulpUrl -ApiBase $apiBase -Href $validatedRepoHref
        Invoke-AapPulpRequest -Url $linkUrl -AdminPassword $adminPass -Method 'PATCH' -Body $linkBody | Out-Null
        Write-Host 'OK' -ForegroundColor Green

        Write-Host -NoNewline '  Syncing validated... '
        $syncUrl = (Join-AapPulpUrl -ApiBase $apiBase -Href $validatedRepoHref).TrimEnd('/') + 'sync/'
        Invoke-AapPulpRequest -Url $syncUrl -AdminPassword $adminPass -Method 'POST' -Body '{"mirror":false}' | Out-Null
        Write-Host 'OK (background)' -ForegroundColor Green
      } else {
        Write-Host 'WARN (validated repository not found)' -ForegroundColor Yellow
      }
    }
  } else {
    Write-AapWarn 'No galaxy token found, skipping console.redhat.com remotes'
  }

  if ($Credentials.PahUrl -and $Credentials.PahToken) {
    Write-Host -NoNewline '  Configuring Private Automation Hub remote... '
    $pahBody = (@{
        name           = 'external-pah'
        url            = $Credentials.PahUrl
        token          = $Credentials.PahToken
        tls_validation = $true
      } | ConvertTo-Json -Compress)
    $createRaw = Invoke-AapPulpRequest -Url $remotesUrl -AdminPassword $adminPass -Method 'POST' -Body $pahBody
    if ($createRaw -match 'pulp_href') {
      Write-Host 'OK' -ForegroundColor Green
    } else {
      Write-Host 'WARN (may already exist or invalid config)' -ForegroundColor Yellow
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
  if (-not (Test-AapPahConfigFormat -Credentials $creds)) {
    throw 'Invalid PAH config'
  }

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
