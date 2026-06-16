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
      Write-Host 'Start with: crc start  or  aap-demo create'
      return
    }
    default {
      Write-Host 'Cluster:     not running' -ForegroundColor Red
      Write-Host ''
      Write-Host 'Create with: aap-demo create'
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

  Install-AapIngressCaTrust

  Write-Host 'Namespaces:'
  Write-Host '-----------'
  $nsResult = Invoke-AapOcCapture @('get', 'ns', '--no-headers', '-o', 'custom-columns=:metadata.name')
  $namespaces = if ($nsResult.ExitCode -eq 0) { $nsResult.Lines } else { @() }
  foreach ($ns in $namespaces) {
    if ([string]::IsNullOrWhiteSpace($ns)) { continue }
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
  Write-Host ''
}

function Get-AapDemoHelp {
  @'
aap-demo — Windows PowerShell CLI

USAGE:
    aap-demo <command> [options]

CLUSTER:
    create          Create OpenShift Local (CRC) cluster
    stop            Stop CRC cluster
    destroy         Delete CRC cluster (--reset clears saved preset)
    repair          Show CRC repair instructions
    setup           CRC setup info (handled by create)
    kubeconfig      Sync and merge kubeconfig (context: aap-demo)
    ssh             SSH into CRC VM

DEPLOY:
    deploy          Deploy AAP 2.7 via OLM (alias: deploy-all)
    deploy-operator Deploy operator only (no AAP CR)
    deploy-aap      Apply AAP CR only (operator must exist)
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
    enable <name>   Enable addon (PowerShell + oc)
    disable <name>  Disable addon

OTHER:
    config [k] [v]  Show or set ~/.aap-demo/config values
    update          git pull and reinstall launcher
    help            Show this help

OPTIONS:
    -Force          Redeploy even if AAP CR exists
    -Namespace=ns   Target namespace (default: aap-operator)
    -Channel=ch     OLM channel (default: stable-2.7)
    CR=name         AAP CR template (default: minimal)
    PUBLIC_URL=url  Required for noingress CRs
    --ai            AI-assisted diagnose (requires Git Bash + claude CLI)

EXAMPLES:
    aap-demo create
    aap-demo deploy
    aap-demo deploy -Force
    aap-demo deploy-operator
    aap-demo deploy-aap CR=minimal
    aap-demo status
    aap-demo diagnose
    aap-demo watch
    aap-demo idle true

NOTES:
    Requires oc and crc on PATH. OpenShift Local needs Hyper-V.
    Pull secret: %USERPROFILE%\.aap-demo\pull-secret.txt
    Git Bash: only needed for diagnose --ai.
'@
}
