[CmdletBinding()]
param(
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'src\CpuMaxFrequencyControl.psm1'
Import-Module -Force -Name $modulePath

function Get-CpuFrequencyControlXaml {
    return @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="CPU 最大频率控制"
        Width="760"
        Height="520"
        MinWidth="700"
        MinHeight="480"
        WindowStartupLocation="CenterScreen"
        Background="#F6F7F9"
        FontFamily="Microsoft YaHei UI"
        ResizeMode="CanResize">
    <Window.Resources>
        <Style TargetType="{x:Type Button}">
            <Setter Property="MinWidth" Value="94" />
            <Setter Property="Height" Value="32" />
            <Setter Property="Margin" Value="0,0,8,0" />
            <Setter Property="Padding" Value="12,0" />
            <Setter Property="Background" Value="#FFFFFF" />
            <Setter Property="BorderBrush" Value="#B9C1C9" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="FontSize" Value="13" />
        </Style>
        <Style TargetType="{x:Type TextBlock}">
            <Setter Property="Foreground" Value="#1F2933" />
        </Style>
        <Style TargetType="{x:Type GroupBox}">
            <Setter Property="Margin" Value="0,0,0,12" />
            <Setter Property="Padding" Value="12" />
            <Setter Property="BorderBrush" Value="#CED6DE" />
            <Setter Property="BorderThickness" Value="1" />
        </Style>
    </Window.Resources>
    <Grid Margin="22">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>

        <DockPanel Grid.Row="0" Margin="0,0,0,16">
            <Button x:Name="RefreshButton" DockPanel.Dock="Right" Content="刷新" />
            <StackPanel>
                <TextBlock Text="CPU 最大频率控制" FontSize="22" FontWeight="SemiBold" />
                <TextBlock x:Name="SubtitleText" Margin="0,4,0,0" Foreground="#5B6673" FontSize="12" />
            </StackPanel>
        </DockPanel>

        <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*" />
                <ColumnDefinition Width="18" />
                <ColumnDefinition Width="*" />
            </Grid.ColumnDefinitions>

            <StackPanel Grid.Column="0">
                <GroupBox Header="当前状态">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="128" />
                            <ColumnDefinition Width="*" />
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto" />
                            <RowDefinition Height="Auto" />
                            <RowDefinition Height="Auto" />
                            <RowDefinition Height="Auto" />
                            <RowDefinition Height="Auto" />
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Grid.Column="0" Text="电源计划" Foreground="#5B6673" />
                        <TextBlock x:Name="SchemeText" Grid.Row="0" Grid.Column="1" TextWrapping="Wrap" />
                        <TextBlock Grid.Row="1" Grid.Column="0" Margin="0,10,0,0" Text="交流电" Foreground="#5B6673" />
                        <TextBlock x:Name="AcText" Grid.Row="1" Grid.Column="1" Margin="0,10,0,0" />
                        <TextBlock Grid.Row="2" Grid.Column="0" Margin="0,10,0,0" Text="电池" Foreground="#5B6673" />
                        <TextBlock x:Name="DcText" Grid.Row="2" Grid.Column="1" Margin="0,10,0,0" />
                        <TextBlock Grid.Row="3" Grid.Column="0" Margin="0,10,0,0" Text="管理员" Foreground="#5B6673" />
                        <TextBlock x:Name="AdminText" Grid.Row="3" Grid.Column="1" Margin="0,10,0,0" />
                        <TextBlock Grid.Row="4" Grid.Column="0" Margin="0,10,0,0" Text="设置 GUID" Foreground="#5B6673" />
                        <TextBlock x:Name="GuidText" Grid.Row="4" Grid.Column="1" Margin="0,10,0,0" TextWrapping="Wrap" />
                    </Grid>
                </GroupBox>

                <GroupBox Header="处理器信息">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="128" />
                            <ColumnDefinition Width="*" />
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto" />
                            <RowDefinition Height="Auto" />
                            <RowDefinition Height="Auto" />
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Grid.Column="0" Text="型号" Foreground="#5B6673" />
                        <TextBlock x:Name="CpuNameText" Grid.Row="0" Grid.Column="1" TextWrapping="Wrap" />
                        <TextBlock Grid.Row="1" Grid.Column="0" Margin="0,10,0,0" Text="当前/标称" Foreground="#5B6673" />
                        <TextBlock x:Name="CpuSpeedText" Grid.Row="1" Grid.Column="1" Margin="0,10,0,0" />
                        <TextBlock Grid.Row="2" Grid.Column="0" Margin="0,10,0,0" Text="核心/线程" Foreground="#5B6673" />
                        <TextBlock x:Name="CpuCoreText" Grid.Row="2" Grid.Column="1" Margin="0,10,0,0" />
                    </Grid>
                </GroupBox>
            </StackPanel>

            <StackPanel Grid.Column="2">
                <GroupBox Header="设置频率">
                    <StackPanel>
                        <TextBlock Text="最大频率" Foreground="#5B6673" />
                        <DockPanel Margin="0,6,0,12">
                            <TextBlock DockPanel.Dock="Right" Width="48" Margin="8,5,0,0" Text="MHz" Foreground="#5B6673" />
                            <TextBox x:Name="FrequencyTextBox" Height="30" VerticalContentAlignment="Center" FontSize="14" />
                        </DockPanel>
                        <TextBlock Text="也可以输入 2.2 GHz；0 请使用取消限制。" Foreground="#66737F" FontSize="12" Margin="0,0,0,12" />

                        <TextBlock Text="应用范围" Foreground="#5B6673" />
                        <ComboBox x:Name="PowerComboBox" Height="30" Margin="0,6,0,16" SelectedIndex="0">
                            <ComboBoxItem Content="交流电和电池" Tag="Both" />
                            <ComboBoxItem Content="仅交流电" Tag="AC" />
                            <ComboBoxItem Content="仅电池" Tag="DC" />
                        </ComboBox>

                        <WrapPanel>
                            <Button x:Name="ApplyButton" Content="应用限制" />
                            <Button x:Name="ClearButton" Content="取消限制" />
                            <Button x:Name="RestoreButton" Content="还原备份" />
                        </WrapPanel>
                    </StackPanel>
                </GroupBox>

                <GroupBox Header="系统入口">
                    <StackPanel>
                        <TextBlock Text="显示 Windows 高级电源选项里的“处理器最大频率”。" TextWrapping="Wrap" Foreground="#5B6673" />
                        <Button x:Name="UnhideButton" Margin="0,12,8,0" Content="显示隐藏项" HorizontalAlignment="Left" />
                    </StackPanel>
                </GroupBox>
            </StackPanel>
        </Grid>

        <Border Grid.Row="2" Margin="0,14,0,0" BorderBrush="#CAD2DA" BorderThickness="1" Background="#FFFFFF" Padding="10">
            <TextBlock x:Name="StatusText" TextWrapping="Wrap" Foreground="#34404A" />
        </Border>
    </Grid>
</Window>
'@
}

function Test-IsWindowsDesktopPowerShell {
    return ($PSVersionTable.PSEdition -eq 'Desktop')
}

function Restart-InWindowsPowerShell {
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $windowsPowerShell)) {
        throw "找不到 Windows PowerShell：$windowsPowerShell"
    }

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`""
    )

    Start-Process -FilePath $windowsPowerShell -ArgumentList $arguments -WorkingDirectory $PSScriptRoot
}

function Restart-Elevated {
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`""
    )

    Start-Process -FilePath $windowsPowerShell -Verb RunAs -ArgumentList $arguments -WorkingDirectory $PSScriptRoot
}

