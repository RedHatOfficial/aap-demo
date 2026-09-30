function Get-AapAoSetting {
  param(
    [Parameter(Mandatory)][string]$Name,
    [string]$Default = ''
  )

  $value = [Environment]::GetEnvironmentVariable($Name)
  if (-not $value) { $value = Get-AapConfigValue $Name }
  if (-not $value) { $value = $Default }
  return $value
}

function Get-AapAoManifestPath {
  param([Parameter(Mandatory)][string]$Name)
  return Join-Path $Script:AapDemoRepoRoot "addons/ao/manifests/$Name"
}

function New-AapAoManifestFile {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][hashtable]$Replacements
  )
  return Write-AapNativeManifest -ManifestPath (Get-AapAoManifestPath -Name $Name) -Replacements $Replacements
}

function New-AapAoJsonFile {
  param([Parameter(Mandatory)]$Object)
  $path = Join-Path ([IO.Path]::GetTempPath()) ("aap-ao-{0}.json" -f ([guid]::NewGuid().ToString('N')))
  [IO.File]::WriteAllText($path, ($Object | ConvertTo-Json -Depth 20 -Compress), (New-Object Text.UTF8Encoding($false)))
  return $path
}

function Get-AapAoStorageClass {
  $explicit = Get-AapAoSetting -Name 'AO_STORAGE_CLASS'
  if ($explicit) { return $explicit }
  foreach ($candidate in @('nfs-local-rwx', 'topolvm-provisioner', 'crc-csi-hostpath-provisioner', 'standard')) {
    if ((Invoke-AapKubectlNative -Arguments @('get', 'sc', $candidate) -AllowFailure).Success) {
      return $candidate
    }
  }
  throw 'No suitable StorageClass found for Automation Orchestrator. Set AO_STORAGE_CLASS or run aap-demo create.'
}

function Invoke-AapAoSccGrant {
  param(
    [Parameter(Mandatory)][string]$Scc,
    [Parameter(Mandatory)][string]$ServiceAccount,
    [Parameter(Mandatory)][string]$Namespace
  )

  $oc = Get-AapNativeExecutable 'oc'
  $result = Invoke-AapNativeProcess -FilePath $oc -ArgumentList @(
    'adm', 'policy', 'add-scc-to-user', $Scc, "system:serviceaccount:$Namespace`:$ServiceAccount"
  )
  if (-not $result.Success) {
    throw "Failed to grant $Scc SCC to ${Namespace}/${ServiceAccount}: $($result.Stderr.Trim())"
  }
}

function Copy-AapAoPullSecret {
  param([Parameter(Mandatory)][string]$Namespace)

  $name = 'automation-orchestrator-pull-secret'
  $pullPath = Get-AapPullSecretPath
  if ($pullPath) {
    $generated = Invoke-AapKubectlNative -Arguments @(
      'create', 'secret', 'generic', $name, "--from-file=.dockerconfigjson=$pullPath",
      '--type=kubernetes.io/dockerconfigjson', '-n', $Namespace, '--dry-run=client', '-o', 'json'
    )
    $secret = $generated.Stdout | ConvertFrom-Json
  } else {
    $secret = Get-AapKubectlJson -Arguments @('get', 'secret', 'redhat-operators-pull-secret', '-n', $Script:AapDemoDefaultNamespace)
    if (-not $secret) {
      throw 'No pull secret found. Save one under ~/.aap-demo or deploy AAP first.'
    }
    $secret.metadata = @{ name = $name; namespace = $Namespace }
    $secret.PSObject.Properties.Remove('status')
    foreach ($field in @('resourceVersion', 'uid', 'creationTimestamp', 'managedFields', 'ownerReferences', 'annotations')) {
      $secret.metadata.PSObject.Properties.Remove($field)
    }
  }

  $secret.metadata.name = $name
  $secret.metadata.namespace = $Namespace
  $path = New-AapAoJsonFile -Object $secret
  try { Invoke-AapKubectlNative -Arguments @('apply', '-f', $path) | Out-Null }
  finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}

function Ensure-AapAoNamespace {
  param([Parameter(Mandatory)][string]$Namespace)

  if (-not (Invoke-AapKubectlNative -Arguments @('get', 'namespace', $Namespace) -AllowFailure).Success) {
    Invoke-AapKubectlNative -Arguments @('create', 'namespace', $Namespace) | Out-Null
  }
  foreach ($scc in @('anyuid', 'privileged')) {
    Invoke-AapAoSccGrant -Scc $scc -ServiceAccount 'default' -Namespace $Namespace
  }
  if (-not (Invoke-AapKubectlNative -Arguments @('get', 'serviceaccount', 'redhat-operators', '-n', $Namespace) -AllowFailure).Success) {
    Invoke-AapKubectlNative -Arguments @('create', 'serviceaccount', 'redhat-operators', '-n', $Namespace) | Out-Null
  }
  foreach ($scc in @('anyuid', 'privileged')) {
    Invoke-AapAoSccGrant -Scc $scc -ServiceAccount 'redhat-operators' -Namespace $Namespace
  }
}

