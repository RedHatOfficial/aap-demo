#Requires -Version 5.1
<#
.SYNOPSIS
  Multi-host aap-demo destroy/deploy/addon test orchestrator (Windows PowerShell).

.DESCRIPTION
  Native PowerShell counterpart to scripts/multi-host-test.sh. Runs destroy -> deploy ->
  addon enable -> verify across hosts in ~/.aap-demo/test-hosts.yaml via local shell or SSH.

  Unlike the bash orchestrator, type: local + shell: powershell is supported (run this
  script on the Windows machine under test).

.EXAMPLE
  .\scripts\multi-host-test.ps1 --dry-run

.EXAMPLE
  .\scripts\multi-host-test.ps1 --host windows

.EXAMPLE
  .\scripts\multi-host-test.ps1 --pr 123 --host windows

.NOTES
  See: .cursor/skills/aap-demo-multi-host-test/SKILL.md
#>
[CmdletBinding()]
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$CliArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath Variable:PSNativeCommandUseErrorActionPreference) {
  $PSNativeCommandUseErrorActionPreference = $false
}

$script:DefaultAddonOrder = @(
  'setup-pah', 'mcp-server', 'portal', 'ao', 'apme-eap',
  'product-demos', 'product-demo-satellite', 'local-cache'
)

$script:DryRun = $false
$script:HostFilter = ''
$script:SkipAddons = $false
$script:OnlyAddons = $false
$script:Strict = $false
$script:PrNumber = ''
$script:UseLocalCache = $true
$script:ConfigFile = ''
$script:Results = @{}
$script:YamlDoc = $null
$script:Quiet = $true
$script:TrustCa = $false
$script:DestroyReset = $false
$script:SyncRepo = $false
$script:GitRemote = 'origin'
$script:DefaultRepo = '~/Documents/GitHub/aap-demo'

function Show-Usage {
  param([int]$ExitCode = 0)
  @'
Multi-host aap-demo destroy/deploy/addon test orchestrator (Windows PowerShell)

Usage:
  .\scripts\multi-host-test.ps1 [options]

Options:
  --dry-run           Print planned actions without executing
  --host NAME         Run only one host from config (mac, linux-vm, windows)
  --skip-addons       Destroy + deploy + diagnose only
  --only-addons       Skip destroy/deploy; enable addons on running cluster
  --strict            Fail on missing prerequisites
  --pr NUMBER         Checkout GitHub PR on each host before test (gh pr checkout, or git fetch)
  --skip-local-cache  Skip save-before-destroy and load-on-deploy (local-cache addon)
  --config PATH       Config file (default: %USERPROFILE%\.aap-demo\test-hosts.yaml)
  -h, --help          Show this help

Requires: ssh (for remote hosts). YAML is parsed natively (yq not required).

See: .cursor/skills/aap-demo-multi-host-test/SKILL.md
'@ | Write-Host
  exit $ExitCode
}

function Write-MhtLog {
  param([string]$Message)
  Write-Host "[multi-host-test] $Message"
}

function Write-MhtWarn {
  param([string]$Message)
  [Console]::Error.WriteLine("[multi-host-test] WARN: $Message")
}

function Write-MhtError {
  param([string]$Message)
  [Console]::Error.WriteLine("[multi-host-test] ERROR: $Message")
  exit 1
}

function ConvertTo-ExpandedPath {
  param([string]$PathValue)
  if ([string]::IsNullOrWhiteSpace($PathValue)) { return $PathValue }
  $homeDir = $env:USERPROFILE
  if ($PathValue -eq '~') { return $homeDir }
  if ($PathValue.StartsWith('~/') -or $PathValue.StartsWith('~\')) {
    return Join-Path $homeDir $PathValue.Substring(2)
  }
  return $PathValue
}

function ConvertTo-BashQuoted {
  param([string]$Value)
  $escaped = $Value.Replace("'", "'\''")
  return "'$escaped'"
}

function ConvertTo-PsSingleQuoted {
  param([string]$Value)
  return ("'{0}'" -f $Value.Replace("'", "''"))
}

function Set-MhtResult {
  param([string]$Key, [string]$Value)
  $script:Results[$Key] = $Value
}

function Get-MhtResult {
  param([string]$Key, [string]$Default = 'skipped')
  if ($script:Results.ContainsKey($Key)) { return [string]$script:Results[$Key] }
  return $Default
}

function ConvertFrom-YamlScalar {
  param([string]$Value)
  if ($null -eq $Value) { return $null }
  $text = $Value.Trim()
  if ($text -eq '') { return $null }

  if (($text.StartsWith('"') -and $text.EndsWith('"') -and $text.Length -ge 2) -or
      ($text.StartsWith("'") -and $text.EndsWith("'") -and $text.Length -ge 2)) {
    return $text.Substring(1, $text.Length - 2)
  }

  switch -Regex ($text) {
    '^(?i:true|yes)$' { return $true }
    '^(?i:false|no)$' { return $false }
    '^(?i:null|~)$' { return $null }
    '^-?\d+$' { return [int]$text }
    default { return $text }
  }
}

function Remove-YamlInlineComment {
  param([string]$Text)
  $inSingle = $false
  $inDouble = $false
  for ($i = 0; $i -lt $Text.Length; $i++) {
    $ch = $Text[$i]
    if ($ch -eq "'" -and -not $inDouble) { $inSingle = -not $inSingle; continue }
    if ($ch -eq '"' -and -not $inSingle) { $inDouble = -not $inDouble; continue }
    if ($ch -eq '#' -and -not $inSingle -and -not $inDouble) {
      if ($i -eq 0 -or [char]::IsWhiteSpace($Text[$i - 1])) {
        return $Text.Substring(0, $i).TrimEnd()
      }
    }
  }
  return $Text
}

function ConvertFrom-SimpleYaml {
  param([Parameter(Mandatory)][string]$Path)

  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "Config file is empty: $Path"
  }

  $parsed = New-Object System.Collections.ArrayList
  foreach ($line in ($raw -split '\r?\n')) {
    if ($line -match '^\s*$' -or $line -match '^\s*#') { continue }
    $stripped = Remove-YamlInlineComment $line
    if ([string]::IsNullOrWhiteSpace($stripped)) { continue }
    $indent = ($stripped.Length - $stripped.TrimStart().Length)
    $row = [pscustomobject]@{
      Indent  = $indent
      Content = $stripped.Trim()
    }
    [void]$parsed.Add($row)
  }

  $script:YamlLines = $parsed
  $script:YamlI = 0
  if ($parsed.Count -eq 0) { return [ordered]@{} }
  try {
    return Read-YamlMapping $parsed[0].Indent
  } catch {
    $peek = Get-YamlPeek
    $hint = if ($peek) { $peek.Content } else { '<eof>' }
    throw "YAML parse error at '$hint': $($_.Exception.Message)"
  }
}

