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

  if (Test-AapGitBashAvailable) { return }

  $bashAddons = Get-AapBashDelegatedAddons
  $addonList = if ($bashAddons.Count -gt 0) { $bashAddons -join ', ' } else { '(see addons/ in repo)' }
  $prefix = if ($Addon) { "Addon '$Addon'" } else { 'This command' }
  $wslStub = Join-Path $env:SystemRoot 'System32\bash.exe'
  $wslNote = if ((Test-Path -LiteralPath $wslStub) -and (Get-Command bash -ErrorAction SilentlyContinue)) {
@"

Note: bash on PATH resolves to the WSL stub ($wslStub).
aap-demo requires Git for Windows, not WSL.
"@
  } else { '' }

  throw @"
$prefix requires Git Bash (Git for Windows).

Install Git for Windows:
  winget install --id Git.Git -e --source winget

Then open a new PowerShell window.$wslNote

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

  if ($null -eq $ScriptArgs) { $ScriptArgs = @() }

  Assert-AapBashAvailable -Addon $Addon

  $deploySh = Join-Path $Script:AapDemoRepoRoot "addons/$Addon/deploy.sh"
  if (-not (Test-Path -LiteralPath $deploySh)) {
    throw "Addon '$Addon' has no deploy.sh"
  }

  Initialize-AapBashAddonEnvironment

  $bashPath = Get-AapGitBashExecutable
  if (-not $bashPath) {
    throw "Git Bash not found. Install Git for Windows: winget install --id Git.Git -e --source winget"
  }

  & $bashPath $deploySh @ScriptArgs
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

  Write-AapStep 'AAP MCP Server deployed'
  Write-Host ''
  Write-Host "  Status:  oc get ansiblemcpserver -n $Namespace"
  Write-Host "  Logs:    oc logs -n $Namespace -l app.kubernetes.io/name=aap-mcp-server"
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

  if ($null -eq $ScriptArgs) { $ScriptArgs = @() }

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

function Get-AapAoEapAdminPassword {
  $aoNs = 'automation-orchestrator'
  foreach ($secretName in @(
    'automation-orchestrator-initial-admin-password',
    'automation-orchestrator-admin-password'
  )) {
    $password = Get-AapSecretPassword -Namespace $aoNs -SecretName $secretName
    if ($password) { return $password }
  }

  $secrets = Invoke-AapOcCapture @('get', 'secret', '-n', $aoNs, '-o', 'name')
  if ($secrets.ExitCode -ne 0 -or -not $secrets.Output) { return $null }
  foreach ($line in $secrets.Lines) {
    if ($line -notmatch 'admin-password') { continue }
    $secretName = ($line -replace '^secret/', '').Trim()
    $password = Get-AapSecretPassword -Namespace $aoNs -SecretName $secretName
    if ($password) { return $password }
  }
  return $null
}

function Get-AapAoEapRouteHost {
  return Get-AapRouteHost -Namespace 'automation-orchestrator'
}

function Get-AapAapAccessEntry {
  param([Parameter(Mandatory)][string]$Namespace)

  $password = Get-AapAdminPassword -Namespace $Namespace
  if (-not $password) { return $null }

  $routeHost = Get-AapRouteHost -Namespace $Namespace
  return [pscustomobject]@{
    Title = "AAP ($Namespace)"
    Url = if ($routeHost) { "https://$routeHost" } else { $null }
    Username = 'admin'
    Password = $password
    PasswordHint = $null
    ProgressNote = $null
  }
}

function Get-AapAoEapAccessEntry {
  if ((Invoke-AapOcQuiet @('get', 'namespace', 'automation-orchestrator')) -ne 0) {
    return $null
  }

  $routeHost = Get-AapAoEapRouteHost
  $password = Get-AapAoEapAdminPassword

  return [pscustomobject]@{
    Title = 'Automation Orchestrator (ao)'
    Url = if ($routeHost) { "https://$routeHost" } else { $null }
    Username = 'admin'
    Password = $password
    PasswordHint = if ($password) { $null } else {
      'oc get secret -n automation-orchestrator -o name | Select-String admin-password'
    }
    ProgressNote = if (-not $routeHost -and -not $password) {
      '(deployment may still be in progress)'
    } else { $null }
  }
}

function Get-AapApmeEapAccessEntry {
  $apmeNs = 'apme'
  if ((Invoke-AapOcQuiet @('get', 'namespace', $apmeNs)) -ne 0) { return $null }

  $routeHost = Get-AapRouteHost -Namespace $apmeNs -RouteName 'redhat-rhaap-portal'
  if (-not $routeHost) { return $null }

  $aapPassword = Get-AapAdminPassword -Namespace $Script:AapDemoDefaultNamespace
  return [pscustomobject]@{
    Title = 'APME Portal (apme-eap)'
    Url = "https://$routeHost"
    Username = 'admin'
    Password = $aapPassword
    PasswordHint = if ($aapPassword) { $null } else {
      'Uses AAP OAuth — retrieve AAP admin password from the AAP entry above'
    }
    Notes = @('Sign in with AAP admin credentials (AAP OAuth)')
  }
}