function Ensure-AapAoCatalogSource {
  param([Parameter(Mandatory)][string]$Namespace)

  $sourceNamespace = Get-AapAoSetting -Name 'AO_CATALOG_NAMESPACE' -Default $Script:AapDemoDefaultNamespace
  $source = Get-AapKubectlJson -Arguments @('get', 'catalogsource', 'redhat-operators', '-n', $sourceNamespace)
  if (-not $source) { throw "AAP redhat-operators CatalogSource not found in $sourceNamespace" }

  $catalog = [ordered]@{
    apiVersion = 'operators.coreos.com/v1alpha1'
    kind = 'CatalogSource'
    metadata = @{ name = 'redhat-operators'; namespace = $Namespace }
    spec = [ordered]@{
      sourceType = 'grpc'
      address = "redhat-operators.$sourceNamespace.svc:50051"
      displayName = 'Red Hat Operators'
      publisher = 'Red Hat'
      updateStrategy = @{ registryPoll = @{ interval = '10m' } }
    }
  }
  $path = New-AapAoJsonFile -Object $catalog
  try { Invoke-AapKubectlNative -Arguments @('apply', '-f', $path) | Out-Null }
  finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }

  $timeout = [int](Get-AapAoSetting -Name 'AO_CATALOG_TIMEOUT' -Default '600')
  for ($i = 0; $i -lt $timeout; $i += 5) {
    $current = Get-AapKubectlJson -Arguments @('get', 'catalogsource', 'redhat-operators', '-n', $Namespace)
    $status = if ($current -and $current.PSObject.Properties['status']) { $current.status } else { $null }
    $connectionState = if ($status -and $status.PSObject.Properties['connectionState']) { $status.connectionState } else { $null }
    if ($connectionState -and $connectionState.lastObservedState -eq 'READY') {
      if ((Invoke-AapKubectlNative -Arguments @('get', 'packagemanifest', 'automation-orchestrator-operator', '-n', $Namespace) -AllowFailure).Success) {
        return
      }
    }
    Start-Sleep -Seconds 5
  }
  throw "AO CatalogSource did not become READY in $Namespace"
}

function Ensure-AapAoCloudNativePg {
  foreach ($scc in @('anyuid', 'privileged')) {
    Invoke-AapAoSccGrant -Scc $scc -ServiceAccount 'cnpg-manager' -Namespace 'cnpg-system'
  }
  $crdsReady = (Invoke-AapKubectlNative -Arguments @('get', 'crd', 'clusters.postgresql.cnpg.io') -AllowFailure).Success -and
    (Invoke-AapKubectlNative -Arguments @('get', 'crd', 'databases.postgresql.cnpg.io') -AllowFailure).Success
  $controller = Invoke-AapKubectlNative -Arguments @('get', 'deployment', 'cnpg-controller-manager', '-n', 'cnpg-system') -AllowFailure
  if ($crdsReady -and $controller.Success) {
    Invoke-AapKubectlNative -Arguments @('wait', '--for=condition=Available', 'deployment/cnpg-controller-manager', '-n', 'cnpg-system', '--timeout=300s') | Out-Null
    return
  }

  $version = Get-AapAoSetting -Name 'CNPG_VERSION' -Default '1.25.1'
  $url = "https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v$version/cnpg-$version.yaml"
  Invoke-AapKubectlNative -Arguments @('apply', '--server-side', '-f', $url) | Out-Null
  Invoke-AapKubectlNative -Arguments @('wait', '--for=condition=Available', 'deployment/cnpg-controller-manager', '-n', 'cnpg-system', '--timeout=300s') | Out-Null
}

