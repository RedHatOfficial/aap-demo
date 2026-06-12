#!/usr/bin/env pwsh
# Install aap-demo PowerShell CLI on Windows
#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

$InstallRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $InstallRoot
$BinDir = Join-Path $env:USERPROFILE '.local\bin'
$LauncherName = 'aap-demo.cmd'
$LauncherPath = Join-Path $BinDir $LauncherName
$Ps1Path = Join-Path $InstallRoot 'aap-demo.ps1'

Write-Host 'Installing aap-demo (Windows PowerShell)...'

if (-not (Test-Path $BinDir)) {
    New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
}

# CMD launcher invokes pwsh with the script (works from cmd.exe and PowerShell)
$launcherContent = @"
@echo off
pwsh -NoProfile -ExecutionPolicy Bypass -File "$Ps1Path" %*
"@
Set-Content -Path $LauncherPath -Value $launcherContent -Encoding ASCII

Write-Host "  Launcher: $LauncherPath"
Write-Host "  Script:   $Ps1Path"
Write-Host "  Module:   $(Join-Path $InstallRoot 'modules\AapDemo')"

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$BinDir*") {
    Write-Host ''
    Write-Host 'NOTE: Adding ~/.local/bin to user PATH...'
    $newPath = if ($userPath) { "$BinDir;$userPath" } else { $BinDir }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    $env:Path = "$BinDir;$env:Path"
    Write-Host '  PATH updated (restart terminal if aap-demo is not found)'
} else {
    Write-Host '  PATH already includes ~/.local/bin'
}

Write-Host ''
Write-Host 'Done. Try:'
Write-Host '  aap-demo help'
Write-Host ''
Write-Host 'Docs: docs/windows/QUICK-START.md'
