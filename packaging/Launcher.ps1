[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    throw 'LOCALAPPDATA is unavailable, so the packaged application cannot prepare its runtime files.'
}

$installRoot = Join-Path $env:LOCALAPPDATA 'FanQuietCpuControl'
$moduleDirectory = Join-Path $installRoot 'src'

$payload = @(
    [pscustomobject]@{
        Source = Join-Path $PSScriptRoot 'FanQuietCpuControl.ps1'
        Destination = Join-Path $moduleDirectory 'FanQuietCpuControl.ps1'
    }
    [pscustomobject]@{
        Source = Join-Path $PSScriptRoot 'CpuMaxFrequencyControl.psm1'
        Destination = Join-Path $moduleDirectory 'CpuMaxFrequencyControl.psm1'
    }
    [pscustomobject]@{
        Source = Join-Path $PSScriptRoot 'CpuUndervolt.psm1'
        Destination = Join-Path $moduleDirectory 'CpuUndervolt.psm1'
    }
    [pscustomobject]@{
        Source = Join-Path $PSScriptRoot 'ProcessPriorityControl.psm1'
        Destination = Join-Path $moduleDirectory 'ProcessPriorityControl.psm1'
    }
)

foreach ($item in $payload) {
    if (-not (Test-Path -LiteralPath $item.Source -PathType Leaf)) {
        throw "Packaged payload is missing: $($item.Source)"
    }

    $destinationDirectory = Split-Path -Parent $item.Destination
    New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
    Copy-Item -LiteralPath $item.Source -Destination $item.Destination -Force
}

$fanQuietScript = Join-Path $moduleDirectory 'FanQuietCpuControl.ps1'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $fanQuietScript
exit $LASTEXITCODE