function Wait-AapAoOperator {
  param([Parameter(Mandatory)][string]$Namespace)

  $timeout = [int](Get-AapAoSetting -Name 'AO_OPERATOR_TIMEOUT' -Default '900')
  for ($i = 0; $i -lt $timeout; $i += 5) {
    $plans = Get-AapKubectlJson -Arguments @('get', 'installplan', '-n', $Namespace)
    foreach ($plan in @($plans.items)) {
      $planStatus = if ($plan -and $plan.PSObject.Properties['status']) { $plan.status } else { $null }
      $planPhase = if ($planStatus -and $planStatus.PSObject.Properties['phase']) { $planStatus.phase } else { $null }
      if (-not $plan.spec.approved -and $planPhase -ne 'Failed') {
        $approve = '{"spec":{"approved":true}}'
        Invoke-AapKubectlNative -Arguments @('patch', 'installplan', $plan.metadata.name, '-n', $Namespace, '--type=merge', '-p', $approve) | Out-Null
      }
    }

    $csvs = Get-AapKubectlJson -Arguments @('get', 'csv', '-n', $Namespace)
    $csv = @($csvs.items) | Where-Object { $_.metadata.name -match 'automation-orchestrator' } | Select-Object -First 1
    $csvStatus = if ($csv -and $csv.PSObject.Properties['status']) { $csv.status } else { $null }
    if ($csvStatus -and $csvStatus.phase -eq 'Succeeded') {
      if ((Invoke-AapKubectlNative -Arguments @('wait', '--for=condition=Available', 'deployment/automation-orchestrator-operator-controller-manager', '-n', $Namespace, '--timeout=5s') -AllowFailure).Success) {
        return
      }
    }
    Start-Sleep -Seconds 5
  }
  throw 'Automation Orchestrator operator did not become ready before the timeout'
}

function Get-AapAoStatePath { Join-Path $Script:AapDemoConfigDir 'ao-native-state.json' }

