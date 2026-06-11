# Status command (cmd_status port — simplified)

function Get-AapDemoStatus {
    Write-AapDemoHeading 'AAP Demo Status'
    Write-Host '==============='
    Write-Host ''

    $state = Get-AapDemoInfraState
    $name = Get-AapDemoInfraName

    Write-Host 'Infra:       OpenShift Local (CRC)'

    switch ($state) {
        'running' {
            Write-Host "Cluster:     running ($name)" -ForegroundColor Green
        }
        'stopped' {
            Write-Host 'Cluster:     stopped' -ForegroundColor Yellow
            Write-Host ''
            Write-Host 'Start with: aap-demo start'
            return
        }
        default {
            Write-Host 'Cluster:     not running' -ForegroundColor Red
            Write-Host ''
            Write-Host 'Start with: aap-demo create'
            return
        }
    }

    Initialize-AapDemoKubeconfig
    Write-Host "Kubeconfig:  $env:KUBECONFIG"
    Write-Host ''

    Write-Host 'Namespaces:'
    Write-Host '-----------'
    $namespaces = & kubectl get ns --no-headers -o custom-columns=':metadata.name' 2>$null
    foreach ($ns in $namespaces) {
        $ns = $ns.Trim()
        if (-not $ns) { continue }
        $pods = & kubectl get pods -n $ns --no-headers 2>$null
        if (-not $pods) { continue }
        $total = ($pods | Where-Object { $_ -notmatch 'Completed' } | Measure-Object).Count
        if ($total -eq 0) { continue }
        $running = ($pods | Select-String '\sRunning\s' | Measure-Object).Count
        $aapCr = & kubectl get aap -n $ns --no-headers 2>$null | ForEach-Object { ($_ -split '\s+')[0] } | Select-Object -First 1
        $line = "  $($ns.PadRight(30)) $running/$total pods"
        if ($aapCr) {
            $url = & kubectl get route $aapCr -n $ns -o jsonpath='https://{.spec.host}' 2>$null
            $line += "   $aapCr"
            if ($url) { $line += "  $url" }
        }
        Write-Host $line
    }

    Write-Host ''
    Write-Host 'Credentials:'
    Write-Host '------------'
    $aapNs = & kubectl get aap -A --no-headers 2>$null | ForEach-Object { ($_ -split '\s+')[0] } | Sort-Object -Unique
    $foundCreds = $false
    foreach ($ns in $aapNs) {
        $adminSecret = & kubectl get aap -n $ns -o jsonpath='{.items[0].status.adminPasswordSecret}' 2>$null
        $password = $null
        if ($adminSecret) {
            $b64 = & kubectl get secret -n $ns $adminSecret -o jsonpath='{.data.password}' 2>$null
            if ($b64) { $password = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) }
        }
        if (-not $password) {
            foreach ($secretName in @('myaap-admin-password', 'aap-admin-password', 'aap-controller-admin-password')) {
                $b64 = & kubectl get secret -n $ns $secretName -o jsonpath='{.data.password}' 2>$null
                if ($b64) {
                    $password = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
                    break
                }
            }
        }
        if ($password) {
            Write-Host "  $($ns): admin / $password"
            $foundCreds = $true
        }
    }
    if (-not $foundCreds) { Write-Host '  (no credentials found)' }

    $addons = Get-AapDemoSavedAddons
    if ($addons.Count -gt 0) {
        Write-Host ''
        Write-Host 'Enabled Addons:'
        Write-Host '---------------'
        foreach ($a in $addons) {
            $url = switch ($a) {
                'console' { 'https://console.apps.127.0.0.1.nip.io' }
                'registry' { 'https://registry.apps.127.0.0.1.nip.io' }
                'mcp-server' { "https://aap-mcp-$($script:AapDemoNamespace).apps.127.0.0.1.nip.io/mcp" }
                default { $null }
            }
            if ($url) { Write-Host "  $($a.PadRight(15)) $url" } else { Write-Host "  $a" }
        }
    }
    Write-Host ''
}
