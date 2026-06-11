# Infrastructure dispatch (infra-api.sh port)

function Invoke-AapDemoInfraCommand {
    param(
        [Parameter(Mandatory)][ValidateSet('exec', 'state', 'name', 'kubeconfig')]
        [string]$Action,
        [string]$Command,
        [string]$Dest
    )
    switch ($Action) {
        'exec' { Invoke-AapDemoInfraExec -Command $Command }
        'state' { return Get-AapDemoInfraState }
        'name' { return Get-AapDemoInfraName }
        'kubeconfig' { return Get-AapDemoInfraKubeconfig -Dest $Dest }
    }
}
