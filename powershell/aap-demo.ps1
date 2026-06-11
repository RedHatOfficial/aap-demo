#!/usr/bin/env pwsh
# aap-demo — Windows PowerShell entry point
# See docs/windows/ARCHITECTURE.md

#Requires -Version 7.0

$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModulePath = Join-Path $ScriptRoot 'modules\AapDemo\AapDemo.psd1'

if (-not (Test-Path $ModulePath)) {
    Write-Error "AapDemo module not found: $ModulePath"
    exit 1
}

Import-Module $ModulePath -Force

# Parse arguments (mirrors aap-demo.sh subset)
$Command = $null
$ExtraArgs = [System.Collections.Generic.List[string]]::new()
$CliOverrides = @{}
$PendingFlag = $null
$DestroyReset = $false
$KubectlContext = ''
$KubectlKubeconfig = ''

foreach ($arg in $Args) {
    if ($PendingFlag) {
        switch ($PendingFlag) {
            'context' { $KubectlContext = $arg }
            'kubeconfig' { $KubectlKubeconfig = $arg }
        }
        $PendingFlag = $null
        continue
    }

    if ($arg -match '^--context=(.+)$') { $KubectlContext = $Matches[1]; continue }
    if ($arg -eq '--context') { $PendingFlag = 'context'; continue }
    if ($arg -match '^--kubeconfig=(.+)$') { $KubectlKubeconfig = $Matches[1]; continue }
    if ($arg -eq '--kubeconfig') { $PendingFlag = 'kubeconfig'; continue }
    if ($arg -eq '--reset') { $DestroyReset = $true; continue }

    if ($arg -match '^([^=]+)=(.+)$' -and $arg -notmatch '^(deploy|create)') {
        $CliOverrides[$Matches[1]] = $Matches[2]
        continue
    }

    switch -Regex ($arg) {
        '^(deploy|deploy-all|deploy-operator|create|destroy|stop|start|status|diagnose|help|--help|-h|ssh)$' {
            $Command = $arg
            continue
        }
    }

    if ($Command) {
        $ExtraArgs.Add($arg)
    } else {
        Write-Host "Unknown argument: $arg"
        Write-Host "Run 'aap-demo help' for usage"
        exit 1
    }
}

Initialize-AapDemoConfig -CliOverrides $CliOverrides -KubectlContext $KubectlContext -KubectlKubeconfig $KubectlKubeconfig

try {
    switch ($Command) {
        { $_ -in $null, '' } {
            Invoke-AapDemoDeploy
        }
        { $_ -in 'help', '--help', '-h' } {
            Show-AapDemoHelp
        }
        'create' {
            Invoke-AapDemoCreate
        }
        { $_ -in 'deploy', 'deploy-all' } {
            Invoke-AapDemoDeploy
        }
        'deploy-operator' {
            Invoke-AapDemoDeploy -OperatorOnly
        }
        'status' {
            Get-AapDemoStatus
        }
        'diagnose' {
            Invoke-AapDemoDiagnose
        }
        'start' {
            Start-AapDemoCluster
        }
        'stop' {
            Stop-AapDemoCluster
        }
        'destroy' {
            Remove-AapDemoCluster -Reset:$DestroyReset
        }
        'ssh' {
            Enter-AapDemoSsh
        }
        default {
            Show-AapDemoWelcome
        }
    }
} catch {
    Write-AapDemoError $_.Exception.Message
    if ($_.ScriptStackTrace) {
        Write-Verbose $_.ScriptStackTrace
    }
    exit 1
}
