function Invoke-AapDemoCreate {
  [CmdletBinding()]
  param()

  Write-AapHeader 'aap-demo create'

  Assert-AapCommand crc 'Install OpenShift Local: https://console.redhat.com/openshift/create/local'

  $status = Get-AapCrcStatus
  $crcState = [string]$status.crcStatus
  if ($crcState -eq 'Running') {
    throw 'CRC already running. Run aap-demo deploy or destroy the cluster first.'
  }

  $preset = Get-AapConfigValue 'CRC_PRESET'
  if (-not $preset) {
    Write-Host 'Select CRC preset:'
    Write-Host '  1) microshift (recommended)'
    Write-Host '  2) openshift'
    $choice = Read-Host 'Choice [1]'
    $preset = switch ($choice) {
      '2' { 'openshift' }
      'openshift' { 'openshift' }
      default { 'microshift' }
    }
    Set-AapConfigValue 'CRC_PRESET' $preset
  }

  $cpus = if ($env:CRC_CPUS) { $env:CRC_CPUS } else { '8' }
  $memory = if ($env:CRC_MEMORY) { $env:CRC_MEMORY } else { '16384' }
  $disk = if ($env:CRC_DISK) { $env:CRC_DISK } else { '100' }
  $pvSize = if ($env:CRC_PV_SIZE) { $env:CRC_PV_SIZE } else { '50' }

  & crc config set preset $preset 2>$null | Out-Null
  & crc config set cpus $cpus 2>$null | Out-Null
  & crc config set memory $memory 2>$null | Out-Null
  & crc config set disk-size $disk 2>$null | Out-Null
  & crc config set persistent-volume-size $pvSize 2>$null | Out-Null
  Write-AapStep "Preset $preset | CPUs $cpus | Memory $memory MiB | Disk ${disk}GB"

  if ($crcState -eq 'Unknown') {
    Write-AapStep 'Running crc setup...'
    & crc setup --show-progressbars
    if ($LASTEXITCODE -ne 0) { throw 'crc setup failed' }
  }

  $pullSecret = Get-AapPullSecretPath
  if (-not $pullSecret) {
    throw "Pull secret not found. Save to $Script:AapDemoConfigDir\pull-secret.txt"
  }
  Write-AapStep "Pull secret: $pullSecret"

  Write-AapStep 'Starting CRC (this may take several minutes)...'
  & crc start -p $pullSecret
  if ($LASTEXITCODE -ne 0) {
    Get-Content -LiteralPath $pullSecret -Raw | & crc start --pull-secret-file -
    if ($LASTEXITCODE -ne 0) { throw 'crc start failed' }
  }

  Initialize-AapKubeEnvironment

  if ($preset -eq 'microshift') {
    Write-AapStep 'Configuring nip.io baseDomain...'
    Invoke-AapCrcSsh @'
sudo tee /etc/microshift/config.d/99-aap-demo-dns.yaml > /dev/null <<'EOF'
dns:
  baseDomain: 127.0.0.1.nip.io
EOF
'@ | Out-Null

    Write-AapStep 'Restarting MicroShift with nip.io domain...'
    Invoke-AapCrcSsh 'sudo systemctl stop microshift 2>/dev/null; sudo rm -rf /var/lib/microshift; sudo systemctl start microshift' | Out-Null

    for ($i = 1; $i -le 60; $i++) {
      try {
        Invoke-AapCrcSsh 'sudo kubectl --kubeconfig /var/lib/microshift/resources/kubeadmin/kubeconfig cluster-info' | Out-Null
        break
      } catch {
        if ($i -eq 60) { throw 'MicroShift API did not become ready' }
        Start-Sleep -Seconds 5
      }
    }

    $kubeDir = Join-Path $env:USERPROFILE '.crc\machines\crc'
    New-Item -ItemType Directory -Force -Path $kubeDir | Out-Null
    Invoke-AapCrcSsh 'sudo cat /var/lib/microshift/resources/kubeadmin/kubeconfig' |
      Set-Content -LiteralPath (Join-Path $kubeDir 'kubeconfig') -Encoding ascii
    $env:KUBECONFIG = Join-Path $kubeDir 'kubeconfig'

    Write-AapStep 'Installing metrics-server...'
    if ((Invoke-AapKubectlQuiet @('get', 'deployment', 'metrics-server', '-n', 'kube-system')) -ne 0) {
      Invoke-AapKubectl @('apply', '-f', 'https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml') | Out-Null
      Invoke-AapKubectl @(
        'patch', 'deployment', 'metrics-server', '-n', 'kube-system', '--type=json',
        '-p', '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
      ) | Out-Null
    }

    if ((Invoke-AapKubectlQuiet @('get', 'sc', 'nfs-local-rwx')) -ne 0) {
      Write-AapStep 'Setting up nfs-local-rwx storage...'
      if (Test-AapCommand oc) {
        Invoke-AapOc @('adm', 'policy', 'add-scc-to-group', 'privileged', 'system:serviceaccounts:nfs-storage') | Out-Null
      }
      $defaultSc = (& kubectl get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>$null)
      if (-not $defaultSc) { $defaultSc = 'topolvm-provisioner' }
      Apply-AapManifestTemplate 'config/manifests/nfs-server.yaml' @{ '__DEFAULT_SC__' = $defaultSc }
      Invoke-AapKubectl @('wait', '--for=condition=Available', 'deployment/nfs-server', '-n', 'nfs-storage', '--timeout=120s') | Out-Null
      $nfsIp = (& kubectl get svc nfs-server -n nfs-storage -o jsonpath='{.spec.clusterIP}')
      Apply-AapManifestTemplate 'config/manifests/nfs-provisioner.yaml' @{ '__NFS_SERVER_IP__' = $nfsIp }
      Invoke-AapKubectl @('wait', '--for=condition=Available', 'deployment/nfs-provisioner', '-n', 'nfs-storage', '--timeout=120s') | Out-Null
    }

    Write-AapStep 'Configuring CoreDNS for in-cluster routes...'
    Set-AapCoreDns -RouteDomain 'apps.127.0.0.1.nip.io'

    Write-AapStep 'Tuning inotify limits on cluster node...'
    Invoke-AapCrcSsh 'sudo sysctl -w fs.inotify.max_user_watches=2099999999 fs.inotify.max_user_instances=2099999999 fs.inotify.max_queued_events=2099999999' | Out-Null
  }

  Install-AapOlm

  $kubeConfig = Get-AapKubeconfigPath
  Write-Host ''
  Write-AapStep 'CRC cluster ready'
  Write-Host "  Kubeconfig: $kubeConfig"
  Write-Host '  Next: aap-demo deploy'
  Write-Host ''
}

function Set-AapCoreDns {
  param([Parameter(Mandatory)][string]$RouteDomain)

  $escaped = [regex]::Escape($RouteDomain)
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

  $patch = @{ data = @{ Corefile = $corefile } } | ConvertTo-Json -Compress
  & kubectl patch configmap dns-default -n openshift-dns --type merge -p $patch 2>$null | Out-Null
  Invoke-AapKubectlQuiet @('rollout', 'restart', 'daemonset/dns-default', '-n', 'openshift-dns') | Out-Null
}
