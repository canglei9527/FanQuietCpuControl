[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$buildScript = Join-Path $projectRoot 'packaging\Build-Exe.ps1'
$buildOutput = @(& $buildScript)
$buildOutput | ForEach-Object { Write-Output $_ }
$builtArtifactLine = @($buildOutput | Where-Object { ([string]$_).StartsWith('Built EXE: ') } | Select-Object -Last 1)
if ($builtArtifactLine.Count -eq 0 -or [string]$builtArtifactLine[0] -notmatch '^Built EXE: (?<Path>.+) \(\d+ bytes\)$') {
    throw 'Package build did not report its output path.'
}
$targetPath = $Matches.Path

if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
    throw "Expected EXE was not created: $targetPath"
}

[byte[]]$header = Get-Content -LiteralPath $targetPath -Encoding Byte -TotalCount 2
if ($header.Count -ne 2 -or $header[0] -ne 0x4D -or $header[1] -ne 0x5A) {
    throw "Generated package does not have a Windows EXE header: $targetPath"
}

Write-Output 'PASS IExpress package build and EXE header validation.'

$tarCommand = Get-Command tar.exe -ErrorAction SilentlyContinue
if ($null -eq $tarCommand) {
    Write-Warning 'NOT_AVAILABLE package payload listing: tar.exe is not installed.'
    exit 0
}

$entries = @(& $tarCommand.Source -tf $targetPath)
if ($LASTEXITCODE -ne 0) {
    throw "Could not inspect the IExpress payload: $targetPath"
}

$requiredEntries = @('FanQuietCpuControl.ps1', 'CpuMaxFrequencyControl.psm1', 'CpuUndervolt.psm1', 'ProcessPriorityControl.psm1', 'Launcher.ps1', 'Launch-FanQuiet.cmd')
foreach ($requiredEntry in $requiredEntries) {
    if ($entries -notcontains $requiredEntry) {
        throw "IExpress payload is missing $requiredEntry. Entries: $($entries -join ', ')"
    }
}

Write-Output 'PASS IExpress payload contains the integrated FanQuiet runtime.'
