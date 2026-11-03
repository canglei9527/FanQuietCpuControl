Set-StrictMode -Version Latest

$script:UndervoltStepMilliVolts = 20
$script:MinimumUndervoltOffsetMilliVolts = -120
$script:MaximumUndervoltOffsetMilliVolts = 0
$script:XtuSettingId = 34
$script:XtuServiceNames = @('XTU3SERVICE', 'IntelXTUService')
$script:StateDirectory = Join-Path $env:LOCALAPPDATA 'FanQuietCpuControl'
$script:BackendConfigPath = Join-Path $script:StateDirectory 'undervolt-backend.json'
$script:StatePath = Join-Path $script:StateDirectory 'undervolt-state.json'

function Test-CpuUndervoltAdministrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CpuUndervoltOffsetLevels {
    [CmdletBinding()]
    param()

    $levels = [System.Collections.Generic.List[int]]::new()
    $levels.Add(0)
    for ($offset = -$script:UndervoltStepMilliVolts; $offset -ge $script:MinimumUndervoltOffsetMilliVolts; $offset -= $script:UndervoltStepMilliVolts) {
        $levels.Add($offset)
    }

    return @($levels)
}

function Format-CpuUndervoltOffset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$OffsetMilliVolts
    )

    if ($OffsetMilliVolts -eq 0) {
        return '不降压（0 mV）'
    }

    return "$OffsetMilliVolts mV"
}

function Test-CpuUndervoltOffset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$OffsetMilliVolts
    )

    if ($OffsetMilliVolts -gt $script:MaximumUndervoltOffsetMilliVolts -or $OffsetMilliVolts -lt $script:MinimumUndervoltOffsetMilliVolts) {
        return $false
    }

    return (([Math]::Abs($OffsetMilliVolts) % $script:UndervoltStepMilliVolts) -eq 0)
}

function Assert-CpuUndervoltOffset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$OffsetMilliVolts
    )

    if (-not (Test-CpuUndervoltOffset -OffsetMilliVolts $OffsetMilliVolts)) {
        throw "降压必须按 20 mV 一档，范围为 0 到 -120 mV。"
    }
}

function Get-CpuUndervoltCpuInfo {
    [CmdletBinding()]
    param()

    try {
        $processor = Get-ItemProperty -Path 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction Stop
        $name = [string]$processor.ProcessorNameString
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $manufacturer = if ($name -match 'Intel') { 'GenuineIntel' } elseif ($name -match 'AMD') { 'AuthenticAMD' } else { $null }
            return [pscustomobject]@{
                Manufacturer = $manufacturer
                Name = $name
            }
        }
    }
    catch {
    }

    try {
        $processor = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($null -eq $processor) {
            return [pscustomobject]@{
                Manufacturer = $null
                Name = $null
            }
        }

        return [pscustomobject]@{
            Manufacturer = [string]$processor.Manufacturer
            Name = [string]$processor.Name
        }
    }
    catch {
        return [pscustomobject]@{
            Manufacturer = $null
            Name = $null
            Error = $_.Exception.Message
        }
    }
}
function Get-CpuUndervoltConfiguredCliPath {
    if (-not (Test-Path -LiteralPath $script:BackendConfigPath -PathType Leaf)) {
        return $null
    }

    try {
        $config = Get-Content -Raw -LiteralPath $script:BackendConfigPath | ConvertFrom-Json
        if ($null -ne $config.XtuCliPath -and (Test-Path -LiteralPath ([string]$config.XtuCliPath) -PathType Leaf)) {
            return (Resolve-Path -LiteralPath ([string]$config.XtuCliPath)).Path
        }
    }
    catch {
        return $null
    }

    return $null
}

function Find-CpuUndervoltCli {
    [CmdletBinding()]
    param()

    $candidates = [System.Collections.Generic.List[string]]::new()
    $configuredPath = Get-CpuUndervoltConfiguredCliPath
    if (-not [string]::IsNullOrWhiteSpace($configuredPath)) {
        $candidates.Add($configuredPath)
    }

    $programFilesX86 = ${env:ProgramFiles(x86)}
    $programFiles = $env:ProgramFiles
    foreach ($root in @($programFilesX86, $programFiles)) {
        if ([string]::IsNullOrWhiteSpace($root)) {
            continue
        }

        $candidates.Add((Join-Path $root 'Intel\Intel(R) Extreme Tuning Utility\Client\XTUCli.exe'))
        $candidates.Add((Join-Path $root 'Intel\Intel Extreme Tuning Utility\Client\XTUCli.exe'))
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Get-CpuUndervoltService {
    [CmdletBinding()]
    param()

    foreach ($name in $script:XtuServiceNames) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($null -ne $service) {
            return $service
        }
    }

    return $null
}

function Get-CpuUndervoltState {
    if (-not (Test-Path -LiteralPath $script:StatePath -PathType Leaf)) {
        return [pscustomobject]@{
            Version = 1
            RequestedOffsetMilliVolts = $null
            AppliedAt = $null
        }
    }

    try {
        return Get-Content -Raw -LiteralPath $script:StatePath | ConvertFrom-Json
    }
    catch {
        return [pscustomobject]@{
            Version = 1
            RequestedOffsetMilliVolts = $null
            AppliedAt = $null
            Error = $_.Exception.Message
        }
    }
}

function Save-CpuUndervoltState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$OffsetMilliVolts,
        [Parameter(Mandatory)]
        [string]$CliPath
    )

    New-Item -ItemType Directory -Force -Path $script:StateDirectory | Out-Null
    [pscustomobject]@{
        Version = 1
        RequestedOffsetMilliVolts = $OffsetMilliVolts
        AppliedAt = (Get-Date).ToString('o')
        Backend = 'Intel XTU CLI'
        XtuCliPath = $CliPath
        SettingId = $script:XtuSettingId
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:StatePath -Encoding UTF8
}

