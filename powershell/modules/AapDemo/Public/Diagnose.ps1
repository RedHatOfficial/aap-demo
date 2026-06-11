# Diagnose command (phase 2 partial — basic checks)

function Invoke-AapDemoDiagnose {
    Write-AapDemoHeading 'aap-demo diagnose - Checking environment health...'
    Write-Host ''

    $issues = 0
    $pass = { param($m) Write-Host "  ✓ $m" -ForegroundColor Green }
    $fail = { param($m) Write-Host "  ✗ $m" -ForegroundColor Red; $script:DiagIssues++ }
    $warn = { param($m) Write-Host "  ⚠ $m" -ForegroundColor Yellow }

    $script:DiagIssues = 0

    Write-Host 'Cluster:'
    $status = Get-AapDemoCrcStatusJson
    $crcState = if ($status) { $status.crcStatus } else { 'unknown' }
    switch ($crcState) {
        'Running' { & $pass 'OpenShift Local running' }
        'Stopped' { & $fail 'OpenShift Local is stopped — run: aap-demo start'; $issues++ }
        default { & $fail 'OpenShift Local cluster not found — run: aap-demo create'; $issues++ }
    }

    Initialize-AapDemoKubeconfig
    if (Test-AapDemoClusterConnection) {
        & $pass 'kubectl connected'
    } else {
        & $fail 'kubectl cannot connect to cluster'
        $issues++
        Write-Host ''
        Write-Host "Cannot proceed without cluster connectivity. KUBECONFIG=$env:KUBECONFIG"
        return
    }
    Write-Host ''

    Write-Host 'Storage:'
    & kubectl get sc topolvm-provisioner 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { & $pass 'topolvm-provisioner StorageClass' } else { & $warn 'topolvm-provisioner not found' }

    & kubectl get sc nfs-local-rwx 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        & $pass 'nfs-local-rwx StorageClass (RWX)'
    } else {
        & $warn 'nfs-local-rwx not found — re-run: aap-demo create'
    }
    Write-Host ''

    Write-Host 'Summary:'
    if ($script:DiagIssues -eq 0) {
        Write-AapDemoSuccess 'No critical issues detected (partial check — see docs/windows/ARCHITECTURE.md phase 2)'
    } else {
        Write-Host "  Found $script:DiagIssues critical issue(s)" -ForegroundColor Red
    }
    Write-Host ''
}
