# Kubeconfig setup (setup_kubeconfig port)

function Initialize-AapDemoKubeconfig {
    if (-not (Test-AapDemoCommand kubectl)) {
        Write-AapDemoError 'kubectl not found'
        Write-Host ''
        Write-Host 'Install kubectl: https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/'
        throw 'kubectl required'
    }

    if ($script:AapDemoKubectlKubeconfig) {
        if (-not (Test-Path $script:AapDemoKubectlKubeconfig)) {
            throw "Kubeconfig file not found: $($script:AapDemoKubectlKubeconfig)"
        }
        $env:KUBECONFIG = $script:AapDemoKubectlKubeconfig
    } else {
        $crcKube = Get-AapDemoCrcKubeconfig
        if (Test-Path $crcKube) {
            $env:KUBECONFIG = $crcKube
        }
        & kubectl cluster-info 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0 -and (Test-Path (Get-AapDemoCrcSshKey))) {
            $tmp = "$crcKube.tmp"
            $refreshed = Get-AapDemoInfraKubeconfig -Dest $tmp
            if ($refreshed -and (Test-Path $tmp)) {
                Move-Item -Path $tmp -Destination $crcKube -Force
                $env:KUBECONFIG = $crcKube
            } else {
                Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if ($script:AapDemoKubectlContext) {
        Invoke-AapDemoKubectl config use-context $script:AapDemoKubectlContext
        if ($LASTEXITCODE -ne 0) {
            throw "Context not found: $($script:AapDemoKubectlContext)"
        }
    }
}

function Test-AapDemoClusterConnection {
    & kubectl cluster-info 2>$null | Out-Null
    return $LASTEXITCODE -eq 0
}
