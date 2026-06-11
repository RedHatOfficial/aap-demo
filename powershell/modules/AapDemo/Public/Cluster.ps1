# Cluster lifecycle (crc-create.sh + start/stop/destroy port)

function Get-AapDemoCrcPreset {
    $saved = Get-AapDemoConfigValue -Key 'CRC_PRESET'
    if ($saved) { return $saved }

    if ([Console]::IsInputRedirected -eq $false) {
        Write-Host ''
        Write-Host 'Select CRC preset:' -ForegroundColor White
        Write-Host ''
        Write-Host '  1) MicroShift — Recommended (default)' -ForegroundColor White
        Write-Host '     Lightweight, ~10 system pods, nip.io routes'
        Write-Host ''
        Write-Host '  2) OpenShift — Full Platform'
        Write-Host '     Complete OpenShift API, heavier resource use'
        Write-Host ''
        $choice = Read-Host 'Choice [1]'
    } else {
        $choice = '1'
    }

    switch ($choice) {
        { $_ -in '2', 'openshift' } { return 'openshift' }
        default { return 'microshift' }
    }
}

function Set-AapDemoCoreDns {
    param([Parameter(Mandatory)][string]$Preset)

    Write-Host 'Configuring CoreDNS for in-cluster route resolution...'

    $routeDomain = if ($Preset -eq 'microshift') {
        $domainLine = Invoke-AapDemoCrcSsh -RemoteCommand 'grep -h baseDomain /etc/microshift/config.d/99-aap-demo-dns.yaml /etc/microshift/config.yaml 2>/dev/null | head -1' -IgnoreExitCode
        $domain = ($domainLine -split '\s+')[-1]
        if ($domain) { "apps.$domain" } else { 'apps.crc.testing' }
    } else {
        'apps-crc.testing'
    }

    $escaped = [regex]::Escape($routeDomain)
    $corefile = @"
.:5353 {
    bufsize 1232
    errors
    log . {
        class error
    }
    health {
        lameduck 20s
    }
    ready
    rewrite stop {
        name regex (.*)\.$escaped router-internal-default.openshift-ingress.svc.cluster.local
        answer auto
    }
    kubernetes cluster.local in-addr.arpa ip6.arpa {
        pods insecure
        fallthrough in-addr.arpa ip6.arpa
    }
    prometheus 127.0.0.1:9153
    forward . /etc/resolv.conf {
        policy sequential
    }
    cache 900 {
        denial 9984 30
    }
    reload
}
"@

    $current = & kubectl get configmap dns-default -n openshift-dns -o jsonpath='{.data.Corefile}' 2>$null
    if ($current -match 'router-internal-default') {
        Write-AapDemoSuccess "CoreDNS already configured for $routeDomain"
        return
    }

    $patch = @{ data = @{ Corefile = $corefile } } | ConvertTo-Json -Compress -Depth 5
    $patchFile = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -Path $patchFile -Value $patch
        Invoke-AapDemoKubectl patch configmap dns-default -n openshift-dns --type merge -p (Get-Content $patchFile -Raw)
        Invoke-AapDemoKubectl rollout restart daemonset/dns-default -n openshift-dns
        Invoke-AapDemoKubectl rollout status daemonset/dns-default -n openshift-dns --timeout=60s -IgnoreExitCode
        Start-Sleep -Seconds 5
        Write-AapDemoSuccess "CoreDNS configured: $routeDomain → router service"
    } finally {
        Remove-Item $patchFile -Force -ErrorAction SilentlyContinue
    }
}

function Install-AapDemoNfsStorage {
    $repo = Get-AapDemoRepoRoot
    & kubectl get sc nfs-local-rwx 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host '  nfs-local-rwx StorageClass already exists'
        return
    }

    Write-Host 'Setting up NFS storage for RWX support...'
    if (Test-AapDemoCommand oc) {
        Invoke-AapDemoOc adm policy add-scc-to-group privileged system:serviceaccounts:nfs-storage -IgnoreExitCode
    }

    $defaultSc = & kubectl get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>$null
    if (-not $defaultSc) { $defaultSc = 'topolvm-provisioner' }
    $defaultSc = ($defaultSc -split '\s+')[0]

    Invoke-AapDemoTemplateApply -TemplatePath (Join-Path $repo 'config/manifests/nfs-server.yaml') -Replacements @{ '__DEFAULT_SC__' = $defaultSc }

    Write-Host '  Waiting for NFS server...'
    Invoke-AapDemoKubectl wait --for=condition=Available deployment/nfs-server -n nfs-storage --timeout=120s -IgnoreExitCode

    $nfsIp = & kubectl get svc nfs-server -n nfs-storage -o jsonpath='{.spec.clusterIP}'
    Invoke-AapDemoTemplateApply -TemplatePath (Join-Path $repo 'config/manifests/nfs-provisioner.yaml') -Replacements @{ '__NFS_SERVER_IP__' = $nfsIp }

    Invoke-AapDemoKubectl wait --for=condition=Available deployment/nfs-provisioner -n nfs-storage --timeout=120s
    Write-AapDemoSuccess 'nfs-local-rwx StorageClass created'
}

