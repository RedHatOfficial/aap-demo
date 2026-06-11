# Deploy flow (cmd_deploy, deploy_latest port)

function Grant-AapDemoNamespaceSccs {
    param([Parameter(Mandatory)][string]$Namespace)
    if (Test-AapDemoCommand oc) {
        & oc adm policy add-scc-to-group anyuid "system:serviceaccounts:$Namespace" 2>&1
        & oc adm policy add-scc-to-group privileged "system:serviceaccounts:$Namespace" 2>&1
    } else {
        foreach ($scc in @('anyuid', 'privileged')) {
            $crb = "system:openshift:scc:${scc}:$Namespace"
            & kubectl get clusterrolebinding $crb 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Invoke-AapDemoKubectl create clusterrolebinding $crb `
                    --clusterrole="system:openshift:scc:$scc" `
                    --group="system:serviceaccounts:$Namespace"
            }
        }
    }
}

function Initialize-AapDemoNamespace {
    param([Parameter(Mandatory)][string]$Namespace)

    Write-Host 'Setting up namespace...'
    & kubectl create namespace $Namespace 2>$null | Out-Null

    if (Test-AapDemoCommand crc) {
        $ocEnv = & crc oc-env 2>$null
        if ($ocEnv -match 'PATH="([^:]+):') {
            $env:PATH = "$($Matches[1]);$env:PATH"
        }
    }

    Grant-AapDemoNamespaceSccs -Namespace $Namespace
    Invoke-AapDemoKubectl label namespace $Namespace `
        pod-security.kubernetes.io/enforce=privileged `
        pod-security.kubernetes.io/audit=privileged `
        pod-security.kubernetes.io/warn=privileged --overwrite

    $pullSecret = Get-AapDemoPullSecretPath
    if ($pullSecret) {
        Write-Host "Using pull secret: $pullSecret"
        & kubectl delete secret redhat-operators-pull-secret -n $Namespace 2>$null | Out-Null
        Invoke-AapDemoKubectl create secret generic redhat-operators-pull-secret `
            --from-file=.dockerconfigjson=$pullSecret `
            --type=kubernetes.io/dockerconfigjson `
            -n $Namespace

        $patch = '{"imagePullSecrets": [{"name": "redhat-operators-pull-secret"}]}'
        & kubectl patch serviceaccount default -n $Namespace -p $patch 2>$null | Out-Null
        Write-AapDemoSuccess 'Pull secret configured'
    } else {
        Write-AapDemoWarn 'No pull secret found'
    }
}

function New-AapDemoInstance {
    param(
        [Parameter(Mandatory)][string]$Namespace,
        [string]$CrName = 'minimal'
    )
    $repo = Get-AapDemoRepoRoot
    $crFile = Join-Path $repo "config/crs/aap-$CrName.yaml"
    if (-not (Test-Path $crFile)) {
        throw "CR file not found: $crFile"
    }

    Write-Host "Using CR: $CrName"
    & kubectl get sc nfs-local-rwx 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Invoke-AapDemoKubectl apply -f $crFile -n $Namespace
    } else {
        $content = Get-Content $crFile -Raw
        $content = $content -replace 'file_storage_storage_class: nfs-local-rwx', '# file_storage_storage_class: (using default)'
        $content = $content -replace 'file_storage_access_mode: ReadWriteMany', 'file_storage_access_mode: ReadWriteOnce'
        $temp = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content $temp $content
            Invoke-AapDemoKubectl apply -f $temp -n $Namespace
        } finally {
            Remove-Item $temp -Force
        }
        Write-Host '  (Using ReadWriteOnce — nfs-local-rwx not available)'
    }
}

function Watch-AapDemoDeployment {
    param([Parameter(Mandatory)][string]$Namespace)

    Write-Host ''
    Write-Host 'Watching AAP deployment (Ctrl+C to stop)...'
    $repo = Get-AapDemoRepoRoot
    $watchScript = Join-Path $repo 'scripts/watch-aap.sh'
    if ($env:OS -match 'Windows' -or $IsWindows) {
        # Phase 2: native watch; for now poll CR status
        for ($i = 0; $i -lt 120; $i++) {
            $successful = & kubectl get aap -n $Namespace -o jsonpath='{.items[0].status.conditions[?(@.type=="Successful")].status}' 2>$null
            $running = & kubectl get aap -n $Namespace -o jsonpath='{.items[0].status.conditions[?(@.type=="Running")].status}' 2>$null
            $pods = & kubectl get pods -n $Namespace --no-headers 2>$null
            $runningCount = ($pods | Select-String 'Running').Count
            $total = ($pods | Measure-Object).Count
            Write-Host "  Pods: $runningCount/$total running | Successful: $successful | Running: $running"
            if ($successful -eq 'True') {
                Write-AapDemoSuccess 'AAP deployment successful'
                return
            }
            Start-Sleep -Seconds 15
        }
        Write-AapDemoWarn 'Watch timeout — run: aap-demo status'
        return
    }
    if (Test-Path $watchScript) {
        $env:NAMESPACE = $Namespace
        & bash $watchScript
    }
}