function Get-YamlPeek {
  if ($script:YamlI -ge $script:YamlLines.Count) { return $null }
  return $script:YamlLines[$script:YamlI]
}

function Read-YamlMapping {
  param([int]$Indent)
  $map = [ordered]@{}
  while ($true) {
    $line = Get-YamlPeek
    if ($null -eq $line) { break }
    if ($line.Indent -lt $Indent) { break }
    if ($line.Indent -gt $Indent) {
      throw "YAML indent error near: $($line.Content)"
    }
    if ($line.Content.StartsWith('- ')) {
      throw "YAML: expected mapping key, got list item: $($line.Content)"
    }

    $colon = $line.Content.IndexOf(':')
    if ($colon -lt 1) { throw "YAML: invalid mapping line: $($line.Content)" }
    $key = $line.Content.Substring(0, $colon).Trim()
    $rest = $line.Content.Substring($colon + 1).Trim()
    $script:YamlI++

    if ($rest -ne '') {
      $map[$key] = ConvertFrom-YamlScalar $rest
      continue
    }

    $next = Get-YamlPeek
    if ($null -eq $next -or $next.Indent -le $Indent) {
      $map[$key] = $null
      continue
    }
    if ($next.Content.StartsWith('- ')) {
      $map[$key] = Read-YamlSequence $next.Indent
    } else {
      $map[$key] = Read-YamlMapping $next.Indent
    }
  }
  return $map
}

function Read-YamlSequence {
  param([int]$Indent)
  $list = New-Object System.Collections.ArrayList
  while ($true) {
    $line = Get-YamlPeek
    if ($null -eq $line) { break }
    if ($line.Indent -lt $Indent) { break }
    if ($line.Indent -gt $Indent) {
      throw "YAML indent error near: $($line.Content)"
    }
    if (-not $line.Content.StartsWith('- ')) {
      break
    }
    $item = $line.Content.Substring(2).Trim()
    $script:YamlI++
    if ($item -ne '') {
      [void]$list.Add((ConvertFrom-YamlScalar $item))
      continue
    }
    $next = Get-YamlPeek
    if ($null -ne $next -and $next.Indent -gt $Indent) {
      if ($next.Content.StartsWith('- ')) {
        [void]$list.Add((Read-YamlSequence $next.Indent))
      } else {
        [void]$list.Add((Read-YamlMapping $next.Indent))
      }
    } else {
      [void]$list.Add($null)
    }
  }
  return @($list)
}

function Get-NodeProperty {
  param($Node, [string]$Name)
  if ($null -eq $Node) { return $null }
  if ($Node -is [System.Collections.IDictionary]) {
    if ($Node.Contains($Name)) { return $Node[$Name] }
    return $null
  }
  $prop = $Node.PSObject.Properties[$Name]
  if ($null -ne $prop) { return $prop.Value }
  return $null
}

function Get-CfgValue {
  param([string]$DottedPath)
  $cur = $script:YamlDoc
  foreach ($part in $DottedPath.Split('.')) {
    $cur = Get-NodeProperty $cur $part
    if ($null -eq $cur) { return $null }
  }
  return $cur
}

function Get-CfgString {
  param([string]$DottedPath, [string]$Default = '')
  $val = Get-CfgValue $DottedPath
  if ($null -eq $val) { return $Default }
  $text = [string]$val
  if ($text -eq '""' -or $text -eq "''") { return $Default }
  return $text
}

function Get-CfgBool {
  param([string]$DottedPath, [bool]$Default)
  $val = Get-CfgValue $DottedPath
  if ($null -eq $val -or $val -eq '') { return $Default }
  if ($val -is [bool]) { return [bool]$val }
  return ([string]$val).ToLowerInvariant() -eq 'true'
}

function Get-HostField {
  param([string]$Name, [string]$Field)
  return Get-CfgString "hosts.$Name.$Field"
}

function Get-HostNames {
  $hostsNode = Get-CfgValue 'hosts'
  if ($null -eq $hostsNode) { return @() }
  if ($hostsNode -is [System.Collections.IDictionary]) {
    return @($hostsNode.Keys)
  }
  return @()
}

