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
    $aapCr = if ($aapResult.ExitCode -eq 0) { $aapResult.Lines | Select-Object -First 1 } else { $null }
    if ($aapCr) {
      $crName = ($aapCr -split '\s+')[0]
      $routeResult = Invoke-AapOcCapture @('get', 'route', $crName, '-n', $ns, '-o', 'jsonpath=https://{.spec.host}')
      $route = if ($routeResult.ExitCode -eq 0) { $routeResult.Output.Trim() } else { '' }
      Write-Host ("  {0,-30} {1}/{2} pods  {3}  {4}" -f $ns, $running, $total, $crName, $route)
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
  $aapNs = if ($aapNsResult.ExitCode -eq 0) {
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

POWERSHELL COMMANDS:
    create          Create OpenShift Local (CRC) cluster
    deploy          Deploy AAP 2.7 via OLM
    status          Show cluster and AAP status
    help            Show this help

DEPLOY OPTIONS:
    -Force          Redeploy even if AAP CR exists
    -Namespace=ns   Target namespace (default: aap-operator)

EXAMPLES:
    aap-demo create
    aap-demo deploy
    aap-demo deploy -Force
    aap-demo status

OTHER COMMANDS (Git Bash):
    diagnose, test, watch, clean, destroy, enable, idle, must-gather, ...
    These delegate to aap-demo.sh and require Git for Windows.

NOTES:
    OpenShift Local on Windows requires Hyper-V.
    Pull secret: %USERPROFILE%\.aap-demo\pull-secret.txt
'@
}
