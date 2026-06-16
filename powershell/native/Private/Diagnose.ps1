function Invoke-AapDemoDiagnose {
  [CmdletBinding()]
  param(
    [string]$Namespace = $Script:AapDemoDefaultNamespace,
    [switch]$Ai
  )

  if ($Ai) {
    Invoke-AapBashCli @('diagnose', '--ai')
    return
  }

  $counts = @{ Issues = 0; Warnings = 0 }

  function Write-AapDiagPass {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "  OK $Message" -ForegroundColor Green
  }

  function Write-AapDiagFail {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "  X $Message" -ForegroundColor Red
    $counts.Issues++
  }

  function Write-AapDiagWarn {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "  WARN $Message" -ForegroundColor Yellow
    $counts.Warnings++
  }

  function Write-AapDiagInfo {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "  - $Message" -ForegroundColor Cyan
  }

  Write-Host ''
  Write-Host 'aap-demo diagnose - Checking environment health...' -ForegroundColor Cyan
  Write-Host ''

  # Cluster
  Write-Host 'Cluster:'
  $crcJson = Get-AapCrcStatusJson
  $crcState = if ($crcJson -and $crcJson.PSObject.Properties['crcStatus']) {
    [string]$crcJson.crcStatus
  } else {
    'Unknown'
  }

  switch ($crcState) {
    'Running' {
      $version = if ($crcJson.openshiftVersion) { [string]$crcJson.openshiftVersion } else { '' }
      if ($version) {
        Write-AapDiagPass "OpenShift Local running (MicroShift $version)"
      } else {
        Write-AapDiagPass 'OpenShift Local running'
      }
    }
    'Stopped' {
      Write-AapDiagFail 'OpenShift Local is stopped - run: crc start'
    }
    default {
      Write-AapDiagFail 'OpenShift Local cluster not found - run: aap-demo create'
    }
  }

  Initialize-AapKubeEnvironment
  if ((Invoke-AapOcQuiet @('cluster-info')) -ne 0) {
    Write-AapDiagFail 'oc cannot connect to cluster'
    Write-Host ''
    Write-Host 'Cannot proceed without cluster connectivity.'
    $kube = Get-AapKubeconfigPath
    Write-Host "  Check KUBECONFIG: $kube"
    return
  }
  Write-AapDiagPass 'oc connected'
  Write-Host ''

  # Storage
  Write-Host 'Storage:'
  if ((Invoke-AapOcQuiet @('get', 'sc', 'topolvm-provisioner')) -eq 0) {
    Write-AapDiagPass 'topolvm-provisioner StorageClass (default)'
  } else {
    Write-AapDiagWarn 'topolvm-provisioner StorageClass not found'
  }

  if ((Invoke-AapOcQuiet @('get', 'sc', 'nfs-local-rwx')) -eq 0) {
    Write-AapDiagPass 'nfs-local-rwx StorageClass (RWX)'
    $nfsResult = Invoke-AapOcCapture @(
      'get', 'deployment', 'nfs-server', '-n', 'nfs-storage',
      '-o', 'jsonpath={.status.readyReplicas}'
    )
    $nfsReady = if ($nfsResult.ExitCode -eq 0 -and $nfsResult.Output) {
      [int]$nfsResult.Output.Trim()
    } else { 0 }
    if ($nfsReady -gt 0) {
      Write-AapDiagPass 'NFS server pod running'
    } else {
      Write-AapDiagFail 'NFS server pod not running - run: aap-demo create (or oc rollout restart deployment/nfs-server -n nfs-storage)'
    }
  } else {
    Write-AapDiagWarn 'nfs-local-rwx StorageClass not found - hub RWX storage unavailable'
    Write-AapDiagInfo "Fix: re-run 'aap-demo create' to deploy NFS provisioner, or create the StorageClass manually"
  }

  $diskPct = Get-AapCrcDiskUsagePercent
  if ($diskPct -gt 90) {
    Write-AapDiagFail "Disk usage: ${diskPct}% - critically low space"
  } elseif ($diskPct -gt 80) {
    Write-AapDiagWarn "Disk usage: ${diskPct}% - consider pruning: aap-demo ssh && sudo crictl rmi --prune"
  } else {
    Write-AapDiagPass "Disk usage: ${diskPct}%"
  }
  Write-Host ''

  # Security
  Write-Host 'Security:'
  $nsExists = (Invoke-AapOcQuiet @('get', 'namespace', $Namespace)) -eq 0
  $sccAnyuid = 0
  $sccPrivileged = 0

  if ($nsExists) {
    $saPattern = [regex]::Escape("system:serviceaccounts:$Namespace")
    $crbResult = Invoke-AapOcCapture @('get', 'clusterrolebinding', '-o', 'wide')
    if ($crbResult.ExitCode -eq 0) {
      $sccAnyuid = @($crbResult.Lines | Where-Object {
        $_ -match 'scc:anyuid' -and $_ -match $saPattern
      }).Count
      $sccPrivileged = @($crbResult.Lines | Where-Object {
        $_ -match 'scc:privileged' -and $_ -match $saPattern
      }).Count
    }
    if ($sccAnyuid -eq 0) {
      $rbResult = Invoke-AapOcCapture @('get', 'rolebinding', '-n', $Namespace, '-o', 'wide')
      if ($rbResult.ExitCode -eq 0) {
        $sccAnyuid = @($rbResult.Lines | Where-Object { $_ -match 'scc:anyuid' }).Count
        $sccPrivileged = @($rbResult.Lines | Where-Object { $_ -match 'scc:privileged' }).Count
      }
    }
  }

  if ($sccAnyuid -gt 0 -and $sccPrivileged -gt 0) {
    Write-AapDiagPass "SCCs granted (anyuid + privileged) in $Namespace"
  } elseif ($sccAnyuid -gt 0) {
    Write-AapDiagWarn "Only anyuid SCC granted - privileged missing in $Namespace"
  } elseif ($sccPrivileged -gt 0) {
    Write-AapDiagWarn "Only privileged SCC granted - anyuid missing in $Namespace"
  } elseif ($nsExists) {
    Write-AapDiagFail "No SCCs granted in $Namespace - pods will fail to start"
    Write-AapDiagInfo "Fix: oc adm policy add-scc-to-group anyuid system:serviceaccounts:$Namespace"
    Write-AapDiagInfo "Fix: oc adm policy add-scc-to-group privileged system:serviceaccounts:$Namespace"
  } else {
    Write-AapDiagInfo "Namespace $Namespace does not exist yet (will be created on deploy)"
  }

  if ($nsExists) {
    $deployResult = Invoke-AapOcCapture @('get', 'deployment', '-n', $Namespace, '-o', 'name')
    $gwDeploy = if ($deployResult.ExitCode -eq 0) {
      $deployResult.Lines |
        Where-Object { $_ -match 'gateway' -and $_ -notmatch 'operator' } |
        Select-Object -First 1
    } else { $null }

    if ($gwDeploy) {
      $sgResult = Invoke-AapOcCapture @(
        'get', $gwDeploy, '-n', $Namespace,
        '-o', 'jsonpath={.spec.template.spec.securityContext.supplementalGroups}'
      )
      $sg = if ($sgResult.ExitCode -eq 0) { $sgResult.Output.Trim() } else { '' }
      $readyResult = Invoke-AapOcCapture @(
        'get', $gwDeploy, '-n', $Namespace,
        '-o', 'jsonpath={.status.readyReplicas}'
      )
      $gwReady = if ($readyResult.ExitCode -eq 0 -and $readyResult.Output) {
        [int]$readyResult.Output.Trim()
      } else { 0 }

      if ($sg -eq '[0]') {
        Write-AapDiagPass 'Gateway has supplementalGroups: [0]'
      } elseif ($gwReady -gt 0) {
        Write-AapDiagPass "Gateway running ($($gwReady) ready replica(s))"
      } else {
        Write-AapDiagFail 'Gateway missing supplementalGroups: [0] - supervisord may crash with EACCES'
        Write-AapDiagInfo ('Fix: oc patch ' + $gwDeploy + ' -n ' + $Namespace + ' --type=json --patch-file <patch.json>')
      }
    }

    $psaResult = Invoke-AapOcCapture @(
      'get', 'namespace', $Namespace,
      '-o', 'jsonpath={.metadata.labels.pod-security\.kubernetes\.io/enforce}'
    )
    $psa = if ($psaResult.ExitCode -eq 0) { $psaResult.Output.Trim() } else { '' }
    if ($psa -eq 'privileged') {
      Write-AapDiagPass 'Namespace PSA labels: privileged'
    } elseif ($psa) {
      Write-AapDiagWarn "Namespace PSA enforce: $psa (expected: privileged)"
    } else {
      Write-AapDiagFail "Namespace $Namespace missing PSA labels"
    }
  }
  Write-Host ''

  # AAP deployment
  Write-Host 'AAP Deployment:'
  $aapNameResult = Invoke-AapOcCapture @(
    'get', 'aap', '-n', $Namespace,
    '-o', 'jsonpath={.items[0].metadata.name}'
  )
  $aapName = if ($aapNameResult.ExitCode -eq 0) { $aapNameResult.Output.Trim() } else { '' }

  if (-not $aapName) {
    Write-AapDiagInfo "No AAP instance found in $Namespace"
  } else {
    $idleResult = Invoke-AapOcCapture @(
      'get', 'aap', $aapName, '-n', $Namespace,
      '-o', 'jsonpath={.spec.idle_aap}'
    )
    $idle = if ($idleResult.ExitCode -eq 0) { $idleResult.Output.Trim() } else { '' }

    if ($idle -eq 'true') {
      Write-AapDiagInfo "AAP '$aapName' is idle (scaled down)"
    } else {
      $aapJsonResult = Invoke-AapOcCapture @('get', 'aap', $aapName, '-n', $Namespace, '-o', 'json')
      $aapOk = ''
      $aapFail = ''
      $failMsg = 'unknown'
      if ($aapJsonResult.ExitCode -eq 0 -and $aapJsonResult.Output) {
        try {
          $aapObj = $aapJsonResult.Output | ConvertFrom-Json
          foreach ($cond in @($aapObj.status.conditions)) {
            if ($cond.type -eq 'Successful') { $aapOk = [string]$cond.status }
            if ($cond.type -eq 'Failure') {
              $aapFail = [string]$cond.status
              if ($cond.message) { $failMsg = [string]$cond.message }
            }
          }
        } catch {
          $aapOk = ''
        }
      }

      if ($aapOk -eq 'True') {
        Write-AapDiagPass "AAP '$aapName' deployed successfully"
      } elseif ($aapFail -eq 'True') {
        Write-AapDiagFail "AAP '$aapName' has failures: $failMsg"
      } else {
        Write-AapDiagWarn "AAP '$aapName' is still reconciling"
      }
    }

    $podsResult = Invoke-AapOcCapture @('get', 'pods', '-n', $Namespace, '--no-headers')
    $pods = if ($podsResult.ExitCode -eq 0) { $podsResult.Lines } else { @() }
    $activePods = @($pods | Where-Object { $_ -notmatch 'Completed' })
    $runningPods = @($pods | Where-Object { $_ -match 'Running' })
    $problemPods = @($pods | Where-Object { $_ -match 'CrashLoopBackOff|Error|ImagePullBackOff|Pending' })

    if ($problemPods.Count -gt 0) {
      Write-AapDiagFail "$($problemPods.Count) pod(s) in error state ($($runningPods.Count)/$($activePods.Count) running)"
      foreach ($line in $problemPods) { Write-AapDiagInfo "  $line" }
    } elseif ($activePods.Count -gt 0) {
      Write-AapDiagPass "All pods healthy ($($runningPods.Count)/$($activePods.Count) running)"
    }

    $pvcResult = Invoke-AapOcCapture @('get', 'pvc', '-n', $Namespace, '--no-headers')
    $pvcs = if ($pvcResult.ExitCode -eq 0) { $pvcResult.Lines } else { @() }
    $pendingPvcs = @($pvcs | Where-Object { $_ -match 'Pending' })
    $boundPvcs = @($pvcs | Where-Object { $_ -match 'Bound' })

    if ($pendingPvcs.Count -gt 0) {
      Write-AapDiagFail "$($pendingPvcs.Count) PVC(s) pending"
      foreach ($line in $pendingPvcs) { Write-AapDiagInfo "  $line" }
    } elseif ($boundPvcs.Count -gt 0) {
      Write-AapDiagPass "All PVCs bound ($($boundPvcs.Count))"
    }
  }
  Write-Host ''

  # DNS
  Write-Host 'DNS:'
  $dnsResult = Invoke-AapOcCapture @('get', 'pods', '-n', 'openshift-dns', '--no-headers')
  $dnsRunning = if ($dnsResult.ExitCode -eq 0) {
    @($dnsResult.Lines | Where-Object { $_ -match 'Running' }).Count
  } else { 0 }

  if ($dnsRunning -gt 0) {
    Write-AapDiagPass "CoreDNS running ($($dnsRunning) pods)"
  } else {
    Write-AapDiagWarn 'CoreDNS pods not found in openshift-dns'
  }
  Write-Host ''

  # Summary
  Write-Host ('-' * 37)
  if ($counts.Issues -eq 0 -and $counts.Warnings -eq 0) {
    Write-Host 'All checks passed - environment is healthy' -ForegroundColor Green
  } elseif ($counts.Issues -eq 0) {
    Write-Host "$($counts.Warnings) warning(s), no critical issues" -ForegroundColor Yellow
  } else {
    Write-Host "$($counts.Issues) issue(s), $($counts.Warnings) warning(s)" -ForegroundColor Red
    Write-Host ''
    Write-Host 'For detailed diagnostics: aap-demo must-gather'
    Write-Host 'For AI-assisted analysis:  aap-demo diagnose --ai'
  }
  Write-Host ''
}