function Get-HostType {
  param([string]$Name)
  $htype = Get-HostField $Name 'type'
  if ([string]::IsNullOrWhiteSpace($htype)) { return 'local' }
  return $htype
}

function Get-HostShell {
  param([string]$Name)
  $shell = Get-HostField $Name 'shell'
  if ([string]::IsNullOrWhiteSpace($shell)) { return 'bash' }
  return $shell
}

function Get-HostRepo {
  param([string]$Name)
  $repo = Get-HostField $Name 'repo_path'
  if ([string]::IsNullOrWhiteSpace($repo)) { $repo = $script:DefaultRepo }
  $htype = Get-HostType $Name
  if ($htype -eq 'local') {
    return ConvertTo-ExpandedPath $repo
  }
  return $repo
}

function Get-HostAapCmd {
  param([string]$Name)
  $cmd = Get-HostField $Name 'aap_cmd'
  if ([string]::IsNullOrWhiteSpace($cmd)) { $cmd = Get-HostField $Name 'aap_demo_cmd' }
  if ([string]::IsNullOrWhiteSpace($cmd)) { return 'aap-demo' }
  return $cmd
}

function Get-SshTarget {
  param([string]$Name)
  $user = Get-HostField $Name 'user'
  $target = Get-HostField $Name 'host'
  if ([string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrWhiteSpace($target)) {
    Write-MhtError "Host $Name`: missing user or host for SSH"
  }
  return "$user@$target"
}

function Get-SshArgs {
  param([string]$Name)
  $sshArgs = @(
    '-o', 'BatchMode=yes',
    '-o', 'ConnectTimeout=15',
    '-o', 'StrictHostKeyChecking=accept-new'
  )
  $identity = Get-HostField $Name 'identity_file'
  if (-not [string]::IsNullOrWhiteSpace($identity)) {
    $sshArgs += @('-i', (ConvertTo-ExpandedPath $identity))
  }
  $sshArgs += Get-SshTarget $Name
  return $sshArgs
}

function Get-AddonOrder {
  $order = Get-CfgValue 'addon_order'
  if ($null -eq $order) { return @($script:DefaultAddonOrder) }
  $items = @($order | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") } | ForEach-Object { [string]$_ })
  if ($items.Count -eq 0) { return @($script:DefaultAddonOrder) }
  return $items
}

function Test-HostFilter {
  param([string]$Name)
  return [string]::IsNullOrWhiteSpace($script:HostFilter) -or ($Name -eq $script:HostFilter)
}

function Get-CurrentPowerShellExe {
  try {
    return (Get-Process -Id $PID).Path
  } catch {
    return 'powershell.exe'
  }
}

function Get-CommandPath {
  param([string]$Name)
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if (-not $cmd) { return $null }
  if ($cmd.PSObject.Properties['Path'] -and $cmd.Path) { return [string]$cmd.Path }
  if ($cmd.PSObject.Properties['Source'] -and $cmd.Source) { return [string]$cmd.Source }
  return $Name
}

function Invoke-Native {
  param(
    [Parameter(Mandatory)][string]$File,
    [string[]]$NativeArgs = @(),
    [switch]$Capture
  )
  $output = & $File @NativeArgs 2>&1
  $code = $LASTEXITCODE
  if ($null -eq $code) { $code = 0 }
  $text = ($output | Out-String).TrimEnd()
  if (-not $Capture -and $text) { Write-Host $text }
  return [pscustomobject]@{
    Success  = ($code -eq 0)
    ExitCode = $code
    Output   = $text
  }
}

function Invoke-LocalBash {
  param([string]$Repo, [string]$Command, [switch]$Capture)
  if ($script:DryRun) {
    Write-MhtLog "[dry-run] local bash: cd $Repo && $Command"
    return [pscustomobject]@{ Success = $true; ExitCode = 0; Output = '' }
  }
  $bashPath = Get-CommandPath 'bash'
  if (-not $bashPath) {
    Write-MhtWarn 'Local bash not found (install Git for Windows or WSL)'
    return [pscustomobject]@{ Success = $false; ExitCode = 1; Output = 'bash not found' }
  }
  $remote = "cd $(ConvertTo-BashQuoted $Repo) && $Command"
  return Invoke-Native -File $bashPath -NativeArgs @('-lc', $remote) -Capture:$Capture
}

function Invoke-LocalPowerShell {
  param([string]$Repo, [string]$Command, [switch]$Capture)
  if ($script:DryRun) {
    Write-MhtLog "[dry-run] local powershell: Set-Location $Repo; $Command"
    return [pscustomobject]@{ Success = $true; ExitCode = 0; Output = '' }
  }
  $exe = Get-CurrentPowerShellExe
  $scriptText = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $(ConvertTo-PsSingleQuoted $Repo)
$Command
if (`$null -ne `$LASTEXITCODE -and `$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }
"@
  return Invoke-Native -File $exe -NativeArgs @('-NoProfile', '-NonInteractive', '-Command', $scriptText) -Capture:$Capture
}

function Invoke-SshBash {
  param([string]$Name, [string]$Repo, [string]$Command, [switch]$Capture)
  $remoteCmd = "cd $(ConvertTo-BashQuoted $Repo) && $Command"
  if ($script:DryRun) {
    Write-MhtLog "[dry-run] ssh bash $(Get-SshTarget $Name): $remoteCmd"
    return [pscustomobject]@{ Success = $true; ExitCode = 0; Output = '' }
  }
  $sshPath = Get-CommandPath 'ssh'
  if (-not $sshPath) {
    Write-MhtError 'ssh not found - install OpenSSH Client'
  }
  $sshArgs = Get-SshArgs $Name
  $sshArgs += @('bash', '-lc', $remoteCmd)
  return Invoke-Native -File $sshPath -NativeArgs $sshArgs -Capture:$Capture
}

function Get-RemotePsRepoExpr {
  param([string]$Repo)
  if ($Repo.StartsWith('~/') -or $Repo.StartsWith('~\') -or $Repo -eq '~') {
    $rel = if ($Repo.Length -gt 2) { $Repo.Substring(2) } else { '' }
    if ($rel) {
      return ('Join-Path $env:USERPROFILE {0}' -f (ConvertTo-PsSingleQuoted $rel))
    }
    return '$env:USERPROFILE'
  }
  return ConvertTo-PsSingleQuoted $Repo
}

function Invoke-SshPowerShell {
  param([string]$Name, [string]$Repo, [string]$Command, [switch]$Capture)
  $repoExpr = Get-RemotePsRepoExpr $Repo
  $psCmd = "Set-Location $repoExpr; $Command"
  if ($script:DryRun) {
    Write-MhtLog "[dry-run] ssh powershell $(Get-SshTarget $Name): $psCmd"
    return [pscustomobject]@{ Success = $true; ExitCode = 0; Output = '' }
  }
  $sshPath = Get-CommandPath 'ssh'
  if (-not $sshPath) {
    Write-MhtError 'ssh not found - install OpenSSH Client'
  }
  $sshArgs = Get-SshArgs $Name
  $sshArgs += @('powershell', '-NoProfile', '-NonInteractive', '-Command', $psCmd)
  return Invoke-Native -File $sshPath -NativeArgs $sshArgs -Capture:$Capture
}

function Invoke-OnHost {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Command,
    [switch]$Capture
  )
  $htype = Get-HostType $Name
  $shell = Get-HostShell $Name
  $repo = Get-HostRepo $Name

  switch ($htype) {
    'local' {
      switch ($shell) {
        'bash' { return Invoke-LocalBash -Repo $repo -Command $Command -Capture:$Capture }
        'powershell' { return Invoke-LocalPowerShell -Repo $repo -Command $Command -Capture:$Capture }
        default { Write-MhtError "Host $Name`: unknown shell $shell" }
      }
    }
    'ssh' {
      switch ($shell) {
        'bash' { return Invoke-SshBash -Name $Name -Repo $repo -Command $Command -Capture:$Capture }
        'powershell' { return Invoke-SshPowerShell -Name $Name -Repo $repo -Command $Command -Capture:$Capture }
        default { Write-MhtError "Host $Name`: unknown shell $shell" }
      }
    }
    default { Write-MhtError "Host $Name`: unknown type $htype" }
  }
}

