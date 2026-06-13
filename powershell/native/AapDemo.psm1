# PowerShell implementation of core aap-demo commands.

$PrivateDir = Join-Path $PSScriptRoot 'Private'
. (Join-Path $PrivateDir 'Helpers.ps1')
. (Join-Path $PrivateDir 'Create.ps1')
. (Join-Path $PrivateDir 'Deploy.ps1')
. (Join-Path $PrivateDir 'Status.ps1')
. (Join-Path $PrivateDir 'Diagnose.ps1')

Export-ModuleMember -Function @(
  'Invoke-AapDemoCreate'
  'Invoke-AapDemoDeploy'
  'Invoke-AapDemoStatus'
  'Invoke-AapDemoDiagnose'
  'Get-AapDemoHelp'
  'Invoke-AapBashCli'
)