function Invoke-AapDemoCreateCluster {
    Write-AapDemoHeading 'aap-demo create - Creating CRC cluster...'

    if (-not (Test-AapDemoCommand crc)) {
        Write-AapDemoError 'CRC (OpenShift Local) is required but not found'
        Write-Host 'Download: https://console.redhat.com/openshift/create/local'
        throw 'crc not found'
    }

    $statusJson = Get-AapDemoCrcStatusJson
    $crcStatus = if ($statusJson) { $statusJson.crcStatus } else { 'Unknown' }
    if ($crcStatus -eq 'Running') {
        Write-Host 'CRC is already running'
        Write-Host "  Use 'aap-demo destroy' first, or 'aap-demo deploy' to deploy AAP"
        return
    }

    $currentPreset = & crc config get preset 2>$null
    if ($currentPreset) { $currentPreset = ($currentPreset -split '\s+')[-1] }

    if ($crcStatus -eq 'Unknown' -or -not $currentPreset -or $currentPreset -eq 'openshift') {
        $savedPreset = Get-AapDemoCrcPreset
        Set-AapDemoConfigValue -Key 'CRC_PRESET' -Value $savedPreset
        & crc config set preset $savedPreset 2>$null | Out-Null
        $currentPreset = $savedPreset
        Write-Host "Saved preset: $savedPreset"
    }

    Write-Host "▸ CRC preset: $currentPreset" -ForegroundColor Green

    $cpus = if ($env:CRC_CPUS) { $env:CRC_CPUS } elseif ($env:VM_CPUS) { $env:VM_CPUS } else { '8' }
    $memory = if ($env:CRC_MEMORY) { $env:CRC_MEMORY } elseif ($env:VM_MEMORY) { $env:VM_MEMORY } else { '16384' }
    $disk = if ($env:CRC_DISK) { $env:CRC_DISK } elseif ($env:VM_DISK_SIZE) { $env:VM_DISK_SIZE } else { '100' }
    $pvSize = if ($env:CRC_PV_SIZE) { $env:CRC_PV_SIZE } elseif ($env:VM_PV_SIZE) { $env:VM_PV_SIZE } else { '50' }

    & crc config set cpus $cpus 2>$null | Out-Null
    & crc config set memory $memory 2>$null | Out-Null
    & crc config set disk-size $disk 2>$null | Out-Null
    & crc config set persistent-volume-size $pvSize 2>$null | Out-Null
    Write-Host "▸ Resources: $cpus CPUs, $([int]$memory / 1024)GB RAM, ${disk}GB disk (${pvSize}GB for PVs)" -ForegroundColor Green

    if ($crcStatus -eq 'Unknown') {
        Write-Host '▸ Running CRC setup...' -ForegroundColor Green
        & crc setup --show-progressbars
    }

    $pullSecret = Get-AapDemoPullSecretPath
    if (-not $pullSecret) {
        Write-AapDemoError 'Pull secret not found'
        Write-Host 'Save to: ~/.aap-demo/pull-secret.txt'
        throw 'pull secret required'
    }
    Write-Host "▸ Pull secret: $pullSecret" -ForegroundColor Green

    Write-Host '▸ Starting CRC...' -ForegroundColor Green
    $logFile = Join-Path $env:TEMP 'crc-start.log'
    & crc start -p $pullSecret *> $logFile
    if ($LASTEXITCODE -ne 0) {
        Write-Host '  Retrying with stdin pull secret...'
        Get-Content $pullSecret | & crc start --pull-secret-file - *> $logFile
        if ($LASTEXITCODE -ne 0) {
            Get-Content $logFile
            throw 'crc start failed'
        }
    }

    if ($currentPreset -eq 'microshift') {
        Write-Host '▸ Configuring nip.io baseDomain...' -ForegroundColor Green
        @'
dns:
  baseDomain: 127.0.0.1.nip.io
'@ | & ssh @(Get-AapDemoCrcSshArgs) core@127.0.0.1 'sudo tee /etc/microshift/config.d/99-aap-demo-dns.yaml > /dev/null'

        Write-Host '▸ Restarting MicroShift with nip.io domain...' -ForegroundColor Green
        Invoke-AapDemoCrcSsh -RemoteCommand 'sudo systemctl stop microshift 2>/dev/null; sudo rm -rf /var/lib/microshift; sudo systemctl start microshift' -IgnoreExitCode

        Write-Host -NoNewline '▸ Waiting for MicroShift API'
        for ($i = 1; $i -le 60; $i++) {
            Invoke-AapDemoCrcSsh -RemoteCommand 'sudo kubectl --kubeconfig /var/lib/microshift/resources/kubeadmin/kubeconfig cluster-info' -IgnoreExitCode | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Host ' ready'; break }
            Write-Host -NoNewline '.'
            Start-Sleep -Seconds 5
        }

        $kubePath = Get-AapDemoCrcKubeconfig
        $kubeDir = Split-Path $kubePath -Parent
        if (-not (Test-Path $kubeDir)) { New-Item -ItemType Directory -Path $kubeDir -Force | Out-Null }
        & ssh @(Get-AapDemoCrcSshArgs) core@127.0.0.1 'sudo cat /var/lib/microshift/resources/kubeadmin/kubeconfig' | Set-Content $kubePath
        Write-AapDemoSuccess 'nip.io baseDomain configured'
    }

    Write-Host '▸ Trusting ingress CA...' -ForegroundColor Green
    $caCert = Join-Path $env:TEMP 'crc-ingress-ca.crt'
    & ssh @(Get-AapDemoCrcSshArgs) core@127.0.0.1 'sudo cat /var/lib/microshift/certs/ingress-ca/ca.crt' | Set-Content $caCert
    if ((Get-Item $caCert).Length -gt 0) {
        Import-AapDemoIngressCa -CertPath $caCert
    }
    Remove-Item $caCert -Force -ErrorAction SilentlyContinue

    Write-Host '▸ Configuring kubeconfig...' -ForegroundColor Green
    $env:KUBECONFIG = Get-AapDemoCrcKubeconfig
    $aapHome = Get-AapDemoHome
    if (-not (Test-Path $aapHome)) { New-Item -ItemType Directory -Path $aapHome -Force | Out-Null }
    if ($currentPreset -eq 'microshift') {
        Copy-Item $env:KUBECONFIG (Join-Path $aapHome 'kubeconfig.microshift') -Force
        $kubeDir = Join-Path $env:USERPROFILE '.kube'
        if (-not (Test-Path $kubeDir)) { New-Item -ItemType Directory -Path $kubeDir -Force | Out-Null }
        Copy-Item $env:KUBECONFIG (Join-Path $kubeDir 'config') -Force
    }
    Write-AapDemoSuccess 'Kubeconfig configured'

    if ($currentPreset -eq 'microshift') {
        Write-Host '▸ Installing metrics-server...' -ForegroundColor Green
        & kubectl get deployment metrics-server -n kube-system 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Invoke-AapDemoKubectl apply -f 'https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml'
            Invoke-AapDemoKubectl patch deployment metrics-server -n kube-system --type=json `
                -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
            Write-AapDemoSuccess 'metrics-server installed'
        } else {
            Write-Host '  Already installed'
        }

        Install-AapDemoNfsStorage
    }

    $addons = Get-AapDemoSavedAddons
    if ($addons.Count -gt 0) {
        Write-Host "▸ Saved addons ($($addons -join ', ')) — enable after deploy if AAP-required" -ForegroundColor Green
    }

    if ($currentPreset -eq 'microshift') {
        Set-AapDemoCoreDns -Preset $currentPreset
        Write-Host '▸ Setting sysctl for performance...' -ForegroundColor Green
        Invoke-AapDemoCrcSsh -RemoteCommand 'sudo sysctl -w fs.inotify.max_user_watches=2099999999 fs.inotify.max_user_instances=2099999999 fs.inotify.max_queued_events=2099999999' -IgnoreExitCode
        Write-AapDemoSuccess 'inotify limits configured'
    }

    Write-Host ''
    Write-AapDemoSuccess 'CRC cluster ready for AAP development!'
    Write-Host ''
    Write-Host '  Next: aap-demo deploy'
}

function Start-AapDemoCluster {
    Write-AapDemoHeading 'aap-demo start - Starting CRC cluster...'
    & crc start
    Write-AapDemoSuccess 'CRC cluster started'
}

function Stop-AapDemoCluster {
    Write-AapDemoHeading 'aap-demo stop - Stopping CRC cluster...'
    & crc stop
    Write-AapDemoSuccess 'CRC cluster stopped'
    Write-Host 'To restart: aap-demo start'
}

function Remove-AapDemoCluster {
    param([switch]$Reset)

    Write-AapDemoHeading 'aap-demo destroy - Deleting CRC cluster...'
    Write-Host ''
    Write-Host 'WARNING: This will DELETE the entire CRC cluster!' -ForegroundColor Red
    Write-Host '  • All cluster data will be PERMANENTLY DESTROYED'
    Write-Host '  • All PVC storage will be LOST'
    Write-Host ''
    Confirm-AapDemoDestructive

    & crc delete -f 2>$null
    if ($LASTEXITCODE -ne 0) { & crc delete }

    if (Test-AapDemoCommand podman) {
        & podman system connection remove aap-demo 2>$null | Out-Null
    }

    if ($LASTEXITCODE -eq 0) {
        Write-AapDemoSuccess 'CRC cluster deleted'
        if ($Reset) {
            Remove-Item $script:AapDemoConfigPath -Force -ErrorAction SilentlyContinue
            Write-AapDemoSuccess "Config reset — next 'create' will re-prompt for preset"
        }
    } else {
        Write-AapDemoError 'CRC delete failed — config preserved'
    }
}

function Invoke-AapDemoCreate {
    Invoke-AapDemoCreateCluster
    Initialize-AapDemoKubeconfig
    try {
        Install-AapDemoOlm
    } catch {
        Write-AapDemoWarn "OLM install failed — retry with: aap-demo enable olm"
    }
}
