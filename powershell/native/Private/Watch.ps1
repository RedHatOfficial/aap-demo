function Write-AapWatchConditions {
  param([Parameter(Mandatory)][string]$Namespace)

  $aapJsonResult = Invoke-AapOcCapture @('get', 'aap', '-n', $Namespace, '-o', 'json')
  if ($aapJsonResult.ExitCode -ne 0 -or -not $aapJsonResult.Output) {
    Write-Host '  No status yet'
    return
  }

  $printed = $false
  try {
    $aapObj = $aapJsonResult.Output | ConvertFrom-Json
    foreach ($item in @($aapObj.items)) {
      foreach ($cond in @($item.status.conditions)) {
        $detail = if ($cond.reason) { [string]$cond.reason }
        elseif ($cond.message) { [string]$cond.message }
        else { 'n/a' }
        Write-Host ("  {0}: {1} - {2}" -f $cond.type, $cond.status, $detail)
        $printed = $true
      }
    }
  } catch {
    Write-Host '  No status yet'
    return
  }

  if (-not $printed) {
    Write-Host '  No status yet'
  }
}

function Invoke-AapDemoWatch {
  [CmdletBinding()]
  param(
    [string]$Namespace = $Script:AapDemoDefaultNamespace,
    [int]$IntervalSeconds = 10,
    [int]$TimeoutSeconds = 3600
  )

  Initialize-AapKubeEnvironment
  $watchStart = Get-Date

  while ($true) {
    Clear-Host

    $elapsed = [int]((Get-Date) - $watchStart).TotalSeconds
    $contextResult = Invoke-AapOcCapture @('config', 'current-context')
    $cluster = if ($contextResult.ExitCode -eq 0) { $contextResult.Output.Trim() } else { 'unknown' }

    Write-Host "=== AAP Deployment Status (${elapsed}s elapsed) ==="
    Write-Host "Cluster: $cluster | Namespace: $Namespace"
    Write-Host 'Press Ctrl+C to exit'
    Write-Host ''

    Write-Host 'AAP CR:'
    $aapResult = Invoke-AapOcCapture @('get', 'aap', '-n', $Namespace)
    if ($aapResult.ExitCode -eq 0 -and $aapResult.Output -notmatch '^No resources found') {
      $aapResult.Lines | ForEach-Object { Write-Host "  $_" }
    } else {
      Write-Host '  No AAP CR found'
    }
    Write-Host ''

    Write-Host 'Conditions:'
    Write-AapWatchConditions -Namespace $Namespace
    Write-Host ''

    Write-Host 'Pods:'
    $podsResult = Invoke-AapOcCapture @('get', 'pods', '-n', $Namespace)
    if ($podsResult.ExitCode -eq 0 -and $podsResult.Output -notmatch '^No resources found') {
      $podsResult.Lines | ForEach-Object { Write-Host "  $_" }
    } else {
      Write-Host '  No pods found'
    }
    Write-Host ''

    Write-Host 'Routes:'
    $routesResult = Invoke-AapOcCapture @('get', 'route', '-n', $Namespace)
    if ($routesResult.ExitCode -eq 0 -and $routesResult.Output -notmatch '^No resources found') {
      $routesResult.Lines | ForEach-Object { Write-Host "  $_" }
    } else {
      Write-Host '  No routes found'
    }
    Write-Host ''

    $routeResult = Invoke-AapOcCapture @(
      'get', 'route', '-n', $Namespace,
      '-o', 'jsonpath={.items[0].spec.host}'
    )
    $aapUrl = if ($routeResult.ExitCode -eq 0 -and $routeResult.Output.Trim()) {
      $routeResult.Output.Trim()
    } else {
      '(route not found)'
    }

    $adminPassword = Get-AapAdminPassword -Namespace $Namespace
    if ($adminPassword) {
      Write-Host 'Credentials:'
      Write-Host "  URL:      https://$aapUrl"
      Write-Host '  Username: admin'
      Write-Host "  Password: $adminPassword"
      Write-Host ''
    }

    if (Get-AapAapSuccessful -Namespace $Namespace) {
      $csvResult = Invoke-AapOcCapture @(
        'get', 'csv', '-n', $Namespace,
        '-o', 'jsonpath={.items[0].metadata.name}'
      )
      $csvName = if ($csvResult.ExitCode -eq 0) { $csvResult.Output.Trim() } else { '' }

      Write-Host 'AAP deployment successful!' -ForegroundColor Green
      Write-Host ''
      if ($csvName) { Write-Host "CSV: $csvName" }
      Write-Host "Namespace: $Namespace"
      Write-Host ''
      Write-Host "AAP UI: https://$aapUrl"
      Write-Host ''
      Write-Host 'Username: admin'
      if ($adminPassword) {
        Write-Host "Password: $adminPassword"
      } else {
        Write-Host "Password: (run: oc get secret -n $Namespace aap-admin-password -o jsonpath='{.data.password}')"
      }
      Write-Host ''
      Write-AapSetupPahReminder
      return
    }

    if ($elapsed -ge $TimeoutSeconds) {
      Write-AapWarn 'Deployment not complete after 60 minutes'
      Write-Host "Check: oc get aap -n $Namespace -o yaml"
      return
    }

    Start-Sleep -Seconds $IntervalSeconds
  }
}
