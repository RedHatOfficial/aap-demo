# Verify the Windows wrapper can execute the repository's Bash addon path.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $repoRoot 'powershell/native/AapDemo.psm1') -Force -PassThru

$bash = & $module { Get-AapGitBashExecutable }
if (-not (Test-Path -LiteralPath $bash)) {
  throw "Git Bash executable was not found at '$bash'"
}

$result = & $module {
  Invoke-AapGitBash -Command 'printf "%s|%s" "$AAP_TEST_BRIDGE_VALUE" "$1"' `
    -Arguments @('argument with spaces') `
    -Environment @{ AAP_TEST_BRIDGE_VALUE = 'forwarded-value' }
}
if (-not $result.Success -or $result.Stdout.Trim() -ne 'forwarded-value|argument with spaces') {
  throw "Git Bash bridge did not preserve environment and argument values: $($result.Stdout)"
}
$failedCommand = & $module { Invoke-AapGitBash -Command 'exit 7' }
if ($failedCommand.Success -or $failedCommand.ExitCode -ne 7) {
  throw "Git Bash bridge did not preserve the child exit code: $($failedCommand.ExitCode)"
}

$cliResult = & $module { Invoke-AapGitBashCli -Arguments @('version') }
if (-not $cliResult.Success -or $cliResult.Stdout -notmatch '(?i)aap-demo') {
  throw "Full Git Bash CLI delegation did not run the repository wrapper: $($cliResult.Output)"
}

$pwsh = (Get-Command 'pwsh' -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { $pwsh = (Get-Command 'powershell.exe' -ErrorAction Stop).Source }
$wrapper = Join-Path $repoRoot 'powershell/aap-demo.ps1'
$version = Invoke-AapNativeProcess -FilePath $pwsh -ArgumentList @(
  '-NoProfile', '-NonInteractive', '-File', $wrapper, 'version'
)
if (-not $version.Success -or $version.Stdout -notmatch '(?i)aap-demo') {
  throw "PowerShell wrapper did not delegate the version command: $($version.Output)"
}
$blocked = Invoke-AapNativeProcess -FilePath $pwsh -ArgumentList @(
  '-NoProfile', '-NonInteractive', '-File', $wrapper, 'enable', 'apme-eap'
)
if ($blocked.Success -or $blocked.Output -notmatch 'not available through the Windows wrapper') {
  throw 'PowerShell wrapper did not enforce the Windows addon policy'
}
$blockedWithGlobalFlag = Invoke-AapNativeProcess -FilePath $pwsh -ArgumentList @(
  '-NoProfile', '-NonInteractive', '-File', $wrapper, '--force', 'enable', 'apme-eap'
)
if ($blockedWithGlobalFlag.Success -or $blockedWithGlobalFlag.Output -notmatch 'not available through the Windows wrapper') {
  throw 'PowerShell wrapper did not enforce the addon policy when global flags precede the command'
}
$blockedFleet = Invoke-AapNativeProcess -FilePath $pwsh -ArgumentList @(
  '-NoProfile', '-NonInteractive', '-File', $wrapper, 'fleet', 'list'
)
if ($blockedFleet.Success -or $blockedFleet.Output -notmatch 'not available through the Windows wrapper') {
  throw 'PowerShell wrapper did not block the Fleet command'
}
$help = Invoke-AapNativeProcess -FilePath $pwsh -ArgumentList @(
  '-NoProfile', '-NonInteractive', '-File', $wrapper, 'help'
)
if (-not $help.Success -or $help.Stdout -match '(?im)^\s*fleet\b|\bapme\b') {
  throw 'PowerShell help exposed an addon that is excluded from the Windows wrapper'
}

$dispatch = Get-Content (Join-Path $repoRoot 'powershell/native/Private/Addons.ps1') -Raw
if ($dispatch -notmatch 'Invoke-AapGitBash' -or $dispatch -notmatch 'aap-demo\.sh' -or
    $dispatch -notmatch '-Interactive') {
  throw 'Windows addon dispatch must use the interactive repository Git Bash wrapper'
}
$wrapperSource = Get-Content $wrapper -Raw
if ($wrapperSource -notmatch 'Invoke-AapGitBashCli' -or
    $wrapperSource -notmatch 'WindowsBlockedAddons') {
  throw 'PowerShell wrapper must delegate through Git Bash and enforce addon policy'
}

Write-Output 'PowerShell Git Bash addon checks passed'
