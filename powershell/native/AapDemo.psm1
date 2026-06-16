# PowerShell implementation of aap-demo commands.



$PrivateDir = Join-Path $PSScriptRoot 'Private'

. (Join-Path $PrivateDir 'Helpers.ps1')

. (Join-Path $PrivateDir 'Create.ps1')

. (Join-Path $PrivateDir 'Deploy.ps1')

. (Join-Path $PrivateDir 'Status.ps1')

. (Join-Path $PrivateDir 'Diagnose.ps1')

. (Join-Path $PrivateDir 'Watch.ps1')

. (Join-Path $PrivateDir 'Addons.ps1')

. (Join-Path $PrivateDir 'Commands.ps1')



Export-ModuleMember -Function @(

  'Invoke-AapDemoCreate'

  'Invoke-AapDemoDeploy'

  'Invoke-AapDemoDeployAap'

  'Invoke-AapDemoStatus'

  'Invoke-AapDemoDiagnose'

  'Invoke-AapDemoWatch'

  'Invoke-AapDemoStop'

  'Invoke-AapDemoDestroy'

  'Invoke-AapDemoClean'

  'Invoke-AapDemoRepair'

  'Invoke-AapDemoSetup'

  'Invoke-AapDemoSsh'

  'Invoke-AapDemoKubeconfig'

  'Invoke-AapDemoIdle'

  'Invoke-AapDemoConfig'

  'Invoke-AapDemoUpdate'

  'Invoke-AapDemoRedhatStatus'

  'Invoke-AapDemoMustGather'

  'Invoke-AapDemoEnable'

  'Invoke-AapDemoDisable'

  'Invoke-AapDemoRedeploy'

  'Invoke-AapDemoRedeployAll'

  'Get-AapDemoHelp'

  'Invoke-AapBashCli'

)