function Test-OnHost {
  param([string]$Name, [string]$Command)
  $result = Invoke-OnHost -Name $Name -Command $Command
  return [bool]$result.Success
}

function Get-EnvPrefixBash {
  param([string]$Mode = '')
  $parts = ''
  if ($script:Quiet) { $parts += 'export QUIET=true; ' }
  if (-not $script:TrustCa) { $parts += 'export AAP_DEMO_TRUST_CA=false; ' }
  if ($Mode -eq 'load_cache' -and $script:UseLocalCache) {
    $parts += 'export AAP_DEMO_LOAD_CACHE=1; '
  }
  return $parts
}

function Get-EnvPrefixPs {
  param([string]$Mode = '')
  $parts = ''
  if ($script:Quiet) { $parts += '$env:QUIET = ''true''; ' }
  if (-not $script:TrustCa) { $parts += '$env:AAP_DEMO_TRUST_CA = ''false''; ' }
  if ($Mode -eq 'load_cache' -and $script:UseLocalCache) {
    $parts += '$env:AAP_DEMO_LOAD_CACHE = ''1''; '
  }
  return $parts
}

function Get-AapInvoke {
  param(
    [string]$Name,
    [string]$AapCmd,
    [string]$SubCmd,
    [string]$Extra = '',
    [string]$Mode = ''
  )
  $shell = Get-HostShell $Name
  $extraPart = if ([string]::IsNullOrWhiteSpace($Extra)) { '' } else { " $Extra" }
  if ($shell -eq 'powershell') {
    return "$(Get-EnvPrefixPs $Mode)$AapCmd $SubCmd$extraPart"
  }
  return "$(Get-EnvPrefixBash $Mode)$AapCmd $SubCmd$extraPart"
}

function Get-PrCheckoutCmd {
  param([string]$Name, [string]$Remote)
  $branch = "pr-$($script:PrNumber)-multi-host-test"
  if ((Get-HostShell $Name) -eq 'powershell') {
    return @"
if (Get-Command gh -ErrorAction SilentlyContinue) {
  gh pr checkout $($script:PrNumber)
} else {
  git fetch $Remote pull/$($script:PrNumber)/head:$branch; if (`$LASTEXITCODE -ne 0) { exit 1 }
  git checkout $branch; if (`$LASTEXITCODE -ne 0) { exit 1 }
}
"@
  }
  return @"
if command -v gh >/dev/null 2>&1; then
  gh pr checkout $($script:PrNumber)
else
  git fetch $Remote pull/$($script:PrNumber)/head:$branch && git checkout $branch
fi
"@
}

