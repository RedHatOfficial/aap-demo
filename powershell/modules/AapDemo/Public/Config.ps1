# Config file and environment handling

function Initialize-AapDemoConfig {
    param(
        [hashtable]$CliOverrides = @{},
        [string]$KubectlContext = '',
        [string]$KubectlKubeconfig = ''
    )

    $script:AapDemoConfigPath = if ($env:AAP_DEMO_CONFIG) { $env:AAP_DEMO_CONFIG } else { Join-Path (Get-AapDemoHome) 'config' }
    $script:AapDemoNamespace = 'aap-operator'
    $script:AapDemoQuiet = 'false'
    $script:AapDemoForce = 'false'
    $script:AapDemoInfraType = 'crc'
    $script:AapDemoKubectlContext = $KubectlContext
    $script:AapDemoKubectlKubeconfig = $KubectlKubeconfig

    if (Test-Path $script:AapDemoConfigPath) {
        Get-Content $script:AapDemoConfigPath | ForEach-Object {
            $line = $_.Trim()
            if (-not $line -or $line.StartsWith('#')) { return }
            $eq = $line.IndexOf('=')
            if ($eq -lt 1) { return }
            $key = $line.Substring(0, $eq).Trim()
            $value = $line.Substring($eq + 1).Trim()
            if (-not $CliOverrides.ContainsKey($key) -and -not (Get-Item -Path "Env:$key" -ErrorAction SilentlyContinue)) {
                Set-Item -Path "Env:$key" -Value $value
            }
        }
    }

    if ($env:NAMESPACE) { $script:AapDemoNamespace = $env:NAMESPACE }
    if ($env:QUIET) { $script:AapDemoQuiet = $env:QUIET.ToLower() }
    if ($env:FORCE) { $script:AapDemoForce = $env:FORCE.ToLower() }
    if ($env:INFRA_TYPE) { $script:AapDemoInfraType = $env:INFRA_TYPE }

    foreach ($key in $CliOverrides.Keys) {
        Set-Item -Path "Env:$key" -Value $CliOverrides[$key]
        switch ($key) {
            'NAMESPACE' { $script:AapDemoNamespace = $CliOverrides[$key] }
            'QUIET' { $script:AapDemoQuiet = $CliOverrides[$key].ToLower() }
            'FORCE' { $script:AapDemoForce = $CliOverrides[$key].ToLower() }
        }
    }
}

function Get-AapDemoConfigValue {
    param([Parameter(Mandatory)][string]$Key)
    $path = $script:AapDemoConfigPath
    if (-not (Test-Path $path)) { return $null }
    foreach ($line in Get-Content $path) {
        if ($line -match "^\s*$Key=(.*)$") { return $Matches[1].Trim() }
    }
    return $null
}

function Set-AapDemoConfigValue {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )
    $path = $script:AapDemoConfigPath
    $dir = Split-Path $path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $lines = @()
    $found = $false
    if (Test-Path $path) {
        $lines = Get-Content $path
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "^\s*$([regex]::Escape($Key))=") {
                $lines[$i] = "${Key}=${Value}"
                $found = $true
            }
        }
    }
    if (-not $found) { $lines += "${Key}=${Value}" }
    Set-Content -Path $path -Value $lines
}

function Get-AapDemoSavedAddons {
    $raw = Get-AapDemoConfigValue -Key 'ADDONS'
    if (-not $raw) { return @() }
    return $raw.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

function Get-AapDemoPullSecretPath {
    $candidates = @(
        $env:PULL_SECRET_PATH,
        (Join-Path (Get-AapDemoHome) 'pull-secret.json'),
        (Join-Path (Get-AapDemoHome) 'pull-secret.txt'),
        (Join-Path (Get-AapDemoHome) 'pull-secret')
    ) | Where-Object { $_ }
    foreach ($p in $candidates) {
        if (Test-Path $p) { return $p }
    }
    return $null
}
