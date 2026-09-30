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

function Invoke-AapGitBash {
  param(
    [Parameter(Mandatory)][string]$Command,
    [string[]]$Arguments = @(),
    [hashtable]$Environment = @{}
  )

  $bash = Get-AapGitBashExecutable
  $result = Invoke-AapNativeProcess -FilePath $bash -ArgumentList (@('-lc', $Command, '--') + @($Arguments)) `
    -Environment $Environment -WorkingDirectory $Script:AapDemoRepoRoot
  return $result
}

function Invoke-AapGitBashCli {
  param(
    [Parameter(Mandatory)][string[]]$Arguments
  )

  $result = Invoke-AapGitBash -Command './aap-demo.sh "$@"' -Arguments $Arguments
  if ($result.Output) { Write-Host $result.Output.TrimEnd() }
  return $result
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
