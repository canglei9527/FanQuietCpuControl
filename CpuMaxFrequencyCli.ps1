[CmdletBinding()]
param(
    [ValidateSet('Status', 'Set', 'Clear', 'Restore', 'Unhide')]
    [string]$Action = 'Status',
    [string]$MHz,
    [ValidateSet('AC', 'DC', 'Both')]
    [string]$Power = 'Both',
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'src\CpuMaxFrequencyControl.psm1'
Import-Module -Force -Name $modulePath

function Write-CpuStatus {
    param(
        [Parameter(Mandatory)]
        $Status
    )

    if ($Json) {
        $Status | ConvertTo-Json -Depth 8
        return
    }

    if (-not $Status.Available) {
        Write-Host "PROCFREQMAX 不可用：$($Status.Error)"
        return
    }

    $schemeName = if ($Status.SchemeName) { $Status.SchemeName } else { '未命名' }
    Write-Host "当前电源计划：$schemeName ($($Status.SchemeGuid))"
    Write-Host "交流电最大频率：$($Status.AcDisplay)"
    Write-Host "电池最大频率：$($Status.DcDisplay)"
    Write-Host "管理员权限：$(if ($Status.IsAdministrator) { '是' } else { '否' })"

    if ($Status.Cpu -and $Status.Cpu.Name) {
        Write-Host "CPU：$($Status.Cpu.Name)"
        Write-Host "WMI 当前/标称频率：$($Status.Cpu.CurrentClockSpeedMHz) / $($Status.Cpu.MaxClockSpeedMHz) MHz"
    }
}

try {
    switch ($Action) {
        'Status' {
            Write-CpuStatus -Status (Get-CpuMaxFrequencyStatus)
        }
        'Set' {
            if ([string]::IsNullOrWhiteSpace($MHz)) {
                throw 'Set 需要 -MHz，例如：-MHz 2200 或 -MHz "2.2 GHz"。'
            }

            $mhzValue = ConvertTo-CpuFrequencyMHz -Value $MHz
            $status = Set-CpuMaxFrequencyLimit -MHz $mhzValue -Power $Power
            Write-CpuStatus -Status $status
        }
        'Clear' {
            $status = Clear-CpuMaxFrequencyLimit -Power $Power
            Write-CpuStatus -Status $status
        }
        'Restore' {
            $status = Restore-CpuMaxFrequencyLimit
            Write-CpuStatus -Status $status
        }
        'Unhide' {
            $status = Enable-CpuMaxFrequencySetting
            Write-CpuStatus -Status $status
        }
    }
}
catch {
    if ($Json) {
        [pscustomobject]@{
            Success = $false
            Error = $_.Exception.Message
        } | ConvertTo-Json -Depth 4
    }
    else {
        Write-Error $_.Exception.Message
    }

    exit 1
}
