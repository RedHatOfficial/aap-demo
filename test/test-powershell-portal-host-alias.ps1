# Regression test for the MicroShift portal OAuth host alias payload.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $repoRoot 'powershell/native/AapDemo.psm1') -Force -PassThru

$patchJson = & $module {
  New-AapPortalAapRouteHostAliasPatch `
    -AapRoute 'aap-aap-operator.apps.127.0.0.1.nip.io' `
    -AapServiceIp '10.43.121.143'
}

$patch = $patchJson | ConvertFrom-Json
$alias = @($patch.spec.template.spec.hostAliases)[0]
if ($alias.ip -ne '10.43.121.143') {
  throw "Expected AAP service IP in host alias, got '$($alias.ip)'"
}
if (@($alias.hostnames) -notcontains 'aap-aap-operator.apps.127.0.0.1.nip.io') {
  throw 'Expected the AAP route hostname in hostAliases'
}

$portalSource = Get-Content (Join-Path $repoRoot 'powershell/native/Private/Portal.ps1') -Raw
if ($portalSource -notmatch '(?s)function Invoke-AapDeployPortalAddon.*?Update-AapPortalAapRouteHostAlias') {
  throw 'Native portal enable path must apply the AAP route host alias before OAuth verification'
}

Write-Output 'Portal host alias checks passed'