function Sync-RepoOnHost {
  param([string]$Name)
  $repo = Get-HostRepo $Name
  $remote = Get-HostField $Name 'git_remote'
  if ([string]::IsNullOrWhiteSpace($remote)) { $remote = $script:GitRemote }

  if (-not [string]::IsNullOrWhiteSpace($script:PrNumber)) {
    Write-MhtLog "Checkout PR #$($script:PrNumber) on $Name (remote: $remote)"
    if ($script:DryRun) {
      Write-MhtLog "[dry-run] $Name`: checkout PR #$($script:PrNumber) in $repo"
      return $true
    }
    $prCmd = Get-PrCheckoutCmd -Name $Name -Remote $remote
    if (-not (Test-OnHost $Name $prCmd)) {
      Write-MhtWarn "$Name`: PR #$($script:PrNumber) checkout failed (install gh or ensure git remote $remote is configured)"
      if ($script:Strict) { return $false }
    }
    return $true
  }

  if ($script:SyncRepo) {
    if ($script:DryRun) {
      Write-MhtLog "[dry-run] $Name`: git pull in $repo"
    } elseif (-not (Test-OnHost $Name 'git pull')) {
      Write-MhtWarn "$Name`: git pull failed"
    }
  }
  return $true
}

function Get-ClusterRunningCmd {
  param([string]$Name)
  if ((Get-HostShell $Name) -eq 'powershell') {
    return @'
$crcOut = crc status 2>&1 | Out-String
if ($crcOut -match 'Running') { exit 0 } else { exit 1 }
'@
  }
  return 'crc status 2>/dev/null | grep -qi Running'
}

function Save-LocalCacheBeforeDestroy {
  param([string]$Name)
  if (-not $script:UseLocalCache) { return $true }

  $aapCmd = Get-HostAapCmd $Name
  Write-MhtLog "Save local-cache before destroy: $Name"
  if ($script:DryRun) {
    Write-MhtLog "[dry-run] $Name`: aap-demo enable local-cache save (if CRC running)"
    return $true
  }

  if (-not (Test-OnHost $Name (Get-ClusterRunningCmd $Name))) {
    Write-MhtWarn "$Name`: CRC not running - skipping local-cache save"
    Set-MhtResult "$Name.local_cache_save" 'skipped'
    return $true
  }

  $saveCmd = Get-AapInvoke -Name $Name -AapCmd $aapCmd -SubCmd 'enable' -Extra 'local-cache save'
  if (-not (Test-OnHost $Name $saveCmd)) {
    if ((Get-HostShell $Name) -eq 'powershell') {
      Write-MhtWarn "$Name`: local-cache save failed (bash/CRC hosts only today)"
    } else {
      Write-MhtWarn "$Name`: local-cache save failed"
    }
    Set-MhtResult "$Name.local_cache_save" 'fail'
    if ($script:Strict) { return $false }
    return $true
  }

  Set-MhtResult "$Name.local_cache_save" 'pass'
  return $true
}

function Invoke-PreflightHost {
  param([string]$Name)
  Write-MhtLog "Preflight: $Name"
  $shell = Get-HostShell $Name
  $aapCmd = Get-HostAapCmd $Name

  if (-not (Sync-RepoOnHost $Name)) { return $false }

  if (-not (Test-OnHost $Name (Get-AapInvoke -Name $Name -AapCmd $aapCmd -SubCmd 'version'))) {
    return $false
  }

  if ($shell -eq 'powershell') {
    $toolsCmd = @'
$ok = (Get-Command crc -ErrorAction SilentlyContinue) -and (
  (Get-Command kubectl -ErrorAction SilentlyContinue) -or (Get-Command oc -ErrorAction SilentlyContinue)
)
if (-not $ok) { exit 1 }
'@
  } else {
    $toolsCmd = 'command -v crc >/dev/null && { command -v kubectl >/dev/null || command -v oc >/dev/null; }'
  }
  if (-not (Test-OnHost $Name $toolsCmd)) {
    Write-MhtWarn "$Name`: crc/kubectl missing"
    if ($script:Strict) { return $false }
  }

  if (Get-CfgBool 'defaults.pull_secret_required' $true) {
    if ($shell -eq 'powershell') {
      $pullCmd = @'
$demo = Join-Path $env:USERPROFILE '.aap-demo'
if (-not (Test-Path (Join-Path $demo 'pull-secret.txt')) -and -not (Test-Path (Join-Path $demo 'pull-secret.json'))) { exit 1 }
'@
      $galaxyCmd = @'
if (-not (Test-Path (Join-Path $env:USERPROFILE '.aap-demo\galaxy-token'))) { exit 1 }
'@
    } else {
      $pullCmd = 'test -f ~/.aap-demo/pull-secret.txt || test -f ~/.aap-demo/pull-secret.json'
      $galaxyCmd = 'test -f ~/.aap-demo/galaxy-token'
    }
    if (-not (Test-OnHost $Name $pullCmd)) {
      Write-MhtWarn "$Name`: pull secret missing"
      if ($script:Strict) { return $false }
    }
    if (-not (Test-OnHost $Name $galaxyCmd)) {
      Write-MhtWarn "$Name`: galaxy-token missing (setup-pah will fail)"
      if ($script:Strict) { return $false }
    }
  }
  return $true
}