function Invoke-AapDemoDeployLatest {
    param(
        [Parameter(Mandatory)][string]$Namespace,
        [switch]$OperatorOnly
    )
    $repo = Get-AapDemoRepoRoot
    $channel = 'stable-2.7'
    $ocpVersion = if ($env:AAP_OCP_VERSION) { $env:AAP_OCP_VERSION } else { '4.20' }

    Write-Host ''
    Write-Host 'Deploying AAP from latest catalog...'
    Write-Host "  Version: 2.7"
    Write-Host "  Namespace: $Namespace"
    Write-Host ''

    Install-AapDemoOlm
    Initialize-AapDemoNamespace -Namespace $Namespace

    Write-Host ''
    Write-Host "Creating CatalogSource (OCP $ocpVersion)..."
    $catSrc = Get-Content (Join-Path $repo 'config/olm/catalogsource.yaml') -Raw
    $catSrc = $catSrc -replace 'redhat-operator-index:v[0-9.]+', "redhat-operator-index:v$ocpVersion"
    $catSrc = $catSrc -replace 'namespace: aap-operator', "namespace: $Namespace"
    $temp = [System.IO.Path]::GetTempFileName()
    Set-Content $temp $catSrc
    Invoke-AapDemoKubectl apply -f $temp
    Remove-Item $temp -Force

    Write-Host 'Waiting for CatalogSource to be ready...'
    $ready = $false
    for ($i = 1; $i -le 60; $i++) {
        $status = & kubectl get catalogsource redhat-operators -n $Namespace `
            -o jsonpath='{.status.connectionState.lastObservedState}' 2>$null
        if ($status -eq 'READY') {
            Write-AapDemoSuccess 'CatalogSource is ready'
            $ready = $true
            break
        }
        Write-Host "  Waiting ($status)... ($i/60)"
        Start-Sleep -Seconds 5
    }
    if (-not $ready) { Write-AapDemoWarn 'CatalogSource not ready after 5 minutes — continuing' }

    Write-Host ''
    Write-Host 'Creating OperatorGroup...'
    $og = Get-Content (Join-Path $repo 'config/olm/operatorgroup.yaml') -Raw
    $og = $og -replace 'namespace: aap', "namespace: $Namespace"
    $og = $og -replace 'name: aap-og', "name: ${Namespace}-og"
    $og = $og -replace '- aap', "- $Namespace"
    $temp = [System.IO.Path]::GetTempFileName()
    Set-Content $temp $og
    Invoke-AapDemoKubectl apply -f $temp
    Remove-Item $temp -Force

    Write-Host ''
    Write-Host 'Creating Subscription...'
    $sub = Get-Content (Join-Path $repo 'config/olm/subscription.yaml') -Raw
    $sub = $sub -replace 'namespace: aap', "namespace: $Namespace"
    $sub = $sub -replace 'channel: stable-2.6', "channel: $channel"
    $temp = [System.IO.Path]::GetTempFileName()
    Set-Content $temp $sub
    Invoke-AapDemoKubectl apply -f $temp
    Remove-Item $temp -Force

    Write-Host ''
    Write-Host 'Waiting for CSV...'
    $csvName = $null
    for ($i = 1; $i -le 60; $i++) {
        $csvName = & kubectl get csv -n $Namespace --no-headers 2>$null | Select-String 'aap-operator' | ForEach-Object { ($_ -split '\s+')[0] } | Select-Object -First 1
        if ($csvName) {
            Write-Host "Found CSV: $csvName"
            break
        }
        Write-Host "  Waiting for CSV... ($i/60)"
        Start-Sleep -Seconds 10
    }
    if (-not $csvName) { throw 'CSV not found after 10 minutes' }

    Write-Host ''
    Write-Host 'Waiting for CSV to reach Succeeded phase...'
    Invoke-AapDemoKubectl wait --for=jsonpath='{.status.phase}'=Succeeded "csv/$csvName" -n $Namespace --timeout=600s -IgnoreExitCode

    if ($OperatorOnly) {
        Write-AapDemoSuccess 'AAP operator deployed'
        Write-Host "To deploy AAP instance: aap-demo deploy-aap"
        return
    }

    New-AapDemoInstance -Namespace $Namespace -CrName $(if ($env:CR) { $env:CR } else { 'minimal' })
    Watch-AapDemoDeployment -Namespace $Namespace
}

function Invoke-AapDemoDeploy {
    param([switch]$OperatorOnly)

    $state = Get-AapDemoInfraState
    if ($state -eq 'not_created') {
        Write-Host 'No cluster found. Creating one first...'
        Invoke-AapDemoCreate
    } elseif ($state -eq 'stopped') {
        Write-Host 'Cluster is stopped. Starting...'
        Start-AapDemoCluster
    }

    Initialize-AapDemoKubeconfig
    Install-AapDemoOlm

    Write-AapDemoHeading 'aap-demo deploy - Deploying AAP to OpenShift Local...'
    if (-not (Test-AapDemoClusterConnection)) {
        throw 'Cannot connect to cluster — check KUBECONFIG'
    }
    Write-Host "Connected to: $(kubectl config current-context 2>$null)"
    Write-Host ''

    $ns = $script:AapDemoNamespace
    if ($script:AapDemoForce -ne 'true') {
        $existing = & kubectl get aap -n $ns --no-headers 2>$null | Select-Object -First 1
        if ($existing) {
            $name = ($existing -split '\s+')[0]
            Write-AapDemoSuccess "AAP instance '$name' already exists in $ns — watching deployment"
            Watch-AapDemoDeployment -Namespace $ns
            return
        }
    }

    Invoke-AapDemoDeployLatest -Namespace $ns -OperatorOnly:$OperatorOnly
}
