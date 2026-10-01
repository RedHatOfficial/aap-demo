# Windows-side checks for commands that the delegated Bash deploy path needs.

function Get-AapWindowsCommandPath {
  param([Parameter(Mandatory)][string[]]$Names)

  foreach ($name in $Names) {
    $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { continue }
    $path = if ($command.Path) { $command.Path } else { $command.Source }
    if ($path) { return $path }
  }
  return $null
}

function Get-AapWindowsDeployPrerequisiteFailures {
  param(
    [AllowEmptyString()][string]$GitBashPath,
    [AllowEmptyString()][string]$CrcPath,
    [AllowEmptyString()][string]$KubernetesPath,
    [AllowEmptyString()][string]$JqPath,
    [AllowEmptyString()][string]$PythonPath
  )

  $missing = [System.Collections.Generic.List[string]]::new()
  if ([string]::IsNullOrWhiteSpace($GitBashPath)) { $missing.Add('Git Bash') }
  if ([string]::IsNullOrWhiteSpace($CrcPath)) { $missing.Add('CRC') }
  if ([string]::IsNullOrWhiteSpace($KubernetesPath)) { $missing.Add('oc or kubectl') }
  if ([string]::IsNullOrWhiteSpace($JqPath)) { $missing.Add('jq') }
  if ([string]::IsNullOrWhiteSpace($PythonPath)) { $missing.Add('Python') }
  return $missing.ToArray()
}

function Assert-AapWindowsDeployPrerequisites {
  $gitBashPath = $null
  try { $gitBashPath = Get-AapGitBashExecutable } catch { }

  $crcPath = Get-AapWindowsCommandPath -Names @('crc')
  $kubernetesPath = Get-AapWindowsCommandPath -Names @('oc', 'kubectl')
  $jqPath = Get-AapWindowsCommandPath -Names @('jq')
  if ([string]::IsNullOrWhiteSpace($jqPath)) {
    try { Ensure-AapJq } catch { }
    $jqPath = Get-AapWindowsCommandPath -Names @('jq')
  }
  $pythonPath = Get-AapPythonRuntimePath
  if ([string]::IsNullOrWhiteSpace($pythonPath)) {
    try { Ensure-AapPython } catch { }
    $pythonPath = Get-AapPythonRuntimePath
  }
  $missing = @(Get-AapWindowsDeployPrerequisiteFailures `
    -GitBashPath $gitBashPath `
    -CrcPath $crcPath `
    -KubernetesPath $kubernetesPath `
    -JqPath $jqPath `
    -PythonPath $pythonPath)

  if ($missing.Count -eq 0) { return }

  $guidance = @(
    'Install Git for Windows so bash.exe is available.'
    'Install OpenShift Local (CRC) and ensure crc.exe is on PATH.'
    'Install the Red Hat OpenShift client (oc) or kubectl and ensure it is on PATH.'
    'Install jq: winget install --id jqlang.jq -e --source winget'
    'Install Python: winget install --id Python.Python.3.13 -e --source winget'
  )
  $details = @($missing | ForEach-Object { "  - $_" })
  throw ((@('Windows deploy prerequisites are missing:') + $details + @('', 'Next steps:') +
      @($guidance | ForEach-Object { "  - $_" })) -join [Environment]::NewLine)
}
