# CRC infrastructure backend (infra-crc.sh port)

function Get-AapDemoInfraState {
    if ($script:AapDemoInfraType -ne 'crc') {
        throw "Unsupported infra type: $($script:AapDemoInfraType)"
    }
    if (-not (Test-AapDemoCommand crc)) { return 'not_created' }
    $status = Get-AapDemoCrcStatusJson
    if (-not $status) { return 'not_created' }
    switch ($status.crcStatus) {
        'Running' { return 'running' }
        'Stopped' { return 'stopped' }
        default { return 'not_created' }
    }
}

function Get-AapDemoInfraName {
    if (-not (Test-AapDemoCommand crc)) { return '' }
    $preset = & crc config get preset 2>$null
    if ($preset) {
        $preset = ($preset -split '\s+')[-1]
    }
    if (-not $preset) { $preset = 'microshift' }
    return "crc-$preset"
}

function Invoke-AapDemoInfraExec {
    param([Parameter(Mandatory)][string]$Command)
    Invoke-AapDemoCrcSsh -RemoteCommand "sudo $Command"
}

function Get-AapDemoInfraKubeconfig {
    param([Parameter(Mandatory)][string]$Dest)
    $dir = Split-Path $Dest -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    try {
        $out = & ssh @(Get-AapDemoCrcSshArgs) core@127.0.0.1 'sudo cat /var/lib/microshift/resources/kubeadmin/kubeconfig' 2>$null
        if ($out) {
            Set-Content -Path $Dest -Value ($out -join "`n")
            return $true
        }
    } catch { }
    $fallback = Get-AapDemoCrcKubeconfig
    if (Test-Path $fallback) {
        Copy-Item $fallback $Dest -Force
        return $true
    }
    return $false
}
