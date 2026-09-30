# Static Windows parity checks. This test does not contact CRC or mutate a cluster.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$parseErrors = @()

Get-ChildItem -LiteralPath (Join-Path $repoRoot 'powershell') -Recurse -Filter '*.ps1' | ForEach-Object {
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile(
    $_.FullName, [ref]$tokens, [ref]$errors
  ) | Out-Null
  if ($errors) { $parseErrors += $errors }
}

if ($parseErrors.Count -gt 0) {
  $parseErrors | ForEach-Object { Write-Error $_.Message }
  exit 1
}

$module = Import-Module (Join-Path $repoRoot 'powershell/native/AapDemo.psm1') -Force -PassThru
$addons = & $module { @($Script:AapAvailableAddons) }
$required = @(
  'mcp-server', 'portal', 'portal-operator', 'setup-pah', 'ao',
  'local-cache', 'product-demos', 'opa', 'ollama'
)

foreach ($addon in $required) {
  if ($addons -notcontains $addon) { throw "Missing Windows addon registry entry: $addon" }
}
if ($addons -contains 'fleet') { throw 'Fleet must remain out of scope for Windows parity' }
if ($addons -contains 'apme-eap') { throw 'APME must remain deferred from the Windows build while alpha' }
foreach ($legacyProductAddon in @('product-demos-base', 'product-demo-linux', 'product-demo-windows', 'product-demo-network', 'product-demo-cloud', 'product-demo-openshift', 'product-demo-satellite')) {
  if ($addons -contains $legacyProductAddon) { throw "Legacy product-demo addon must not be exposed on Windows: $legacyProductAddon" }
}
foreach ($command in @('Invoke-AapDemoStart', 'Invoke-AapDemoWire')) {
  if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
    throw "Missing PowerShell command: $command"
  }
}

$hostCommand = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $hostCommand) { $hostCommand = Get-Command powershell.exe -ErrorAction Stop }
$echoScript = Join-Path ([IO.Path]::GetTempPath()) ("aap-native-args-{0}.ps1" -f ([guid]::NewGuid().ToString('N')))
try {
  [IO.File]::WriteAllText($echoScript, 'Write-Output $args[0]', (New-Object Text.UTF8Encoding($false)))
  $runner = Invoke-AapNativeProcess -FilePath $hostCommand.Source -ArgumentList @(
    '-NoProfile', '-File', $echoScript, 'native argument with spaces'
  )
  if (-not $runner.Success -or $runner.Stdout.Trim() -ne 'native argument with spaces') {
    throw 'Native process runner did not preserve an argument containing spaces'
  }
} finally {
  Remove-Item -LiteralPath $echoScript -Force -ErrorAction SilentlyContinue
}

Write-Output 'PowerShell parity checks passed'
