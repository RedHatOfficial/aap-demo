function Get-AapNativeExecutable {
  param([Parameter(Mandatory)][string]$Name)

  $command = Get-Command $Name -ErrorAction SilentlyContinue
  if (-not $command) {
    throw "'$Name' is required for this native addon. Install it and ensure it is on PATH."
  }
  return $command.Source
}

function Get-AapGitBashExecutable {
  $candidates = @(
    (Join-Path ${env:ProgramFiles} 'Git\bin\bash.exe'),
    (Join-Path ${env:LOCALAPPDATA} 'Programs\Git\bin\bash.exe'),
    (Get-Command 'bash.exe' -ErrorAction SilentlyContinue).Source
  )

  foreach ($candidate in $candidates) {
    if (-not $candidate -or -not (Test-Path -LiteralPath $candidate)) { continue }
    if ($candidate -match '(?i)[\\/]Windows[\\/]System32[\\/]bash\.exe$') { continue }
    return $candidate
  }

  throw 'Git Bash is required for Windows addon commands. Install Git for Windows and ensure bash.exe is available.'
}

function Get-AapGitBashEnvironment {
  param([hashtable]$Environment = @{})

  # Git Bash needs the normal Windows runtime values, while addon commands only
  # need the documented aap-demo settings. Do not pass the caller's complete
  # environment: that would expose unrelated credentials to every Bash addon.
  $allowedNames = @(
    'Path', 'HOME', 'USERPROFILE', 'HOMEDRIVE', 'HOMEPATH', 'TEMP', 'TMP',
    'SystemRoot', 'WINDIR', 'ComSpec', 'PATHEXT', 'ProgramFiles',
    'ProgramFiles(x86)', 'ProgramW6432', 'LOCALAPPDATA', 'APPDATA',
    'CommonProgramFiles', 'CommonProgramFiles(x86)', 'CommonProgramW6432',
    'PUBLIC', 'OS', 'PROCESSOR_ARCHITECTURE', 'PROCESSOR_ARCHITEW6432',
    'PROCESSOR_IDENTIFIER', 'PROCESSOR_LEVEL', 'PROCESSOR_REVISION',
    'NUMBER_OF_PROCESSORS', 'USERNAME', 'USERDOMAIN', 'COMPUTERNAME',
    'TERM', 'TERM_PROGRAM', 'LANG', 'LC_ALL', 'CI', 'GIT_CONFIG_NOSYSTEM',
    'GIT_SSH', 'GIT_SSH_COMMAND', 'GIT_ASKPASS', 'SSH_AUTH_SOCK',
    'AAP_DEMO_CONFIG', 'AAP_DEMO_DIR', 'AAP_DEMO_GIT_BRANCH',
    'AAP_DEMO_SKIP_CACHE', 'AAP_DEMO_WIRE_AFTER_DEPLOY', 'CRC_CPUS',
    'CRC_MEMORY', 'CRC_DISK', 'CRC_PV_SIZE', 'CRC_PRESET', 'CRC_VERSION',
    'CRC_SSH_KEY', 'NFS_BACKING_STORAGE_SIZE', 'NAMESPACE', 'QUIET', 'FORCE',
    'KUBECONFIG', 'PULL_SECRET_PATH', 'AAP_DEMO_TRUST_CA', 'SKIP_COLLECTIONS',
    'GALAXY_TOKEN_FILE', 'PAH_CONFIG_FILE', 'AO_LLM_PROVIDER',
    'AO_LLM_BASE_URL', 'AO_LLM_MODEL', 'AO_LLM_API_KEY_FILE', 'OPENAI_API_KEY',
    'AO_IMPORT_DEMOS', 'AO_DEMOS_REF', 'AO_DEMOS_REPOSITORY',
    'AO_INSTALL_PLAN_APPROVAL', 'AO_OPERATOR_CHANNEL', 'AO_OPERATOR_TIMEOUT',
    'AO_CATALOG_TIMEOUT', 'AO_INSTANCE_TIMEOUT', 'AO_STORAGE_CLASS',
    'AO_REPLICA_COUNT', 'AO_PULL_SECRET_NAME', 'AO_NAMESPACE', 'AO_STATE_DIR',
    'AO_AGENT_CREDENTIAL_ID', 'AO_AGENT_INTEGRATION_ID', 'OLLAMA_MODEL',
    'OLLAMA_STORAGE_CLASS', 'OLLAMA_STORAGE_SIZE', 'OLLAMA_ROLLOUT_TIMEOUT'
  )

  $result = @{}
  $current = [Environment]::GetEnvironmentVariables()
  foreach ($entry in $current.GetEnumerator()) {
    $name = [string]$entry.Key
    if ($allowedNames -contains $name) {
      $result[$name] = [string]$entry.Value
    }
  }
  foreach ($key in $Environment.Keys) {
    # Explicit values are intentional caller input (for example, test hooks or
    # addon-specific paths), so preserve them exactly.
    $result[[string]$key] = [string]$Environment[$key]
  }
  return $result
}

