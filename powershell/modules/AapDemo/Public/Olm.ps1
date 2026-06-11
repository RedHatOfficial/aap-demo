# OLM install (addons/olm/deploy.sh port)

function Install-AapDemoOlm {
    if (-not (Test-AapDemoClusterConnection)) {
        throw 'kubectl not connected — run: aap-demo start'
    }
    if (-not (Test-AapDemoCommand operator-sdk)) {
        Write-AapDemoError 'operator-sdk not found'
        Write-Host 'Install: https://sdk.operatorframework.io/docs/installation/'
        throw 'operator-sdk required'
    }

    & kubectl get crd subscriptions.operators.coreos.com 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-AapDemoSuccess 'OLM is already installed'
        & operator-sdk olm status 2>$null
        return
    }

    Write-Host 'Installing OLM...'
    & operator-sdk olm install 2>&1 | Select-Object -Last 10
    & kubectl delete catsrc operatorhubio-catalog -n olm 2>$null | Out-Null

    & kubectl get crd subscriptions.operators.coreos.com 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-AapDemoSuccess 'OLM installed'
    } else {
        Write-AapDemoWarn 'OLM install may have issues — check: operator-sdk olm status'
    }
}