function Invoke-DestroyDeployHost {
  param([string]$Name)
  $aapCmd = Get-HostAapCmd $Name
  $resetArg = if ($script:DestroyReset) { '--reset' } else { '' }

  if (-not (Save-LocalCacheBeforeDestroy $Name)) { return $false }

  Write-MhtLog "Destroy: $Name"
  if (-not (Test-OnHost $Name (Get-AapInvoke -Name $Name -AapCmd $aapCmd -SubCmd 'destroy' -Extra $resetArg))) {
    Set-MhtResult "$Name.destroy" 'fail'
    return $false
  }
  Set-MhtResult "$Name.destroy" 'pass'

  Write-MhtLog "Deploy: $Name"
  if (-not (Test-OnHost $Name (Get-AapInvoke -Name $Name -AapCmd $aapCmd -SubCmd 'deploy' -Extra '' -Mode 'load_cache'))) {
    Set-MhtResult "$Name.deploy" 'fail'
    return $false
  }
  Set-MhtResult "$Name.deploy" 'pass'

  Write-MhtLog "Diagnose: $Name"
  if ($script:DryRun) {
    Write-MhtLog "[dry-run] $Name`: aap-demo diagnose"
    Set-MhtResult "$Name.diagnose" 'pass'
    return $true
  }

  $diag = Invoke-OnHost -Name $Name -Command (Get-AapInvoke -Name $Name -AapCmd $aapCmd -SubCmd 'diagnose') -Capture
  if ($diag.Output) { Write-Host $diag.Output }

  $failMark = [char]0x2717
  if ($diag.Output -match [regex]::Escape([string]$failMark)) {
    Set-MhtResult "$Name.diagnose" 'fail'
    Write-MhtWarn "$Name`: diagnose reported failures"
    if ($script:Strict) { return $false }
    return $true
  }

  if (-not $diag.Success) {
    Set-MhtResult "$Name.diagnose" 'fail'
    return $false
  }

  Set-MhtResult "$Name.diagnose" 'pass'
  return $true
}