function Invoke-AapGitBash {
  param(
    [Parameter(Mandatory)][string]$Command,
    [string[]]$Arguments = @(),
    [hashtable]$Environment = @{},
    [switch]$Interactive
  )

  $bash = Get-AapGitBashExecutable
  $bashEnvironment = Get-AapGitBashEnvironment -Environment $Environment
  if ($Interactive) { $bashEnvironment.AAP_DEMO_INTERACTIVE = '1' }
  $result = Invoke-AapNativeProcess -FilePath $bash -ArgumentList (@('-lc', $Command, '--') + @($Arguments)) `
    -Environment $bashEnvironment -WorkingDirectory $Script:AapDemoRepoRoot `
    -ClearEnvironment -Interactive:$Interactive
  return $result
}

function Get-AapGitBashCliEnvironment {
  param(
    [Parameter(Mandatory)][string[]]$Arguments,
    [hashtable]$Environment = @{}
  )

  $bashEnvironment = @{}
  $isPortalEnable = $Arguments.Count -ge 2 -and
    $Arguments[0].ToLowerInvariant() -eq 'enable' -and
    $Arguments[1].ToLowerInvariant() -eq 'portal'
  if ($isPortalEnable) {
    foreach ($name in @('REGISTRY_USERNAME', 'REGISTRY_PASSWORD')) {
      $value = [Environment]::GetEnvironmentVariable($name)
      if ($null -ne $value) { $bashEnvironment[$name] = $value }
    }
  }
  foreach ($key in $Environment.Keys) { $bashEnvironment[$key] = $Environment[$key] }
  return $bashEnvironment
}