function Set-CpuUndervoltBackendPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$XtuCliPath
    )

    $resolvedPath = Resolve-Path -LiteralPath $XtuCliPath -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $resolvedPath.Path -PathType Leaf)) {
        throw "找不到 XTU CLI：$XtuCliPath"
    }

    if ([System.IO.Path]::GetFileName($resolvedPath.Path) -ine 'XTUCli.exe') {
        throw '请选择 Intel XTU 的 XTUCli.exe。'
    }

    New-Item -ItemType Directory -Force -Path $script:StateDirectory | Out-Null
    [pscustomobject]@{
        Version = 1
        XtuCliPath = $resolvedPath.Path
        UpdatedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:BackendConfigPath -Encoding UTF8

    return Get-CpuUndervoltStatus
}

function Get-CpuUndervoltStatus {
    [CmdletBinding()]
    param()

    $cpu = Get-CpuUndervoltCpuInfo
    $cliPath = Find-CpuUndervoltCli
    $service = Get-CpuUndervoltService
    $state = Get-CpuUndervoltState
    $isIntel = $cpu.Manufacturer -match 'Intel|GenuineIntel' -or $cpu.Name -match 'Intel\(R\)'
    $errorMessage = $null

    if (-not $isIntel) {
        $errorMessage = '当前 CPU 不是 Intel，Intel XTU 降压后端不可用。'
    }
    elseif ([string]::IsNullOrWhiteSpace($cliPath)) {
        $errorMessage = '未检测到 Intel XTU 的 XTUCli.exe。请先安装兼容版本，或点击“选择 XTU”指定文件。'
    }

    $requestedOffset = $null
    if ($null -ne $state.RequestedOffsetMilliVolts) {
        $requestedOffset = [int]$state.RequestedOffsetMilliVolts
    }

    return [pscustomobject]@{
        Available = ($isIntel -and -not [string]::IsNullOrWhiteSpace($cliPath))
        CanApply = ($isIntel -and -not [string]::IsNullOrWhiteSpace($cliPath) -and (Test-CpuUndervoltAdministrator))
        BackendName = 'Intel XTU CLI'
        XtuCliPath = $cliPath
        ServiceName = if ($null -ne $service) { $service.Name } else { $null }
        ServiceStatus = if ($null -ne $service) { [string]$service.Status } else { '未安装' }
        IsAdministrator = Test-CpuUndervoltAdministrator
        CpuManufacturer = $cpu.Manufacturer
        CpuName = $cpu.Name
        RequestedOffsetMilliVolts = $requestedOffset
        RequestedOffsetDisplay = if ($null -eq $requestedOffset) { '未记录' } else { Format-CpuUndervoltOffset -OffsetMilliVolts $requestedOffset }
        StepMilliVolts = $script:UndervoltStepMilliVolts
        MinimumOffsetMilliVolts = $script:MinimumUndervoltOffsetMilliVolts
        MaximumOffsetMilliVolts = $script:MaximumUndervoltOffsetMilliVolts
        SettingId = $script:XtuSettingId
        Error = $errorMessage
    }
}

function Start-CpuUndervoltService {
    [CmdletBinding()]
    param(
        $Service
    )

    if ($null -eq $Service -or $Service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) {
        return
    }

    try {
        Start-Service -Name $Service.Name -ErrorAction Stop
        $Service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(10))
    }
    catch {
        throw "Intel XTU 服务无法启动：$($_.Exception.Message)"
    }
}

function Invoke-CpuUndervoltXtu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CliPath,
        [Parameter(Mandatory)]
        [int]$OffsetMilliVolts
    )

    $output = @(& $CliPath '-t' '-id' ([string]$script:XtuSettingId) '-v' ([string]$OffsetMilliVolts) 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $details = ($output | ForEach-Object { [string]$_ }) -join ' '
        if ([string]::IsNullOrWhiteSpace($details)) {
            $details = "XTU CLI 返回退出码 $exitCode"
        }

        throw "Intel XTU 降压失败：$details。可能是 BIOS/微码启用了 Undervolt Protection。"
    }

    return @($output | ForEach-Object { [string]$_ })
}

function Set-CpuUndervoltOffset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$OffsetMilliVolts
    )

    Assert-CpuUndervoltOffset -OffsetMilliVolts $OffsetMilliVolts
    $status = Get-CpuUndervoltStatus
    if (-not $status.Available) {
        throw $status.Error
    }

    if (-not $status.IsAdministrator) {
        throw '应用 CPU 降压需要管理员权限。'
    }

    $service = Get-CpuUndervoltService
    Start-CpuUndervoltService -Service $service
    $null = Invoke-CpuUndervoltXtu -CliPath $status.XtuCliPath -OffsetMilliVolts $OffsetMilliVolts
    Save-CpuUndervoltState -OffsetMilliVolts $OffsetMilliVolts -CliPath $status.XtuCliPath
    return Get-CpuUndervoltStatus
}

function Clear-CpuUndervoltOffset {
    [CmdletBinding()]
    param()

    return Set-CpuUndervoltOffset -OffsetMilliVolts 0
}

Export-ModuleMember -Function @(
    'Test-CpuUndervoltAdministrator',
    'Get-CpuUndervoltOffsetLevels',
    'Format-CpuUndervoltOffset',
    'Test-CpuUndervoltOffset',
    'Set-CpuUndervoltBackendPath',
    'Get-CpuUndervoltStatus',
    'Set-CpuUndervoltOffset',
    'Clear-CpuUndervoltOffset'
)
