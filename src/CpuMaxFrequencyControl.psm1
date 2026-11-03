Set-StrictMode -Version Latest

$script:ProcessorSubgroupGuid = '54533251-82be-4824-96c1-47b60b740d00'
$script:ProcessorMaxFrequencyGuid = '75b0ae3f-bce0-45a7-8c89-c9611c25e100'
$script:PowerCfgPath = Join-Path $env:SystemRoot 'System32\powercfg.exe'
$script:StateDirectory = Join-Path $env:LOCALAPPDATA 'CpuMaxFrequencyControl'
$script:StatePath = Join-Path $script:StateDirectory 'power-frequency-backup.json'
$script:MinimumLimitMHz = 100
$script:MaximumLimitMHz = 100000

function Invoke-CpuPowerCfg {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )

    if (-not (Test-Path -LiteralPath $script:PowerCfgPath)) {
        throw "找不到 powercfg：$script:PowerCfgPath"
    }

    $output = @(& $script:PowerCfgPath @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg 执行失败：$($output -join ' ')"
    }

    return @($output | ForEach-Object { [string]$_ })
}

function Test-CpuFrequencyAdministrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ActivePowerScheme {
    [CmdletBinding()]
    param()

    $output = (Invoke-CpuPowerCfg /getactivescheme) -join [Environment]::NewLine
    $guidMatch = [regex]::Match($output, '[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}')
    if (-not $guidMatch.Success) {
        throw '无法读取当前电源方案 GUID。'
    }

    $name = $null
    $nameMatch = [regex]::Match($output, '\((?<name>[^)]*)\)\s*$')
    if ($nameMatch.Success) {
        $name = $nameMatch.Groups['name'].Value
    }

    return [pscustomobject]@{
        Guid = $guidMatch.Value
        Name = $name
        RawOutput = $output
    }
}

function ConvertFrom-CpuPowerSettingText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [string[]]$Text
    )

    process {
        $joined = $Text -join [Environment]::NewLine
        $hexMatches = [regex]::Matches($joined, '0x([0-9a-fA-F]+)')
        if ($hexMatches.Count -lt 2) {
            throw '无法从 powercfg 输出中解析 AC/DC 频率值。'
        }

        $unit = $null
        $unitMatch = [regex]::Match($joined, '(?:可能的设置单位|Possible Settings units|Possible setting units)\s*:\s*(?<unit>.+)')
        if ($unitMatch.Success) {
            $unit = $unitMatch.Groups['unit'].Value.Trim()
        }

        $acHex = $hexMatches[$hexMatches.Count - 2].Groups[1].Value
        $dcHex = $hexMatches[$hexMatches.Count - 1].Groups[1].Value

        return [pscustomobject]@{
            AcValueMHz = [uint64]::Parse($acHex, [Globalization.NumberStyles]::HexNumber)
            DcValueMHz = [uint64]::Parse($dcHex, [Globalization.NumberStyles]::HexNumber)
            Unit = $unit
            RawOutput = $joined
        }
    }
}

function Get-ProcessorFrequencySetting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SchemeGuid
    )

    $output = Invoke-CpuPowerCfg /qh $SchemeGuid $script:ProcessorSubgroupGuid $script:ProcessorMaxFrequencyGuid
    return ConvertFrom-CpuPowerSettingText -Text $output
}

function Format-CpuFrequencyMHz {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [uint64]$MHz
    )

    if ($MHz -eq 0) {
        return '不限制'
    }

    $ghz = [Math]::Round(([double]$MHz / 1000), 2)
    return "$MHz MHz ($ghz GHz)"
}

function ConvertTo-CpuFrequencyMHz {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Value
    )

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [uint32] -or $Value -is [uint64]) {
        return [int]$Value
    }

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw '请输入要限制的 CPU 最大频率，例如 2200 或 2.2 GHz。'
    }

    if ($text -match '%|percent|百分') {
        throw '本工具控制 MHz/GHz 具体频率，不接受百分比。'
    }

    $match = [regex]::Match($text, '^(?<number>\d+(?:[\.,]\d+)?)\s*(?<unit>mhz|m|兆赫|ghz|g|吉赫)?$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        throw "无法识别频率：$Value。请使用 2200、2200 MHz 或 2.2 GHz。"
    }

    $numberText = $match.Groups['number'].Value.Replace(',', '.')
    $number = [double]::Parse($numberText, [Globalization.CultureInfo]::InvariantCulture)
    $unit = $match.Groups['unit'].Value.ToLowerInvariant()

    if ($unit -eq 'ghz' -or $unit -eq 'g' -or $unit -eq '吉赫') {
        return [int][Math]::Round($number * 1000, 0, [MidpointRounding]::AwayFromZero)
    }

    return [int][Math]::Round($number, 0, [MidpointRounding]::AwayFromZero)
}

