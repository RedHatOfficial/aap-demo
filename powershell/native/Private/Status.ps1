function Invoke-AapDemoStatus {
  [CmdletBinding()]
  param(
    [string]$Namespace = $Script:AapDemoDefaultNamespace
  )

  Write-AapHeader 'AAP Demo Status'

  $crc = Get-AapCrcStatus
  $state = [string]$crc.crcStatus
  Write-Host "Infra:       OpenShift Local (CRC)"

  switch ($state) {
    'Running' {
      Write-Host 'Cluster:     running' -ForegroundColor Green
    }
    'Stopped' {
      Write-Host 'Cluster:     stopped' -ForegroundColor Yellow
      Write-Host ''
      Write-Host 'Start with: aap-demo deploy'
      return
    }
    default {
      Write-Host 'Cluster:     not running' -ForegroundColor Red
      Write-Host ''
      Write-Host 'Run: aap-demo deploy'
      return
    }
  }

  Initialize-AapKubeEnvironment
  $kube = Get-AapKubeconfigPath
  Write-Host "Kubeconfig:  $kube"
  Write-Host ''

  if ((Invoke-AapOcQuiet @('cluster-info')) -ne 0) {
    Write-AapWarn 'oc cannot connect'
    return
  }

  Set-AapIngressCaEnvFromSaved

  Write-Host 'Namespaces:'
  Write-Host '-----------'
  $hiddenNamespaces = @(
    'default',
    'kube-node-lease',
    'kube-public',
    'openshift-controller-manager',
    'openshift-infra',
    'openshift-kube-controller-manager',
    'openshift-route-controller-manager',
    'operators'
  )
  $nsResult = Invoke-AapOcCapture @('get', 'ns', '--no-headers', '-o', 'custom-columns=:metadata.name')
  $namespaces = if ($nsResult.ExitCode -eq 0) { $nsResult.Lines } else { @() }
  foreach ($ns in $namespaces) {
    if ([string]::IsNullOrWhiteSpace($ns)) { continue }
    if ($hiddenNamespaces -contains $ns.Trim()) { continue }
    $podsResult = Invoke-AapOcCapture @('get', 'pods', '-n', $ns, '--no-headers')
    $pods = if ($podsResult.ExitCode -eq 0) { $podsResult.Lines } else { @() }
    if (-not $pods) { continue }
    $total = @($pods | Where-Object { $_ -notmatch 'Completed' }).Count
    if ($total -eq 0) { continue }
    $running = @($pods | Select-String 'Running').Count
    $aapResult = Invoke-AapOcCapture @('get', 'aap', '-n', $ns, '--no-headers')
    $aapCr = if ($aapResult.ExitCode -eq 0 -and $aapResult.Output -notmatch '^No resources found') {
      $aapResult.Lines | Select-Object -First 1
    } else { $null }
    if ($aapCr) {
      $crName = ($aapCr -split '\s+')[0]
      $idleResult = Invoke-AapOcCapture @(
        'get', 'aap', $crName, '-n', $ns, '-o', 'jsonpath={.spec.idle_aap}'
      )
      $idleLabel = if ($idleResult.ExitCode -eq 0 -and $idleResult.Output.Trim() -eq 'true') {
        ' (idle)'
      } else { '' }
      $routeResult = Invoke-AapOcCapture @('get', 'route', $crName, '-n', $ns, '-o', 'jsonpath=https://{.spec.host}')
      $route = if ($routeResult.ExitCode -eq 0) { $routeResult.Output.Trim() } else { '' }
      Write-Host ("  {0,-30} {1}/{2} pods{3}  {4}  {5}" -f $ns, $running, $total, $idleLabel, $crName, $route)
    } else {
      Write-Host ("  {0,-30} {1}/{2} pods" -f $ns, $running, $total)
    }
  }

  Write-Host ''
  Write-Host 'AAP Deployments:'
  Write-Host '----------------'
  $routesResult = Invoke-AapOcCapture @('get', 'route', '-A', '--no-headers')
  $routes = if ($routesResult.ExitCode -eq 0) {
    $routesResult.Lines |
      Where-Object { $_ -notmatch '^(openshift-|kube-|aap-demo-)' } |
      ForEach-Object { $cols = $_ -split '\s+'; "  https://$($cols[2])" }
  } else { @() }
  if ($routes) { $routes | ForEach-Object { Write-Host $_ } }
  else { Write-Host '  (no AAP routes found)' }

  Write-Host ''
  Write-Host 'Credentials:'
  Write-Host '------------'
  $aapNsResult = Invoke-AapOcCapture @('get', 'aap', '-A', '--no-headers')
  $aapNs = if ($aapNsResult.ExitCode -eq 0 -and $aapNsResult.Output -notmatch '^No resources found') {
    $aapNsResult.Lines | ForEach-Object { ($_ -split '\s+')[0] } | Sort-Object -Unique
  } else { @() }
  $foundCred = $false
  foreach ($ns in $aapNs) {
    foreach ($secretName in @('aap-admin-password', 'myaap-admin-password', 'aap-controller-admin-password')) {
      $pwResult = Invoke-AapOcCapture @('get', 'secret', $secretName, '-n', $ns, '-o', 'jsonpath={.data.password}')
      $pw = if ($pwResult.ExitCode -eq 0) { $pwResult.Output.Trim() } else { '' }
      if ($pw) {
        $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pw))
        Write-Host ("  {0,-20} admin / {1}" -f "${ns}:", $decoded)
        $foundCred = $true
        break
      }
    }
  }
  if (-not $foundCred) { Write-Host '  (no admin password secret found yet)' }

  $savedAddons = @(Get-AapAddonsList)
  Write-Host ''
  Write-Host 'Addons:'
  Write-Host '-------'
  foreach ($a in $Script:AapAvailableAddons) {
    $enabled = $savedAddons -contains $a
    $label = Get-AapAddonStatusLabel -Addon $a -Namespace $Namespace -Enabled $enabled
    if ($label) {
      Write-Host ("  {0,-15} {1}" -f $a, $label)
    } else {
      Write-Host "  $a"
    }
  }
  Write-Host ''
}

function Get-AapDemoHelp {
  @'
aap-demo — Windows PowerShell CLI

USAGE:
    aap-demo <command> [options]

CLUSTER:
    stop            Stop cluster
    start           Start stopped cluster
    destroy         Deletes cluster (--reset clears saved preset)
    repair          Show repair instructions
    ssh             SSH into VM

DEPLOY:
    deploy          Deploy AAP 2.7 via OLM (creates cluster if missing; alias: deploy-all)
    redeploy        Clean namespace and redeploy AAP
    redeploy-all    Destroy cluster and full redeploy
    clean           Remove AAP namespace and resources
    watch           Monitor AAP deployment progress

STATUS:
    status          Show cluster and AAP status
    diagnose        Check environment health
    idle            Scale AAP down/up (true|false)
    redhat-status   Check Red Hat registry status (alias: rh-status)
    must-gather     Collect diagnostic bundle

ADDONS:
    enable portal   Enable Self-Service Portal (Helm; auto-detects arm64 vs amd64)
                    Requires: AAP 2.6+, Helm 3.10+, Red Hat pull secret
    enable mcp-server  Enable MCP server for AI assistants
    disable <name>  Disable an addon (portal, mcp-server)

NOTES:
    Requires oc and crc on PATH. OpenShift Local needs Hyper-V.
    Pull secret: %USERPROFILE%\.aap-demo\pull-secret.txt
'@
}