function Get-AddonVerifyCmd {
  param([string]$Name, [string]$Addon)
  $ns = if ($env:NAMESPACE) { $env:NAMESPACE } else { 'aap-operator' }
  $shell = Get-HostShell $Name

  if ($shell -eq 'powershell') {
    switch ($Addon) {
      'setup-pah' {
        return 'if (-not (Test-Path (Join-Path $env:USERPROFILE ''.aap-demo\galaxy-token''))) { exit 1 }'
      }
      'mcp-server' {
        return @"
kubectl get ansiblemcpserver -n $ns 2>`$null | Out-Null
if (`$LASTEXITCODE -ne 0) { exit 1 }
`$pods = kubectl get pods -n $ns -l app.kubernetes.io/name=aap-mcp-server --no-headers 2>`$null | Out-String
if (`$pods -notmatch 'Running') { exit 1 }
"@
      }
      'portal' {
        return @'
$dep = kubectl get deployment -n redhat-rhaap-portal --no-headers 2>$null | Out-String
$rt = kubectl get route -n redhat-rhaap-portal --no-headers 2>$null | Out-String
if (-not $dep.Trim() -or -not $rt.Trim()) { exit 1 }
'@
      }
      'ao' {
        return @'
kubectl get namespace automation-orchestrator 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { exit 1 }
$pods = kubectl get pods -n automation-orchestrator --no-headers 2>$null | Out-String
if ($pods -notmatch 'Running') { exit 1 }
'@
      }
      'apme-eap' {
        return @'
$pods = kubectl get pods -n apme --no-headers 2>$null | Out-String
if ($pods -notmatch 'Running') { exit 1 }
'@
      }
      'product-demos' {
        return @"
kubectl get aap -n $ns 2>`$null | Out-Null
if (`$LASTEXITCODE -ne 0) { exit 1 }
"@
      }
      'product-demo-satellite' { return 'exit 0' }
      'local-cache' {
        return @'
$cache = Join-Path $env:USERPROFILE '.aap-demo\local-cache'
if (-not (Test-Path $cache)) { exit 1 }
$tars = Get-ChildItem -Path $cache -Filter '*.tar' -Recurse -ErrorAction SilentlyContinue
if (-not $tars) { exit 1 }
'@
      }
      default { return $null }
    }
  }

  switch ($Addon) {
    'setup-pah' { return 'test -f ~/.aap-demo/galaxy-token' }
    'mcp-server' {
      return (@'
kubectl get ansiblemcpserver -n {0} >/dev/null 2>&1 && kubectl get pods -n {0} -l app.kubernetes.io/name=aap-mcp-server --no-headers 2>/dev/null | grep -q Running
'@ -f $ns)
    }
    'portal' {
      return 'kubectl get deployment -n redhat-rhaap-portal --no-headers 2>/dev/null | grep -q . && kubectl get route -n redhat-rhaap-portal --no-headers 2>/dev/null | grep -q .'
    }
    'ao' {
      return 'kubectl get namespace automation-orchestrator >/dev/null 2>&1 && kubectl get pods -n automation-orchestrator --no-headers 2>/dev/null | grep -q Running'
    }
    'apme-eap' { return 'kubectl get pods -n apme --no-headers 2>/dev/null | grep -q Running' }
    'product-demos' {
      return (@'
kubectl get aap -n {0} >/dev/null 2>&1
'@ -f $ns)
    }
    'product-demo-satellite' { return 'true' }
    'local-cache' { return 'test -d ~/.aap-demo/local-cache && ls ~/.aap-demo/local-cache/*/*.tar >/dev/null 2>&1' }
    default { return $null }
  }
}

function Invoke-VerifyAddon {
  param([string]$Name, [string]$Addon)
  $checkCmd = Get-AddonVerifyCmd -Name $Name -Addon $Addon
  if ([string]::IsNullOrWhiteSpace($checkCmd)) {
    Write-MhtWarn "No verify check for addon: $Addon"
    return $true
  }
  if ($script:DryRun) {
    Write-MhtLog "[dry-run] verify $Name/$Addon`: $checkCmd"
    return $true
  }
  if (Test-OnHost $Name $checkCmd) {
    Set-MhtResult "$Name.addon.$Addon" 'pass'
    return $true
  }
  Set-MhtResult "$Name.addon.$Addon" 'fail'
  return $false
}

function Invoke-EnableAddonsHost {
  param([string]$Name)
  $aapCmd = Get-HostAapCmd $Name
  $satUrl = Get-CfgString 'prerequisites.satellite.url'

  foreach ($addon in (Get-AddonOrder)) {
    Write-MhtLog "Enable addon $addon on $Name"
    $enableCmd = Get-AapInvoke -Name $Name -AapCmd $aapCmd -SubCmd 'enable' -Extra $addon
    if ($addon -eq 'product-demo-satellite' -and -not [string]::IsNullOrWhiteSpace($satUrl)) {
      if ((Get-HostShell $Name) -eq 'powershell') {
        $enableCmd = "`$env:SATELLITE_URL = $(ConvertTo-PsSingleQuoted $satUrl); $enableCmd"
      } else {
        $enableCmd = "export SATELLITE_URL=$(ConvertTo-BashQuoted $satUrl); $enableCmd"
      }
    }

    if (-not (Test-OnHost $Name $enableCmd)) {
      Set-MhtResult "$Name.addon.$addon" 'fail'
      if ($script:Strict) { return $false }
      continue
    }

    if (-not (Invoke-VerifyAddon -Name $Name -Addon $addon)) {
      if ($script:Strict) { return $false }
    }

    Write-MhtLog "Post-addon diagnose: $Name / $addon"
    $diagCmd = Get-AapInvoke -Name $Name -AapCmd $aapCmd -SubCmd 'diagnose'
    $diag = Invoke-OnHost -Name $Name -Command $diagCmd -Capture
    if (-not $diag.Success) {
      Write-MhtWarn "$Name`: diagnose warnings after $addon"
    }
  }
  return $true
}

function Write-MhtReport {
  $ts = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
  $reportDir = Join-Path $env:USERPROFILE '.aap-demo\test-reports'
  New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
  $jsonFile = Join-Path $reportDir "$ts.json"
  $mdFile = Join-Path $reportDir "$ts.md"
  $addons = @(Get-AddonOrder)
  $hostNames = @(Get-HostNames | Where-Object { Test-HostFilter $_ })

  $hostsObj = [ordered]@{}
  foreach ($h in $hostNames) {
    $addonMap = [ordered]@{}
    foreach ($a in $addons) {
      $addonMap[$a] = Get-MhtResult "$h.addon.$a"
    }
    $hostsObj[$h] = [ordered]@{
      destroy           = Get-MhtResult "$h.destroy"
      deploy            = Get-MhtResult "$h.deploy"
      diagnose          = Get-MhtResult "$h.diagnose"
      local_cache_save  = Get-MhtResult "$h.local_cache_save"
      addons            = $addonMap
    }
  }

  $report = [ordered]@{
    timestamp = $ts
    config    = $script:ConfigFile
    pr        = if ([string]::IsNullOrWhiteSpace($script:PrNumber)) { $null } else { [int]$script:PrNumber }
    dry_run   = [bool]$script:DryRun
    hosts     = $hostsObj
  }

  $json = $report | ConvertTo-Json -Depth 8
  Set-Content -LiteralPath $jsonFile -Value $json -Encoding UTF8

  $md = New-Object System.Collections.Generic.List[string]
  [void]$md.Add("# aap-demo multi-host test - $ts")
  [void]$md.Add('')
  [void]$md.Add('| Host | Destroy | Deploy | Diagnose | Addons passed |')
  [void]$md.Add('|------|---------|--------|----------|---------------|')
  foreach ($h in $hostNames) {
    $passed = @($addons | Where-Object { (Get-MhtResult "$h.addon.$_") -eq 'pass' }).Count
    $row = '| {0} | {1} | {2} | {3} | {4}/{5} |' -f $h,
      (Get-MhtResult "$h.destroy"),
      (Get-MhtResult "$h.deploy"),
      (Get-MhtResult "$h.diagnose"),
      $passed, $addons.Count
    [void]$md.Add($row)
  }
  [void]$md.Add('')
  [void]$md.Add("JSON: ``$jsonFile``")
  $mdText = $md -join "`n"
  Set-Content -LiteralPath $mdFile -Value $mdText -Encoding UTF8

  Write-MhtLog "Report: $mdFile"
  Write-MhtLog "JSON:   $jsonFile"
  Write-Host $mdText
}

function ConvertFrom-CliArgs {
  param([string[]]$ArgList)
  $i = 0
  while ($i -lt $ArgList.Count) {
    $arg = $ArgList[$i]
    switch ($arg) {
      { $_ -in @('--dry-run', '-DryRun') } { $script:DryRun = $true }
      { $_ -in @('--host', '-HostName') } {
        $i++
        if ($i -ge $ArgList.Count -or [string]::IsNullOrWhiteSpace($ArgList[$i])) {
          Write-MhtError '--host requires a name'
        }
        $script:HostFilter = $ArgList[$i]
      }
      { $_ -in @('--skip-addons', '-SkipAddons') } { $script:SkipAddons = $true }
      { $_ -in @('--only-addons', '-OnlyAddons') } { $script:OnlyAddons = $true }
      { $_ -in @('--strict', '-Strict') } { $script:Strict = $true }
      { $_ -in @('--pr', '-Pr') } {
        $i++
        if ($i -ge $ArgList.Count -or [string]::IsNullOrWhiteSpace($ArgList[$i])) {
          Write-MhtError '--pr requires a pull request number'
        }
        if ($ArgList[$i] -notmatch '^\d+$') {
          Write-MhtError "PR must be a number, got: $($ArgList[$i])"
        }
        $script:PrNumber = $ArgList[$i]
      }
      { $_ -in @('--skip-local-cache', '-SkipLocalCache') } { $script:UseLocalCache = $false }
      { $_ -in @('--config', '-Config') } {
        $i++
        if ($i -ge $ArgList.Count -or [string]::IsNullOrWhiteSpace($ArgList[$i])) {
          Write-MhtError '--config requires a path'
        }
        $script:ConfigFile = $ArgList[$i]
      }
      { $_ -in @('-h', '--help', '-Help', '-?') } { Show-Usage 0 }
      default { Write-MhtError "Unknown option: $arg (try --help)" }
    }
    $i++
  }
}

function Invoke-MhtMain {
  if ($script:SkipAddons -and $script:OnlyAddons) {
    Write-MhtError 'Cannot use --skip-addons and --only-addons together'
  }

  if ([string]::IsNullOrWhiteSpace($script:ConfigFile)) {
    $script:ConfigFile = Join-Path $env:USERPROFILE '.aap-demo\test-hosts.yaml'
  } else {
    $script:ConfigFile = ConvertTo-ExpandedPath $script:ConfigFile
  }

  if (-not (Test-Path -LiteralPath $script:ConfigFile)) {
    Write-MhtError "Config not found: $($script:ConfigFile) - copy machines.example.yaml to $env:USERPROFILE\.aap-demo\test-hosts.yaml"
  }

  $script:YamlDoc = ConvertFrom-SimpleYaml -Path $script:ConfigFile

  if (-not $script:Strict) {
    $script:Strict = Get-CfgBool 'defaults.strict' $false
  }
  $script:Quiet = Get-CfgBool 'defaults.quiet' $true
  $script:TrustCa = Get-CfgBool 'defaults.trust_ca' $false
  $script:DestroyReset = Get-CfgBool 'defaults.destroy_reset' $false
  $script:SyncRepo = Get-CfgBool 'defaults.sync_repo' $false
  $script:GitRemote = Get-CfgString 'defaults.git_remote' 'origin'
  if ([string]::IsNullOrWhiteSpace($script:GitRemote)) { $script:GitRemote = 'origin' }
  $script:DefaultRepo = Get-CfgString 'defaults.repo_path' '~/Documents/GitHub/aap-demo'

  if ([string]::IsNullOrWhiteSpace($script:PrNumber)) {
    $cfgPr = Get-CfgValue 'defaults.pr'
    if ($null -ne $cfgPr -and "$cfgPr" -ne '') { $script:PrNumber = [string]$cfgPr }
  }
  if (-not [string]::IsNullOrWhiteSpace($script:PrNumber) -and $script:PrNumber -notmatch '^\d+$') {
    Write-MhtError "PR must be a number, got: $($script:PrNumber)"
  }

  if ($script:UseLocalCache) {
    $script:UseLocalCache = Get-CfgBool 'defaults.use_local_cache' $true
  }

  Write-MhtLog "Config: $($script:ConfigFile)"
  if ($script:DryRun) { Write-MhtLog 'Mode: dry-run' }
  if ($script:HostFilter) { Write-MhtLog "Host filter: $($script:HostFilter)" }
  if ($script:PrNumber) { Write-MhtLog "PR under test: #$($script:PrNumber)" }
  if ($script:UseLocalCache) {
    Write-MhtLog 'Local-cache: save before destroy, load on deploy'
  } else {
    Write-MhtLog 'Local-cache: disabled (--skip-local-cache or use_local_cache: false)'
  }

  $failures = 0
  $matched = 0
  foreach ($hostItem in (Get-HostNames)) {
    if (-not (Test-HostFilter $hostItem)) { continue }
    $matched++
    Write-MhtLog "========== $hostItem =========="
    $started = Get-Date

    if (-not (Invoke-PreflightHost $hostItem)) {
      Set-MhtResult "$hostItem.preflight" 'fail'
      $failures++
      if ($script:Strict) { continue }
    }

    if (-not $script:OnlyAddons) {
      if (-not (Invoke-DestroyDeployHost $hostItem)) { $failures++ }
    }

    if (-not $script:SkipAddons) {
      if (-not (Invoke-EnableAddonsHost $hostItem)) { $failures++ }
    }

    $elapsed = [int]((Get-Date) - $started).TotalSeconds
    Write-MhtLog "$hostItem completed in ${elapsed}s"
  }

  if ($matched -eq 0) {
    $filterLabel = if ($script:HostFilter) { $script:HostFilter } else { 'all' }
    Write-MhtError "No hosts matched filter: $filterLabel"
  }

  Write-MhtReport

  if ($failures -gt 0) {
    Write-MhtError "$failures host phase(s) failed"
  }
  Write-MhtLog 'All hosts completed successfully'
}

if ($CliArgs -and $CliArgs.Count -gt 0) {
  ConvertFrom-CliArgs $CliArgs
}

Invoke-MhtMain