function Get-AapAoState {
  $path = Get-AapAoStatePath
  if (Test-Path -LiteralPath $path) { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
  return [pscustomobject]@{}
}

function Save-AapAoState {
  param([Parameter(Mandatory)]$State)
  $path = Get-AapAoStatePath
  Set-AapUtf8Content -Path $path -Value ($State | ConvertTo-Json -Depth 10)
}

function Ensure-AapAoDatabaseSecrets {
  param([Parameter(Mandatory)][string]$Namespace)

  $state = Get-AapAoState
  $postgresPassword = if ($state.PSObject.Properties['PostgresPassword']) { $state.PostgresPassword } else { $null }
  $adminPassword = if ($state.PSObject.Properties['AdminPassword']) { $state.AdminPassword } else { $null }
  if (-not $postgresPassword) {
    $postgresPassword = [guid]::NewGuid().ToString('N')
    $state | Add-Member -NotePropertyName PostgresPassword -NotePropertyValue $postgresPassword
  }
  if (-not $adminPassword) {
    $adminPassword = [guid]::NewGuid().ToString('N')
    $state | Add-Member -NotePropertyName AdminPassword -NotePropertyValue $adminPassword
  }
  Save-AapAoState -State $state

  $secrets = @(
    @{ Name = 'orchestrator-postgres-secret'; Data = @{ database = 'orchestrator'; host = 'orchestrator-postgres-rw'; password = $postgresPassword; port = '5432'; username = 'orchestrator' }; Type = 'kubernetes.io/basic-auth' },
    @{ Name = 'temporal-postgres-secret'; Data = @{ database = 'temporal'; host = 'orchestrator-postgres-rw'; password = $postgresPassword; port = '5432'; username = 'orchestrator' }; Type = 'kubernetes.io/basic-auth' },
    @{ Name = 'temporal-visibility-postgres-secret'; Data = @{ database = 'temporal_visibility'; host = 'orchestrator-postgres-rw'; password = $postgresPassword; port = '5432'; username = 'orchestrator' }; Type = 'kubernetes.io/basic-auth' },
    @{ Name = 'automation-orchestrator-initial-admin-password'; Data = @{ password = $adminPassword }; Type = 'Opaque' }
  )
  foreach ($item in $secrets) {
    $manifest = [ordered]@{
      apiVersion = 'v1'; kind = 'Secret'; metadata = @{ name = $item.Name; namespace = $Namespace }
      type = $item.Type; stringData = $item.Data
    }
    $path = New-AapAoJsonFile -Object $manifest
    try { Invoke-AapKubectlNative -Arguments @('apply', '-f', $path) | Out-Null }
    finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
  }
}

function Wait-AapAoResource {
  param([Parameter(Mandatory)][string]$Namespace)
  $timeout = [int](Get-AapAoSetting -Name 'AO_INSTANCE_TIMEOUT' -Default '1200')
  for ($i = 0; $i -lt $timeout; $i += 10) {
    $instance = Get-AapKubectlJson -Arguments @('get', 'automationorchestrator', 'automation-orchestrator', '-n', $Namespace)
  $conditions = if ($instance -and $instance.PSObject.Properties['status'] -and $instance.status.PSObject.Properties['conditions']) {
    @($instance.status.conditions)
  } else {
    @()
  }
  $ready = @($conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' })
  $degraded = @($conditions | Where-Object { $_.type -eq 'Degraded' -and $_.status -eq 'True' })
    $route = Invoke-AapKubectlNative -Arguments @('get', 'route', 'automation-orchestrator', '-n', $Namespace, '-o', 'jsonpath={.spec.host}') -AllowFailure
    if ($ready.Count -gt 0 -and $degraded.Count -eq 0 -and $route.Success -and $route.Stdout.Trim()) { return $route.Stdout.Trim() }
    Start-Sleep -Seconds 10
  }
  throw 'Automation Orchestrator did not become Ready before the timeout'
}

function ConvertTo-AapAoHostListJson {
  param([Parameter(Mandatory)][string[]]$Hosts)
  return (ConvertTo-Json -InputObject @($Hosts) -Compress)
}

function Set-AapAoLocalAccess {
  param([Parameter(Mandatory)][string]$Namespace)

  $aapRoute = Invoke-AapKubectlNative -Arguments @('get', 'route', 'aap', '-n', $Script:AapDemoDefaultNamespace, '-o', 'jsonpath={.spec.host}') -AllowFailure
  if (-not $aapRoute.Success -or -not $aapRoute.Stdout.Trim()) { return }
  $aapHost = $aapRoute.Stdout.Trim()
  $router = Invoke-AapKubectlNative -Arguments @('get', 'svc', 'router-internal-default', '-n', 'openshift-ingress', '-o', 'jsonpath={.spec.clusterIP}') -AllowFailure
  if (-not $router.Success -or -not $router.Stdout.Trim()) { return }

  $aoRoute = Invoke-AapKubectlNative -Arguments @('get', 'route', 'automation-orchestrator', '-n', $Namespace, '-o', 'jsonpath={.spec.host}') -AllowFailure
  $hosts = @($aapHost)
  if ($aoRoute.Success -and $aoRoute.Stdout.Trim()) { $hosts += $aoRoute.Stdout.Trim() }
  $aliasPatch = @{ spec = @{ template = @{ spec = @{ hostAliases = @(@{ ip = $router.Stdout.Trim(); hostnames = $hosts }) } } } } | ConvertTo-Json -Depth 8 -Compress
  foreach ($deployment in @('automation-orchestrator-backend', 'automation-orchestrator-worker', 'automation-orchestrator-background-worker')) {
    if ((Invoke-AapKubectlNative -Arguments @('get', 'deployment', $deployment, '-n', $Namespace) -AllowFailure).Success) {
      Invoke-AapKubectlNative -Arguments @('patch', 'deployment', $deployment, '-n', $Namespace, '--type=merge', '-p', $aliasPatch) | Out-Null
    }
  }

  $allowedHostsJson = ConvertTo-AapAoHostListJson -Hosts @($aapHost)
  $config = [ordered]@{
    apiVersion = 'v1'; kind = 'ConfigMap'
    metadata = @{ name = 'automation-orchestrator-admin-settings'; namespace = $Namespace; labels = @{ 'app.kubernetes.io/managed-by' = 'aap-demo'; 'app.kubernetes.io/part-of' = 'automation-orchestrator' } }
    data = @{ APP_INTEGRATION_URL_ALLOWED_HOSTS = $allowedHostsJson; APP_WORKFLOW_HTTP_REQUEST_ALLOWED_HOSTS = $allowedHostsJson }
  }
  $path = New-AapAoJsonFile -Object $config
  try { Invoke-AapKubectlNative -Arguments @('apply', '-f', $path) | Out-Null }
  finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
  $crPatch = @{ spec = @{ workflowHttpRequestAllowedHosts = @($aapHost) } } | ConvertTo-Json -Depth 6 -Compress
  Invoke-AapKubectlNative -Arguments @('patch', 'automationorchestrator', 'automation-orchestrator', '-n', $Namespace, '--type=merge', '-p', $crPatch) -AllowFailure | Out-Null
}

function Invoke-AapAoAddonNative {
  param(
    [string[]]$ScriptArgs = @(),
    [string]$Namespace = 'automation-orchestrator'
  )

  $action = if ($ScriptArgs.Count -gt 0) { $ScriptArgs[0].ToLowerInvariant() } else { 'deploy' }
  if ($action -in @('--delete', 'delete')) {
    Write-Host 'Removing Automation Orchestrator...'
    Invoke-AapKubectlNative -Arguments @('delete', 'automationorchestrator', '--all', '-n', $Namespace, '--wait=false') -AllowFailure | Out-Null
    Invoke-AapKubectlNative -Arguments @('delete', 'subscription', 'automation-orchestrator-operator', '-n', $Namespace, '--wait=false') -AllowFailure | Out-Null
    Invoke-AapKubectlNative -Arguments @('delete', 'operatorgroup', 'automation-orchestrator-operator', '-n', $Namespace, '--wait=false') -AllowFailure | Out-Null
    Invoke-AapKubectlNative -Arguments @('delete', 'clusterrolebinding', 'automation-orchestrator-operator-cluster-rolebinding', '--ignore-not-found') -AllowFailure | Out-Null
    Invoke-AapKubectlNative -Arguments @('delete', 'clusterrole', 'automation-orchestrator-operator-cluster-role', '--ignore-not-found') -AllowFailure | Out-Null
    Invoke-AapKubectlNative -Arguments @('delete', 'namespace', $Namespace, '--ignore-not-found', '--wait=false') -AllowFailure | Out-Null
    if ($ScriptArgs -contains '--purge-data') { Remove-Item -LiteralPath (Get-AapAoStatePath) -Force -ErrorAction SilentlyContinue }
    Write-AapStep 'Automation Orchestrator removal requested'
    return
  }

  if (-not (Invoke-AapKubectlNative -Arguments @('get', 'ansiblemcpserver', 'aap-mcp-server', '-n', $Script:AapDemoDefaultNamespace) -AllowFailure).Success) {
    Write-AapStep 'AO requires mcp-server; deploy it first with aap-demo enable mcp-server'
    throw 'AO dependency mcp-server is not deployed'
  }

  Write-Host 'Deploying Automation Orchestrator natively...'
  Ensure-AapAoNamespace -Namespace $Namespace
  Copy-AapAoPullSecret -Namespace $Namespace
  Ensure-AapAoCatalogSource -Namespace $Namespace
  Ensure-AapAoCloudNativePg
  Ensure-AapAoDatabaseSecrets -Namespace $Namespace

  $channel = Get-AapAoSetting -Name 'AO_OPERATOR_CHANNEL' -Default 'stable'
  $operatorSub = New-AapAoManifestFile -Name 'operator-subscription.yaml' -Replacements @{
    '__NAMESPACE__' = $Namespace; '__CATALOG_NAMESPACE__' = $Namespace; '__OPERATOR_CHANNEL__' = $channel
  }
  $operatorRbac = New-AapAoManifestFile -Name 'operator-rbac.yaml' -Replacements @{ '__NAMESPACE__' = $Namespace }
  try {
    Invoke-AapKubectlNative -Arguments @('apply', '-f', $operatorSub) | Out-Null
    Invoke-AapKubectlNative -Arguments @('apply', '-f', $operatorRbac) | Out-Null
  } finally {
    Remove-Item -LiteralPath $operatorSub, $operatorRbac -Force -ErrorAction SilentlyContinue
  }
  Wait-AapAoOperator -Namespace $Namespace

  $postgres = New-AapAoManifestFile -Name 'postgres-cluster.yaml' -Replacements @{
    '__NAMESPACE__' = $Namespace; '__STORAGE_CLASS__' = (Get-AapAoStorageClass)
  }
  try { Invoke-AapKubectlNative -Arguments @('apply', '-f', $postgres) | Out-Null }
  finally { Remove-Item -LiteralPath $postgres -Force -ErrorAction SilentlyContinue }

  $replicas = Get-AapAoSetting -Name 'AO_REPLICA_COUNT' -Default '1'
  $domain = Get-AapClusterAppsDomain -Namespace $Script:AapDemoDefaultNamespace
  $cr = New-AapAoManifestFile -Name 'automationorchestrator-cr.yaml' -Replacements @{
    '__NAMESPACE__' = $Namespace; '__INGRESS_HOST__' = "automation-orchestrator.$domain"
    '__PULL_SECRET_NAME__' = 'automation-orchestrator-pull-secret'; '__AO_REPLICA_COUNT__' = $replicas
  }
  try { Invoke-AapKubectlNative -Arguments @('apply', '-f', $cr) | Out-Null }
  finally { Remove-Item -LiteralPath $cr -Force -ErrorAction SilentlyContinue }

  $route = Wait-AapAoResource -Namespace $Namespace
  Set-AapAoLocalAccess -Namespace $Namespace
  Write-AapStep 'Automation Orchestrator deployed'
  Write-Host "  Route: https://$route"
  $state = Get-AapAoState
  if ($state.AdminPassword) { Write-Host "  Admin password: $($state.AdminPassword)" }
}