function Invoke-AapGitBashCli {
  param(
    [Parameter(Mandatory)][string[]]$Arguments,
    [switch]$Interactive
  )

  $bashEnvironment = Get-AapGitBashCliEnvironment -Arguments $Arguments
  $result = Invoke-AapGitBash -Command './aap-demo.sh "$@"' -Arguments $Arguments `
    -Environment $bashEnvironment -Interactive:$Interactive
  if ($result.Output) { Write-Host $result.Output.TrimEnd() }
  return $result
}

function Invoke-AapGitBashInteractive {
  param(
    [Parameter(Mandatory)][string]$Command,
    [string[]]$Arguments = @(),
    [hashtable]$Environment = @{}
  )

  return Invoke-AapGitBash -Command $Command -Arguments $Arguments -Environment $Environment -Interactive
}

function Get-AapKubernetesExecutable {
  $kubectl = Get-Command 'kubectl' -ErrorAction SilentlyContinue
  if ($kubectl) { return $kubectl.Source }

  $oc = Get-Command 'oc' -ErrorAction SilentlyContinue
  if ($oc) { return $oc.Source }

  throw "'kubectl' or 'oc' is required for native addons. Install one and ensure it is on PATH."
}

function Invoke-AapKubectlNative {
  param(
    [Parameter(Mandatory)][string[]]$Arguments,
    [switch]$AllowFailure
  )

  $kubectl = Get-AapKubernetesExecutable
  $result = Invoke-AapNativeProcess -FilePath $kubectl -ArgumentList $Arguments
  if (-not $result.Success -and -not $AllowFailure) {
    $detail = if ($result.Stderr) { $result.Stderr.Trim() } else { $result.Stdout.Trim() }
    throw "kubectl $($Arguments -join ' ') failed (exit $($result.ExitCode)): $detail"
  }
  return $result
}

function Get-AapKubectlJson {
  param([Parameter(Mandatory)][string[]]$Arguments)

  $result = Invoke-AapKubectlNative -Arguments ($Arguments + @('-o', 'json'))
  if (-not $result.Stdout) { return $null }
  return $result.Stdout | ConvertFrom-Json
}

function Write-AapNativeManifest {
  param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][hashtable]$Replacements
  )

  $manifest = Get-Content -LiteralPath $ManifestPath -Raw
  foreach ($key in $Replacements.Keys) {
    $manifest = $manifest.Replace([string]$key, [string]$Replacements[$key])
  }
  $temp = Join-Path ([IO.Path]::GetTempPath()) ("aap-native-{0}.yaml" -f ([guid]::NewGuid().ToString('N')))
  [IO.File]::WriteAllText($temp, $manifest, (New-Object Text.UTF8Encoding($false)))
  return $temp
}

function Get-AapClusterAppsDomain {
  param([string]$Namespace = $Script:AapDemoDefaultNamespace)

  $route = Invoke-AapKubectlNative -Arguments @(
    'get', 'route', 'aap', '-n', $Namespace, '-o', 'jsonpath={.spec.host}'
  ) -AllowFailure
  if ($route.Success -and $route.Stdout.Trim()) {
    return ($route.Stdout.Trim() -split '\.', 2)[1]
  }
  return 'apps.127.0.0.1.nip.io'
}

function ConvertTo-AapDurationSeconds {
  param([Parameter(Mandatory)][string]$Value)

  $remaining = $Value.Trim()
  $total = 0
  while ($remaining.Length -gt 0) {
    if ($remaining -notmatch '^([0-9]+)([smh])') {
      throw "Duration must use values such as 15m or 1h30m (got '$Value')"
    }
    $amount = [int]$Matches[1]
    switch ($Matches[2]) {
      's' { $total += $amount }
      'm' { $total += $amount * 60 }
      'h' { $total += $amount * 3600 }
    }
    $remaining = $remaining.Substring($Matches[0].Length)
  }
  if ($total -lt 1) { throw "Duration must be greater than zero (got '$Value')" }
  return $total
}

function Invoke-AapOllamaAddonNative {
  param(
    [string[]]$ScriptArgs = @(),
    [string]$Namespace = $Script:AapDemoDefaultNamespace
  )

  $action = if ($ScriptArgs.Count -gt 0) { $ScriptArgs[0].ToLowerInvariant() } else { 'deploy' }
  if ($action -in @('--delete', 'delete')) {
    Write-Host 'Removing Ollama...'
    Invoke-AapKubectlNative -Arguments @('delete', 'namespace', 'aap-demo-ollama', '--ignore-not-found') -AllowFailure | Out-Null
    Invoke-AapKubectlNative -Arguments @('delete', 'clusterrolebinding', 'aap-demo-ollama-anyuid', '--ignore-not-found') -AllowFailure | Out-Null
    Write-AapStep 'Ollama removed'
    return
  }

  $storageClass = if ($env:OLLAMA_STORAGE_CLASS) { $env:OLLAMA_STORAGE_CLASS } else { $null }
  if (-not $storageClass) {
    foreach ($candidate in @('topolvm-provisioner', 'crc-csi-hostpath-provisioner', 'standard')) {
      if ((Invoke-AapKubectlNative -Arguments @('get', 'sc', $candidate) -AllowFailure).Success) {
        $storageClass = $candidate
        break
      }
    }
  }
  if (-not $storageClass) {
    throw 'No suitable StorageClass found for Ollama. Set OLLAMA_STORAGE_CLASS or run aap-demo create.'
  }

  $model = if ($env:OLLAMA_MODEL) { $env:OLLAMA_MODEL } else { 'qwen2.5:3b' }
  $size = if ($env:OLLAMA_STORAGE_SIZE) { $env:OLLAMA_STORAGE_SIZE } else { '10Gi' }
  $domain = Get-AapClusterAppsDomain -Namespace $Namespace
  $timeout = if ($env:OLLAMA_ROLLOUT_TIMEOUT) { $env:OLLAMA_ROLLOUT_TIMEOUT } else { '15m' }
  $deadline = ConvertTo-AapDurationSeconds -Value $timeout

  $manifestPath = Join-Path $Script:AapDemoRepoRoot 'addons/ollama/ollama.yaml'
  $temp = Write-AapNativeManifest -ManifestPath $manifestPath -Replacements @{
    'ollama.apps.127.0.0.1.nip.io' = "ollama.$domain"
    '__STORAGE_CLASS__' = $storageClass
    '__STORAGE_SIZE__' = $size
    '__PROGRESS_DEADLINE_SECONDS__' = $deadline
  }
  try {
    Write-Host 'Deploying Ollama (CPU-only)...'
    Invoke-AapKubectlNative -Arguments @('apply', '-f', $temp) | Out-Null
  } finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
  }

  Invoke-AapKubectlNative -Arguments @(
    'rollout', 'status', 'deployment/ollama', '-n', 'aap-demo-ollama', "--timeout=$timeout"
  ) | Out-Null

  $pods = Get-AapKubectlJson -Arguments @(
    'get', 'pods', '-n', 'aap-demo-ollama', '-l', 'app=ollama'
  )
  $pod = @($pods.items | Sort-Object { $_.metadata.creationTimestamp } -Descending | Select-Object -First 1)
  if (-not $pod) { throw 'Ollama pod was not found after rollout' }
  Invoke-AapKubectlNative -Arguments @(
    'wait', '--for=condition=ready', "pod/$($pod.metadata.name)", '-n', 'aap-demo-ollama', '--timeout=120s'
  ) | Out-Null
  Invoke-AapKubectlNative -Arguments @(
    'exec', '-n', 'aap-demo-ollama', $pod.metadata.name, '--', 'ollama', 'pull', $model
  ) | Out-Null

  Write-AapStep 'Ollama deployed'
  Write-Host "  Route:      https://ollama.$domain"
  Write-Host "  OpenAI API: https://ollama.$domain/v1"
  Write-Host "  Model:      $model"
}

function Invoke-AapLocalCacheAddonNative {
  param([string[]]$ScriptArgs = @())

  $action = if ($ScriptArgs.Count -gt 0) { $ScriptArgs[0].ToLowerInvariant() } else { 'save' }
  $preset = Get-AapConfigValue 'CRC_PRESET'
  if (-not $preset) { $preset = 'microshift' }
  $cacheDir = Join-Path $Script:AapDemoConfigDir "local-cache\$preset"

  switch ($action) {
    { $_ -in @('clear', 'delete', '--delete') } {
      if (Test-Path -LiteralPath $cacheDir) {
        Remove-Item -LiteralPath $cacheDir -Recurse -Force
        Write-AapStep "Cleared image cache for $preset"
      } else {
        Write-Host "No image cache found for $preset"
      }
      return
    }
    'validate' {
      if (-not (Test-Path -LiteralPath $cacheDir)) { throw "No image cache found for $preset" }
      $archives = @(Get-ChildItem -LiteralPath $cacheDir -Filter '*.tar' -File)
      if ($archives.Count -eq 0) { throw "No cached image archives found for $preset" }
      Write-AapStep "Found $($archives.Count) cached image archive(s)"
      return
    }
    default {
      throw "Native local-cache '$action' is not implemented yet. Native clear and validate are supported on this branch."
    }
  }
}