function Get-AapMcpServerAccessEntry {
  param([string]$Namespace = $Script:AapDemoDefaultNamespace)

  $mcpHost = Get-AapMcpServerRouteHost -Namespace $Namespace
  if (-not $mcpHost) { return $null }

  $aapHost = Get-AapRouteHost -Namespace $Namespace
  $notes = @('Connect your MCP client to the endpoint above')
  if ($aapHost) {
    $notes += "Authenticate with AAP credentials at https://$aapHost"
  }

  return [pscustomobject]@{
    Title = 'AAP MCP Server'
    Url = "https://$mcpHost/mcp"
    Username = $null
    Password = $null
    PasswordHint = $null
    Notes = $notes
  }
}

function Get-AapPortalAccessEntry {
  param([string]$Namespace = $Script:AapDemoDefaultNamespace)

  $portalHost = Get-AapPortalRouteHost -AapNamespace $Namespace
  if (-not $portalHost) { return $null }

  $password = Get-AapAdminPassword -Namespace $Namespace
  return [pscustomobject]@{
    Title = 'Developer Portal (portal)'
    Url = "https://$portalHost"
    Username = 'admin'
    Password = $password
    PasswordHint = if ($password) { $null } else {
      "oc get secret -n $Namespace aap-admin-password -o jsonpath='{.data.password}'"
    }
    Notes = @('Sign in with AAP admin credentials when the portal prompts you')
  }
}

function Get-AapAddonAccessEntries {
  param(
    [Parameter(Mandatory)][string]$Addon,
    [string]$Namespace = $Script:AapDemoDefaultNamespace
  )

  switch ($Addon) {
    'mcp-server' {
      $entry = Get-AapMcpServerAccessEntry -Namespace $Namespace
      $entries = @()
      if ($entry) { $entries += $entry }
      $aapEntry = Get-AapAapAccessEntry -Namespace $Namespace
      if ($aapEntry -and $aapEntry.Password) { $entries += $aapEntry }
      return $entries
    }
    'portal' {
      $entry = Get-AapPortalAccessEntry -Namespace $Namespace
      if ($entry) { return @($entry) }
      return @()
    }
    'ao' {
      $entry = Get-AapAoEapAccessEntry
      if ($entry) { return @($entry) }
      return @()
    }
    'ao-eap' {
      $entry = Get-AapAoEapAccessEntry
      if ($entry) { return @($entry) }
      return @()
    }
    'apme-eap' {
      $entry = Get-AapApmeEapAccessEntry
      if ($entry) { return @($entry) }
      return @()
    }
    default { return @() }
  }
}

function Get-AapDeployedAccessEntries {
  param([string]$Namespace = $Script:AapDemoDefaultNamespace)

  $entries = @()
  $aapNsResult = Invoke-AapOcCapture @('get', 'aap', '-A', '--no-headers')
  $aapNamespaces = if ($aapNsResult.ExitCode -eq 0 -and $aapNsResult.Output -notmatch '^No resources found') {
    $aapNsResult.Lines | ForEach-Object { ($_ -split '\s+')[0] } | Sort-Object -Unique
  } else { @() }

  foreach ($ns in $aapNamespaces) {
    $entry = Get-AapAapAccessEntry -Namespace $ns
    if ($entry) { $entries += $entry }
  }

  $aoEntry = Get-AapAoEapAccessEntry
  if ($aoEntry) { $entries += $aoEntry }

  return $entries
}

function Write-AapAccessEntry {
  param($Entry)

  if (-not $Entry) { return }
  if ($Entry.Title) { Write-Host $Entry.Title }
  if ($Entry.Url) { Write-Host "  URL:      $($Entry.Url)" }
  if ($Entry.Username) { Write-Host "  Username: $($Entry.Username)" }
  if ($Entry.Password) {
    Write-Host "  Password: $($Entry.Password)"
  } elseif ($Entry.PasswordHint) {
    Write-Host "  Password: $($Entry.PasswordHint)"
  }
  if ($Entry.ProgressNote) { Write-Host "  $($Entry.ProgressNote)" }
  $notes = @()
  if ($null -ne $Entry.PSObject.Properties['Notes']) {
    $notes = @($Entry.Notes)
  }
  foreach ($note in $notes) {
    if ($note) { Write-Host "  $note" }
  }
  Write-Host ''
}

function Write-AapCredentialsStatus {
  param([string]$Namespace = $Script:AapDemoDefaultNamespace)

  $entries = @(Get-AapDeployedAccessEntries -Namespace $Namespace)
  if ($entries.Count -eq 0) { return }

  Write-Host ''
  Write-Host 'Credentials:'
  Write-Host '------------'
  foreach ($entry in $entries) {
    Write-AapAccessEntry -Entry $entry
  }
}

function Write-AapAddonAccessInfo {
  param(
    [Parameter(Mandatory)][string]$Addon,
    [string]$Namespace = $Script:AapDemoDefaultNamespace
  )

  if ($Addon -eq 'portal') { return }

  $entries = @(Get-AapDeployedAccessEntries -Namespace $Namespace)
  foreach ($addonEntry in @(Get-AapAddonAccessEntries -Addon $Addon -Namespace $Namespace)) {
    $duplicate = $false
    foreach ($existing in $entries) {
      if ($existing.Title -eq $addonEntry.Title) {
        $duplicate = $true
        break
      }
    }
    if (-not $duplicate) {
      $entries += $addonEntry
    }
  }
  if ($entries.Count -eq 0) { return }

  Write-Host ''
  Write-Host 'Credentials:'
  Write-Host '------------'
  foreach ($entry in $entries) {
    Write-AapAccessEntry -Entry $entry
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
