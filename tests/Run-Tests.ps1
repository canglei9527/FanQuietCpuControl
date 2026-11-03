[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $projectRoot 'src\CpuMaxFrequencyControl.psm1'
Import-Module -Force -Name $modulePath
$undervoltModulePath = Join-Path $projectRoot 'src\CpuUndervolt.psm1'
Import-Module -Force -Name $undervoltModulePath

$script:Failures = 0

function Assert-Equal {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        $Actual,
        [Parameter(Mandatory)]
        $Expected
    )

    if ($Actual -ne $Expected) {
        Write-Host "FAIL $Name - expected [$Expected], got [$Actual]" -ForegroundColor Red
        $script:Failures++
        return
    }

    Write-Host "PASS $Name" -ForegroundColor Green
}

function Assert-True {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [bool]$Condition
    )

    if (-not $Condition) {
        Write-Host "FAIL $Name" -ForegroundColor Red
        $script:Failures++
        return
    }

    Write-Host "PASS $Name" -ForegroundColor Green
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock
    )

    try {
        & $ScriptBlock
        Write-Host "FAIL $Name - expected exception" -ForegroundColor Red
        $script:Failures++
    }
    catch {
        Write-Host "PASS $Name" -ForegroundColor Green
    }
}

Assert-Equal -Name 'plain MHz input' -Actual (ConvertTo-CpuFrequencyMHz -Value '2200') -Expected 2200
Assert-Equal -Name 'MHz unit input' -Actual (ConvertTo-CpuFrequencyMHz -Value '2200 MHz') -Expected 2200
Assert-Equal -Name 'GHz unit input' -Actual (ConvertTo-CpuFrequencyMHz -Value '2.2 GHz') -Expected 2200
Assert-Equal -Name 'comma GHz input' -Actual (ConvertTo-CpuFrequencyMHz -Value '2,25GHz') -Expected 2250
Assert-Throws -Name 'percent input rejected' -ScriptBlock { ConvertTo-CpuFrequencyMHz -Value '80%' | Out-Null }

Assert-True -Name 'valid frequency accepted' -Condition (Test-CpuFrequencyLimitValue -MHz 2200)
Assert-True -Name 'zero accepted only for clear internals' -Condition (Test-CpuFrequencyLimitValue -MHz 0 -AllowZero)
Assert-True -Name 'too low rejected' -Condition (-not (Test-CpuFrequencyLimitValue -MHz 99))
Assert-True -Name 'too high rejected' -Condition (-not (Test-CpuFrequencyLimitValue -MHz 100001))

$fastStatus = Get-CpuMaxFrequencyStatus -SkipTelemetry
Assert-True -Name 'fast frequency status omits CPU telemetry' -Condition ($null -eq $fastStatus.Cpu)

$sample = @'
Power Setting GUID: 75b0ae3f-bce0-45a7-8c89-c9611c25e100  (Maximum processor frequency)
  Possible Setting Minimum: 0x00000000
  Possible Setting Maximum: 0xffffffff
  Possible Settings increment: 0x00000001
  Possible Settings units: MHz
  Current AC Power Setting Index: 0x00000898
  Current DC Power Setting Index: 0x000005dc
'@

$parsed = ConvertFrom-CpuPowerSettingText -Text $sample
Assert-Equal -Name 'parse AC MHz' -Actual ([int]$parsed.AcValueMHz) -Expected 2200
Assert-Equal -Name 'parse DC MHz' -Actual ([int]$parsed.DcValueMHz) -Expected 1500
Assert-Equal -Name 'format unlimited' -Actual (Format-CpuFrequencyMHz -MHz 0) -Expected '不限制'

Assert-Equal -Name 'undervolt level count' -Actual (@(Get-CpuUndervoltOffsetLevels).Count) -Expected 7
Assert-Equal -Name 'undervolt first step' -Actual (@(Get-CpuUndervoltOffsetLevels)[1]) -Expected -20
Assert-True -Name '20 mV undervolt accepted' -Condition (Test-CpuUndervoltOffset -OffsetMilliVolts -20)
Assert-True -Name '120 mV undervolt accepted' -Condition (Test-CpuUndervoltOffset -OffsetMilliVolts -120)
Assert-True -Name '10 mV undervolt rejected' -Condition (-not (Test-CpuUndervoltOffset -OffsetMilliVolts -10))
Assert-True -Name 'positive voltage offset rejected' -Condition (-not (Test-CpuUndervoltOffset -OffsetMilliVolts 20))
Assert-Equal -Name 'format zero undervolt' -Actual (Format-CpuUndervoltOffset -OffsetMilliVolts 0) -Expected '不降压（0 mV）'
$undervoltStatus = Get-CpuUndervoltStatus
Assert-True -Name 'undervolt status schema' -Condition ($null -ne $undervoltStatus.PSObject.Properties['Available'] -and $null -ne $undervoltStatus.PSObject.Properties['RequestedOffsetMilliVolts'])
$fanQuietLayoutTests = Join-Path $projectRoot 'tests\FanQuietLayoutTests.ps1'
$layoutTestOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fanQuietLayoutTests 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "FanQuiet layout tests failed: $($layoutTestOutput -join ' ')"
}
$layoutTestOutput | ForEach-Object { Write-Host $_ }

$fanQuietEntry = Join-Path $projectRoot 'src\FanQuietCpuControl.ps1'
$asyncTestOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fanQuietEntry -AsyncLifecycleTest 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Async UI lifecycle test failed: $($asyncTestOutput -join ' ')"
}
$asyncTestOutput | ForEach-Object { Write-Host $_ }

$processPriorityTests = Join-Path $projectRoot 'tests\ProcessPriorityTests.ps1'
$processPriorityOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $processPriorityTests 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Process priority isolated tests failed: $($processPriorityOutput -join ' ')"
}
$processPriorityOutput | ForEach-Object { Write-Host $_ }

if ($script:Failures -gt 0) {
    throw "$script:Failures test(s) failed."
}

Write-Host 'All isolated tests passed.'