$xaml = Get-CpuFrequencyControlXaml

if ($ValidateOnly) {
    [xml]$null = $xaml
    $requiredNames = @(
        'RefreshButton', 'SubtitleText', 'SchemeText', 'AcText', 'DcText',
        'AdminText', 'GuidText', 'CpuNameText', 'CpuSpeedText', 'CpuCoreText',
        'FrequencyTextBox', 'PowerComboBox', 'ApplyButton', 'ClearButton',
        'RestoreButton', 'UnhideButton', 'StatusText'
    )

    foreach ($name in $requiredNames) {
        if ($xaml -notmatch "x:Name=`"$name`"") {
            throw "XAML 缺少控件：$name"
        }
    }

    Write-Host 'UI XAML 验证通过。'
    exit 0
}

if (-not (Test-IsWindowsDesktopPowerShell)) {
    Restart-InWindowsPowerShell
    exit 0
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

if (-not (Test-CpuFrequencyAdministrator)) {
    Restart-Elevated
    exit 0
}

$reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
$window = [Windows.Markup.XamlReader]::Load($reader)

$ui = @{}
$window.FindName('RefreshButton'), $window.FindName('SubtitleText'), $window.FindName('SchemeText'),
$window.FindName('AcText'), $window.FindName('DcText'), $window.FindName('AdminText'),
$window.FindName('GuidText'), $window.FindName('CpuNameText'), $window.FindName('CpuSpeedText'),
$window.FindName('CpuCoreText'), $window.FindName('FrequencyTextBox'), $window.FindName('PowerComboBox'),
$window.FindName('ApplyButton'), $window.FindName('ClearButton'), $window.FindName('RestoreButton'),
$window.FindName('UnhideButton'), $window.FindName('StatusText') | ForEach-Object {
    $ui[$_.Name] = $_
}

function Get-SelectedPowerTarget {
    $selected = $ui.PowerComboBox.SelectedItem
    if ($null -eq $selected) {
        return 'Both'
    }

    return [string]$selected.Tag
}

function Set-StatusMessage {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [switch]$Error
    )

    $ui.StatusText.Text = $Message
    if ($Error) {
        $ui.StatusText.Foreground = [System.Windows.Media.Brushes]::Firebrick
    }
    else {
        $ui.StatusText.Foreground = [System.Windows.Media.Brushes]::DarkSlateGray
    }
}

function Refresh-Ui {
    param(
        [string]$Message
    )

    $status = Get-CpuMaxFrequencyStatus
    if (-not $status.Available) {
        $ui.SubtitleText.Text = '当前系统未公开 PROCFREQMAX 频率上限。'
        $ui.SchemeText.Text = '-'
        $ui.AcText.Text = '-'
        $ui.DcText.Text = '-'
        $ui.AdminText.Text = if ($status.IsAdministrator) { '是' } else { '否' }
        $ui.GuidText.Text = $status.ProcessorMaxFrequencyGuid
        Set-StatusMessage -Message "读取失败：$($status.Error)" -Error
        return
    }

    $schemeName = if ($status.SchemeName) { $status.SchemeName } else { '未命名' }
    $ui.SubtitleText.Text = '使用 Windows PROCFREQMAX，写入单位为 MHz。'
    $ui.SchemeText.Text = "$schemeName ($($status.SchemeGuid))"
    $ui.AcText.Text = $status.AcDisplay
    $ui.DcText.Text = $status.DcDisplay
    $ui.AdminText.Text = if ($status.IsAdministrator) { '是' } else { '否' }
    $ui.GuidText.Text = $status.ProcessorMaxFrequencyGuid

    if ($status.Cpu -and $status.Cpu.Name) {
        $ui.CpuNameText.Text = $status.Cpu.Name
        $ui.CpuSpeedText.Text = "$($status.Cpu.CurrentClockSpeedMHz) / $($status.Cpu.MaxClockSpeedMHz) MHz"
        $ui.CpuCoreText.Text = "$($status.Cpu.NumberOfCores) / $($status.Cpu.NumberOfLogicalProcessors)"
    }
    else {
        $ui.CpuNameText.Text = '不可用'
        $ui.CpuSpeedText.Text = '不可用'
        $ui.CpuCoreText.Text = '不可用'
    }

    if ($Message) {
        Set-StatusMessage -Message $Message
    }
    else {
        Set-StatusMessage -Message '状态已刷新。'
    }
}

$ui.RefreshButton.Add_Click({
    Refresh-Ui
})

$ui.ApplyButton.Add_Click({
    try {
        $mhz = ConvertTo-CpuFrequencyMHz -Value $ui.FrequencyTextBox.Text
        Set-StatusMessage -Message "正在写入 $mhz MHz..."
        $null = Set-CpuMaxFrequencyLimit -MHz $mhz -Power (Get-SelectedPowerTarget)
        Refresh-Ui -Message "已应用最大频率：$mhz MHz。"
    }
    catch {
        Set-StatusMessage -Message "应用失败：$($_.Exception.Message)" -Error
    }
})

$ui.ClearButton.Add_Click({
    try {
        Set-StatusMessage -Message '正在取消限制...'
        $null = Clear-CpuMaxFrequencyLimit -Power (Get-SelectedPowerTarget)
        Refresh-Ui -Message '已取消所选供电状态的最大频率限制。'
    }
    catch {
        Set-StatusMessage -Message "取消失败：$($_.Exception.Message)" -Error
    }
})

$ui.RestoreButton.Add_Click({
    try {
        Set-StatusMessage -Message '正在还原备份...'
        $null = Restore-CpuMaxFrequencyLimit
        Refresh-Ui -Message '已还原首次修改前的 AC/DC 最大频率。'
    }
    catch {
        Set-StatusMessage -Message "还原失败：$($_.Exception.Message)" -Error
    }
})

$ui.UnhideButton.Add_Click({
    try {
        Set-StatusMessage -Message '正在显示 Windows 高级电源选项隐藏项...'
        $null = Enable-CpuMaxFrequencySetting
        Refresh-Ui -Message '已请求显示“处理器最大频率”高级电源选项。'
    }
    catch {
        Set-StatusMessage -Message "显示隐藏项失败：$($_.Exception.Message)" -Error
    }
})

Refresh-Ui
$window.ShowDialog() | Out-Null
