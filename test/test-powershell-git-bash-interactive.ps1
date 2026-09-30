# Verify interactive Bash addon prompts remain usable through the PowerShell wrapper.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$pwsh = (Get-Command 'pwsh' -ErrorAction Stop).Source
$driverPath = Join-Path ([IO.Path]::GetTempPath()) ("aap-ao-interactive-{0}.ps1" -f [guid]::NewGuid().ToString('N'))

$driver = @'
param([Parameter(Mandatory)][string]$RepoRoot)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $RepoRoot 'powershell/native/AapDemo.psm1') -Force

$stateRoot = Join-Path ([IO.Path]::GetTempPath()) ("aap-ao-state-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
$env:AAP_DEMO_DIR = Join-Path $stateRoot 'home'
$env:AAP_DEMO_CONFIG = Join-Path $stateRoot 'config'
$env:AO_LLM_PROVIDER = 'ollama'

$result = Invoke-AapGitBashInteractive -Command 'printf "interactive Bash output\\n"; source includes/ao-llm.sh; aap_demo_ao_llm_prepare'
if (-not $result.Success) {
  throw "Interactive Git Bash command failed with exit $($result.ExitCode)"
}
Write-Output 'Interactive Git Bash command passed'
'@

Set-Content -LiteralPath $driverPath -Value $driver -Encoding UTF8
try {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $pwsh
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.WorkingDirectory = $repoRoot
  $arguments = @('-NoProfile', '-NonInteractive', '-File', $driverPath, '-RepoRoot', $repoRoot)
  if ($psi.PSObject.Properties['ArgumentList']) {
    foreach ($argument in $arguments) { [void]$psi.ArgumentList.Add([string]$argument) }
  } else {
    $psi.Arguments = ($arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '(\*)"', '$1$1\"') + '"' } else { $_ }
      }) -join ' '
  }

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $psi
  if (-not $process.Start()) { throw 'Unable to start interactive bridge test driver' }
  $process.StandardInput.Close()
  $stdout = $process.StandardOutput.ReadToEnd()
  $stderr = $process.StandardError.ReadToEnd()
  $process.WaitForExit()
  if ($process.ExitCode -ne 0) {
    throw "Interactive bridge test failed (exit $($process.ExitCode)): $stdout $stderr"
  }
  if ($stdout -notmatch 'interactive Bash output' -or $stdout -notmatch 'Interactive Git Bash command passed') {
    throw "Interactive Bash output was not visible: $stdout $stderr"
  }
} finally {
  if ($process) { $process.Dispose() }
  Remove-Item -LiteralPath $driverPath -Force -ErrorAction SilentlyContinue
}

Write-Output 'PowerShell Git Bash interactive checks passed'