function Test-CpuFrequencyLimitValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$MHz,
        [switch]$AllowZero
    )

    if ($AllowZero -and $MHz -eq 0) {
        return $true
    }

    return ($MHz -ge $script:MinimumLimitMHz -and $MHz -le $script:MaximumLimitMHz)
}

function Assert-CpuFrequencyLimitValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$MHz,
        [switch]$AllowZero
    )

    if (-not (Test-CpuFrequencyLimitValue -MHz $MHz -AllowZero:$AllowZero)) {
        if ($AllowZero) {
            throw "频率必须为 0 或 $script:MinimumLimitMHz-$script:MaximumLimitMHz MHz。0 表示取消限制。"
        }

        throw "频率必须在 $script:MinimumLimitMHz-$script:MaximumLimitMHz MHz 之间；取消限制请使用 Clear。"
    }
}

function Get-CpuFrequencyState {
    [CmdletBinding()]
    param()

    if (-not (Test-Path -LiteralPath $script:StatePath)) {
        return [pscustomobject]@{
            Version = 1
            Profiles = @()
        }
    }

    try {
        $state = Get-Content -Raw -LiteralPath $script:StatePath | ConvertFrom-Json
        if ($null -eq $state.Profiles) {
            $state | Add-Member -MemberType NoteProperty -Name Profiles -Value @()
        }

        return $state
    }
    catch {
        throw '已保存的 CPU 频率备份无法读取，未对电源策略进行修改。'
    }
}

function Save-CpuFrequencyState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $State
    )

    if (-not (Test-Path -LiteralPath $script:StateDirectory)) {
        New-Item -ItemType Directory -Force -Path $script:StateDirectory | Out-Null
    }

    $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:StatePath -Encoding UTF8
}

function Get-CpuFrequencyBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $State,
        [Parameter(Mandatory)]
        [string]$SchemeGuid
    )

    $matches = @($State.Profiles | Where-Object { $_.SchemeGuid -eq $SchemeGuid } | Select-Object -First 1)
    if ($matches.Count -eq 0) {
        return $null
    }

    return $matches[0]
}

function Ensure-CpuFrequencyBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Scheme,
        [Parameter(Mandatory)]
        $Setting
    )

    $state = Get-CpuFrequencyState
    $existing = Get-CpuFrequencyBackup -State $state -SchemeGuid $Scheme.Guid
    if ($null -ne $existing) {
        return
    }

    $backup = [pscustomobject]@{
        SchemeGuid = $Scheme.Guid
        SchemeName = $Scheme.Name
        AcMaxFrequencyMHz = [uint64]$Setting.AcValueMHz
        DcMaxFrequencyMHz = [uint64]$Setting.DcValueMHz
        SavedAt = (Get-Date).ToString('o')
    }

    $state.Profiles = @($state.Profiles) + $backup
    Save-CpuFrequencyState -State $state
}

function Set-CpuPowerSettingValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SchemeGuid,
        [Parameter(Mandatory)]
        [ValidateSet('AC', 'DC')]
        [string]$Power,
        [Parameter(Mandatory)]
        [uint64]$MHz
    )

    $command = if ($Power -eq 'AC') { '/setacvalueindex' } else { '/setdcvalueindex' }
    Invoke-CpuPowerCfg $command $SchemeGuid $script:ProcessorSubgroupGuid $script:ProcessorMaxFrequencyGuid ([string]$MHz) | Out-Null
}

