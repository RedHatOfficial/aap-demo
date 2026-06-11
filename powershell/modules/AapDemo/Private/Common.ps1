# Shared helpers for the AapDemo module

function Get-AapDemoRepoRoot {
    if ($script:AapDemoRepoRoot) { return $script:AapDemoRepoRoot }
    # modules/AapDemo/Private -> repo root
    $script:AapDemoRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
    return $script:AapDemoRepoRoot
}

function Get-AapDemoHome {
    Join-Path $env:USERPROFILE '.aap-demo'
}

function Get-AapDemoCrcKubeconfig {
    Join-Path $env:USERPROFILE '.crc\machines\crc\kubeconfig'
}

function Get-AapDemoCrcSshKey {
    Join-Path $env:USERPROFILE '.crc\machines\crc\id_ed25519'
}

function Write-AapDemoError {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "ERROR: $Message" -ForegroundColor Red
}

function Write-AapDemoHeading {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ""
    Write-Host $Message -ForegroundColor White
}

function Write-AapDemoSuccess {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "✓ $Message" -ForegroundColor Green
}

function Write-AapDemoWarn {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "WARNING: $Message" -ForegroundColor Yellow
}

function Test-AapDemoCommand {
    param([Parameter(Mandatory)][string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-AapDemoExternal {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [switch]$IgnoreExitCode,
        [switch]$Quiet
    )
    if (-not $Quiet) {
        & $FilePath @ArgumentList
    } else {
        & $FilePath @ArgumentList 2>&1 | Out-Null
    }
    if (-not $IgnoreExitCode -and $LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $FilePath $($ArgumentList -join ' ')"
    }
}

function Invoke-AapDemoKubectl {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Args
    )
    Invoke-AapDemoExternal -FilePath kubectl -ArgumentList $Args
}

function Invoke-AapDemoOc {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Args
    )
    if (Test-AapDemoCommand oc) {
        Invoke-AapDemoExternal -FilePath oc -ArgumentList $Args
    } else {
        throw "oc not found on PATH"
    }
}

function Get-AapDemoCrcStatusJson {
    if (-not (Test-AapDemoCommand crc)) { return $null }
    $raw = & crc status --output json 2>$null
    if (-not $raw) { return $null }
    try {
        return $raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-AapDemoCrcSshArgs {
    $key = Get-AapDemoCrcSshKey
    return @(
        '-p', '2222',
        '-i', $key,
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=NUL',
        '-o', 'LogLevel=ERROR'
    )
}

function Invoke-AapDemoCrcSsh {
    param(
        [Parameter(Mandatory)][string]$RemoteCommand,
        [switch]$IgnoreExitCode
    )
    $sshArgs = @(Get-AapDemoCrcSshArgs) + @('core@127.0.0.1', $RemoteCommand)
    Invoke-AapDemoExternal -FilePath ssh -ArgumentList $sshArgs -IgnoreExitCode:$IgnoreExitCode
}

function Invoke-AapDemoTemplateApply {
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [hashtable]$Replacements = @{},
        [string]$Namespace
    )
    $content = Get-Content -Path $TemplatePath -Raw
    foreach ($key in $Replacements.Keys) {
        $content = $content -replace [regex]::Escape($key), [string]$Replacements[$key]
    }
    $temp = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -Path $temp -Value $content -NoNewline
        if ($Namespace) {
            Invoke-AapDemoKubectl apply -f $temp -n $Namespace
        } else {
            Invoke-AapDemoKubectl apply -f $temp
        }
    } finally {
        Remove-Item -Path $temp -Force -ErrorAction SilentlyContinue
    }
}

function Confirm-AapDemoDestructive {
    param([string]$Prompt = 'Press Enter to continue, Ctrl+C to cancel...')
    if ($script:AapDemoQuiet -eq 'true') { return }
    Write-Host $Prompt
    Write-Host 'Auto-continuing in 10 seconds...'
    $null = Read-Host -TimeoutSec 10
}

function Import-AapDemoIngressCa {
    param([Parameter(Mandatory)][string]$CertPath)
    if (-not (Test-Path $CertPath)) { return $false }
    try {
        Import-Certificate -FilePath $CertPath -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
        Write-AapDemoSuccess 'Ingress CA trusted (LocalMachine\Root)'
        return $true
    } catch {
        Write-AapDemoWarn "Could not add ingress CA to trust store (run as Administrator): $($_.Exception.Message)"
        Write-Host "  Manual: Import-Certificate -FilePath '$CertPath' -CertStoreLocation Cert:\LocalMachine\Root"
        return $false
    }
}
