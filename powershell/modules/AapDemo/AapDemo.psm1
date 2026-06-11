# aap-demo PowerShell module loader

$PrivateDir = Join-Path $PSScriptRoot 'Private'
$PublicDir = Join-Path $PSScriptRoot 'Public'

Get-ChildItem -Path $PrivateDir -Filter '*.ps1' -File | ForEach-Object { . $_.FullName }
Get-ChildItem -Path $PublicDir -Filter '*.ps1' -File | ForEach-Object { . $_.FullName }

Export-ModuleMember -Function @(
    'Initialize-AapDemoConfig'
    'Invoke-AapDemoCreate'
    'Invoke-AapDemoDeploy'
    'Get-AapDemoStatus'
    'Invoke-AapDemoDiagnose'
    'Start-AapDemoCluster'
    'Stop-AapDemoCluster'
    'Remove-AapDemoCluster'
    'Show-AapDemoHelp'
    'Show-AapDemoWelcome'
    'Enter-AapDemoSsh'
    'Initialize-AapDemoKubeconfig'
)