function Get-CpuTelemetry {
    [CmdletBinding()]
    param()

    try {
        $processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
        if ($processors.Count -eq 0) {
            return $null
        }

        $first = $processors[0]
        return [pscustomobject]@{
            Name = $first.Name
            CurrentClockSpeedMHz = $first.CurrentClockSpeed
            MaxClockSpeedMHz = $first.MaxClockSpeed
            NumberOfCores = ($processors | Measure-Object -Property NumberOfCores -Sum).Sum
            NumberOfLogicalProcessors = ($processors | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
        }
    }
    catch {
        return [pscustomobject]@{
            Name = $null
            CurrentClockSpeedMHz = $null
            MaxClockSpeedMHz = $null
            NumberOfCores = $null
            NumberOfLogicalProcessors = $null
            Error = $_.Exception.Message
        }
    }
}

function Get-CpuMaxFrequencyStatus {
    [CmdletBinding()]
    param(
        [switch]$SkipTelemetry
    )

    $telemetry = if ($SkipTelemetry) { $null } else { Get-CpuTelemetry }

    try {
        $scheme = Get-ActivePowerScheme
        $setting = Get-ProcessorFrequencySetting -SchemeGuid $scheme.Guid

        return [pscustomobject]@{
            Available = $true
            IsAdministrator = Test-CpuFrequencyAdministrator
            SchemeGuid = $scheme.Guid
            SchemeName = $scheme.Name
            AcValueMHz = [uint64]$setting.AcValueMHz
            DcValueMHz = [uint64]$setting.DcValueMHz
            AcDisplay = Format-CpuFrequencyMHz -MHz ([uint64]$setting.AcValueMHz)
            DcDisplay = Format-CpuFrequencyMHz -MHz ([uint64]$setting.DcValueMHz)
            Unit = $setting.Unit
            ProcessorSubgroupGuid = $script:ProcessorSubgroupGuid
            ProcessorMaxFrequencyGuid = $script:ProcessorMaxFrequencyGuid
            PowerCfgPath = $script:PowerCfgPath
            BackupPath = $script:StatePath
            Cpu = $telemetry
            Error = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Available = $false
            IsAdministrator = Test-CpuFrequencyAdministrator
            SchemeGuid = $null
            SchemeName = $null
            AcValueMHz = $null
            DcValueMHz = $null
            AcDisplay = $null
            DcDisplay = $null
            Unit = $null
            ProcessorSubgroupGuid = $script:ProcessorSubgroupGuid
            ProcessorMaxFrequencyGuid = $script:ProcessorMaxFrequencyGuid
            PowerCfgPath = $script:PowerCfgPath
            BackupPath = $script:StatePath
            Cpu = $telemetry
            Error = $_.Exception.Message
        }
    }
}

function Set-CpuMaxFrequencyLimit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$MHz,
        [ValidateSet('AC', 'DC', 'Both')]
        [string]$Power = 'Both'
    )

    Assert-CpuFrequencyLimitValue -MHz $MHz

    $scheme = Get-ActivePowerScheme
    $setting = Get-ProcessorFrequencySetting -SchemeGuid $scheme.Guid
    Ensure-CpuFrequencyBackup -Scheme $scheme -Setting $setting

    if ($Power -eq 'AC' -or $Power -eq 'Both') {
        Set-CpuPowerSettingValue -SchemeGuid $scheme.Guid -Power AC -MHz ([uint64]$MHz)
    }

    if ($Power -eq 'DC' -or $Power -eq 'Both') {
        Set-CpuPowerSettingValue -SchemeGuid $scheme.Guid -Power DC -MHz ([uint64]$MHz)
    }

    Invoke-CpuPowerCfg /setactive $scheme.Guid | Out-Null
    return Get-CpuMaxFrequencyStatus
}

function Clear-CpuMaxFrequencyLimit {
    [CmdletBinding()]
    param(
        [ValidateSet('AC', 'DC', 'Both')]
        [string]$Power = 'Both'
    )

    $scheme = Get-ActivePowerScheme
    $setting = Get-ProcessorFrequencySetting -SchemeGuid $scheme.Guid
    Ensure-CpuFrequencyBackup -Scheme $scheme -Setting $setting

    if ($Power -eq 'AC' -or $Power -eq 'Both') {
        Set-CpuPowerSettingValue -SchemeGuid $scheme.Guid -Power AC -MHz 0
    }

    if ($Power -eq 'DC' -or $Power -eq 'Both') {
        Set-CpuPowerSettingValue -SchemeGuid $scheme.Guid -Power DC -MHz 0
    }

    Invoke-CpuPowerCfg /setactive $scheme.Guid | Out-Null
    return Get-CpuMaxFrequencyStatus
}

function Restore-CpuMaxFrequencyLimit {
    [CmdletBinding()]
    param()

    $scheme = Get-ActivePowerScheme
    $state = Get-CpuFrequencyState
    $backup = Get-CpuFrequencyBackup -State $state -SchemeGuid $scheme.Guid
    if ($null -eq $backup) {
        throw '当前电源方案没有可还原的 CPU 最大频率备份。'
    }

    Set-CpuPowerSettingValue -SchemeGuid $scheme.Guid -Power AC -MHz ([uint64]$backup.AcMaxFrequencyMHz)
    Set-CpuPowerSettingValue -SchemeGuid $scheme.Guid -Power DC -MHz ([uint64]$backup.DcMaxFrequencyMHz)
    Invoke-CpuPowerCfg /setactive $scheme.Guid | Out-Null
    return Get-CpuMaxFrequencyStatus
}

function Enable-CpuMaxFrequencySetting {
    [CmdletBinding()]
    param()

    Invoke-CpuPowerCfg /attributes $script:ProcessorSubgroupGuid $script:ProcessorMaxFrequencyGuid -ATTRIB_HIDE | Out-Null
    return Get-CpuMaxFrequencyStatus
}

Export-ModuleMember -Function @(
    'Get-CpuMaxFrequencyStatus',
    'Set-CpuMaxFrequencyLimit',
    'Clear-CpuMaxFrequencyLimit',
    'Restore-CpuMaxFrequencyLimit',
    'Enable-CpuMaxFrequencySetting',
    'ConvertTo-CpuFrequencyMHz',
    'Test-CpuFrequencyLimitValue',
    'ConvertFrom-CpuPowerSettingText',
    'Format-CpuFrequencyMHz',
    'Test-CpuFrequencyAdministrator'
)
