@{
    RootModule        = 'AapDemo.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author            = 'aap-demo contributors'
    Description       = 'Native PowerShell module for aap-demo on Windows (OpenShift Local / CRC)'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
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
}
