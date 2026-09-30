function ConvertTo-AapWindowsProcessArgument {
  param([AllowEmptyString()][string]$Argument)

  if ($null -eq $Argument -or $Argument.Length -eq 0) { return '""' }
  if ($Argument -notmatch '[\s"]') { return $Argument }
  $quoted = $Argument -replace '(\\*)"', '$1$1\"'
  $quoted = $quoted -replace '(\\+)$', '$1$1'
  return '"' + $quoted + '"'
}

function Invoke-AapNativeProcess {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [string[]]$ArgumentList = @(),
    [hashtable]$Environment = @{},
    [string]$WorkingDirectory = $null
  )

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FilePath
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

  $argumentListProperty = $psi.PSObject.Properties['ArgumentList']
  if ($argumentListProperty) {
    foreach ($argument in @($ArgumentList)) {
      [void]$psi.ArgumentList.Add([string]$argument)
    }
  } else {
    $psi.Arguments = (@($ArgumentList) | ForEach-Object {
        ConvertTo-AapWindowsProcessArgument -Argument ([string]$_)
      }) -join ' '
  }

  foreach ($name in $Environment.Keys) {
    $psi.EnvironmentVariables[$name] = [string]$Environment[$name]
  }

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $psi
  try {
    if (-not $process.Start()) { throw "Unable to start process: $FilePath" }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    return [pscustomobject]@{
      FilePath = $FilePath
      Arguments = @($ArgumentList)
      ExitCode = $process.ExitCode
      Success = ($process.ExitCode -eq 0)
      Stdout = $stdout
      Stderr = $stderr
      Output = (($stdout.TrimEnd(), $stderr.TrimEnd() | Where-Object { $_ }) -join [Environment]::NewLine)
    }
  } finally {
    $process.Dispose()
  }
}
