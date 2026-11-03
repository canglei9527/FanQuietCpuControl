[CmdletBinding()]
param(
    [switch]$ValidateOnly,
    [switch]$DriverStatusOnly,
    [string]$WorkerAction,
    [string]$WorkerPayloadBase64,
    [switch]$AsyncLifecycleTest,
    [switch]$LayoutPreview
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ApplicationScriptPath = $PSCommandPath
$script:OperationInProgress = $false
$script:CanApplyCpuUndervolt = $false
$script:LegionControllerInstance = $null
$script:OperationCompletionHandler = $null
$script:OperationProcess = $null
$script:OperationIsReadOnly = $false
$script:OperationTimedOut = $false
$script:OperationCancelled = $false
$script:CloseWhenOperationEnds = $false
$script:SlowOperationNoticeShown = $false
$script:ReadOnlyOperationTimeoutMilliseconds = 20000
$script:ProcessPageLoaded = $false
$script:GraphicsPageLoaded = $false
$script:PendingPageRefreshAction = $null
$script:AsyncTestStartedActions = New-Object 'System.Collections.Generic.List[string]'
$script:MainProcessId = $PID
$script:NvidiaControlPanelAppId = $null
$script:NvidiaControlPanelAppName = $null
$script:LenovoVantageAppId = $null
$script:LenovoVantageAppName = $null
$script:WindowsGraphicsSettingsAvailable = ([System.Environment]::OSVersion.Version.Major -ge 10)

if (-not $WorkerAction) {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
}

$energyDriverSource = @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class LenovoEnergyFanDriver
{
    private const uint GenericRead = 0x80000000;
    private const uint GenericWrite = 0x40000000;
    private const uint FileShareRead = 0x00000001;
    private const uint FileShareWrite = 0x00000002;
    private const uint OpenExisting = 3;
    private const uint FileAttributeNormal = 0x00000080;
    private const uint IoctlSetFanMode = 0x831020C0;
    private const uint IoctlGetFanMode = 0x831020C4;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeviceIoControl(
        SafeFileHandle device,
        uint controlCode,
        byte[] inputBuffer,
        uint inputBufferLength,
        byte[] outputBuffer,
        uint outputBufferLength,
        out uint bytesReturned,
        IntPtr overlapped);

    public static bool TryGetMode(out uint mode, out int error)
    {
        byte[] output;
        bool result = Send(IoctlGetFanMode, new uint[] { 14 }, 4, out output, out error);
        mode = result && output.Length >= 4 ? BitConverter.ToUInt32(output, 0) : 0;
        return result;
    }

    public static bool TrySetMode(uint mode, out int error)
    {
        byte[] output;
        return Send(IoctlSetFanMode, new uint[] { 6, 1, mode }, 4, out output, out error);
    }

    private static bool Send(uint controlCode, uint[] words, int outputLength, out byte[] output, out int error)
    {
        byte[] input = new byte[words.Length * 4];
        for (int index = 0; index < words.Length; index++)
            Buffer.BlockCopy(BitConverter.GetBytes(words[index]), 0, input, index * 4, 4);

        output = new byte[outputLength];
        error = 0;

        using (SafeFileHandle handle = CreateFile(
            @"\\.\EnergyDrv",
            GenericRead | GenericWrite,
            FileShareRead | FileShareWrite,
            IntPtr.Zero,
            OpenExisting,
            FileAttributeNormal,
            IntPtr.Zero))
        {
            if (handle.IsInvalid)
            {
                error = Marshal.GetLastWin32Error();
                return false;
            }

            uint bytesReturned;
            bool result = DeviceIoControl(
                handle,
                controlCode,
                input,
                (uint)input.Length,
                output,
                (uint)output.Length,
                out bytesReturned,
                IntPtr.Zero);

            if (!result)
                error = Marshal.GetLastWin32Error();

            return result;
        }
    }
}
'@

function Initialize-EnergyFanDriver {
    if ($null -eq ('LenovoEnergyFanDriver' -as [type])) {
        Add-Type -TypeDefinition $energyDriverSource
    }
}

if ($DriverStatusOnly) {
    Initialize-EnergyFanDriver
    [uint32]$mode = 0
    [int]$errorCode = 0
    $success = [LenovoEnergyFanDriver]::TryGetMode([ref]$mode, [ref]$errorCode)
    [pscustomobject]@{
        Success = $success
        Mode = if ($success) { [int]$mode } else { $null }
        ErrorCode = if ($success) { 0 } else { $errorCode }
    } | Format-List
    exit $(if ($success) { 0 } else { 1 })
}

$script:ProcessorSubgroup = '54533251-82be-4824-96c1-47b60b740d00'
$script:ProcessorMinimum = '893dee8e-2bef-41e0-89c6-b55d0929964c'
$script:ProcessorMaximum = 'bc5038f7-23e0-4960-96da-33abaf5935ec'
$script:SystemCooling = '94d3a615-a899-4ac5-ae2b-e4d8f634367f'
$script:PowerCfg = Join-Path $env:SystemRoot 'System32\powercfg.exe'
$script:StateDirectory = Join-Path $env:LOCALAPPDATA 'LenovoFanQuiet'
$script:StatePath = Join-Path $script:StateDirectory 'power-policy-backup.json'
$script:CpuFrequencyModulePath = Join-Path $PSScriptRoot 'CpuMaxFrequencyControl.psm1'
$script:CpuUndervoltModulePath = Join-Path $PSScriptRoot 'CpuUndervolt.psm1'
$script:ProcessPriorityModulePath = Join-Path $PSScriptRoot 'ProcessPriorityControl.psm1'

foreach ($modulePath in @($script:CpuFrequencyModulePath, $script:CpuUndervoltModulePath, $script:ProcessPriorityModulePath)) {
    if (-not (Test-Path -LiteralPath $modulePath)) {
        throw "找不到 CPU 控制模块：$modulePath"
    }
}

Import-Module -Force -Name $script:CpuFrequencyModulePath
Import-Module -Force -Name $script:CpuUndervoltModulePath
Import-Module -Force -Name $script:ProcessPriorityModulePath

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="联想 Legion 风扇静音控制"
        Width="980"
        Height="760"
        MinWidth="800"
        MinHeight="600"
        WindowStartupLocation="CenterScreen"
        ResizeMode="CanResize"
        Background="#EDF1F6"
        FontFamily="Microsoft YaHei UI"
        Foreground="#12212E"
        UseLayoutRounding="True"
        SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display"
        TextOptions.TextRenderingMode="ClearType">
    <Window.Resources>
        <SolidColorBrush x:Key="PageBackgroundBrush" Color="#EDF1F6" />
        <SolidColorBrush x:Key="CardBrush" Color="#FFFFFF" />
        <SolidColorBrush x:Key="CardBorderBrush" Color="#DEE6EF" />
        <SolidColorBrush x:Key="InkBrush" Color="#12212E" />
        <SolidColorBrush x:Key="MutedBrush" Color="#62748A" />
        <SolidColorBrush x:Key="SubtleBrush" Color="#8A9AAC" />
        <SolidColorBrush x:Key="AccentBrush" Color="#0F766E" />
        <SolidColorBrush x:Key="AccentDarkBrush" Color="#0B5F59" />
        <SolidColorBrush x:Key="AccentSoftBrush" Color="#E6F4F1" />
        <SolidColorBrush x:Key="SurfaceAltBrush" Color="#F5F8FB" />
        <SolidColorBrush x:Key="DividerBrush" Color="#E8EEF4" />
        <SolidColorBrush x:Key="WarningSurfaceBrush" Color="#FFF8EB" />
        <SolidColorBrush x:Key="WarningBorderBrush" Color="#F3D9A4" />
        <SolidColorBrush x:Key="WarningInkBrush" Color="#8A5A12" />
        <SolidColorBrush x:Key="ErrorSurfaceBrush" Color="#FEF2F2" />
        <SolidColorBrush x:Key="ErrorBorderBrush" Color="#F5C2C2" />
        <SolidColorBrush x:Key="ErrorInkBrush" Color="#A12828" />
        <SolidColorBrush x:Key="SuccessBrush" Color="#12805C" />
        <SolidColorBrush x:Key="ModeIdleBrush" Color="#FFFFFF" />
        <SolidColorBrush x:Key="ModeIdleBorderBrush" Color="#DCE5EE" />

        <Style TargetType="{x:Type TextBlock}">
            <Setter Property="FontFamily" Value="Microsoft YaHei UI" />
            <Setter Property="TextOptions.TextFormattingMode" Value="Display" />
        </Style>

        <Style x:Key="PageTitle" TargetType="{x:Type TextBlock}">
            <Setter Property="FontSize" Value="18" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="Foreground" Value="{StaticResource InkBrush}" />
        </Style>
        <Style x:Key="PageDescription" TargetType="{x:Type TextBlock}">
            <Setter Property="FontSize" Value="12" />
            <Setter Property="Foreground" Value="{StaticResource MutedBrush}" />
            <Setter Property="TextWrapping" Value="Wrap" />
            <Setter Property="LineHeight" Value="19" />
            <Setter Property="Margin" Value="0,4,0,0" />
        </Style>
        <Style x:Key="CardTitle" TargetType="{x:Type TextBlock}">
            <Setter Property="FontSize" Value="14" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="Foreground" Value="{StaticResource InkBrush}" />
        </Style>
        <Style x:Key="CardHint" TargetType="{x:Type TextBlock}">
            <Setter Property="FontSize" Value="12" />
            <Setter Property="Foreground" Value="{StaticResource MutedBrush}" />
            <Setter Property="TextWrapping" Value="Wrap" />
            <Setter Property="LineHeight" Value="19" />
        </Style>
        <Style x:Key="FieldLabel" TargetType="{x:Type TextBlock}">
            <Setter Property="FontSize" Value="12" />
            <Setter Property="Foreground" Value="{StaticResource MutedBrush}" />
            <Setter Property="VerticalAlignment" Value="Center" />
        </Style>
        <Style x:Key="MetricLabel" TargetType="{x:Type TextBlock}">
            <Setter Property="FontSize" Value="12" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="Foreground" Value="{StaticResource MutedBrush}" />
            <Setter Property="VerticalAlignment" Value="Center" />
        </Style>
        <Style x:Key="MetricValue" TargetType="{x:Type TextBlock}">
            <Setter Property="FontSize" Value="20" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="Foreground" Value="{StaticResource InkBrush}" />
            <Setter Property="TextWrapping" Value="NoWrap" />
            <Setter Property="TextTrimming" Value="CharacterEllipsis" />
            <Setter Property="Margin" Value="0,6,0,0" />
        </Style>
        <Style x:Key="MetricHint" TargetType="{x:Type TextBlock}">
            <Setter Property="FontSize" Value="11" />
            <Setter Property="Foreground" Value="{StaticResource SubtleBrush}" />
            <Setter Property="TextWrapping" Value="Wrap" />
            <Setter Property="Margin" Value="0,4,0,0" />
        </Style>

        <Style x:Key="Card" TargetType="{x:Type Border}">
            <Setter Property="Background" Value="{StaticResource CardBrush}" />
            <Setter Property="BorderBrush" Value="{StaticResource CardBorderBrush}" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="CornerRadius" Value="12" />
            <Setter Property="Padding" Value="16" />
        </Style>
        <Style x:Key="MetricCard" TargetType="{x:Type Border}" BasedOn="{StaticResource Card}">
            <Setter Property="Padding" Value="14" />
            <Setter Property="MinHeight" Value="96" />
        </Style>
        <Style x:Key="InsetCard" TargetType="{x:Type Border}">
            <Setter Property="Background" Value="{StaticResource SurfaceAltBrush}" />
            <Setter Property="BorderBrush" Value="{StaticResource DividerBrush}" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="CornerRadius" Value="8" />
            <Setter Property="Padding" Value="12" />
        </Style>

        <Style x:Key="BaseButton" TargetType="{x:Type Button}">
            <Setter Property="MinWidth" Value="88" />
            <Setter Property="Height" Value="32" />
            <Setter Property="Padding" Value="14,0" />
            <Setter Property="Background" Value="{StaticResource CardBrush}" />
            <Setter Property="BorderBrush" Value="{StaticResource CardBorderBrush}" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="Foreground" Value="{StaticResource InkBrush}" />
            <Setter Property="FontSize" Value="12.5" />
            <Setter Property="Cursor" Value="Hand" />
            <Setter Property="FocusVisualStyle" Value="{x:Null}" />
            <Setter Property="HorizontalContentAlignment" Value="Center" />
            <Setter Property="VerticalContentAlignment" Value="Center" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Button}">
                        <Grid>
                            <Border x:Name="ButtonBorder"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{TemplateBinding BorderThickness}"
                                    CornerRadius="8"
                                    SnapsToDevicePixels="True" />
                            <Border x:Name="HoverOverlay" Background="#0F000000" CornerRadius="8" Opacity="0" />
                            <ContentPresenter x:Name="ButtonContent"
                                              Margin="{TemplateBinding Padding}"
                                              HorizontalAlignment="Center"
                                              VerticalAlignment="Center"
                                              RecognizesAccessKey="True"
                                              TextElement.Foreground="{TemplateBinding Foreground}" />
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="HoverOverlay" Property="Opacity" Value="0.05" />
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="HoverOverlay" Property="Opacity" Value="0.11" />
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="ButtonBorder" Property="BorderBrush" Value="{StaticResource AccentBrush}" />
                                <Setter TargetName="ButtonBorder" Property="BorderThickness" Value="1.5" />
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="ButtonBorder" Property="Opacity" Value="0.45" />
                                <Setter TargetName="ButtonContent" Property="Opacity" Value="0.55" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="{x:Type Button}" BasedOn="{StaticResource BaseButton}" />
        <Style x:Key="AccentButton" TargetType="{x:Type Button}" BasedOn="{StaticResource BaseButton}">
            <Setter Property="Background" Value="{StaticResource AccentBrush}" />
            <Setter Property="BorderBrush" Value="{StaticResource AccentBrush}" />
            <Setter Property="Foreground" Value="#FFFFFF" />
            <Setter Property="FontWeight" Value="SemiBold" />
        </Style>
        <Style x:Key="ModeButton" TargetType="{x:Type Button}" BasedOn="{StaticResource BaseButton}">
            <Setter Property="MinWidth" Value="0" />
            <Setter Property="Margin" Value="2" />
            <Setter Property="Padding" Value="6,0" />
            <Setter Property="Background" Value="{StaticResource ModeIdleBrush}" />
            <Setter Property="BorderBrush" Value="{StaticResource ModeIdleBorderBrush}" />
            <Setter Property="Foreground" Value="{StaticResource InkBrush}" />
        </Style>

        <Style TargetType="{x:Type TextBox}">
            <Setter Property="Height" Value="34" />
            <Setter Property="Padding" Value="10,0" />
            <Setter Property="Background" Value="{StaticResource CardBrush}" />
            <Setter Property="BorderBrush" Value="{StaticResource CardBorderBrush}" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="Foreground" Value="{StaticResource InkBrush}" />
            <Setter Property="FontSize" Value="13" />
            <Setter Property="CaretBrush" Value="{StaticResource AccentBrush}" />
            <Setter Property="SelectionBrush" Value="{StaticResource AccentSoftBrush}" />
            <Setter Property="VerticalContentAlignment" Value="Center" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type TextBox}">
                        <Border x:Name="TextBoxBorder"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="8"
                                Padding="{TemplateBinding Padding}"
                                SnapsToDevicePixels="True">
                            <ScrollViewer x:Name="PART_ContentHost"
                                          VerticalAlignment="Center"
                                          HorizontalScrollBarVisibility="Hidden"
                                          VerticalScrollBarVisibility="Hidden" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="TextBoxBorder" Property="BorderBrush" Value="{StaticResource AccentBrush}" />
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="TextBoxBorder" Property="Opacity" Value="0.55" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="{x:Type ComboBoxItem}">
            <Setter Property="Padding" Value="10,7" />
            <Setter Property="Foreground" Value="{StaticResource InkBrush}" />
            <Setter Property="FontSize" Value="12.5" />
            <Setter Property="HorizontalContentAlignment" Value="Stretch" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ComboBoxItem}">
                        <Border x:Name="ItemBorder" Background="Transparent" CornerRadius="6" Padding="{TemplateBinding Padding}" Margin="4,2">
                            <ContentPresenter TextElement.Foreground="{TemplateBinding Foreground}" VerticalAlignment="Center" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsHighlighted" Value="True">
                                <Setter TargetName="ItemBorder" Property="Background" Value="{StaticResource AccentSoftBrush}" />
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="ItemBorder" Property="Background" Value="{StaticResource AccentSoftBrush}" />
                                <Setter Property="FontWeight" Value="SemiBold" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="{x:Type ComboBox}">
            <Setter Property="Height" Value="34" />
            <Setter Property="Padding" Value="10,0" />
            <Setter Property="Background" Value="{StaticResource CardBrush}" />
            <Setter Property="BorderBrush" Value="{StaticResource CardBorderBrush}" />
            <Setter Property="Foreground" Value="{StaticResource InkBrush}" />
            <Setter Property="FontSize" Value="12.5" />
            <Setter Property="Cursor" Value="Hand" />
            <Setter Property="FocusVisualStyle" Value="{x:Null}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ComboBox}">
                        <Grid>
                            <Border x:Name="ComboBorder"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="1"
                                    CornerRadius="8"
                                    SnapsToDevicePixels="True" />
                            <ContentPresenter Margin="10,0,32,0"
                                              VerticalAlignment="Center"
                                              IsHitTestVisible="False"
                                              Content="{TemplateBinding SelectionBoxItem}"
                                              ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                              ContentStringFormat="{TemplateBinding SelectionBoxItemStringFormat}"
                                              TextElement.Foreground="{TemplateBinding Foreground}" />
                            <ToggleButton x:Name="DropDownToggle"
                                          Focusable="False"
                                          ClickMode="Press"
                                          Background="Transparent"
                                          BorderThickness="0"
                                          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="{x:Type ToggleButton}">
                                        <Grid Background="Transparent">
                                            <Path Data="M 0 0 L 4 4 L 8 0"
                                                  Stroke="{StaticResource MutedBrush}"
                                                  StrokeThickness="1.6"
                                                  HorizontalAlignment="Right"
                                                  VerticalAlignment="Center"
                                                  Margin="0,0,12,0" />
                                        </Grid>
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>
                            <Popup x:Name="PART_Popup"
                                   Placement="Bottom"
                                   VerticalOffset="4"
                                   AllowsTransparency="True"
                                   Focusable="False"
                                   PopupAnimation="None"
                                   IsOpen="{TemplateBinding IsDropDownOpen}">
                                <Border Background="{StaticResource CardBrush}"
                                        BorderBrush="{StaticResource CardBorderBrush}"
                                        BorderThickness="1"
                                        CornerRadius="8"
                                        Padding="4"
                                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}"
                                        MaxHeight="280">
                                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                                        <ItemsPresenter />
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="ComboBorder" Property="BorderBrush" Value="{StaticResource AccentBrush}" />
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="ComboBorder" Property="Opacity" Value="0.55" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="{x:Type CheckBox}">
            <Setter Property="Foreground" Value="{StaticResource InkBrush}" />
            <Setter Property="FontSize" Value="12.5" />
            <Setter Property="Cursor" Value="Hand" />
            <Setter Property="FocusVisualStyle" Value="{x:Null}" />
            <Setter Property="VerticalContentAlignment" Value="Center" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type CheckBox}">
                        <StackPanel x:Name="CheckRoot" Orientation="Horizontal" Background="Transparent">
                            <Border x:Name="CheckBoxBorder"
                                    Width="18"
                                    Height="18"
                                    CornerRadius="4"
                                    Background="{StaticResource CardBrush}"
                                    BorderBrush="#B9C7D4"
                                    BorderThickness="1"
                                    VerticalAlignment="Center">
                                <Path x:Name="CheckGlyph"
                                      Data="M 3,7 L 7,11 L 14,4"
                                      Stroke="#FFFFFF"
                                      StrokeThickness="2"
                                      StrokeStartLineCap="Round"
                                      StrokeEndLineCap="Round"
                                      StrokeLineJoin="Round"
                                      Visibility="Collapsed" />
                            </Border>
                            <ContentPresenter Margin="8,0,0,0"
                                              VerticalAlignment="Center"
                                              TextElement.Foreground="{TemplateBinding Foreground}" />
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="CheckBoxBorder" Property="Background" Value="{StaticResource AccentBrush}" />
                                <Setter TargetName="CheckBoxBorder" Property="BorderBrush" Value="{StaticResource AccentBrush}" />
                                <Setter TargetName="CheckGlyph" Property="Visibility" Value="Visible" />
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="CheckBoxBorder" Property="BorderBrush" Value="{StaticResource AccentBrush}" />
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="CheckRoot" Property="Opacity" Value="0.5" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="{x:Type Expander}">
            <Setter Property="Foreground" Value="{StaticResource InkBrush}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Expander}">
                        <StackPanel>
                            <ToggleButton x:Name="HeaderToggle"
                                          Focusable="False"
                                          Cursor="Hand"
                                          Background="Transparent"
                                          BorderThickness="0"
                                          Content="{TemplateBinding Header}"
                                          ContentTemplate="{TemplateBinding HeaderTemplate}"
                                          IsChecked="{Binding IsExpanded, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="{x:Type ToggleButton}">
                                        <Border x:Name="HeaderBorder" Background="Transparent" CornerRadius="8" Padding="10,8" Margin="0,0,0,4">
                                            <Grid>
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="Auto" />
                                                    <ColumnDefinition Width="*" />
                                                </Grid.ColumnDefinitions>
                                                <Path x:Name="Chevron"
                                                      Data="M 0 0 L 4 4 L 0 8"
                                                      Stroke="{StaticResource MutedBrush}"
                                                      StrokeThickness="1.6"
                                                      VerticalAlignment="Center"
                                                      Margin="2,0,10,0">
                                                </Path>
                                                <ContentPresenter Grid.Column="1"
                                                                  Content="{TemplateBinding Content}"
                                                                  ContentTemplate="{TemplateBinding ContentTemplate}"
                                                                  VerticalAlignment="Center"
                                                                  TextElement.Foreground="{TemplateBinding Foreground}"
                                                                  TextElement.FontWeight="SemiBold"
                                                                  TextElement.FontSize="13" />
                                            </Grid>
                                        </Border>
                                        <ControlTemplate.Triggers>
                                            <Trigger Property="IsMouseOver" Value="True">
                                                <Setter TargetName="HeaderBorder" Property="Background" Value="{StaticResource SurfaceAltBrush}" />
                                            </Trigger>
                                            <Trigger Property="IsChecked" Value="True">
                                                                                                    <Setter TargetName="Chevron" Property="RenderTransform">
                                                        <Setter.Value>
                                                            <RotateTransform Angle="90" />
                                                        </Setter.Value>
                                                    </Setter>
                                            </Trigger>
                                        </ControlTemplate.Triggers>
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>
                            <ContentPresenter x:Name="ExpandSite" Visibility="Collapsed" Margin="0,4,0,0" Content="{TemplateBinding Content}" ContentTemplate="{TemplateBinding ContentTemplate}" />
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsExpanded" Value="True">
                                <Setter TargetName="ExpandSite" Property="Visibility" Value="Visible" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="{x:Type TabItem}">
            <Setter Property="Foreground" Value="{StaticResource MutedBrush}" />
            <Setter Property="FontSize" Value="13" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type TabItem}">
                        <Border x:Name="TabBorder" Background="Transparent" CornerRadius="8" Padding="15,7" Margin="0,0,2,0">
                            <ContentPresenter ContentSource="Header"
                                              VerticalAlignment="Center"
                                              TextElement.FontWeight="SemiBold"
                                              TextElement.Foreground="{TemplateBinding Foreground}" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="TabBorder" Property="Background" Value="#F7FAFD" />
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="TabBorder" Property="Background" Value="{StaticResource CardBrush}" />
                                <Setter Property="Foreground" Value="{StaticResource AccentBrush}" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="{x:Type TabControl}">
            <Setter Property="Background" Value="Transparent" />
            <Setter Property="BorderThickness" Value="0" />
            <Setter Property="Padding" Value="0" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type TabControl}">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto" />
                                <RowDefinition Height="*" />
                            </Grid.RowDefinitions>
                            <Border Background="#E7EDF3" CornerRadius="10" Padding="4" HorizontalAlignment="Left" Margin="0,0,0,10">
                                <TabPanel IsItemsHost="True" />
                            </Border>
                            <ContentPresenter x:Name="PART_SelectedContentHost" Grid.Row="1" ContentSource="SelectedContent" />
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="{x:Type DataGridColumnHeader}">
            <Setter Property="Height" Value="36" />
            <Setter Property="Padding" Value="10,0" />
            <Setter Property="Background" Value="#F8FAFC" />
            <Setter Property="BorderBrush" Value="{StaticResource DividerBrush}" />
            <Setter Property="BorderThickness" Value="0,0,0,1" />
            <Setter Property="Foreground" Value="{StaticResource MutedBrush}" />
            <Setter Property="FontSize" Value="11.5" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="HorizontalContentAlignment" Value="Left" />
            <Setter Property="Cursor" Value="Hand" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type DataGridColumnHeader}">
                        <Border x:Name="HeaderBorder"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                Padding="{TemplateBinding Padding}"
                                SnapsToDevicePixels="True">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*" />
                                    <ColumnDefinition Width="Auto" />
                                </Grid.ColumnDefinitions>
                                <ContentPresenter VerticalAlignment="Center"
                                                  Content="{TemplateBinding Content}"
                                                  ContentTemplate="{TemplateBinding ContentTemplate}"
                                                  TextElement.Foreground="{TemplateBinding Foreground}" />
                                <Path x:Name="SortArrow"
                                      Grid.Column="1"
                                      Data="M 0 4 L 4 0 L 8 4"
                                      Stroke="{StaticResource MutedBrush}"
                                      StrokeThickness="1.4"
                                      VerticalAlignment="Center"
                                      Margin="6,0,0,0"
                                      Visibility="Collapsed" />
                            </Grid>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="SortDirection" Value="Descending">
                                <Setter TargetName="SortArrow" Property="Visibility" Value="Visible" />
                                <Setter TargetName="SortArrow" Property="RenderTransform">
                                    <Setter.Value>
                                        <RotateTransform Angle="180" />
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                            <Trigger Property="SortDirection" Value="Ascending">
                                <Setter TargetName="SortArrow" Property="Visibility" Value="Visible" />
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="HeaderBorder" Property="Background" Value="#F1F6FA" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="{x:Type DataGridRow}">
            <Setter Property="Background" Value="{StaticResource CardBrush}" />
            <Setter Property="Foreground" Value="{StaticResource InkBrush}" />
            <Setter Property="Height" Value="34" />
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#F8FAFC" />
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="{StaticResource AccentSoftBrush}" />
                    <Setter Property="Foreground" Value="{StaticResource InkBrush}" />
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="{x:Type DataGridCell}">
            <Setter Property="Background" Value="Transparent" />
            <Setter Property="BorderThickness" Value="0" />
            <Setter Property="Padding" Value="10,0" />
            <Setter Property="Foreground" Value="{StaticResource InkBrush}" />
            <Setter Property="FocusVisualStyle" Value="{x:Null}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type DataGridCell}">
                        <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
                            <ContentPresenter VerticalAlignment="Center"
                                              Content="{TemplateBinding Content}"
                                              ContentTemplate="{TemplateBinding ContentTemplate}"
                                              TextElement.Foreground="{TemplateBinding Foreground}" />
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="{x:Type DataGrid}">
            <Setter Property="Background" Value="{StaticResource CardBrush}" />
            <Setter Property="BorderThickness" Value="0" />
            <Setter Property="Foreground" Value="{StaticResource InkBrush}" />
            <Setter Property="RowBackground" Value="{StaticResource CardBrush}" />
            <Setter Property="HorizontalGridLinesBrush" Value="{StaticResource DividerBrush}" />
            <Setter Property="VerticalGridLinesBrush" Value="Transparent" />
            <Setter Property="GridLinesVisibility" Value="Horizontal" />
            <Setter Property="HeadersVisibility" Value="Column" />
            <Setter Property="RowHeaderWidth" Value="0" />
            <Setter Property="ColumnHeaderHeight" Value="36" />
            <Setter Property="RowHeight" Value="34" />
            <Setter Property="CanUserAddRows" Value="False" />
            <Setter Property="CanUserResizeRows" Value="False" />
            <Setter Property="CanUserResizeColumns" Value="False" />
            <Setter Property="SelectionMode" Value="Single" />
            <Setter Property="SelectionUnit" Value="FullRow" />
            <Setter Property="EnableRowVirtualization" Value="True" />
            <Setter Property="EnableColumnVirtualization" Value="True" />
            <Setter Property="VirtualizingPanel.IsVirtualizing" Value="True" />
            <Setter Property="VirtualizingPanel.VirtualizationMode" Value="Recycling" />
            <Setter Property="ScrollViewer.CanContentScroll" Value="True" />
            <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Auto" />
            <Setter Property="ScrollViewer.VerticalScrollBarVisibility" Value="Auto" />
        </Style>

        <Style TargetType="{x:Type ToolTip}">
            <Setter Property="Background" Value="#0F172A" />
            <Setter Property="Foreground" Value="#FFFFFF" />
            <Setter Property="Padding" Value="10,7" />
            <Setter Property="FontSize" Value="12" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ToolTip}">
                        <Border Background="{TemplateBinding Background}"
                                CornerRadius="6"
                                Padding="{TemplateBinding Padding}"
                                MaxWidth="380">
                            <ContentPresenter TextElement.Foreground="{TemplateBinding Foreground}" />
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <ControlTemplate x:Key="VerticalScrollBarTemplate" TargetType="{x:Type ScrollBar}">
            <Grid Width="10" Background="Transparent">
                <Track x:Name="PART_Track" IsDirectionReversed="True">
                    <Track.DecreaseRepeatButton>
                        <RepeatButton Command="{x:Static ScrollBar.PageUpCommand}" Opacity="0" Focusable="False" />
                    </Track.DecreaseRepeatButton>
                    <Track.Thumb>
                        <Thumb MinHeight="24">
                            <Thumb.Template>
                                <ControlTemplate TargetType="{x:Type Thumb}">
                                    <Border x:Name="ThumbBorder" Background="#C9D5E1" CornerRadius="3" Margin="2,0" />
                                    <ControlTemplate.Triggers>
                                        <Trigger Property="IsMouseOver" Value="True">
                                            <Setter TargetName="ThumbBorder" Property="Background" Value="#AFC0D0" />
                                        </Trigger>
                                        <Trigger Property="IsDragging" Value="True">
                                            <Setter TargetName="ThumbBorder" Property="Background" Value="#8FA5B8" />
                                        </Trigger>
                                    </ControlTemplate.Triggers>
                                </ControlTemplate>
                            </Thumb.Template>
                        </Thumb>
                    </Track.Thumb>
                    <Track.IncreaseRepeatButton>
                        <RepeatButton Command="{x:Static ScrollBar.PageDownCommand}" Opacity="0" Focusable="False" />
                    </Track.IncreaseRepeatButton>
                </Track>
            </Grid>
        </ControlTemplate>
        <ControlTemplate x:Key="HorizontalScrollBarTemplate" TargetType="{x:Type ScrollBar}">
            <Grid Height="10" Background="Transparent">
                <Track x:Name="PART_Track" Orientation="Horizontal" IsDirectionReversed="False">
                    <Track.DecreaseRepeatButton>
                        <RepeatButton Command="{x:Static ScrollBar.PageLeftCommand}" Opacity="0" Focusable="False" />
                    </Track.DecreaseRepeatButton>
                    <Track.Thumb>
                        <Thumb MinWidth="24">
                            <Thumb.Template>
                                <ControlTemplate TargetType="{x:Type Thumb}">
                                    <Border x:Name="ThumbBorder" Background="#C9D5E1" CornerRadius="3" Margin="0,2" />
                                    <ControlTemplate.Triggers>
                                        <Trigger Property="IsMouseOver" Value="True">
                                            <Setter TargetName="ThumbBorder" Property="Background" Value="#AFC0D0" />
                                        </Trigger>
                                        <Trigger Property="IsDragging" Value="True">
                                            <Setter TargetName="ThumbBorder" Property="Background" Value="#8FA5B8" />
                                        </Trigger>
                                    </ControlTemplate.Triggers>
                                </ControlTemplate>
                            </Thumb.Template>
                        </Thumb>
                    </Track.Thumb>
                    <Track.IncreaseRepeatButton>
                        <RepeatButton Command="{x:Static ScrollBar.PageRightCommand}" Opacity="0" Focusable="False" />
                    </Track.IncreaseRepeatButton>
                </Track>
            </Grid>
        </ControlTemplate>
        <Style TargetType="{x:Type ScrollBar}">
            <Setter Property="Width" Value="10" />
            <Setter Property="Background" Value="Transparent" />
            <Setter Property="Template" Value="{StaticResource VerticalScrollBarTemplate}" />
            <Style.Triggers>
                <Trigger Property="Orientation" Value="Horizontal">
                    <Setter Property="Width" Value="Auto" />
                    <Setter Property="Height" Value="10" />
                    <Setter Property="Template" Value="{StaticResource HorizontalScrollBarTemplate}" />
                </Trigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>
    <Border Background="{StaticResource PageBackgroundBrush}" TextElement.Foreground="{StaticResource InkBrush}">
        <Grid Margin="18,14,18,14">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto" />
                <RowDefinition Height="*" />
                <RowDefinition Height="Auto" />
            </Grid.RowDefinitions>

            <Grid Grid.Row="0" Margin="0,0,0,10">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto" />
                    <ColumnDefinition Width="*" />
                </Grid.ColumnDefinitions>
                <Border Width="40" Height="40" CornerRadius="11" Background="{StaticResource AccentBrush}" VerticalAlignment="Center">
                    <TextBlock Text="FQ" Foreground="#FFFFFF" FontWeight="Bold" FontSize="15" HorizontalAlignment="Center" VerticalAlignment="Center" />
                </Border>
                <StackPanel Grid.Column="1" Margin="12,0,0,0" VerticalAlignment="Center">
                    <TextBlock Text="联想 Legion 风扇静音控制" FontSize="19" FontWeight="SemiBold" Foreground="{StaticResource InkBrush}" TextTrimming="CharacterEllipsis" />
                    <TextBlock x:Name="ModelText" Margin="0,2,0,0" Foreground="{StaticResource MutedBrush}" FontSize="11.5" TextTrimming="CharacterEllipsis" />
                </StackPanel>
            </Grid>

            <TabControl x:Name="MainTabs" Grid.Row="1">
                <TabItem x:Name="CpuTab" Header="风扇与 CPU">
                    <ScrollViewer x:Name="CpuPageScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" CanContentScroll="False">
                        <StackPanel Margin="2,2,8,0">
                            <Grid Margin="0,0,0,14">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*" />
                                    <ColumnDefinition Width="Auto" />
                                </Grid.ColumnDefinitions>
                                <StackPanel>
                                    <TextBlock Text="散热与性能" Style="{StaticResource PageTitle}" />
                                    <TextBlock Text="查看温度与风扇，切换联想散热档，并按具体 MHz 限制 CPU 最大频率。" Style="{StaticResource PageDescription}" />
                                </StackPanel>
                                <Button x:Name="RefreshButton" Grid.Column="1" Content="刷新状态" VerticalAlignment="Center" Margin="12,0,0,0" ToolTip="异步读取散热控制器、电源策略、最大频率和降压状态" />
                            </Grid>

                            <UniformGrid Columns="4">
                                <Border Style="{StaticResource MetricCard}" Margin="0,0,10,0">
                                    <StackPanel>
                                        <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                                            <Border Width="8" Height="8" CornerRadius="4" Background="#E09A3E" Margin="0,0,8,0" VerticalAlignment="Center" />
                                            <TextBlock Text="CPU 温度" Style="{StaticResource MetricLabel}" />
                                        </StackPanel>
                                        <TextBlock x:Name="CpuTempValue" Text="--" Style="{StaticResource MetricValue}" />
                                        <TextBlock Text="联想固件读数" Style="{StaticResource MetricHint}" />
                                    </StackPanel>
                                </Border>
                                <Border Style="{StaticResource MetricCard}" Margin="0,0,10,0">
                                    <StackPanel>
                                        <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                                            <Border Width="8" Height="8" CornerRadius="4" Background="#D97706" Margin="0,0,8,0" VerticalAlignment="Center" />
                                            <TextBlock Text="GPU 温度" Style="{StaticResource MetricLabel}" />
                                        </StackPanel>
                                        <TextBlock x:Name="GpuTempValue" Text="--" Style="{StaticResource MetricValue}" />
                                        <TextBlock Text="固件或 NVIDIA 读数" Style="{StaticResource MetricHint}" />
                                    </StackPanel>
                                </Border>
                                <Border Style="{StaticResource MetricCard}" Margin="0,0,10,0">
                                    <StackPanel>
                                        <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                                            <Border Width="8" Height="8" CornerRadius="4" Background="#0F766E" Margin="0,0,8,0" VerticalAlignment="Center" />
                                            <TextBlock Text="CPU 风扇" Style="{StaticResource MetricLabel}" />
                                        </StackPanel>
                                        <TextBlock x:Name="Fan1Value" Text="--" Style="{StaticResource MetricValue}" />
                                        <TextBlock Text="当前转速" Style="{StaticResource MetricHint}" />
                                    </StackPanel>
                                </Border>
                                <Border Style="{StaticResource MetricCard}">
                                    <StackPanel>
                                        <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                                            <Border Width="8" Height="8" CornerRadius="4" Background="#0E7490" Margin="0,0,8,0" VerticalAlignment="Center" />
                                            <TextBlock Text="GPU 风扇" Style="{StaticResource MetricLabel}" />
                                        </StackPanel>
                                        <TextBlock x:Name="Fan2Value" Text="--" Style="{StaticResource MetricValue}" />
                                        <TextBlock Text="当前转速" Style="{StaticResource MetricHint}" />
                                    </StackPanel>
                                </Border>
                            </UniformGrid>

                            <Grid Margin="0,12,0,0">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="1*" />
                                    <ColumnDefinition Width="12" />
                                    <ColumnDefinition Width="1.05*" />
                                </Grid.ColumnDefinitions>
                                <Border Grid.Column="0" Style="{StaticResource Card}">
                                    <StackPanel>
                                        <TextBlock Text="散热模式" Style="{StaticResource CardTitle}" />
                                        <TextBlock Text="由联想固件执行；静音档在高温时仍会自动提高转速。" Style="{StaticResource CardHint}" Margin="0,4,0,0" />
                                        <Border Background="{StaticResource SurfaceAltBrush}" CornerRadius="8" Padding="4" Margin="0,12,0,0">
                                            <UniformGrid Columns="3">
                                                <Button x:Name="QuietButton" Content="静音" Style="{StaticResource ModeButton}" ToolTip="切换到联想官方静音散热档" />
                                                <Button x:Name="BalancedButton" Content="均衡" Style="{StaticResource ModeButton}" ToolTip="切换到联想官方均衡散热档" />
                                                <Button x:Name="PerformanceButton" Content="性能" Style="{StaticResource ModeButton}" ToolTip="切换到联想官方性能散热档" />
                                            </UniformGrid>
                                        </Border>
                                        <CheckBox x:Name="TurboLimitCheck" IsChecked="True" Content="静音时限制 CPU 睿频（最高状态 99%）" Margin="0,14,0,0" />
                                        <TextBlock Text="最低处理器状态设为 5%，并使用被动散热策略。" Style="{StaticResource CardHint}" Margin="22,5,0,0" />
                                        <Button x:Name="RestorePowerButton" Content="还原电源设置" HorizontalAlignment="Left" Margin="0,12,0,0" ToolTip="还原此工具首次修改前保存的电源设置" />
                                    </StackPanel>
                                </Border>
                                <Border Grid.Column="2" Style="{StaticResource Card}">
                                    <StackPanel>
                                        <TextBlock Text="CPU 最大频率" Style="{StaticResource CardTitle}" />
                                        <TextBlock x:Name="CpuFrequencyLimitValue" Style="{StaticResource CardHint}" Margin="0,4,0,0" />
                                        <Grid Margin="0,12,0,0">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*" />
                                                <ColumnDefinition Width="Auto" />
                                            </Grid.ColumnDefinitions>
                                            <TextBox x:Name="CpuFrequencyInput" ToolTip="输入 2200、2200 MHz 或 2.2 GHz" FontSize="14" />
                                            <TextBlock Grid.Column="1" Text="MHz" Margin="10,0,0,0" VerticalAlignment="Center" Foreground="{StaticResource MutedBrush}" />
                                        </Grid>
                                        <TextBlock Text="输入 2200 或 2.2 GHz" Style="{StaticResource MetricHint}" />
                                        <TextBlock Text="供电范围" Style="{StaticResource FieldLabel}" Margin="0,12,0,5" />
                                        <ComboBox x:Name="CpuFrequencyPowerCombo" SelectedIndex="0">
                                            <ComboBoxItem Content="交流电和电池" Tag="Both" />
                                            <ComboBoxItem Content="仅交流电" Tag="AC" />
                                            <ComboBoxItem Content="仅电池" Tag="DC" />
                                        </ComboBox>
                                        <WrapPanel Margin="0,12,0,0">
                                            <Button x:Name="ApplyFrequencyButton" Content="应用频率" Style="{StaticResource AccentButton}" ToolTip="按具体 MHz 写入处理器最大频率" />
                                            <Button x:Name="ClearFrequencyButton" Content="取消限制" ToolTip="将处理器最大频率设为 0，不限制" />
                                            <Button x:Name="RestoreFrequencyButton" Content="还原频率" ToolTip="还原首次修改前保存的 CPU 最大频率" />
                                            <Button x:Name="UnhideFrequencyButton" Content="显示选项" ToolTip="在 Windows 高级电源选项中显示处理器最大频率" />
                                        </WrapPanel>
                                        <TextBlock Text="写入 Windows PROCFREQMAX，单位为 MHz。" Style="{StaticResource MetricHint}" />
                                    </StackPanel>
                                </Border>
                            </Grid>

                            <Border Style="{StaticResource Card}" Margin="0,12,0,0" Padding="16,14">
                                <StackPanel>
                                    <WrapPanel>
                                        <Border Background="{StaticResource SurfaceAltBrush}" CornerRadius="20" Padding="12,6" Margin="0,0,8,0">
                                            <StackPanel Orientation="Horizontal">
                                                <TextBlock Text="联想散热档" Style="{StaticResource FieldLabel}" />
                                                <TextBlock x:Name="ModeValue" Margin="8,0,0,0" FontWeight="SemiBold" Foreground="{StaticResource InkBrush}" />
                                            </StackPanel>
                                        </Border>
                                        <Border Background="{StaticResource SurfaceAltBrush}" CornerRadius="20" Padding="12,6" Margin="0,0,8,0">
                                            <StackPanel Orientation="Horizontal">
                                                <TextBlock Text="风扇控制器" Style="{StaticResource FieldLabel}" />
                                                <TextBlock x:Name="FanCoolingValue" Margin="8,0,0,0" FontWeight="SemiBold" Foreground="{StaticResource InkBrush}" />
                                            </StackPanel>
                                        </Border>
                                    </WrapPanel>
                                    <Grid Margin="0,10,0,0">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="Auto" />
                                            <ColumnDefinition Width="*" />
                                        </Grid.ColumnDefinitions>
                                        <TextBlock Text="当前电源策略" Style="{StaticResource FieldLabel}" Margin="0,1,12,0" />
                                        <TextBlock x:Name="PowerPolicyValue" Grid.Column="1" TextWrapping="Wrap" Foreground="{StaticResource InkBrush}" FontSize="12.5" LineHeight="19" />
                                    </Grid>
                                </StackPanel>
                            </Border>


                            <Grid Margin="0,12,0,0">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="1*" />
                                    <ColumnDefinition Width="12" />
                                    <ColumnDefinition Width="1.05*" />
                                </Grid.ColumnDefinitions>
                                <Expander x:Name="DetailedDiagnosisExpander" Grid.Column="0" Header="详细诊断" IsExpanded="False">
                                    <Border Style="{StaticResource InsetCard}" Margin="0,4,0,0">
                                        <TextBlock x:Name="DiagnosisValue" TextWrapping="Wrap" Foreground="{StaticResource MutedBrush}" FontSize="12.5" LineHeight="20" />
                                    </Border>
                                </Expander>
                                <Expander x:Name="CpuUndervoltExpander" Grid.Column="2" Header="高级设置：CPU 降压" IsExpanded="False">
                                    <Border Style="{StaticResource InsetCard}" Margin="0,4,0,0">
                                        <StackPanel>
                                            <TextBlock x:Name="CpuUndervoltStatusValue" TextWrapping="Wrap" Foreground="{StaticResource MutedBrush}" FontSize="12.5" LineHeight="20" />
                                            <TextBlock Text="降压档位" Style="{StaticResource FieldLabel}" Margin="0,10,0,5" />
                                            <ComboBox x:Name="CpuUndervoltLevelCombo" SelectedIndex="1" ToolTip="每档间隔 20 mV；从 -20 mV 开始逐步测试稳定性" />
                                            <WrapPanel Margin="0,10,0,0">
                                                <Button x:Name="ApplyUndervoltButton" Content="应用降压" Style="{StaticResource AccentButton}" ToolTip="通过 Intel XTU 应用所选 CPU 核心电压偏移" />
                                                <Button x:Name="ClearUndervoltButton" Content="还原降压" ToolTip="通过 Intel XTU 将 CPU 核心电压偏移恢复为 0 mV" />
                                                <Button x:Name="SelectXtuButton" Content="选择 XTU" ToolTip="选择已安装的 Intel XTU XTUCli.exe" />
                                            </WrapPanel>
                                            <TextBlock Text="仅支持 Intel XTU。建议从 -20 mV 开始逐步测试；降压可能导致蓝屏、死机或数据丢失。" Style="{StaticResource CardHint}" Margin="0,10,0,0" />
                                        </StackPanel>
                                    </Border>
                                </Expander>
                            </Grid>
                        </StackPanel>
                    </ScrollViewer>
                </TabItem>

                <TabItem x:Name="ProcessPriorityTab" Header="程序优先级">
                    <Grid Margin="2,2,8,0">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto" />
                            <RowDefinition Height="*" />
                            <RowDefinition Height="Auto" />
                        </Grid.RowDefinitions>

                        <Border Grid.Row="0" Style="{StaticResource Card}" Padding="10,6" Margin="0,0,0,8">
                            <StackPanel>
                                <WrapPanel>
                                    <TextBlock Text="目标优先级" Style="{StaticResource FieldLabel}" Margin="0,0,8,0" />
                                    <ComboBox x:Name="ProcessPriorityChoiceCombo" Width="132" SelectedIndex="2" Margin="0,0,8,0">
                                        <ComboBoxItem Content="空闲" Tag="Idle" />
                                        <ComboBoxItem Content="低于正常" Tag="BelowNormal" />
                                        <ComboBoxItem Content="正常" Tag="Normal" />
                                        <ComboBoxItem Content="高于正常" Tag="AboveNormal" />
                                        <ComboBoxItem Content="高" Tag="High" />
                                    </ComboBox>
                                    <Button x:Name="ProcessPriorityApplyButton" Content="调整选定程序" IsEnabled="False" Style="{StaticResource AccentButton}" ToolTip="仅调整表格中选中的单个程序" />
                                    <Button x:Name="ProcessPriorityRestoreButton" Content="恢复原等级" IsEnabled="False" ToolTip="仅恢复选定程序；应用前会核对 PID、启动时间和程序路径" />
                                    <Button x:Name="ProcessPriorityRefreshButton" Content="刷新列表" ToolTip="异步读取当前登录会话内的桌面窗口和后台程序" />
                                </WrapPanel>
                                <TextBlock Text="只调整当前会话中的单个程序；系统关键进程、其他会话和本工具不可调整。" Style="{StaticResource CardHint}" Margin="0,5,0,0" FontSize="11.5" />
                            </StackPanel>
                        </Border>
                        <Border Grid.Row="1" Style="{StaticResource Card}" Padding="6">
                            <DataGrid x:Name="ProcessPriorityGrid" AutoGenerateColumns="False" IsReadOnly="True"
                                      SelectionMode="Single" SelectionUnit="FullRow" HeadersVisibility="Column" GridLinesVisibility="Horizontal"
                                      ScrollViewer.VerticalScrollBarVisibility="Auto" ScrollViewer.HorizontalScrollBarVisibility="Disabled">
                                <DataGrid.Columns>
                                    <DataGridTextColumn Header="类别" Binding="{Binding UiCategory}" Width="78" />
                                    <DataGridTextColumn Header="程序" Binding="{Binding ProcessName}" Width="180">
                                        <DataGridTextColumn.CellStyle>
                                            <Style TargetType="{x:Type DataGridCell}">
                                                <Setter Property="ToolTip" Value="{Binding ExecutablePath}" />
                                            </Style>
                                        </DataGridTextColumn.CellStyle>
                                        <DataGridTextColumn.ElementStyle>
                                            <Style TargetType="{x:Type TextBlock}">
                                                <Setter Property="TextTrimming" Value="CharacterEllipsis" />
                                                <Setter Property="ToolTip" Value="{Binding ExecutablePath}" />
                                            </Style>
                                        </DataGridTextColumn.ElementStyle>
                                    </DataGridTextColumn>
                                    <DataGridTextColumn Header="PID" Binding="{Binding ProcessId}" Width="56" />
                                    <DataGridTextColumn Header="当前等级" Binding="{Binding UiCurrentPriority}" Width="82" />
                                    <DataGridTextColumn Header="原等级" Binding="{Binding UiOriginalPriority}" Width="72" />
                                    <DataGridTextColumn Header="状态 / 原因" Binding="{Binding Reason}" Width="170">
                                        <DataGridTextColumn.CellStyle>
                                            <Style TargetType="{x:Type DataGridCell}">
                                                <Setter Property="ToolTip" Value="{Binding Reason}" />
                                            </Style>
                                        </DataGridTextColumn.CellStyle>
                                        <DataGridTextColumn.ElementStyle>
                                            <Style TargetType="{x:Type TextBlock}">
                                                <Setter Property="TextTrimming" Value="CharacterEllipsis" />
                                                <Setter Property="ToolTip" Value="{Binding Reason}" />
                                            </Style>
                                        </DataGridTextColumn.ElementStyle>
                                    </DataGridTextColumn>
                                </DataGrid.Columns>
                            </DataGrid>
                        </Border>
                        <Border Grid.Row="2" Style="{StaticResource InsetCard}" Margin="0,8,0,0" Padding="8,6" MaxHeight="68">
                            <StackPanel>

                                <ScrollViewer MaxHeight="44" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                                    <TextBlock x:Name="ProcessPriorityDetailValue" TextWrapping="Wrap" Foreground="{StaticResource InkBrush}" FontSize="12.5" LineHeight="19"
                                               Text="选择一行查看完整程序路径、窗口标题和可调原因。" />
                                </ScrollViewer>
                            </StackPanel>
                        </Border>
                    </Grid>
                </TabItem>

                <TabItem x:Name="GraphicsTab" Header="显卡与显示">
                    <Grid Margin="2,2,8,0">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto" />
                            <RowDefinition Height="*" />
                        </Grid.RowDefinitions>
                        <Grid Margin="0,0,0,10">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*" />
                                <ColumnDefinition Width="Auto" />
                            </Grid.ColumnDefinitions>
                            <StackPanel>
                                <TextBlock Text="显卡与显示" Style="{StaticResource PageTitle}" />
                                <TextBlock Text="只读观察图形适配器与显示连接；不写入 BIOS，也不伪造独显直连开关。" Style="{StaticResource PageDescription}" />
                            </StackPanel>
                            <Button x:Name="GraphicsRefreshButton" Grid.Column="1" Content="刷新显卡状态" VerticalAlignment="Center" Margin="12,0,0,0" ToolTip="只读刷新图形适配器与当前显示连接信息" />
                        </Grid>
                        <ScrollViewer x:Name="GraphicsPageScroll" Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                            <StackPanel Margin="0,0,8,0">
                                <Border Style="{StaticResource Card}">
                                    <StackPanel>
                                        <TextBlock Text="适配器与当前显示" Style="{StaticResource CardTitle}" />
                                        <TextBlock Text="仅列出 PCI 显示适配器；虚拟显示驱动不计入。" Style="{StaticResource CardHint}" Margin="0,4,0,0" />
                                        <TextBlock x:Name="GpuAdapterValue" Margin="0,10,0,0" Foreground="{StaticResource InkBrush}" TextWrapping="Wrap" FontSize="12.5" LineHeight="20" />
                                        <TextBlock x:Name="GpuDisplayObservationValue" Margin="0,7,0,0" Foreground="{StaticResource MutedBrush}" TextWrapping="Wrap" FontSize="12.5" LineHeight="20" />
                                    </StackPanel>
                                </Border>
                                <Border Style="{StaticResource Card}" Margin="0,12,0,0">
                                    <StackPanel>
                                        <TextBlock Text="打开官方或 Windows 设置入口" Style="{StaticResource CardTitle}" />
                                        <TextBlock Text="按钮仅在检测到已注册入口时可用。" Style="{StaticResource CardHint}" Margin="0,4,0,0" />
                                        <WrapPanel Margin="0,10,0,0">
                                            <Button x:Name="NvidiaControlPanelButton" Content="NVIDIA 控制面板" IsEnabled="False" ToolTip="检查受支持的显示模式；不代表本机一定有 MUX" />
                                            <Button x:Name="LenovoVantageButton" Content="Lenovo Vantage" IsEnabled="False" />
                                            <Button x:Name="WindowsGraphicsSettingsButton" Content="应用 GPU 偏好（非独显直连）" />
                                        </WrapPanel>
                                    </StackPanel>
                                </Border>
                                <Border Style="{StaticResource Card}" Margin="0,12,0,0">
                                    <StackPanel>
                                        <TextBlock Text="独显直连 / MUX" Style="{StaticResource CardTitle}" />
                                        <Border Background="{StaticResource WarningSurfaceBrush}" BorderBrush="{StaticResource WarningBorderBrush}" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,10,0,0">
                                            <TextBlock x:Name="GpuMuxStatusValue" Foreground="{StaticResource WarningInkBrush}" TextWrapping="Wrap" FontSize="12.5" LineHeight="20"
                                                       Text="支持状态未证实；本程序不会禁用核显、写入 BIOS 或重启。" />
                                        </Border>
                                        <TextBlock x:Name="GpuAppStatusValue" Margin="0,10,0,0" Foreground="{StaticResource MutedBrush}" TextWrapping="Wrap" FontSize="12.5" LineHeight="20" />
                                    </StackPanel>
                                </Border>
                                <Expander x:Name="GraphicsDetailsExpander" Header="详细说明与资料" IsExpanded="False" Margin="0,12,0,0">
                                    <Border Style="{StaticResource InsetCard}" Margin="0,4,0,0">
                                        <TextBlock x:Name="GraphicsDetailsText" TextWrapping="Wrap" Foreground="{StaticResource MutedBrush}" FontSize="12.5" LineHeight="20"
                                                   Text="Windows 高性能 GPU 偏好只选择应用使用哪块 GPU，不改变内屏物理显示连线。系统报告的活动适配器和显示输出属于状态观测，不能证明硬件 MUX 支持。若设备没有官方软件或 BIOS 切换入口，本程序不会伪造开关。机型资料与检查说明见项目 README。" />
                                    </Border>
                                </Expander>
                            </StackPanel>
                        </ScrollViewer>
                    </Grid>
                </TabItem>
            </TabControl>

            <Border x:Name="StatusBorder" Grid.Row="2" MaxHeight="72" Background="#F8FAFC" BorderBrush="{StaticResource CardBorderBrush}" BorderThickness="1" CornerRadius="10" Padding="10,6" Margin="0,10,0,0">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto" />
                        <ColumnDefinition Width="*" />
                    </Grid.ColumnDefinitions>
                    <Ellipse x:Name="StatusDot" Width="9" Height="9" Fill="{StaticResource SuccessBrush}" Margin="0,3,10,0" VerticalAlignment="Top" />
                    <ScrollViewer Grid.Column="1" MaxHeight="50" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                        <TextBlock x:Name="StatusText" Foreground="{StaticResource InkBrush}" TextWrapping="Wrap" FontSize="12.5" LineHeight="19" />
                    </ScrollViewer>
                </Grid>
            </Border>
        </Grid>
    </Border>
</Window>
'@

if ($ValidateOnly) {
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $null = [System.Windows.Markup.XamlReader]::Load($reader)
    Write-Output 'FanQuiet UI validation passed.'
    exit 0
}

function Test-IsAdministrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-Elevated {
    $scriptPath = $PSCommandPath
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $scriptPath + '"'

    try {
        $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath $windowsPowerShell -Verb RunAs -ArgumentList $arguments -WorkingDirectory (Split-Path -Parent $scriptPath)
    }
    catch {
        [System.Windows.MessageBox]::Show(
            '该工具需要管理员权限才能访问联想散热控制器。请在 UAC 提示中选择“是”。',
            '联想风扇静音控制',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        ) | Out-Null
    }
}

if (-not (Test-IsAdministrator) -and -not $WorkerAction -and -not $AsyncLifecycleTest -and -not $LayoutPreview) {
    Restart-Elevated
    exit 0
}

if (-not $WorkerAction -and -not $AsyncLifecycleTest) {
    New-Item -ItemType Directory -Force -Path $script:StateDirectory | Out-Null
}

function Invoke-PowerCfg {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )

    $output = @(& $script:PowerCfg @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg 执行失败：$($output -join ' ')"
    }

    return $output
}

function Get-ActivePowerScheme {
    $output = (Invoke-PowerCfg /getactivescheme) -join [Environment]::NewLine
    $match = [regex]::Match($output, '[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}')
    if (-not $match.Success) {
        throw '无法读取当前电源方案。'
    }

    return $match.Value
}

function Get-PowerAcValue {
    param(
        [Parameter(Mandatory)]
        [string]$Scheme,
        [Parameter(Mandatory)]
        [string]$Setting
    )

    $output = (Invoke-PowerCfg /qh $Scheme $script:ProcessorSubgroup $Setting) -join [Environment]::NewLine
    $matches = [regex]::Matches($output, '0x([0-9a-fA-F]+)')
    if ($matches.Count -lt 2) {
        throw "无法读取电源设置 $Setting。"
    }

    return [Convert]::ToInt32($matches[$matches.Count - 2].Groups[1].Value, 16)
}

function Get-PowerPolicyStatus {
    $scheme = Get-ActivePowerScheme

    return [pscustomobject]@{
        SchemeGuid = $scheme
        MinimumAc = Get-PowerAcValue -Scheme $scheme -Setting $script:ProcessorMinimum
        MaximumAc = Get-PowerAcValue -Scheme $scheme -Setting $script:ProcessorMaximum
        CoolingAc = Get-PowerAcValue -Scheme $scheme -Setting $script:SystemCooling
    }
}

function Get-CoolingPolicyName {
    param($Value)

    switch ($Value) {
        0 { return '被动' }
        1 { return '主动' }
        255 { return '系统默认' }
        default { return "值 $Value" }
    }
}

function Get-QuietState {
    if (-not (Test-Path $script:StatePath)) {
        return [pscustomobject]@{
            Version = 1
            Profiles = @()
        }
    }

    try {
        return Get-Content -Raw -Path $script:StatePath | ConvertFrom-Json
    }
    catch {
        throw '已保存的电源设置备份无法读取，未对电源策略进行修改。'
    }
}

function Save-QuietState {
    param(
        [Parameter(Mandatory)]
        $State
    )

    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $script:StatePath -Encoding UTF8
}

function Get-ProfileBackup {
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

function Ensure-PowerBackup {
    param(
        [Parameter(Mandatory)]
        $Policy
    )

    $state = Get-QuietState
    $existing = Get-ProfileBackup -State $state -SchemeGuid $Policy.SchemeGuid
    if ($null -ne $existing) {
        return
    }

    $backup = [pscustomobject]@{
        SchemeGuid = $Policy.SchemeGuid
        MinimumAc = $Policy.MinimumAc
        MaximumAc = $Policy.MaximumAc
        CoolingAc = $Policy.CoolingAc
        SavedAt = (Get-Date).ToString('o')
    }

    $state.Profiles = @($state.Profiles) + $backup
    Save-QuietState -State $state
}

function Apply-QuietPowerPolicy {
    param(
        [bool]$LimitTurbo
    )

    $policy = Get-PowerPolicyStatus
    Ensure-PowerBackup -Policy $policy

    Invoke-PowerCfg /setacvalueindex $policy.SchemeGuid $script:ProcessorSubgroup $script:ProcessorMinimum 5 | Out-Null
    Invoke-PowerCfg /setacvalueindex $policy.SchemeGuid $script:ProcessorSubgroup $script:SystemCooling 0 | Out-Null
    if ($LimitTurbo) {
        Invoke-PowerCfg /setacvalueindex $policy.SchemeGuid $script:ProcessorSubgroup $script:ProcessorMaximum 99 | Out-Null
    }
    Invoke-PowerCfg /setactive $policy.SchemeGuid | Out-Null

    if ($LimitTurbo) {
        return '已降低交流电下的待机频率，并限制睿频。'
    }

    return '已降低交流电下的待机频率。'
}

function Restore-QuietPowerPolicy {
    $state = Get-QuietState
    $activeScheme = Get-ActivePowerScheme
    $backup = Get-ProfileBackup -State $state -SchemeGuid $activeScheme
    if ($null -eq $backup) {
        throw '当前电源方案没有可还原的备份。'
    }

    Invoke-PowerCfg /setacvalueindex $backup.SchemeGuid $script:ProcessorSubgroup $script:ProcessorMinimum $backup.MinimumAc | Out-Null
    Invoke-PowerCfg /setacvalueindex $backup.SchemeGuid $script:ProcessorSubgroup $script:ProcessorMaximum $backup.MaximumAc | Out-Null
    Invoke-PowerCfg /setacvalueindex $backup.SchemeGuid $script:ProcessorSubgroup $script:SystemCooling $backup.CoolingAc | Out-Null
    Invoke-PowerCfg /setactive $backup.SchemeGuid | Out-Null

    return '已还原当前电源方案在首次静音设置前的处理器策略。'
}

function Get-EnergyFanMode {
    Initialize-EnergyFanDriver
    [uint32]$mode = 0
    [int]$errorCode = 0
    if (-not [LenovoEnergyFanDriver]::TryGetMode([ref]$mode, [ref]$errorCode)) {
        throw "无法读取 EnergyDrv 风扇状态（错误 $errorCode）。"
    }

    return [int]$mode
}

function Set-EnergyFanMode {
    param(
        [Parameter(Mandatory)]
        [ValidateSet(0, 1)]
        [int]$Mode
    )

    Initialize-EnergyFanDriver
    [int]$errorCode = 0
    if (-not [LenovoEnergyFanDriver]::TrySetMode([uint32]$Mode, [ref]$errorCode)) {
        throw "无法写入 EnergyDrv 风扇状态（错误 $errorCode）。"
    }
}

function Get-EnergyFanModeName {
    param($Mode)

    switch ($Mode) {
        0 { return '自动' }
        1 { return '强制高速' }
        $null { return '不可用' }
        default { return "未知 ($Mode)" }
    }
}

function Test-TemperatureValue {
    param($Value)

    if ($null -eq $Value) {
        return $false
    }

    [int]$temperature = 0
    if (-not [int]::TryParse([string]$Value, [ref]$temperature)) {
        return $false
    }

    return $temperature -ge 1 -and $temperature -le 120
}

function Get-NvidiaGpuTelemetry {
    $nvidiaSmi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if ($null -eq $nvidiaSmi) {
        return $null
    }

    try {
        $output = @(& $nvidiaSmi.Source '--query-gpu=temperature.gpu,utilization.gpu,pstate,clocks.current.graphics' '--format=csv,noheader,nounits' 2>$null)
        if ($LASTEXITCODE -ne 0 -or $output.Count -eq 0) {
            return $null
        }

        $values = @($output[0].Split(',') | ForEach-Object { $_.Trim() })
        if ($values.Count -lt 4) {
            return $null
        }

        $temperature = 0
        $utilization = 0
        $clock = 0
        if (-not [int]::TryParse($values[0], [ref]$temperature) -or -not [int]::TryParse($values[1], [ref]$utilization) -or -not [int]::TryParse($values[3], [ref]$clock)) {
            return $null
        }

        return [pscustomobject]@{
            Temperature = $temperature
            Utilization = $utilization
            PerformanceState = $values[2]
            GraphicsClock = $clock
        }
    }
    catch {
        return $null
    }
}

function Get-LegionControllerInstance {
    if ($null -eq $script:LegionControllerInstance) {
        $script:LegionControllerInstance = Get-CimInstance -Namespace root\WMI -ClassName LENOVO_GAMEZONE_DATA | Select-Object -First 1
    }

    return $script:LegionControllerInstance
}

function Invoke-LegionMethod {
    param(
        [Parameter(Mandatory)]
        [string]$Method,
        [Nullable[int]]$Data
    )

    $instance = Get-LegionControllerInstance
    if ($null -eq $instance) {
        throw '未找到联想散热控制器。'
    }

    $arguments = @{}
    if ($PSBoundParameters.ContainsKey('Data') -and $null -ne $Data) {
        $arguments.Data = [uint32]$Data
    }

    $result = Invoke-CimMethod -InputObject $instance -MethodName $Method -Arguments $arguments
    $dataProperty = $result.PSObject.Properties['Data']
    if ($null -ne $dataProperty) {
        return [int]$dataProperty.Value
    }

    $returnProperty = $result.PSObject.Properties['ReturnValue']
    if ($null -ne $returnProperty) {
        return [int]$returnProperty.Value
    }

    return 0
}

function Get-LegionStatus {
    $status = [ordered]@{
        Available = $false
        Error = $null
        EnergyAvailable = $false
        EnergyFanMode = $null
        SmartFanSupported = $false
        Mode = $null
        CpuTemperature = $null
        CpuTemperatureSource = $null
        GpuTemperature = $null
        GpuTemperatureSource = $null
        FanCount = $null
        Fan1Speed = $null
        Fan2Speed = $null
        FanCoolingSupported = $false
        FanCoolingStatus = $null
    }

    try {
        $status['EnergyFanMode'] = Get-EnergyFanMode
        $status['EnergyAvailable'] = $true
    }
    catch {
        $status['EnergyAvailable'] = $false
    }

    try {
        $status['SmartFanSupported'] = (Invoke-LegionMethod -Method 'IsSupportSmartFan') -eq 1
        $status['Available'] = $true
    }
    catch {
        $status['Error'] = $_.Exception.Message
    }

    if ($status['Available']) {
        $readMethods = [ordered]@{
            Mode = 'GetSmartFanMode'
            CpuTemperature = 'GetCPUTemp'
            GpuTemperature = 'GetGPUTemp'
            FanCount = 'GetFanCount'
            Fan1Speed = 'GetFan1Speed'
            Fan2Speed = 'GetFan2Speed'
            FanCoolingStatus = 'GetFanCoolingStatus'
        }

        foreach ($entry in $readMethods.GetEnumerator()) {
            try {
                $status[$entry.Key] = Invoke-LegionMethod -Method $entry.Value
            }
            catch {
                $status[$entry.Key] = $null
            }
        }

        try {
            $status['FanCoolingSupported'] = (Invoke-LegionMethod -Method 'IsSupportFanCooling') -eq 1
        }
        catch {
            $status['FanCoolingSupported'] = $false
        }
    }

    if (Test-TemperatureValue -Value $status['CpuTemperature']) {
        $status['CpuTemperatureSource'] = '联想固件'
    }
    else {
        $status['CpuTemperatureSource'] = '固件未公开'
    }

    if (Test-TemperatureValue -Value $status['GpuTemperature']) {
        $status['GpuTemperatureSource'] = '联想固件'
    }
    else {
        $nvidiaTelemetry = Get-NvidiaGpuTelemetry
        if ($null -ne $nvidiaTelemetry -and (Test-TemperatureValue -Value $nvidiaTelemetry.Temperature)) {
            $status['GpuTemperature'] = $nvidiaTelemetry.Temperature
            $status['GpuTemperatureSource'] = 'NVIDIA'
        }
        else {
            $status['GpuTemperatureSource'] = '固件未公开'
        }
    }

    return [pscustomobject]$status
}

function Get-LegionModeName {
    param($Mode)

    switch ($Mode) {
        1 { return '静音' }
        2 { return '均衡' }
        3 { return '性能' }
        254 { return '自定义' }
        255 { return '自定义' }
        $null { return '不可用' }
        default { return "未知 ($Mode)" }
    }
}

function Format-Temperature {
    param(
        $Value,
        [string]$Source
    )

    if (-not (Test-TemperatureValue -Value $Value)) {
        if ($Source -eq '固件未公开') {
            return '固件未公开'
        }

        return '不可用'
    }

    $text = "$Value C"
    if ($Source -eq 'NVIDIA') {
        return "$text [NVIDIA]"
    }

    return $text
}

function Get-TemperatureTooltip {
    param([string]$Source)

    switch ($Source) {
        'NVIDIA' { return '由 NVIDIA 显卡驱动读取。' }
        '联想固件' { return '由联想固件接口读取。' }
        '固件未公开' { return '这台机型的固件没有向 Windows 公开该温度传感器。' }
        default { return '没有可用的温度数据来源。' }
    }
}

function Format-FanSpeed {
    param($Value)

    if ($null -eq $Value -or $Value -lt 0 -or $Value -gt 20000) {
        return '不可用'
    }

    return "$Value RPM"
}

function Set-LegionMode {
    param(
        [Parameter(Mandatory)]
        [ValidateSet(1, 2, 3)]
        [int]$Mode
    )

    if ((Invoke-LegionMethod -Method 'IsSupportSmartFan') -ne 1) {
        throw '这台电脑未报告联想智能散热档支持。'
    }

    Invoke-LegionMethod -Method 'SetSmartFanMode' -Data $Mode | Out-Null
    Start-Sleep -Milliseconds 800

    $actualMode = Invoke-LegionMethod -Method 'GetSmartFanMode'
    if ($actualMode -ne $Mode) {
        throw "联想散热档未切换，控制器回读为 $(Get-LegionModeName $actualMode)。"
    }

    return $actualMode
}

function Set-QuietMode {
    param(
        [bool]$LimitTurbo
    )

    $before = Get-LegionStatus
    $actions = @()

    if ($before.EnergyAvailable -and $before.EnergyFanMode -eq 1) {
        Set-EnergyFanMode -Mode 0
        $actions += '已退出风扇强制高速'
    }

    if ($before.Available -and $before.SmartFanSupported) {
        $null = Set-LegionMode -Mode 1
        $actions += '已确认切换为联想官方静音散热档'

        if ($before.FanCoolingSupported -and $before.FanCoolingStatus -eq 1) {
            Invoke-LegionMethod -Method 'SetFanCooling' -Data 0 | Out-Null
            $actions += '已关闭强冷'
        }
    }
    else {
        $actions += '未能读取联想散热档，已应用 Windows 静音策略'
    }

    $actions += Apply-QuietPowerPolicy -LimitTurbo $LimitTurbo

    $temperatures = @($before.CpuTemperature, $before.GpuTemperature | Where-Object { $null -ne $_ -and $_ -gt 0 })
    if ($temperatures.Count -gt 0 -and (($temperatures | Measure-Object -Maximum).Maximum -ge 80)) {
        $actions += '当前温度偏高，固件会保留必要散热'
    }

    return $actions -join '；'
}

function Get-ModelDescription {
    try {
        $bios = Get-ItemProperty -Path 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -ErrorAction Stop
        $vendor = [string]$bios.SystemManufacturer
        $version = [string]$bios.SystemVersion
        $name = [string]$bios.SystemProductName
        if (-not [string]::IsNullOrWhiteSpace($version)) {
            if (-not [string]::IsNullOrWhiteSpace($vendor) -and $version.IndexOf($vendor, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                return "$vendor $version ($name)"
            }
            if (-not [string]::IsNullOrWhiteSpace($name)) { return "$version ($name)" }
            return $version
        }
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            if (-not [string]::IsNullOrWhiteSpace($vendor)) { return "$vendor $name" }
            return $name
        }
    }
    catch {
    }

    return 'Lenovo Legion'
}

function Get-Diagnosis {
    param(
        $LegionStatus,
        $PowerPolicy
    )

    $parts = @()
    if (-not $LegionStatus.Available) {
        $parts += '联想散热控制器当前不可读，静音按钮仍会降低 Windows 处理器功耗。'
    }

    if ($LegionStatus.CpuTemperatureSource -eq '固件未公开') {
        $parts += 'CPU 温度未由本机固件向 Windows 公开。'
    }

    if ($LegionStatus.GpuTemperatureSource -eq 'NVIDIA') {
        $parts += 'GPU 温度由 NVIDIA 驱动读取。'
    }

    if ($LegionStatus.EnergyAvailable -and $LegionStatus.EnergyFanMode -eq 1) {
        $parts += '风扇控制器当前处于强制高速状态。'
    }

    switch ($LegionStatus.Mode) {
        1 { $parts += '当前已回读为静音档，风扇转速仍由联想固件曲线决定。' }
        3 { $parts += '当前回读为性能档，风扇转速会明显更高。' }
    }

    if ($PowerPolicy.MinimumAc -ge 100) {
        $parts += '交流电最低处理器状态为 100%，会让 CPU 长时间维持较高频率。'
    }
    elseif ($PowerPolicy.MinimumAc -gt 20) {
        $parts += "交流电最低处理器状态为 $($PowerPolicy.MinimumAc)%，偏高。"
    }

    $temperatures = @($LegionStatus.CpuTemperature, $LegionStatus.GpuTemperature | Where-Object { $null -ne $_ -and $_ -gt 0 })
    if ($temperatures.Count -gt 0 -and (($temperatures | Measure-Object -Maximum).Maximum -ge 80)) {
        $parts += '温度已达到较高水平，风扇加速属于正常保护。'
    }

    if ($parts.Count -eq 0) {
        $parts += '未发现明显的电源策略异常。若低温下仍持续高转速，可能需要清灰或检查风扇轴承。'
    }

    return $parts -join ' '
}

function Get-CpuFrequencyPowerTarget {
    $selected = $script:UI.CpuFrequencyPowerCombo.SelectedItem
    if ($null -eq $selected) {
        return 'Both'
    }

    return [string]$selected.Tag
}

function Initialize-CpuUndervoltLevels {
    $script:UI.CpuUndervoltLevelCombo.Items.Clear()
    foreach ($offset in @(Get-CpuUndervoltOffsetLevels)) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = Format-CpuUndervoltOffset -OffsetMilliVolts ([int]$offset)
        $item.Tag = [string]$offset
        $null = $script:UI.CpuUndervoltLevelCombo.Items.Add($item)
    }

    if ($script:UI.CpuUndervoltLevelCombo.Items.Count -gt 1) {
        $script:UI.CpuUndervoltLevelCombo.SelectedIndex = 1
    }
}

function Get-CpuUndervoltLevelFromUi {
    $selected = $script:UI.CpuUndervoltLevelCombo.SelectedItem
    if ($null -eq $selected) {
        $levels = @(Get-CpuUndervoltOffsetLevels)
        if ($levels.Count -gt 1) {
            return [int]$levels[1]
        }

        return -20
    }

    return [int]$selected.Tag
}

function Update-CpuUndervoltUi {
    param(
        [Parameter(Mandatory)]
        $Status
    )

    if ($Status.Available) {
        $pathText = Split-Path -Leaf ([string]$Status.XtuCliPath)
        $serviceText = if ($Status.ServiceStatus -eq '未安装') { 'XTU 服务未检测到，应用时会由 XTU 返回结果' } else { "XTU 服务：$($Status.ServiceStatus)" }
        $script:UI.CpuUndervoltStatusValue.Text = "后端：$($Status.BackendName)（$pathText）；最近请求：$($Status.RequestedOffsetDisplay)；$serviceText。"
        $script:UI.CpuUndervoltStatusValue.Foreground = $script:MutedBrush
    }
    else {
        $script:UI.CpuUndervoltStatusValue.Text = "降压不可用：$($Status.Error)"
        $script:UI.CpuUndervoltStatusValue.Foreground = $script:ErrorInkBrush
    }

    $script:CanApplyCpuUndervolt = [bool]$Status.CanApply
    $script:UI.ApplyUndervoltButton.IsEnabled = $script:CanApplyCpuUndervolt -and -not $script:OperationInProgress
    $script:UI.ClearUndervoltButton.IsEnabled = $script:CanApplyCpuUndervolt -and -not $script:OperationInProgress
    $script:UI.SelectXtuButton.IsEnabled = -not $script:OperationInProgress
}

function Update-ModeButtons {
    param($Mode)

    $buttons = @{
        1 = $script:UI.QuietButton
        2 = $script:UI.BalancedButton
        3 = $script:UI.PerformanceButton
    }

    foreach ($entry in $buttons.GetEnumerator()) {
        $isActive = $null -ne $Mode -and [int]$Mode -eq [int]$entry.Key
        $button = $entry.Value
        $button.Background = if ($isActive) { $script:ActiveModeBrush } else { $script:ModeIdleBrush }
        $button.Foreground = if ($isActive) { [System.Windows.Media.Brushes]::White } else { $script:InkBrush }
        $button.BorderBrush = if ($isActive) { $script:ActiveModeBrush } else { $script:DefaultModeBorderBrush }
        $button.FontWeight = if ($isActive) { [System.Windows.FontWeights]::SemiBold } else { [System.Windows.FontWeights]::Normal }
    }
}

function Set-StatusMessage {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [switch]$Error
    )

    $script:UI.StatusText.Text = $Message
    if ($Error) {
        $script:UI.StatusText.Foreground = $script:ErrorInkBrush
        $script:UI.StatusBorder.Background = $script:ErrorSurfaceBrush
        $script:UI.StatusBorder.BorderBrush = $script:ErrorBorderBrush
        if ($null -ne $script:UI.StatusDot) { $script:UI.StatusDot.Fill = $script:ErrorDotBrush }
    }
    else {
        $script:UI.StatusText.Foreground = $script:InkBrush
        $script:UI.StatusBorder.Background = $script:StatusSurfaceBrush
        $script:UI.StatusBorder.BorderBrush = $script:StatusBorderBrush
        if ($null -ne $script:UI.StatusDot) { $script:UI.StatusDot.Fill = $script:StatusDotBrush }
    }
}

function Get-SelectedPageRefreshAction {
    if ($script:UI.MainTabs.SelectedItem -eq $script:UI.ProcessPriorityTab) {
        return 'ProcessPageRefresh'
    }
    if ($script:UI.MainTabs.SelectedItem -eq $script:UI.GraphicsTab) {
        return 'GraphicsPageRefresh'
    }
    return $null
}

function Start-PageRefreshAction {
    param([Parameter(Mandatory)][string]$Action)

    if ($script:OperationInProgress) {
        $script:PendingPageRefreshAction = $Action
        return $false
    }

    switch ($Action) {
        'ProcessPageRefresh' {
            $started = Start-UiOperation -Action $Action -Payload @{ ProtectedProcessId = $script:MainProcessId } -ProgressMessage '正在后台读取当前会话程序列表...'
            if ($started) { $script:ProcessPageLoaded = $true }
            return $started
        }
        'GraphicsPageRefresh' {
            $started = Start-UiOperation -Action $Action -Payload @{} -ProgressMessage '正在后台读取图形适配器与显示状态...'
            if ($started) { $script:GraphicsPageLoaded = $true }
            return $started
        }
        default { throw "未知的页面刷新操作：$Action" }
    }
}

function Request-CurrentPageRefresh {
    param([switch]$Force)

    $action = Get-SelectedPageRefreshAction
    if ([string]::IsNullOrWhiteSpace([string]$action)) {
        $script:PendingPageRefreshAction = $null
        return $false
    }

    $loaded = if ($action -eq 'ProcessPageRefresh') { $script:ProcessPageLoaded } else { $script:GraphicsPageLoaded }
    if (-not $Force -and $loaded) {
        if ($script:OperationInProgress) { $script:PendingPageRefreshAction = $null }
        return $false
    }

    return (Start-PageRefreshAction -Action $action)
}

function Get-UiStatusSnapshot {
    [pscustomobject]@{
        TestOnly = $false
        Partial = $false
        LegionStatus = Get-LegionStatus
        PowerPolicyStatus = Get-PowerPolicyStatus
        CpuFrequencyStatus = Get-CpuMaxFrequencyStatus -SkipTelemetry
        CpuUndervoltStatus = Get-CpuUndervoltStatus
    }
}

function Get-CpuUiStatusSnapshot {
    [pscustomobject]@{
        TestOnly = $false
        Partial = $true
        LegionStatus = $null
        PowerPolicyStatus = Get-PowerPolicyStatus
        CpuFrequencyStatus = Get-CpuMaxFrequencyStatus -SkipTelemetry
        CpuUndervoltStatus = Get-CpuUndervoltStatus
    }
}

function Get-DisplayAdapterObservation {
    $classRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    $adapters = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    foreach ($key in @(Get-ChildItem -LiteralPath $classRoot -ErrorAction SilentlyContinue)) {
        if ($key.PSChildName -notmatch '^\d{4}$') { continue }
        $properties = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
        if ($null -eq $properties) { continue }
        $driverDescProperty = $properties.PSObject.Properties['DriverDesc']
        if ($null -eq $driverDescProperty -or [string]::IsNullOrWhiteSpace([string]$driverDescProperty.Value)) { continue }
        $matchingDeviceProperty = $properties.PSObject.Properties['MatchingDeviceId']
        $matchingDeviceId = if ($null -ne $matchingDeviceProperty) { [string]$matchingDeviceProperty.Value } else { '' }
        if ($matchingDeviceId -notmatch '(?i)^PCI\\') { continue }
        $driverVersionProperty = $properties.PSObject.Properties['DriverVersion']
        $name = [string]$driverDescProperty.Value
        $version = if ($null -ne $driverVersionProperty) { [string]$driverVersionProperty.Value } else { '' }
        $dedupeKey = "$name|$version"
        if ($seen.ContainsKey($dedupeKey)) { continue }
        $seen[$dedupeKey] = $true
        $adapters.Add([pscustomobject]@{
            Name = $name
            DriverVersion = $version
        })
    }

    return @($adapters | Sort-Object -Property Name)
}

function Get-StartMenuAppEntries {
    $result = [pscustomobject]@{
        Nvidia = $null
        LenovoVantage = $null
    }
    $shell = $null
    $folder = $null
    try {
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.NameSpace('shell:AppsFolder')
        if ($null -eq $folder) { return $result }
        foreach ($item in @($folder.Items())) {
            $appId = [string]$item.Path
            if ($null -eq $result.Nvidia -and $appId -match '(?i)^NVIDIACorp\.NVIDIAControlPanel_') {
                $result.Nvidia = [pscustomobject]@{ AppId = $appId; Name = [string]$item.Name }
            }
            elseif ($null -eq $result.LenovoVantage -and $appId -match '(?i)^E046963F\.LenovoCompanion_') {
                $result.LenovoVantage = [pscustomobject]@{ AppId = $appId; Name = [string]$item.Name }
            }
        }
    }
    catch {
    }
    finally {
        if ($null -ne $folder) { try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($folder) } catch { } }
        if ($null -ne $shell) { try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch { } }
    }

    return $result
}

function Get-GraphicsCapabilitySnapshot {
    $model = Get-ModelDescription
    $adapters = @(Get-DisplayAdapterObservation)
    $activeMonitors = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams -ErrorAction SilentlyContinue | Where-Object { $_.Active } | Select-Object InstanceName, VideoOutputTechnology)

    $screen = $null
    $screenCount = 0
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen
        $screenCount = @([System.Windows.Forms.Screen]::AllScreens).Count
    }
    catch {
    }

    $monitorSummary = if ($activeMonitors.Count -eq 0) {
        if ($null -ne $screen) { "Windows 显示类报告 $screenCount 个活动屏幕；WMI 未报告连接类型。" }
        else { 'Windows WMI 未报告活动显示器连接。' }
    }
    else {
        @($activeMonitors | ForEach-Object {
            $technology = if ([uint64]$_.VideoOutputTechnology -eq 2147483648) { 'Internal（内置显示器）' } else { "输出类型 $($_.VideoOutputTechnology)" }
            "$($_.InstanceName)：$technology"
        }) -join '；'
    }

    $adapterSummary = @($adapters | ForEach-Object {
        "$($_.Name)（驱动 $($_.DriverVersion)）"
    }) -join '；'
    if ($null -ne $screen) {
        $desktopMode = "当前桌面模式 $($screen.Bounds.Width)×$($screen.Bounds.Height)"
        if ([string]::IsNullOrWhiteSpace($adapterSummary)) { $adapterSummary = $desktopMode }
        else { $adapterSummary = "$adapterSummary；$desktopMode" }
    }
    if ([string]::IsNullOrWhiteSpace($adapterSummary)) { $adapterSummary = 'Windows 显示类未返回 PCI 显示适配器。' }

    $nvidiaDisplayObservation = '未检测到 nvidia-smi，无法读取 NVIDIA 显示状态。'
    $nvidiaSmi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if ($null -ne $nvidiaSmi) {
        try {
            $nvidiaOutput = @(& $nvidiaSmi.Source '--query-gpu=name,display_active,display_mode' '--format=csv,noheader' 2>$null)
            if ($LASTEXITCODE -eq 0 -and $nvidiaOutput.Count -gt 0) {
                $nvidiaDisplayObservation = 'nvidia-smi 当前观测：' + ($nvidiaOutput -join '；') + '。该字段不证明是否支持 MUX。'
            }
            else {
                $nvidiaDisplayObservation = 'nvidia-smi 存在，但当前无法读取 NVIDIA 显示状态。'
            }
        }
        catch {
            $nvidiaDisplayObservation = "nvidia-smi 查询失败：$($_.Exception.Message)"
        }
    }

    $switchProviderNames = @('Lenovo_BiosSetting', 'Lenovo_GetBiosSelections', 'Lenovo_SetBiosSetting', 'Lenovo_WmiOpcodeInterface')
    $switchProviders = New-Object 'System.Collections.Generic.List[string]'
    foreach ($className in $switchProviderNames) {
        if ($null -ne (Get-CimClass -Namespace root\wmi -ClassName $className -ErrorAction SilentlyContinue)) {
            $switchProviders.Add($className)
        }
    }

    $appEntries = Get-StartMenuAppEntries
    $nvidiaApp = $appEntries.Nvidia
    $lenovoVantageApp = $appEntries.LenovoVantage
    $muxAssessment = if ($switchProviders.Count -gt 0) {
        "硬件独显直连（MUX）尚未证实；检测到 Lenovo BIOS WMI 设置入口类：$($switchProviders -join ', ')，但没有经官方确认的 GPU MUX 控制项。"
    }
    else {
        '硬件独显直连（MUX）支持未证实；本机没有可确认的 Lenovo BIOS GPU 切换 WMI 入口。本程序不会写入固件，也不提供直连开关。未发现入口不等于确认不支持。'
    }

    [pscustomobject]@{
        Model = $model
        AdapterSummary = $adapterSummary
        ActiveMonitorSummary = $monitorSummary
        NvidiaDisplayObservation = $nvidiaDisplayObservation
        MuxAssessment = $muxAssessment
        NvidiaControlPanelAppId = if ($null -ne $nvidiaApp) { [string]$nvidiaApp.AppId } else { $null }
        NvidiaControlPanelAppName = if ($null -ne $nvidiaApp) { [string]$nvidiaApp.Name } else { $null }
        LenovoVantageAppId = if ($null -ne $lenovoVantageApp) { [string]$lenovoVantageApp.AppId } else { $null }
        LenovoVantageAppName = if ($null -ne $lenovoVantageApp) { [string]$lenovoVantageApp.Name } else { $null }
        WindowsGraphicsSettingsAvailable = ([System.Environment]::OSVersion.Version.Major -ge 10)
    }
}
function Set-GraphicsCapabilityUi {
    param([Parameter(Mandatory)]$Snapshot)

    $script:UI.GpuMuxStatusValue.Text = $Snapshot.MuxAssessment
    $script:UI.GpuAdapterValue.Text = "机型观测：$($Snapshot.Model)。$($Snapshot.AdapterSummary)"
    $script:UI.GpuDisplayObservationValue.Text = "活动显示器观测：$($Snapshot.ActiveMonitorSummary) $($Snapshot.NvidiaDisplayObservation)"

    $nvidiaAvailable = -not [string]::IsNullOrWhiteSpace([string]$Snapshot.NvidiaControlPanelAppId)
    $lenovoVantageAvailable = -not [string]::IsNullOrWhiteSpace([string]$Snapshot.LenovoVantageAppId)
    $script:NvidiaControlPanelAppId = if ($nvidiaAvailable) { [string]$Snapshot.NvidiaControlPanelAppId } else { $null }
    $script:NvidiaControlPanelAppName = if ($nvidiaAvailable -and -not [string]::IsNullOrWhiteSpace([string]$Snapshot.NvidiaControlPanelAppName)) { [string]$Snapshot.NvidiaControlPanelAppName } else { 'NVIDIA 控制面板' }
    $script:LenovoVantageAppId = if ($lenovoVantageAvailable) { [string]$Snapshot.LenovoVantageAppId } else { $null }
    $script:LenovoVantageAppName = if ($lenovoVantageAvailable -and -not [string]::IsNullOrWhiteSpace([string]$Snapshot.LenovoVantageAppName)) { [string]$Snapshot.LenovoVantageAppName } else { 'Lenovo Vantage' }
    $script:WindowsGraphicsSettingsAvailable = [bool]$Snapshot.WindowsGraphicsSettingsAvailable
    $nvidiaLabel = if ($nvidiaAvailable) { '已检测到 NVIDIA 控制面板，可打开查看显示模式（是否有 MUX 选项仍以该机型支持为准）' } else { '未检测到 NVIDIA 控制面板入口。' }
    $lenovoLabel = if ($lenovoVantageAvailable) { '已检测到 Lenovo Vantage，可打开检查本机官方硬件选项。' } else { '未检测到 Lenovo Vantage 已注册入口。' }
    $script:UI.GpuAppStatusValue.Text = "$nvidiaLabel $lenovoLabel Windows 应用图形首选项只设置应用使用哪块 GPU，不切换物理显示连线。"
    Update-ProcessPriorityButtons
}

function ConvertTo-PriorityDisplayName {
    param([string]$Priority)
    switch ($Priority) {
        'Idle' { return '空闲' }
        'BelowNormal' { return '低于正常' }
        'Normal' { return '正常' }
        'AboveNormal' { return '高于正常' }
        'High' { return '高' }
        default { return '—' }
    }
}

function Update-ProcessPriorityDetails {
    if ($null -eq $script:UI) { return }
    $selected = $script:UI.ProcessPriorityGrid.SelectedItem
    if ($null -eq $selected) {
        $script:UI.ProcessPriorityDetailValue.Text = '所选程序：选择一行查看完整程序路径、窗口标题和可调原因。'
        return
    }

    $parts = New-Object 'System.Collections.Generic.List[string]'
    $parts.Add("所选程序：$($selected.ProcessName)（PID $($selected.ProcessId)） · $($selected.UiCategory) · 当前 $($selected.UiCurrentPriority) · 原等级 $($selected.UiOriginalPriority)")
    if (-not [string]::IsNullOrWhiteSpace([string]$selected.Reason)) { $parts.Add("状态：$($selected.Reason)") }
    if (-not [string]::IsNullOrWhiteSpace([string]$selected.WindowTitle)) { $parts.Add("窗口：$($selected.WindowTitle)") }
    if (-not [string]::IsNullOrWhiteSpace([string]$selected.ExecutablePath)) { $parts.Add("路径：$($selected.ExecutablePath)") }
    $script:UI.ProcessPriorityDetailValue.Text = $parts -join [Environment]::NewLine
}

function Update-ProcessPriorityButtons {
    if ($null -eq $script:UI) { return }
    $selected = $script:UI.ProcessPriorityGrid.SelectedItem
    $canAdjust = $null -ne $selected -and [bool]$selected.CanAdjust
    $canRestore = $null -ne $selected -and [bool]$selected.CanRestore
    $ready = -not $script:OperationInProgress
    $script:UI.ProcessPriorityRefreshButton.IsEnabled = $ready
    $script:UI.ProcessPriorityApplyButton.IsEnabled = $ready -and $canAdjust
    $script:UI.ProcessPriorityRestoreButton.IsEnabled = $ready -and $canRestore
    $script:UI.GraphicsRefreshButton.IsEnabled = $ready
    $script:UI.NvidiaControlPanelButton.IsEnabled = $ready -and -not [string]::IsNullOrWhiteSpace([string]$script:NvidiaControlPanelAppId)
    $script:UI.LenovoVantageButton.IsEnabled = $ready -and -not [string]::IsNullOrWhiteSpace([string]$script:LenovoVantageAppId)
    $script:UI.WindowsGraphicsSettingsButton.IsEnabled = $ready -and $script:WindowsGraphicsSettingsAvailable
    Update-ProcessPriorityDetails
}

function Set-UiStatusSnapshot {
    param(
        [Parameter(Mandatory)]
        $Snapshot
    )

    $legionStatus = $Snapshot.LegionStatus
    $powerPolicy = $Snapshot.PowerPolicyStatus
    $cpuFrequencyStatus = $Snapshot.CpuFrequencyStatus
    $cpuUndervoltStatus = $Snapshot.CpuUndervoltStatus

    if ($null -ne $legionStatus) {
        $script:UI.CpuTempValue.Text = Format-Temperature -Value $legionStatus.CpuTemperature -Source $legionStatus.CpuTemperatureSource
        $script:UI.CpuTempValue.ToolTip = Get-TemperatureTooltip -Source $legionStatus.CpuTemperatureSource
        $script:UI.GpuTempValue.Text = Format-Temperature -Value $legionStatus.GpuTemperature -Source $legionStatus.GpuTemperatureSource
        $script:UI.GpuTempValue.ToolTip = Get-TemperatureTooltip -Source $legionStatus.GpuTemperatureSource
        $script:UI.Fan1Value.Text = Format-FanSpeed $legionStatus.Fan1Speed
        $script:UI.Fan2Value.Text = Format-FanSpeed $legionStatus.Fan2Speed
        $script:UI.ModeValue.Text = Get-LegionModeName $legionStatus.Mode
        Update-ModeButtons -Mode $legionStatus.Mode

        if ($legionStatus.EnergyAvailable) {
            $script:UI.FanCoolingValue.Text = Get-EnergyFanModeName $legionStatus.EnergyFanMode
        }
        else {
            $script:UI.FanCoolingValue.Text = '不支持'
        }
    }

    if ($null -ne $cpuFrequencyStatus) {
        if ($cpuFrequencyStatus.Available) {
            $script:UI.CpuFrequencyLimitValue.Text = "当前：交流电 $($cpuFrequencyStatus.AcDisplay) / 电池 $($cpuFrequencyStatus.DcDisplay)"
        }
        else {
            $script:UI.CpuFrequencyLimitValue.Text = "当前：不可用（$($cpuFrequencyStatus.Error)）"
        }
    }

    if ($null -ne $cpuUndervoltStatus) {
        Update-CpuUndervoltUi -Status $cpuUndervoltStatus
    }

    if ($null -ne $powerPolicy) {
        $frequencySummary = if ($null -eq $cpuFrequencyStatus) {
            '最大频率：未刷新'
        }
        elseif ($cpuFrequencyStatus.Available) {
            "最大频率：交流电 $($cpuFrequencyStatus.AcDisplay) / 电池 $($cpuFrequencyStatus.DcDisplay)"
        }
        else {
            "最大频率：不可用（$($cpuFrequencyStatus.Error)）"
        }

        $script:UI.PowerPolicyValue.Text = "交流电 CPU：最低 $($powerPolicy.MinimumAc)% / 最高状态 $($powerPolicy.MaximumAc)% / 散热策略：$(Get-CoolingPolicyName $powerPolicy.CoolingAc)。$frequencySummary"
    }

    if ($null -ne $legionStatus -and $null -ne $powerPolicy) {
        $script:UI.DiagnosisValue.Text = Get-Diagnosis -LegionStatus $legionStatus -PowerPolicy $powerPolicy
    }
}

function Set-UiOperationBusy {
    param([bool]$Busy)

    foreach ($button in @(
        $script:UI.RefreshButton,
        $script:UI.QuietButton,
        $script:UI.BalancedButton,
        $script:UI.PerformanceButton,
        $script:UI.RestorePowerButton,
        $script:UI.ApplyFrequencyButton,
        $script:UI.ClearFrequencyButton,
        $script:UI.RestoreFrequencyButton,
        $script:UI.UnhideFrequencyButton,
        $script:UI.ApplyUndervoltButton,
        $script:UI.ClearUndervoltButton,
        $script:UI.SelectXtuButton,
        $script:UI.ProcessPriorityRefreshButton,
        $script:UI.GraphicsRefreshButton,
        $script:UI.ProcessPriorityApplyButton,
        $script:UI.ProcessPriorityRestoreButton,
        $script:UI.NvidiaControlPanelButton,
        $script:UI.LenovoVantageButton,
        $script:UI.WindowsGraphicsSettingsButton
    )) {
        $button.IsEnabled = -not $Busy
    }

    $script:UI.ApplyUndervoltButton.IsEnabled = -not $Busy -and $script:CanApplyCpuUndervolt
    $script:UI.ClearUndervoltButton.IsEnabled = -not $Busy -and $script:CanApplyCpuUndervolt
    $script:UI.SelectXtuButton.IsEnabled = -not $Busy
    Update-ProcessPriorityButtons
}

function Start-UiOperation {
    param(
        [Parameter(Mandatory)]
        [string]$Action,
        [hashtable]$Payload = @{},
        [Parameter(Mandatory)]
        [string]$ProgressMessage
    )

    if ($script:OperationInProgress) {
        return $false
    }

    try {
        $payloadJson = $Payload | ConvertTo-Json -Depth 6 -Compress
        $payloadBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($payloadJson))
        $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $script:ApplicationScriptPath + '" -WorkerAction ' + $Action + ' -WorkerPayloadBase64 ' + $payloadBase64
        if ($script:AsyncLifecycleTest) {
            $arguments += ' -AsyncLifecycleTest'
        }

        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = Join-Path $PSHOME 'powershell.exe'
        $processInfo.Arguments = $arguments
        $processInfo.WorkingDirectory = Split-Path -Parent $script:ApplicationScriptPath
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        if (-not $process.Start()) {
            throw '无法启动后台 PowerShell 工作进程。'
        }

        $script:OperationProcess = $process
        $script:OperationStdoutTask = $process.StandardOutput.ReadToEndAsync()
        $script:OperationStderrTask = $process.StandardError.ReadToEndAsync()
        $script:OperationAction = $Action
        $script:LastWorkerResponse = $null
        if ($script:AsyncLifecycleTest) { $script:AsyncTestStartedActions.Add($Action) }
        $script:OperationIsReadOnly = ($Action -in @('Refresh', 'ProcessPageRefresh', 'GraphicsPageRefresh') -or ($script:AsyncLifecycleTest -and $Action -eq 'AsyncTestDelay'))
        $script:OperationTimedOut = $false
        $script:OperationCancelled = $false
        $script:SlowOperationNoticeShown = $false
        $script:ReadOnlyCancelError = $null
        $script:OperationStartedAt = [DateTime]::UtcNow
        $script:OperationInProgress = $true
        Set-UiOperationBusy -Busy $true
        Set-StatusMessage -Message $ProgressMessage
        $script:OperationPollTimer.Start()
        return $true
    }
    catch {
        if ($null -ne $script:OperationProcess) {
            try { $script:OperationProcess.Dispose() } catch { }
            $script:OperationProcess = $null
        }
        $script:OperationInProgress = $false
        Set-UiOperationBusy -Busy $false
        Set-StatusMessage -Message "无法启动后台操作：$($_.Exception.Message)" -Error
        return $false
    }
}

function Get-CompletedTaskText {
    param([System.Threading.Tasks.Task[string]]$Task)

    if (-not $Task.IsCompleted) {
        throw '后台输出尚未完成。'
    }

    return $Task.GetAwaiter().GetResult()
}

function Stop-ReadOnlyUiWorker {
    if (-not $script:OperationIsReadOnly -or $null -eq $script:OperationProcess) {
        return $false
    }

    try {
        if (-not $script:OperationProcess.HasExited) {
            $script:OperationProcess.Kill()
        }
        return $true
    }
    catch {
        $script:ReadOnlyCancelError = $_.Exception.Message
        return $false
    }
}

function Set-WorkerResponseMessage {
    param(
        [Parameter(Mandatory)]
        $Response
    )

    if ($null -ne $Response.ActionData) {
        try {
            $processRowsProperty = $Response.ActionData.PSObject.Properties['ProcessRows']
            $processRowsErrorProperty = $Response.ActionData.PSObject.Properties['ProcessRowsError']
            if ($null -ne $processRowsProperty) {
                if ($null -ne $processRowsErrorProperty -and -not [string]::IsNullOrWhiteSpace([string]$processRowsErrorProperty.Value)) {
                    $script:UI.ProcessPriorityGrid.ItemsSource = @()
                }
                else {
                    $uiRows = foreach ($row in @($processRowsProperty.Value)) {
                        $uiCategory = switch ([string]$row.Category) {
                            '桌面窗口' { '桌面' }
                            '当前会话后台程序' { '后台' }
                            '原恢复记录' { '恢复记录' }
                            default { [string]$row.Category }
                        }
                        $null = Add-Member -InputObject $row -NotePropertyName UiCategory -NotePropertyValue $uiCategory -Force
                        $null = Add-Member -InputObject $row -NotePropertyName UiCurrentPriority -NotePropertyValue (ConvertTo-PriorityDisplayName -Priority ([string]$row.CurrentPriority)) -Force
                        Add-Member -InputObject $row -NotePropertyName UiOriginalPriority -NotePropertyValue (ConvertTo-PriorityDisplayName -Priority ([string]$row.OriginalPriority)) -Force -PassThru
                    }
                    $script:UI.ProcessPriorityGrid.ItemsSource = @($uiRows)
                }
                Update-ProcessPriorityButtons
            }

            $graphicsProperty = $Response.ActionData.PSObject.Properties['Graphics']
            $graphicsErrorProperty = $Response.ActionData.PSObject.Properties['GraphicsError']
            if ($null -ne $graphicsProperty -and $null -ne $graphicsProperty.Value) {
                Set-GraphicsCapabilityUi -Snapshot $graphicsProperty.Value
            }
            elseif ($null -ne $graphicsErrorProperty -and -not [string]::IsNullOrWhiteSpace([string]$graphicsErrorProperty.Value)) {
                $script:UI.GpuMuxStatusValue.Text = "图形状态读取失败：$($graphicsErrorProperty.Value)"
            }
        }
        catch {
            $uiDataError = "界面更新失败：$($_.Exception.Message)"
            if ([string]::IsNullOrWhiteSpace([string]$Response.ActionDataError)) { $Response.ActionDataError = $uiDataError }
            else { $Response.ActionDataError = [string]$Response.ActionDataError + '；' + $uiDataError }
        }
    }

    if ($Response.SnapshotSucceeded -and $null -ne $Response.Snapshot -and -not $Response.Snapshot.TestOnly) {
        try {
            Set-UiStatusSnapshot -Snapshot $Response.Snapshot
        }
        catch {
            $Response.SnapshotSucceeded = $false
            $Response.SnapshotError = "界面更新失败：$($_.Exception.Message)"
        }
    }

    if ($Response.ActionSucceeded -and $Response.Action -eq 'UndervoltClear') {
        $script:UI.CpuUndervoltLevelCombo.SelectedIndex = 0
    }

    $actionFailed = -not [bool]$Response.ActionSucceeded
    $snapshotFailed = -not [bool]$Response.SnapshotSucceeded
    $actionWarning = [bool]$Response.ActionWarning
    $actionDataFailed = -not [string]::IsNullOrWhiteSpace([string]$Response.ActionDataError)
    $messageParts = New-Object 'System.Collections.Generic.List[string]'

    if ($actionFailed) {
        $actionError = if ([string]::IsNullOrWhiteSpace([string]$Response.ActionError)) { '后台操作失败。' } else { [string]$Response.ActionError }
        $messageParts.Add("操作失败：$actionError")
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$Response.ActionMessage)) {
        $messageParts.Add([string]$Response.ActionMessage)
    }
    elseif ($script:OperationAction -eq 'Refresh') {
        $messageParts.Add('状态已刷新。')
    }

    if ($snapshotFailed) {
        $snapshotError = if ([string]::IsNullOrWhiteSpace([string]$Response.SnapshotError)) { '后台状态读取失败。' } else { [string]$Response.SnapshotError }
        if ($actionFailed) {
            $messageParts.Add("状态刷新也失败：$snapshotError")
        }
        elseif ($Response.ActionSucceeded) {
            $messageParts.Add("操作已完成，但状态刷新失败：$snapshotError")
        }
        else {
            $messageParts.Add("状态读取失败：$snapshotError")
        }
    }
    elseif ($actionFailed) {
        if ($Response.Action -in @('ProcessPrioritySet', 'ProcessPriorityRestore', 'ProcessPageRefresh')) {
            $messageParts.Add('已重新读取相关进程状态。')
        }
        else {
            $messageParts.Add('已重新读取当前状态。')
        }
    }

    if ($actionDataFailed) {
        $messageParts.Add("相关数据读取或显示失败：$($Response.ActionDataError)")
    }

    $message = $messageParts -join ' '
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = '后台操作已完成。'
    }
    if ($actionFailed -or $snapshotFailed -or $actionDataFailed -or $actionWarning) {
        Set-StatusMessage -Message $message -Error
    }
    else {
        Set-StatusMessage -Message $message
    }
}

function Complete-UiOperationIfReady {
    if ($null -eq $script:OperationProcess) {
        return
    }

    $elapsedMilliseconds = ([DateTime]::UtcNow - $script:OperationStartedAt).TotalMilliseconds
    if ($script:OperationIsReadOnly -and -not $script:OperationTimedOut -and -not $script:OperationCancelled -and $elapsedMilliseconds -ge $script:ReadOnlyOperationTimeoutMilliseconds) {
        $script:OperationTimedOut = $true
        Set-StatusMessage -Message '只读状态刷新超时，正在取消读取；完成后可以重试。' -Error
        $null = Stop-ReadOnlyUiWorker
    }
    elseif (-not $script:OperationIsReadOnly -and -not $script:SlowOperationNoticeShown -and $elapsedMilliseconds -ge 30000) {
        $script:SlowOperationNoticeShown = $true
        Set-StatusMessage -Message '设置操作仍在后台运行，未中断；为避免部分应用，请等待操作完成。'
    }

    if (-not $script:OperationProcess.HasExited -or -not $script:OperationStdoutTask.IsCompleted -or -not $script:OperationStderrTask.IsCompleted) {
        return
    }

    try {
        if ($script:OperationTimedOut) {
            $details = if ($script:ReadOnlyCancelError) { "；取消读取失败：$script:ReadOnlyCancelError" } else { '' }
            Set-StatusMessage -Message "只读状态刷新超时，已结束读取$details；可以重试。" -Error
        }
        elseif ($script:OperationCancelled) {
            Set-StatusMessage -Message '只读状态刷新已取消。'
        }
        else {
            $stdout = Get-CompletedTaskText -Task $script:OperationStdoutTask
            $stderr = Get-CompletedTaskText -Task $script:OperationStderrTask
            $exitCode = $script:OperationProcess.ExitCode
            $output = $stdout.Trim()

            if ($output.Length -eq 0) {
                $details = $stderr.Trim()
                if ([string]::IsNullOrWhiteSpace($details)) {
                    $details = "后台进程退出码 $exitCode，未返回结果。"
                }
                Set-StatusMessage -Message "后台操作失败：$details" -Error
            }
            else {
                try {
                    $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($output))
                    $response = ConvertFrom-Json -InputObject $json -ErrorAction Stop
                    $script:LastWorkerResponse = $response
                    Set-WorkerResponseMessage -Response $response
                }
                catch {
                    $details = $stderr.Trim()
                    if ([string]::IsNullOrWhiteSpace($details)) {
                        $details = $_.Exception.Message
                    }
                    Set-StatusMessage -Message "无法读取后台操作结果：$details" -Error
                }
            }
        }
    }
    catch {
        Set-StatusMessage -Message "后台操作完成处理失败：$($_.Exception.Message)" -Error
    }
    finally {
        $script:OperationPollTimer.Stop()
        try { $script:OperationProcess.Dispose() } catch { }
        $script:OperationProcess = $null
        $script:OperationStdoutTask = $null
        $script:OperationStderrTask = $null
        $script:OperationAction = $null
        $script:OperationInProgress = $false
        $script:OperationIsReadOnly = $false
        Set-UiOperationBusy -Busy $false

        if ($null -ne $script:OperationCompletionHandler) {
            try { & $script:OperationCompletionHandler } catch { }
        }
        if ($script:CloseWhenOperationEnds) {
            $script:CloseWhenOperationEnds = $false
            $script:PendingPageRefreshAction = $null
            $script:UI.Window.Close()
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$script:PendingPageRefreshAction)) {
            $pendingAction = [string]$script:PendingPageRefreshAction
            $script:PendingPageRefreshAction = $null
            if ((Get-SelectedPageRefreshAction) -eq $pendingAction) {
                $null = Start-PageRefreshAction -Action $pendingAction
            }
        }
    }
}

function Invoke-WorkerAction {
    param(
        [Parameter(Mandatory)]
        [string]$Action,
        [Parameter(Mandatory)]
        $Payload
    )

    $actionSucceeded = $true
    $actionMessage = $null
    $actionError = $null
    $actionWarning = $false
    $actionData = $null
    $actionDataError = $null
    $snapshotSucceeded = $false
    $snapshotError = $null
    $snapshot = $null

    try {
        switch ($Action) {
            'Refresh' { }
            'ProcessPageRefresh' {
                if ($AsyncLifecycleTest -and $null -ne $Payload.PSObject.Properties['AsyncTestDelayMilliseconds']) {
                    $delay = [Math]::Max(1, [Math]::Min(5000, [int]$Payload.AsyncTestDelayMilliseconds))
                    Start-Sleep -Milliseconds $delay
                }
                $actionMessage = '程序列表已刷新。'
            }
            'GraphicsPageRefresh' {
                if ($AsyncLifecycleTest -and $null -ne $Payload.PSObject.Properties['AsyncTestDelayMilliseconds']) {
                    $delay = [Math]::Max(1, [Math]::Min(5000, [int]$Payload.AsyncTestDelayMilliseconds))
                    Start-Sleep -Milliseconds $delay
                }
                $actionMessage = '图形状态已刷新。'
            }
            'ProcessPrioritySet' {
                $result = Set-ManagedProcessPriority -ProcessId ([int]$Payload.ProcessId) -StartTimeUtcTicks ([long]$Payload.StartTimeUtcTicks) -ExecutablePath ([string]$Payload.ExecutablePath) -Priority ([string]$Payload.Priority) -ProtectedProcessId ([int]$Payload.ProtectedProcessId)
                $actionMessage = "已将选定程序 $($result.ProcessName)（PID $($result.ProcessId)）调整为 $($result.CurrentPriority)；首次原等级 $($result.OriginalPriority) 已保存。"
            }
            'ProcessPriorityRestore' {
                $result = Restore-ManagedProcessPriority -ProcessId ([int]$Payload.ProcessId) -StartTimeUtcTicks ([long]$Payload.StartTimeUtcTicks) -ExecutablePath ([string]$Payload.ExecutablePath) -ProtectedProcessId ([int]$Payload.ProtectedProcessId)
                $actionMessage = "已将选定程序 $($result.ProcessName)（PID $($result.ProcessId)）恢复为 $($result.CurrentPriority)。"
            }
            'Quiet' { $actionMessage = Set-QuietMode -LimitTurbo ([bool]$Payload.LimitTurbo) }
            'Balanced' {
                $null = Set-LegionMode -Mode 2
                $actionMessage = '已确认切换为联想官方均衡散热档。'
            }
            'Performance' {
                $null = Set-LegionMode -Mode 3
                $actionMessage = '已确认切换为联想官方性能散热档。'
            }
            'RestorePower' { $actionMessage = Restore-QuietPowerPolicy }
            'FrequencyApply' {
                $mhz = [int]$Payload.MHz
                $null = Set-CpuMaxFrequencyLimit -MHz $mhz -Power ([string]$Payload.Power)
                $actionMessage = "已按具体频率限制 CPU 最大频率：$mhz MHz。"
            }
            'FrequencyClear' {
                $null = Clear-CpuMaxFrequencyLimit -Power ([string]$Payload.Power)
                $actionMessage = '已取消所选供电状态的 CPU 最大频率限制。'
            }
            'FrequencyRestore' {
                $null = Restore-CpuMaxFrequencyLimit
                $actionMessage = '已还原首次修改前的 CPU 最大频率。'
            }
            'FrequencyUnhide' {
                $null = Enable-CpuMaxFrequencySetting
                $actionMessage = '已请求显示 Windows 高级电源选项里的“处理器最大频率”。'
            }
            'UndervoltApply' {
                $offset = [int]$Payload.OffsetMilliVolts
                if ($offset -eq 0) {
                    $null = Clear-CpuUndervoltOffset
                    $actionMessage = '已请求将 CPU 核心电压偏移还原为 0 mV。'
                }
                else {
                    $null = Set-CpuUndervoltOffset -OffsetMilliVolts $offset
                    $actionMessage = "已请求应用 CPU 核心降压：$offset mV。请进行稳定性测试。"
                }
            }
            'UndervoltClear' {
                $null = Clear-CpuUndervoltOffset
                $actionMessage = '已请求将 CPU 核心电压偏移还原为 0 mV。'
            }
            'SelectXtu' {
                $null = Set-CpuUndervoltBackendPath -XtuCliPath ([string]$Payload.XtuCliPath)
                $actionMessage = '已保存 Intel XTU CLI 路径；请从 -20 mV 开始逐档测试。'
            }
            'AsyncTestDelay' {
                if (-not $AsyncLifecycleTest) { throw '异步生命周期自测操作只能由项目测试入口调用。' }
                $delayMilliseconds = [Math]::Max(1, [Math]::Min(5000, [int]$Payload.DelayMilliseconds))
                Start-Sleep -Milliseconds $delayMilliseconds
                $actionMessage = '异步生命周期自测操作已完成。'
            }
            'AsyncTestPartialSnapshot' {
                if (-not $AsyncLifecycleTest) { throw '异步生命周期自测操作只能由项目测试入口调用。' }
                $actionMessage = '异步生命周期自测：部分状态快照。'
            }
            'AsyncTestFailure' {
                if (-not $AsyncLifecycleTest) { throw '异步生命周期自测操作只能由项目测试入口调用。' }
                throw '异步生命周期自测的预期失败。'
            }
            'AsyncTestPriorityRestoreWarning' {
                if (-not $AsyncLifecycleTest) { throw '优先级恢复警告自测只能由项目测试入口调用。' }
                $warningException = New-Object System.InvalidOperationException('优先级已恢复为 Normal，但恢复记录清理失败；可重试清理记录。')
                $warningException.Data['PriorityRestored'] = $true
                throw $warningException
            }
            default { throw "未知后台操作：$Action" }
        }
    }
    catch {
        $priorityRestored = $false
        $exception = $_.Exception
        while ($null -ne $exception) {
            if ($exception.Data.Contains('PriorityRestored') -and [bool]$exception.Data['PriorityRestored']) {
                $priorityRestored = $true
                break
            }
            $exception = $exception.InnerException
        }
        if ($priorityRestored) {
            $actionSucceeded = $true
            $actionWarning = $true
            $actionMessage = $_.Exception.Message
        }
        else {
            $actionSucceeded = $false
            $actionError = $_.Exception.Message
        }
    }

    if ($Action -in @('ProcessPageRefresh', 'GraphicsPageRefresh', 'ProcessPrioritySet', 'ProcessPriorityRestore')) {
        $processRows = $null
        $processRowsError = $null
        $graphics = $null
        $graphicsError = $null
        $protectedProcessId = 0
        try { $protectedProcessId = [int]$Payload.ProtectedProcessId } catch { }
        if ($Action -in @('ProcessPageRefresh', 'ProcessPrioritySet', 'ProcessPriorityRestore')) {
            try {
                $processRows = @(Get-ProcessPrioritySnapshot -ProtectedProcessId $protectedProcessId)
            }
            catch {
                $processRowsError = $_.Exception.Message
            }
        }
        if ($Action -eq 'GraphicsPageRefresh') {
            try {
                $graphics = Get-GraphicsCapabilitySnapshot
            }
            catch {
                $graphicsError = $_.Exception.Message
            }
        }
        $actionDataValues = @{}
        if ($Action -in @('ProcessPageRefresh', 'ProcessPrioritySet', 'ProcessPriorityRestore')) {
            $actionDataValues.ProcessRows = $processRows
            $actionDataValues.ProcessRowsError = $processRowsError
        }
        if ($Action -eq 'GraphicsPageRefresh') {
            $actionDataValues.Graphics = $graphics
            $actionDataValues.GraphicsError = $graphicsError
        }
        $actionData = [pscustomobject]$actionDataValues
        $dataErrors = New-Object 'System.Collections.Generic.List[string]'
        if (-not [string]::IsNullOrWhiteSpace($processRowsError)) { $dataErrors.Add("程序列表：$processRowsError") }
        if (-not [string]::IsNullOrWhiteSpace($graphicsError)) { $dataErrors.Add("图形状态：$graphicsError") }
        if ($dataErrors.Count -gt 0) { $actionDataError = $dataErrors -join '；' }
        $snapshot = [pscustomobject]@{ TestOnly = $true }
        $snapshotSucceeded = $true
    }
    elseif ($AsyncLifecycleTest -and $Action -in @('AsyncTestDelay', 'AsyncTestFailure', 'AsyncTestPriorityRestoreWarning')) {
        $snapshot = [pscustomobject]@{ TestOnly = $true }
        $snapshotSucceeded = $true
    }
    else {
        $partialSnapshotActions = @('FrequencyApply', 'FrequencyClear', 'FrequencyRestore', 'FrequencyUnhide', 'UndervoltApply', 'UndervoltClear', 'SelectXtu', 'RestorePower')
        try {
            $snapshot = if ($Action -eq 'AsyncTestPartialSnapshot' -or $Action -in $partialSnapshotActions) { Get-CpuUiStatusSnapshot } else { Get-UiStatusSnapshot }
            $snapshotSucceeded = $true
        }
        catch {
            $snapshotError = $_.Exception.Message
        }
    }

    return [pscustomobject]@{
        Action = $Action
        ActionSucceeded = $actionSucceeded
        ActionMessage = $actionMessage
        ActionError = $actionError
        ActionWarning = $actionWarning
        ActionData = $actionData
        ActionDataError = $actionDataError
        SnapshotSucceeded = $snapshotSucceeded
        SnapshotError = $snapshotError
        Snapshot = $snapshot
    }
}

if ($WorkerAction) {
    try {
        $payloadJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($WorkerPayloadBase64))
        $payload = ConvertFrom-Json -InputObject $payloadJson -ErrorAction Stop
        $response = Invoke-WorkerAction -Action $WorkerAction -Payload $payload
        $responseJson = $response | ConvertTo-Json -Depth 12 -Compress
        $responseBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($responseJson))
        [Console]::Out.WriteLine($responseBase64)
        exit 0
    }
    catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    }
}

function Invoke-AsyncLifecycleSelfTest {
    $script:AsyncTestTicks = 0
    $script:AsyncTestFrame = $null
    $script:OperationCompletionHandler = $null

    $heartbeat = New-Object System.Windows.Threading.DispatcherTimer
    $heartbeat.Interval = [TimeSpan]::FromMilliseconds(50)
    $heartbeat.Add_Tick({ $script:AsyncTestTicks++ })
    $heartbeat.Start()

    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $script:AsyncTestFrame = $frame
    $script:OperationCompletionHandler = {
        $script:AsyncTestFrame.Continue = $false
    }

    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $started = Start-UiOperation -Action 'AsyncTestDelay' -Payload @{ DelayMilliseconds = 1500 } -ProgressMessage '自测：后台延迟操作运行中。'
    $dispatchMilliseconds = $clock.ElapsedMilliseconds
    if (-not $started) { throw '后台延迟操作未能启动。' }

    $overlapStarted = Start-UiOperation -Action 'AsyncTestDelay' -Payload @{ DelayMilliseconds = 10 } -ProgressMessage '不应显示。'
    if ($overlapStarted) { throw '防重入检查未阻止第二个 worker。' }

    $timeout = New-Object System.Windows.Threading.DispatcherTimer
    $timeout.Interval = [TimeSpan]::FromSeconds(8)
    $timeout.Add_Tick({ $script:AsyncTestFrame.Continue = $false })
    $timeout.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    $timeout.Stop()
    $heartbeat.Stop()

    if ($dispatchMilliseconds -gt 900) { throw "启动后台操作阻塞了 UI Dispatcher $dispatchMilliseconds ms。" }
    if ($script:AsyncTestTicks -lt 8) { throw "后台采样期间 Dispatcher 心跳过少：$script:AsyncTestTicks。" }
    if ($script:OperationInProgress) { throw '延迟 worker 完成后仍处于忙碌状态。' }
    if (-not $script:UI.RefreshButton.IsEnabled) { throw '延迟 worker 完成后没有恢复操作按钮。' }
    if ($script:UI.StatusText.Text -notmatch '异步生命周期自测操作已完成') { throw '成功结果未显示在界面状态栏。' }

    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $script:AsyncTestFrame = $frame
    $script:OperationCompletionHandler = { $script:AsyncTestFrame.Continue = $false }
    $started = Start-UiOperation -Action 'AsyncTestFailure' -Payload @{} -ProgressMessage '自测：验证失败反馈。'
    if (-not $started) { throw '失败反馈 worker 未能启动，无法继续恢复检查。' }
    $timeout = New-Object System.Windows.Threading.DispatcherTimer
    $timeout.Interval = [TimeSpan]::FromSeconds(8)
    $timeout.Add_Tick({ $script:AsyncTestFrame.Continue = $false })
    $timeout.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    $timeout.Stop()

    if ($script:OperationInProgress) { throw '失败 worker 完成后仍处于忙碌状态。' }
    if (-not $script:UI.RefreshButton.IsEnabled) { throw '失败 worker 完成后没有恢复操作按钮。' }
    if ($script:UI.StatusText.Text -notmatch '操作失败：异步生命周期自测的预期失败') { throw '失败结果没有显示在界面状态栏。' }

    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $script:AsyncTestFrame = $frame
    $script:OperationCompletionHandler = { $script:AsyncTestFrame.Continue = $false }
    $started = Start-UiOperation -Action 'AsyncTestPriorityRestoreWarning' -Payload @{} -ProgressMessage '自测：验证优先级已恢复但记录清理失败的提示。'
    if (-not $started) { throw '恢复记录警告 worker 未能启动。' }
    $timeout = New-Object System.Windows.Threading.DispatcherTimer
    $timeout.Interval = [TimeSpan]::FromSeconds(8)
    $timeout.Add_Tick({ $script:AsyncTestFrame.Continue = $false })
    $timeout.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    $timeout.Stop()
    if ($script:OperationInProgress) { throw '恢复记录警告 worker 完成后仍处于忙碌状态。' }
    if ($script:LastWorkerResponse.ActionSucceeded -ne $true -or $script:LastWorkerResponse.ActionWarning -ne $true) { throw '恢复记录清理失败被错误归类为操作失败。' }
    if ($script:UI.StatusText.Text -notmatch '优先级已恢复为' -or $script:UI.StatusText.Text -match '操作失败：') { throw '恢复记录警告没有准确说明优先级已恢复。' }

    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $script:AsyncTestFrame = $frame
    $script:OperationCompletionHandler = { $script:AsyncTestFrame.Continue = $false }
    $started = Start-UiOperation -Action 'AsyncTestDelay' -Payload @{ DelayMilliseconds = 20 } -ProgressMessage '自测：确认失败后可再次操作。'
    if (-not $started) { throw '失败后未恢复接受新操作。' }
    $timeout = New-Object System.Windows.Threading.DispatcherTimer
    $timeout.Interval = [TimeSpan]::FromSeconds(8)
    $timeout.Add_Tick({ $script:AsyncTestFrame.Continue = $false })
    $timeout.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    $timeout.Stop()

    if ($script:OperationInProgress) { throw '恢复 worker 完成后仍处于忙碌状态。' }
    if ($script:UI.StatusText.Text -notmatch '异步生命周期自测操作已完成') { throw '恢复操作的结果未返回到界面。' }

    $script:ReadOnlyOperationTimeoutMilliseconds = 300
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $script:AsyncTestFrame = $frame
    $script:OperationCompletionHandler = { $script:AsyncTestFrame.Continue = $false }
    $started = Start-UiOperation -Action 'AsyncTestDelay' -Payload @{ DelayMilliseconds = 1500 } -ProgressMessage '自测：验证只读刷新超时取消。'
    if (-not $started) { throw '只读超时 worker 未能启动。' }
    $timeout = New-Object System.Windows.Threading.DispatcherTimer
    $timeout.Interval = [TimeSpan]::FromSeconds(8)
    $timeout.Add_Tick({ $script:AsyncTestFrame.Continue = $false })
    $timeout.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    $timeout.Stop()
    $script:ReadOnlyOperationTimeoutMilliseconds = 20000

    if ($script:OperationInProgress) { throw '超时取消后仍处于忙碌状态。' }
    if (-not $script:UI.RefreshButton.IsEnabled) { throw '超时取消后没有恢复操作按钮。' }
    if ($script:UI.StatusText.Text -notmatch '只读状态刷新超时') { throw '只读超时没有显示为可重试的刷新失败。' }

    $script:ReadOnlyOperationTimeoutMilliseconds = 300
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $script:AsyncTestFrame = $frame
    $script:OperationCompletionHandler = { $script:AsyncTestFrame.Continue = $false }
    $started = Start-UiOperation -Action 'ProcessPageRefresh' -Payload @{ ProtectedProcessId = $script:MainProcessId; AsyncTestDelayMilliseconds = 1500 } -ProgressMessage '自测：验证程序列表刷新可取消。'
    if (-not $started) { throw '程序列表只读超时 worker 未能启动。' }
    $timeout = New-Object System.Windows.Threading.DispatcherTimer
    $timeout.Interval = [TimeSpan]::FromSeconds(8)
    $timeout.Add_Tick({ $script:AsyncTestFrame.Continue = $false })
    $timeout.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    $timeout.Stop()
    $script:ReadOnlyOperationTimeoutMilliseconds = 20000
    if ($script:OperationInProgress) { throw '程序列表只读超时取消后仍处于忙碌状态。' }
    if ($script:UI.ProcessPriorityRefreshButton.IsEnabled -ne $true) { throw '程序列表超时取消后没有恢复刷新控件。' }
    if ($script:UI.StatusText.Text -notmatch '只读状态刷新超时') { throw '程序列表刷新超时没有显示为可重试的只读失败。' }

    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $script:AsyncTestFrame = $frame
    $script:OperationCompletionHandler = { $script:AsyncTestFrame.Continue = $false }
    $started = Start-UiOperation -Action 'Refresh' -Payload @{} -ProgressMessage '自测：执行真实只读状态刷新。'
    if (-not $started) { throw '真实只读刷新 worker 未能启动。' }
    $timeout = New-Object System.Windows.Threading.DispatcherTimer
    $timeout.Interval = [TimeSpan]::FromSeconds(25)
    $timeout.Add_Tick({ $script:AsyncTestFrame.Continue = $false })
    $timeout.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    $timeout.Stop()

    if ($script:OperationInProgress) { throw '真实只读刷新未在测试期限内完成。' }
    if ($null -eq $script:LastWorkerResponse) { throw '真实只读刷新没有解码 worker JSON。' }
    if (-not $script:LastWorkerResponse.SnapshotSucceeded -and $script:UI.StatusText.Text -notmatch '失败|错误|不可用') {
        throw '真实只读刷新失败时，界面没有显示可见错误。'
    }
    if ($script:LastWorkerResponse.SnapshotSucceeded -and [string]::IsNullOrWhiteSpace($script:UI.CpuFrequencyLimitValue.Text)) {
        throw '真实只读刷新成功但未把状态快照应用到 UI 控件。'
    }

    $cpuTempBeforePartial = [string]$script:UI.CpuTempValue.Text
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $script:AsyncTestFrame = $frame
    $script:OperationCompletionHandler = { $script:AsyncTestFrame.Continue = $false }
    $started = Start-UiOperation -Action 'AsyncTestPartialSnapshot' -Payload @{} -ProgressMessage '自测：验证部分状态快照不读取散热控制器。'
    if (-not $started) { throw '部分状态快照 worker 未能启动。' }
    $timeout = New-Object System.Windows.Threading.DispatcherTimer
    $timeout.Interval = [TimeSpan]::FromSeconds(15)
    $timeout.Add_Tick({ $script:AsyncTestFrame.Continue = $false })
    $timeout.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    $timeout.Stop()
    if ($script:OperationInProgress) { throw '部分状态快照未在测试期限内完成。' }
    if ($null -eq $script:LastWorkerResponse -or $script:LastWorkerResponse.Action -ne 'AsyncTestPartialSnapshot') { throw '部分状态快照没有解码 worker JSON。' }
    if (-not $script:LastWorkerResponse.Snapshot.Partial -or $null -ne $script:LastWorkerResponse.Snapshot.LegionStatus) { throw '部分状态快照仍读取了散热控制器。' }
    if ([string]::IsNullOrWhiteSpace($script:UI.CpuFrequencyLimitValue.Text)) { throw '部分状态快照没有更新 CPU 频率状态。' }
    if ([string]$script:UI.CpuTempValue.Text -ne $cpuTempBeforePartial) { throw '部分状态快照不应改写散热读数。' }

    $graphicsStatusBeforeProcessRefresh = [string]$script:UI.GpuMuxStatusValue.Text
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $script:AsyncTestFrame = $frame
    $script:OperationCompletionHandler = { $script:AsyncTestFrame.Continue = $false }
    $started = Start-UiOperation -Action 'ProcessPageRefresh' -Payload @{ ProtectedProcessId = $script:MainProcessId } -ProgressMessage '自测：读取并应用真实程序列表。'
    if (-not $started) { throw '真实程序列表只读 worker 未能启动。' }
    $timeout = New-Object System.Windows.Threading.DispatcherTimer
    $timeout.Interval = [TimeSpan]::FromSeconds(25)
    $timeout.Add_Tick({ $script:AsyncTestFrame.Continue = $false })
    $timeout.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    $timeout.Stop()
    if ($script:OperationInProgress) { throw '真实程序列表读取未在测试期限内完成。' }
    if ($null -eq $script:LastWorkerResponse -or $script:LastWorkerResponse.Action -ne 'ProcessPageRefresh') { throw '真实程序列表 worker JSON 没有成功解码。' }
    $processRowsProperty = $script:LastWorkerResponse.ActionData.PSObject.Properties['ProcessRows']
    $processRowsError = [string]$script:LastWorkerResponse.ActionData.ProcessRowsError
    if ([string]::IsNullOrWhiteSpace($processRowsError) -and @($processRowsProperty.Value).Count -gt 0) {
        if ($script:UI.ProcessPriorityGrid.Items.Count -eq 0) { throw '真实程序列表 JSON 已解码但没有应用到 WPF 表格。' }
    }
    elseif ($script:UI.StatusText.Text -notmatch '相关数据读取或显示失败') {
        throw '程序列表真实读取失败时，界面没有显示可见错误。'
    }
    if ($script:UI.GpuMuxStatusValue.Text -ne $graphicsStatusBeforeProcessRefresh) { throw '程序列表刷新清空或改写了独立图形页的缓存状态。' }
    $liveProcessCount = $script:UI.ProcessPriorityGrid.Items.Count

    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $script:AsyncTestFrame = $frame
    $script:OperationCompletionHandler = { $script:AsyncTestFrame.Continue = $false }
    $started = Start-UiOperation -Action 'GraphicsPageRefresh' -Payload @{} -ProgressMessage '自测：读取并应用真实图形状态。'
    if (-not $started) { throw '真实图形状态只读 worker 未能启动。' }
    $timeout = New-Object System.Windows.Threading.DispatcherTimer
    $timeout.Interval = [TimeSpan]::FromSeconds(25)
    $timeout.Add_Tick({ $script:AsyncTestFrame.Continue = $false })
    $timeout.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    $timeout.Stop()
    if ($script:OperationInProgress) { throw '真实图形状态读取未在测试期限内完成。' }
    if ($null -eq $script:LastWorkerResponse -or $script:LastWorkerResponse.Action -ne 'GraphicsPageRefresh') { throw '真实图形状态 worker JSON 没有成功解码。' }
    $graphicsProperty = $script:LastWorkerResponse.ActionData.PSObject.Properties['Graphics']
    $graphicsError = [string]$script:LastWorkerResponse.ActionData.GraphicsError
    $graphicsSnapshot = if ($null -ne $graphicsProperty) { $graphicsProperty.Value } else { $null }
    if ($null -ne $graphicsSnapshot) {
        if ([string]::IsNullOrWhiteSpace($script:UI.GpuMuxStatusValue.Text) -or [string]::IsNullOrWhiteSpace($script:UI.GpuAdapterValue.Text)) { throw '真实图形快照已解码但没有应用到图形状态控件。' }
        $nvidiaEntryAvailable = -not [string]::IsNullOrWhiteSpace([string]$graphicsSnapshot.NvidiaControlPanelAppId)
        $vantageEntryAvailable = -not [string]::IsNullOrWhiteSpace([string]$graphicsSnapshot.LenovoVantageAppId)
        if ($script:UI.NvidiaControlPanelButton.IsEnabled -ne $nvidiaEntryAvailable) { throw 'NVIDIA 控制面板按钮状态没有按已注册 AppID 更新。' }
        if ($script:UI.LenovoVantageButton.IsEnabled -ne $vantageEntryAvailable) { throw 'Lenovo Vantage 按钮状态没有按已注册 AppID 更新。' }
    }
    elseif ($script:UI.StatusText.Text -notmatch '相关数据读取或显示失败') {
        throw '图形信息真实读取失败时，界面没有显示可见错误。'
    }
    if ($script:UI.ProcessPriorityGrid.Items.Count -ne $liveProcessCount) { throw '图形刷新改写了独立程序优先级表格。' }

    function Wait-AsyncLifecycleOperations {
        param([int]$TimeoutSeconds = 45)
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ($script:OperationInProgress) {
            if ([DateTime]::UtcNow -ge $deadline) { throw '排队页面刷新没有在期限内完成。' }
            $script:AsyncTestFrame = New-Object System.Windows.Threading.DispatcherFrame
            $script:OperationCompletionHandler = { $script:AsyncTestFrame.Continue = $false }
            $waitTimer = New-Object System.Windows.Threading.DispatcherTimer
            $waitTimer.Interval = [TimeSpan]::FromSeconds([Math]::Max(1, [Math]::Min(25, ($deadline - [DateTime]::UtcNow).TotalSeconds)))
            $waitTimer.Add_Tick({ $script:AsyncTestFrame.Continue = $false })
            $waitTimer.Start()
            [System.Windows.Threading.Dispatcher]::PushFrame($script:AsyncTestFrame)
            $waitTimer.Stop()
        }
    }

    $actionCountBeforeQueueTest = $script:AsyncTestStartedActions.Count
    $script:ProcessPageLoaded = $false
    $script:GraphicsPageLoaded = $false
    $script:PendingPageRefreshAction = $null
    $script:UI.MainTabs.SelectedItem = $script:UI.CpuTab
    $script:AsyncTestFrame = New-Object System.Windows.Threading.DispatcherFrame
    $script:OperationCompletionHandler = { $script:AsyncTestFrame.Continue = $false }
    $started = Start-UiOperation -Action 'Refresh' -Payload @{} -ProgressMessage '自测：CPU状态读取期间切换页面。'
    if (-not $started) { throw 'CPU忙时页面切换自测的初始刷新未能启动。' }
    $script:UI.MainTabs.SelectedItem = $script:UI.ProcessPriorityTab
    $null = Request-CurrentPageRefresh
    $script:UI.MainTabs.SelectedItem = $script:UI.GraphicsTab
    $null = Request-CurrentPageRefresh
    if ($script:PendingPageRefreshAction -ne 'GraphicsPageRefresh') { throw '忙碌时的页面队列没有保留最终选中页。' }
    Wait-AsyncLifecycleOperations
    $queuedActionCount = $script:AsyncTestStartedActions.Count - $actionCountBeforeQueueTest
    if ($queuedActionCount -ne 2 -or $script:AsyncTestStartedActions[$actionCountBeforeQueueTest + 1] -ne 'GraphicsPageRefresh') { throw 'CPU后台操作完成后没有只启动最终选中页的独立图形查询。' }
    if ($null -eq $script:LastWorkerResponse -or $script:LastWorkerResponse.Action -ne 'GraphicsPageRefresh') { throw '最终选中图形页在排队查询完成后没有应用数据。' }
    if ($script:UI.ProcessPriorityGrid.Items.Count -ne $liveProcessCount) { throw '排队图形页查询清空了已加载的程序列表。' }

    $refreshResult = if ($script:LastWorkerResponse.SnapshotSucceeded) { 'CPU snapshot applied' } else { "visible CPU error: $($script:UI.StatusText.Text)" }
    $processResult = if ($liveProcessCount -gt 0) { 'process snapshot applied independently' } else { "visible process data error: $script:UI.StatusText.Text" }
    $graphicsResult = if (-not [string]::IsNullOrWhiteSpace($script:UI.GpuAdapterValue.Text)) { 'graphics snapshot applied independently' } else { "visible graphics data error: $script:UI.StatusText.Text" }
    Write-Output "PASS async UI lifecycle: dispatch ${dispatchMilliseconds} ms; dispatcher ticks $script:AsyncTestTicks; overlap blocked; failure visible; restore warning accurate; retry recovered; readonly refreshes cancelled; live refresh $refreshResult; $processResult; $graphicsResult; final-page queue applied."
}

function Complete-UiOperationPoll {
    Complete-UiOperationIfReady
}

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)
$workArea = [System.Windows.SystemParameters]::WorkArea
if ($workArea.Width -gt 0 -and $workArea.Height -gt 0) {
    $window.Width = [Math]::Min(980, $workArea.Width)
    $window.Height = [Math]::Min(760, $workArea.Height)
    $window.MinWidth = [Math]::Min(800, $workArea.Width)
    $window.MinHeight = [Math]::Min(600, $workArea.Height)
    $window.MaxWidth = $workArea.Width
    $window.MaxHeight = $workArea.Height
}

$script:UI = @{
    Window = $window
    MainTabs = $window.FindName('MainTabs')
    CpuTab = $window.FindName('CpuTab')
    ProcessPriorityTab = $window.FindName('ProcessPriorityTab')
    GraphicsTab = $window.FindName('GraphicsTab')
    ModelText = $window.FindName('ModelText')
    CpuTempValue = $window.FindName('CpuTempValue')
    GpuTempValue = $window.FindName('GpuTempValue')
    Fan1Value = $window.FindName('Fan1Value')
    Fan2Value = $window.FindName('Fan2Value')
    ModeValue = $window.FindName('ModeValue')
    FanCoolingValue = $window.FindName('FanCoolingValue')
    PowerPolicyValue = $window.FindName('PowerPolicyValue')
    DiagnosisValue = $window.FindName('DiagnosisValue')
    StatusText = $window.FindName('StatusText')
    StatusDot = $window.FindName('StatusDot')
    TurboLimitCheck = $window.FindName('TurboLimitCheck')
    RefreshButton = $window.FindName('RefreshButton')
    QuietButton = $window.FindName('QuietButton')
    BalancedButton = $window.FindName('BalancedButton')
    PerformanceButton = $window.FindName('PerformanceButton')
    RestorePowerButton = $window.FindName('RestorePowerButton')
    CpuFrequencyLimitValue = $window.FindName('CpuFrequencyLimitValue')
    CpuFrequencyInput = $window.FindName('CpuFrequencyInput')
    CpuFrequencyPowerCombo = $window.FindName('CpuFrequencyPowerCombo')
    ApplyFrequencyButton = $window.FindName('ApplyFrequencyButton')
    ClearFrequencyButton = $window.FindName('ClearFrequencyButton')
    RestoreFrequencyButton = $window.FindName('RestoreFrequencyButton')
    UnhideFrequencyButton = $window.FindName('UnhideFrequencyButton')
    CpuUndervoltStatusValue = $window.FindName('CpuUndervoltStatusValue')
    CpuUndervoltLevelCombo = $window.FindName('CpuUndervoltLevelCombo')
    ApplyUndervoltButton = $window.FindName('ApplyUndervoltButton')
    ClearUndervoltButton = $window.FindName('ClearUndervoltButton')
    SelectXtuButton = $window.FindName('SelectXtuButton')
    ProcessPriorityGrid = $window.FindName('ProcessPriorityGrid')
    ProcessPriorityDetailValue = $window.FindName('ProcessPriorityDetailValue')
    ProcessPriorityRefreshButton = $window.FindName('ProcessPriorityRefreshButton')
    ProcessPriorityChoiceCombo = $window.FindName('ProcessPriorityChoiceCombo')
    ProcessPriorityApplyButton = $window.FindName('ProcessPriorityApplyButton')
    ProcessPriorityRestoreButton = $window.FindName('ProcessPriorityRestoreButton')
    GpuMuxStatusValue = $window.FindName('GpuMuxStatusValue')
    GpuAdapterValue = $window.FindName('GpuAdapterValue')
    GpuDisplayObservationValue = $window.FindName('GpuDisplayObservationValue')
    GpuAppStatusValue = $window.FindName('GpuAppStatusValue')
    NvidiaControlPanelButton = $window.FindName('NvidiaControlPanelButton')
    LenovoVantageButton = $window.FindName('LenovoVantageButton')
    WindowsGraphicsSettingsButton = $window.FindName('WindowsGraphicsSettingsButton')
    GraphicsRefreshButton = $window.FindName('GraphicsRefreshButton')
    GraphicsPageScroll = $window.FindName('GraphicsPageScroll')
    GraphicsDetailsText = $window.FindName('GraphicsDetailsText')
    CpuPageScroll = $window.FindName('CpuPageScroll')
    CpuUndervoltExpander = $window.FindName('CpuUndervoltExpander')
    DetailedDiagnosisExpander = $window.FindName('DetailedDiagnosisExpander')
    GraphicsDetailsExpander = $window.FindName('GraphicsDetailsExpander')
    StatusBorder = $window.FindName('StatusBorder')
}

$script:ActiveModeBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#0F766E')
$script:DefaultModeBorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#DCE5EE')
$script:InkBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#12212E')
$script:MutedBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#62748A')
$script:ModeIdleBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFFFFF')
$script:StatusSurfaceBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F8FAFC')
$script:StatusBorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#DEE6EF')
$script:StatusDotBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#12805C')
$script:ErrorSurfaceBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FEF2F2')
$script:ErrorBorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F5C2C2')
$script:ErrorInkBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#A12828')
$script:ErrorDotBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#B91C1C')

$script:OperationPollTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:OperationPollTimer.Interval = [TimeSpan]::FromMilliseconds(80)
$script:OperationPollTimer.Add_Tick({ Complete-UiOperationPoll })

function Update-ProcessPriorityColumnWidths {
    $grid = $script:UI.ProcessPriorityGrid
    if ($null -eq $grid -or $grid.Columns.Count -lt 6 -or $grid.ActualWidth -le 0) { return }

    $flexWidth = [Math]::Max(0.0, [double]$grid.ActualWidth - 292.0)
    $processNameWidth = [Math]::Max(150.0, [Math]::Floor($flexWidth * 0.56))
    $reasonWidth = [Math]::Max(135.0, $flexWidth - $processNameWidth)
    $grid.Columns[1].Width = [System.Windows.Controls.DataGridLength]::new($processNameWidth)
    $grid.Columns[5].Width = [System.Windows.Controls.DataGridLength]::new($reasonWidth)
}

$script:UI.ProcessPriorityGrid.Add_SizeChanged({ Update-ProcessPriorityColumnWidths })

function Get-LayoutPreviewBounds {
    param(
        [Parameter(Mandatory)]$Element,
        [Parameter(Mandatory)]$Root
    )

    $rect = [System.Windows.Rect]::new(0.0, 0.0, [double]$Element.RenderSize.Width, [double]$Element.RenderSize.Height)
    return $Element.TransformToAncestor($Root).TransformBounds($rect)
}

function Assert-LayoutPreviewBounds {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Element,
        [Parameter(Mandatory)]$Root,
        [Parameter(Mandatory)][double]$Width,
        [Parameter(Mandatory)][double]$Height
    )

    $bounds = Get-LayoutPreviewBounds -Element $Element -Root $Root
    if ($bounds.IsEmpty -or $bounds.X -lt -1 -or $bounds.Y -lt -1 -or $bounds.Right -gt ($Width + 1) -or $bounds.Bottom -gt ($Height + 1)) {
        throw "$Name 未能在页面可视区域内布局：$bounds。"
    }
    return $bounds
}

function Assert-LayoutPreviewScrollAccess {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Element,
        [Parameter(Mandatory)]$ScrollViewer,
        [Parameter(Mandatory)]$Root
    )

    $bounds = Get-LayoutPreviewBounds -Element $Element -Root $Root
    $viewport = Get-LayoutPreviewBounds -Element $ScrollViewer -Root $Root
    if ($bounds.IsEmpty -or $bounds.Bottom -le $viewport.Top -or $bounds.Top -ge $viewport.Bottom) {
        throw "$Name 在页面滚动后仍无法进入可视区域。"
    }
    return $bounds
}

function Save-LayoutPreviewImage {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Root,
        [Parameter(Mandatory)][double]$Width,
        [Parameter(Mandatory)][double]$Height
    )

    $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap([int]$Width, [int]$Height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($Root)
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}

function Export-LayoutPreview {
    $projectRoot = Split-Path -Parent $PSScriptRoot
    $previewRoot = Join-Path $projectRoot 'build\layout-preview'
    $previewDirectory = Join-Path $previewRoot ('preview-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
    $null = New-Item -Path $previewDirectory -ItemType Directory -Force

    Initialize-CpuUndervoltLevels
    $script:UI.ModelText.Text = '布局预览：模拟 Legion Y7000 / i5 状态 · 仅测试 fixture，不读取或写入控制设置。'
    $script:UI.CpuTempValue.Text = '58 °C'
    $script:UI.GpuTempValue.Text = '49 °C'
    $script:UI.Fan1Value.Text = '2,100 RPM'
    $script:UI.Fan2Value.Text = '1,800 RPM'
    $script:UI.ModeValue.Text = '均衡（模拟回读）'
    Update-ModeButtons -Mode 2
    $script:UI.FanCoolingValue.Text = '支持'
    $script:UI.PowerPolicyValue.Text = '交流电 CPU：最低 5% / 最高状态 99% / 散热策略：被动。最大频率：交流电 2,400 MHz / 电池 1,800 MHz。此处为布局用模拟文本。'
    $script:UI.CpuFrequencyLimitValue.Text = '当前：交流电 2,400 MHz / 电池 1,800 MHz（模拟）'
    $script:UI.CpuUndervoltStatusValue.Text = '后端：Intel XTU（XTUCli.exe）；最近请求：未设置（模拟预览）'
    $script:UI.DiagnosisValue.Text = '仅为模拟诊断：运行时读取来自 Lenovo Energy Driver、Windows 电源策略和 XTU 后端。页面调整没有改变任何机器设置。'
    Set-StatusMessage -Message ((1..8 | ForEach-Object { '模拟错误详情（无真实操作）：状态读取未完成；请查看本页说明并重试。' }) -join ' ') -Error
    Initialize-CpuUndervoltLevels

    $fixtureRows = New-Object 'System.Collections.Generic.List[object]'
    for ($index = 1; $index -le 24; $index++) {
        $name = if ($index -eq 1) { '桌面图像设计与视频剪辑程序_长名称用于验证宽度分配.exe' } else { "桌面应用程序-$('{0:D2}' -f $index).exe" }
        $priority = if ($index % 3 -eq 0) { 'AboveNormal' } elseif ($index % 2 -eq 0) { 'Normal' } else { 'BelowNormal' }
        $category = if ($index % 3 -eq 0) { '桌面窗口' } else { '当前会话后台程序' }
        $reason = if ($index -eq 1) { '允许：当前用户会话、进程路径与启动时间核对通过；可调整，原始等级已备份。' } elseif ($index % 5 -eq 0) { '受保护或无法核对身份；如状态变化请刷新后再操作。' } else { '可调整；变更前会保存原始等级，恢复前再次核对进程身份。' }
        $path = if ($index -eq 1) { 'E:\用户资料\桌面项目\2026年秋季\图形与视频工具\桌面图像设计与视频剪辑程序_长名称用于验证中文长路径布局.exe' } else { "C:\Users\23526\AppData\Local\Programs\示例应用\应用$index.exe" }
        $title = if ($index -eq 1) { '正在编辑：很长的中文设计工程标题，包含多段章节说明与文件名以测试所选窗口详情换行' } else { "示例窗口 $index" }
        $fixtureRow = [pscustomobject]@{
            ProcessId = 3000 + $index
            StartTimeUtcTicks = [long]([DateTime]::UtcNow.Ticks - $index * 10000000)
            ProcessName = $name
            Category = $category
            UiCategory = if ($category -eq '桌面窗口') { '桌面' } else { '后台' }
            WindowTitle = $title
            CurrentPriority = $priority
            UiCurrentPriority = ConvertTo-PriorityDisplayName -Priority $priority
            OriginalPriority = 'Normal'
            UiOriginalPriority = '正常'
            CanAdjust = ($index -ne 5)
            CanRestore = ($index -eq 1)
            Reason = $reason
            ExecutablePath = $path
        }
        $fixtureRows.Add($fixtureRow)
    }
    $script:UI.ProcessPriorityGrid.ItemsSource = $fixtureRows
    $script:UI.ProcessPriorityGrid.SelectedIndex = 0
    Update-ProcessPriorityButtons
    Update-ProcessPriorityColumnWidths

    Set-GraphicsCapabilityUi -Snapshot ([pscustomobject]@{
        Model = 'Lenovo Legion Y7000 2019 1050 / 81V4（模拟）'
        AdapterSummary = 'Intel UHD Graphics 630（驱动 27.20）与 NVIDIA GeForce GTX 1050（驱动 31.0）；当前桌面模式 1920×1080。'
        ActiveMonitorSummary = '内置屏幕活动（状态观测）；活动适配器不等于 MUX 能力证明。'
        NvidiaDisplayObservation = 'nvidia-smi 显示模式为 Disabled（模拟），此字段不证明物理直连支持。'
        MuxAssessment = '支持状态未证实；此界面不禁用核显、不写入 BIOS，也不提供伪切换开关。'
        NvidiaControlPanelAppId = 'NVIDIACorp.NVIDIAControlPanel_preview!ControlPanel'
        NvidiaControlPanelAppName = 'NVIDIA 控制面板（模拟）'
        LenovoVantageAppId = 'E046963F.LenovoCompanion_preview!Vantage'
        LenovoVantageAppName = 'Lenovo Vantage（模拟）'
        WindowsGraphicsSettingsAvailable = $true
    })

    $root = $script:UI.Window.Content
    $pageCases = @(
        @{ Name = 'cpu'; Tab = $script:UI.CpuTab },
        @{ Name = 'process'; Tab = $script:UI.ProcessPriorityTab },
        @{ Name = 'graphics'; Tab = $script:UI.GraphicsTab }
    )
    $sizeCases = @(
        @{ Name = 'default-980x760'; Width = 980.0; Height = 760.0 },
        @{ Name = 'minimum-800x600'; Width = 800.0; Height = 600.0 }
    )

    foreach ($size in $sizeCases) {
        $script:UI.Window.Width = $size.Width
        $script:UI.Window.Height = $size.Height
        $layoutWidth = [Math]::Max(300.0, $size.Width - 52.0)
        $layoutHeight = [Math]::Max(240.0, $size.Height - 76.0)
        foreach ($page in $pageCases) {
            $script:UI.MainTabs.SelectedItem = $page.Tab
            $root.Measure([System.Windows.Size]::new($layoutWidth, $layoutHeight))
            $root.Arrange([System.Windows.Rect]::new(0.0, 0.0, $layoutWidth, $layoutHeight))
            $root.UpdateLayout()
            $null = Assert-LayoutPreviewBounds -Name '固定状态栏' -Element $script:UI.StatusBorder -Root $root -Width $layoutWidth -Height $layoutHeight
            if ($script:UI.StatusBorder.ActualWidth -lt 400 -or $script:UI.StatusBorder.ActualHeight -gt 72) { throw "状态栏在$($size.Name)下宽高异常：$($script:UI.StatusBorder.ActualWidth)×$($script:UI.StatusBorder.ActualHeight) DIP。" }

            switch ($page.Name) {
                'cpu' {
                    $null = Assert-LayoutPreviewBounds -Name 'CPU刷新按钮' -Element $script:UI.RefreshButton -Root $root -Width $layoutWidth -Height $layoutHeight
                    $null = Assert-LayoutPreviewBounds -Name '静音按钮' -Element $script:UI.QuietButton -Root $root -Width $layoutWidth -Height $layoutHeight
                    foreach ($metricControl in @($script:UI.CpuTempValue, $script:UI.GpuTempValue, $script:UI.Fan1Value, $script:UI.Fan2Value, $script:UI.StatusDot)) {
                        $null = Assert-LayoutPreviewBounds -Name 'CPU 概览指标或状态点' -Element $metricControl -Root $root -Width $layoutWidth -Height $layoutHeight
                    }
                    if ($script:UI.CpuPageScroll.ScrollableWidth -gt 1.0) {
                        throw "CPU 页出现横向溢出，$($size.Name)：$($script:UI.CpuPageScroll.ScrollableWidth) DIP。"
                    }
                    $script:UI.CpuPageScroll.ScrollToVerticalOffset($script:UI.CpuPageScroll.ScrollableHeight)
                    $root.UpdateLayout()
                    $null = Assert-LayoutPreviewScrollAccess -Name '最大频率操作' -Element $script:UI.ApplyFrequencyButton -ScrollViewer $script:UI.CpuPageScroll -Root $root
                    $script:UI.CpuUndervoltExpander.IsExpanded = $true
                    $script:UI.DetailedDiagnosisExpander.IsExpanded = $true
                    $script:UI.CpuPageScroll.ScrollToEnd()
                    $root.UpdateLayout()
                    $null = Assert-LayoutPreviewBounds -Name '展开后的降压操作' -Element $script:UI.ApplyUndervoltButton -Root $root -Width $layoutWidth -Height $layoutHeight
                    $null = Assert-LayoutPreviewScrollAccess -Name '展开后的降压操作' -Element $script:UI.ApplyUndervoltButton -ScrollViewer $script:UI.CpuPageScroll -Root $root
                    if ($size.Name -eq 'minimum-800x600') {
                        $script:UI.Window.Width = $size.Width
                        $script:UI.Window.Height = $size.Height
                        $script:UI.CpuPageScroll.ScrollToEnd()
                        $root.UpdateLayout()
                        $advancedPath = Join-Path $previewDirectory 'cpu-minimum-advanced-expanded.png'
                        Save-LayoutPreviewImage -Path $advancedPath -Root $root -Width $layoutWidth -Height $layoutHeight
                    }
                    $script:UI.CpuUndervoltExpander.IsExpanded = $false
                    $script:UI.DetailedDiagnosisExpander.IsExpanded = $false
                    $script:UI.CpuPageScroll.ScrollToTop()
                }
                'process' {
                    Update-ProcessPriorityColumnWidths
                    $root.UpdateLayout()
                    if ($script:UI.ProcessPriorityGrid.ActualHeight -lt 150) { throw "程序列表高度不足，$($size.Name)：$($script:UI.ProcessPriorityGrid.ActualHeight) DIP。" }
                    $columnWidths = @($script:UI.ProcessPriorityGrid.Columns | ForEach-Object { [Math]::Round($_.ActualWidth, 1) })
                    if ($columnWidths.Count -lt 6 -or $columnWidths[1] -lt 120 -or $columnWidths[5] -lt 110) {
                        throw "程序名或状态列没有获得可读宽度，$($size.Name)：$($columnWidths -join ', ') DIP。"
                    }
                    foreach ($control in @($script:UI.ProcessPriorityRefreshButton, $script:UI.ProcessPriorityChoiceCombo, $script:UI.ProcessPriorityApplyButton, $script:UI.ProcessPriorityRestoreButton, $script:UI.ProcessPriorityDetailValue)) {
                        $null = Assert-LayoutPreviewBounds -Name '程序页工具或选定详情' -Element $control -Root $root -Width $layoutWidth -Height $layoutHeight
                    }
                    if ($size.Name -eq 'default-980x760') {
                        Set-StatusMessage -Message '就绪：请先选中一个程序，再选择目标优先级；原等级已记录时可恢复。'
                        $root.UpdateLayout()
                        $normalStatusPath = Join-Path $previewDirectory 'process-default-normal-status.png'
                        Save-LayoutPreviewImage -Path $normalStatusPath -Root $root -Width $layoutWidth -Height $layoutHeight
                        Set-StatusMessage -Message ((1..8 | ForEach-Object { '模拟错误详情（无真实操作）：状态读取未完成；请查看本页说明并重试。' }) -join ' ') -Error
                    }
                }
                'graphics' {
                    if ($script:UI.GraphicsPageScroll.ActualHeight -lt 180) { throw "图形页滚动区域高度不足，$($size.Name)。" }
                    foreach ($control in @($script:UI.GraphicsRefreshButton, $script:UI.GpuAdapterValue)) {
                        $null = Assert-LayoutPreviewBounds -Name '图形页状态' -Element $control -Root $root -Width $layoutWidth -Height $layoutHeight
                    }
                    $script:UI.GpuMuxStatusValue.BringIntoView()
                    $root.UpdateLayout()
                    $null = Assert-LayoutPreviewScrollAccess -Name '图形页MUX状态' -Element $script:UI.GpuMuxStatusValue -ScrollViewer $script:UI.GraphicsPageScroll -Root $root
                    foreach ($graphicsControl in @($script:UI.NvidiaControlPanelButton, $script:UI.WindowsGraphicsSettingsButton)) {
                        $graphicsControl.BringIntoView()
                        $root.UpdateLayout()
                        $null = Assert-LayoutPreviewScrollAccess -Name '显卡设置入口' -Element $graphicsControl -ScrollViewer $script:UI.GraphicsPageScroll -Root $root
                    }
                    $script:UI.GraphicsDetailsExpander.IsExpanded = $true
                    $script:UI.GraphicsPageScroll.ScrollToEnd()
                    $root.UpdateLayout()
                    $detailsBounds = Assert-LayoutPreviewScrollAccess -Name '展开后的图形资料' -Element $script:UI.GraphicsDetailsText -ScrollViewer $script:UI.GraphicsPageScroll -Root $root
                    if ($size.Name -eq 'minimum-800x600') {
                        $detailsPath = Join-Path $previewDirectory 'graphics-minimum-scrolled-details-expanded.png'
                        Save-LayoutPreviewImage -Path $detailsPath -Root $root -Width $layoutWidth -Height $layoutHeight
                        $viewportBounds = Get-LayoutPreviewBounds -Element $script:UI.GraphicsPageScroll -Root $root
                        @(
                            'Fixture preview only; 800x600 DIP window, graphics page scrolled to the end with details expanded.'
                            ('Graphics viewport: X={0:N1}, Y={1:N1}, Width={2:N1}, Height={3:N1} DIP' -f $viewportBounds.X, $viewportBounds.Y, $viewportBounds.Width, $viewportBounds.Height)
                            ('Details text: X={0:N1}, Y={1:N1}, Width={2:N1}, Height={3:N1} DIP; intersects viewport={4}' -f $detailsBounds.X, $detailsBounds.Y, $detailsBounds.Width, $detailsBounds.Height, ($detailsBounds.Bottom -gt $viewportBounds.Top -and $detailsBounds.Top -lt $viewportBounds.Bottom))
                            ('Scroll offset: {0:N1} / {1:N1} DIP' -f $script:UI.GraphicsPageScroll.VerticalOffset, $script:UI.GraphicsPageScroll.ScrollableHeight)
                        ) | Set-Content -LiteralPath (Join-Path $previewDirectory 'graphics-minimum-scrolled-details-expanded-bounds.txt') -Encoding UTF8
                    }
                    $script:UI.GraphicsDetailsExpander.IsExpanded = $false
                    $script:UI.GraphicsPageScroll.ScrollToTop()
                }
            }

            $root.UpdateLayout()
            $path = Join-Path $previewDirectory ("{0}-{1}.png" -f $page.Name, $size.Name)
            Save-LayoutPreviewImage -Path $path -Root $root -Width $layoutWidth -Height $layoutHeight
        }
    }

    Write-Output "PASS WPF fixture layout: default and minimum sizes, three tabs, fixed status, responsive CPU metrics without horizontal overflow, process table and controls, collapsible diagnostics verified."
    Write-Output "LAYOUT_PREVIEW=$previewDirectory"
}

function Start-DetectedGraphicsApp {
    param(
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][string]$DisplayName
    )

    if ([string]::IsNullOrWhiteSpace($AppId)) {
        Set-StatusMessage -Message "$DisplayName 未检测到可启动的已安装入口。" -Error
        return
    }
    try {
        $explorerPath = Join-Path $env:SystemRoot 'explorer.exe'
        $null = Start-Process -FilePath $explorerPath -ArgumentList "shell:AppsFolder\$AppId"
        Set-StatusMessage -Message "已请求打开 $DisplayName。"
    }
    catch {
        Set-StatusMessage -Message "无法打开 $DisplayName：$($_.Exception.Message)" -Error
    }
}

if ($LayoutPreview) {
    Export-LayoutPreview
    exit 0
}

$script:UI.MainTabs.Add_SelectionChanged({
    param($sender, $eventArgs)
    if ($sender -eq $script:UI.MainTabs) {
        $null = Request-CurrentPageRefresh
    }
})

$script:UI.ProcessPriorityGrid.Add_SelectionChanged({ Update-ProcessPriorityButtons })
$script:UI.ProcessPriorityRefreshButton.Add_Click({ $null = Request-CurrentPageRefresh -Force })
$script:UI.GraphicsRefreshButton.Add_Click({ $null = Request-CurrentPageRefresh -Force })
$script:UI.ProcessPriorityApplyButton.Add_Click({
    $selected = $script:UI.ProcessPriorityGrid.SelectedItem
    $choice = $script:UI.ProcessPriorityChoiceCombo.SelectedItem
    if ($null -eq $selected -or -not [bool]$selected.CanAdjust -or $null -eq $choice) {
        Set-StatusMessage -Message '请先选择一个允许调整的程序和目标优先级。' -Error
        return
    }
    $payload = @{
        ProcessId = [int]$selected.ProcessId
        StartTimeUtcTicks = [long]$selected.StartTimeUtcTicks
        ExecutablePath = [string]$selected.ExecutablePath
        Priority = [string]$choice.Tag
        ProtectedProcessId = $script:MainProcessId
    }
    $null = Start-UiOperation -Action 'ProcessPrioritySet' -Payload $payload -ProgressMessage "正在后台核对并调整选定程序 $($selected.ProcessName)（PID $($selected.ProcessId)）..."
})

$script:UI.ProcessPriorityRestoreButton.Add_Click({
    $selected = $script:UI.ProcessPriorityGrid.SelectedItem
    if ($null -eq $selected -or -not [bool]$selected.CanRestore) {
        Set-StatusMessage -Message '请选择有可用恢复记录且身份可核对的程序。' -Error
        return
    }
    $payload = @{
        ProcessId = [int]$selected.ProcessId
        StartTimeUtcTicks = [long]$selected.StartTimeUtcTicks
        ExecutablePath = [string]$selected.ExecutablePath
        ProtectedProcessId = $script:MainProcessId
    }
    $null = Start-UiOperation -Action 'ProcessPriorityRestore' -Payload $payload -ProgressMessage "正在后台核对并恢复选定程序 $($selected.ProcessName)（PID $($selected.ProcessId)）..."
})

$script:UI.NvidiaControlPanelButton.Add_Click({ Start-DetectedGraphicsApp -AppId ([string]$script:NvidiaControlPanelAppId) -DisplayName ([string]$script:NvidiaControlPanelAppName) })
$script:UI.LenovoVantageButton.Add_Click({ Start-DetectedGraphicsApp -AppId ([string]$script:LenovoVantageAppId) -DisplayName ([string]$script:LenovoVantageAppName) })
$script:UI.WindowsGraphicsSettingsButton.Add_Click({
    try {
        $null = Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList 'ms-settings:display-advancedgraphics'
        Set-StatusMessage -Message '已请求打开 Windows 应用图形首选项；此设置不切换物理显示连线。'
    }
    catch {
        Set-StatusMessage -Message "无法打开 Windows 应用图形首选项：$($_.Exception.Message)" -Error
    }
})
Update-ProcessPriorityButtons

$script:UI.RefreshButton.Add_Click({
    $null = Start-UiOperation -Action 'Refresh' -Payload @{} -ProgressMessage '正在后台读取状态...'
})

$script:UI.QuietButton.Add_Click({
    $null = Start-UiOperation -Action 'Quiet' -Payload @{ LimitTurbo = [bool]$script:UI.TurboLimitCheck.IsChecked } -ProgressMessage '正在后台写入联想静音散热档...'
})

$script:UI.BalancedButton.Add_Click({
    $null = Start-UiOperation -Action 'Balanced' -Payload @{} -ProgressMessage '正在切换联想官方均衡散热档...'
})

$script:UI.PerformanceButton.Add_Click({
    $null = Start-UiOperation -Action 'Performance' -Payload @{} -ProgressMessage '正在切换联想官方性能散热档...'
})

$script:UI.ApplyFrequencyButton.Add_Click({
    try {
        $mhz = ConvertTo-CpuFrequencyMHz -Value $script:UI.CpuFrequencyInput.Text
        $null = Start-UiOperation -Action 'FrequencyApply' -Payload @{ MHz = $mhz; Power = (Get-CpuFrequencyPowerTarget) } -ProgressMessage "正在后台写入 CPU 最大频率 $mhz MHz..."
    }
    catch {
        Set-StatusMessage -Message "频率设置失败：$($_.Exception.Message)" -Error
    }
})

$script:UI.ClearFrequencyButton.Add_Click({
    $null = Start-UiOperation -Action 'FrequencyClear' -Payload @{ Power = (Get-CpuFrequencyPowerTarget) } -ProgressMessage '正在后台取消 CPU 最大频率限制...'
})

$script:UI.RestoreFrequencyButton.Add_Click({
    $null = Start-UiOperation -Action 'FrequencyRestore' -Payload @{} -ProgressMessage '正在后台还原 CPU 最大频率备份...'
})

$script:UI.UnhideFrequencyButton.Add_Click({
    $null = Start-UiOperation -Action 'FrequencyUnhide' -Payload @{} -ProgressMessage '正在后台显示 Windows 的“处理器最大频率”选项...'
})

$script:UI.ApplyUndervoltButton.Add_Click({
    $offset = Get-CpuUndervoltLevelFromUi
    $progress = if ($offset -eq 0) { '正在通过 Intel XTU 后台还原 CPU 电压偏移...' } else { "正在通过 Intel XTU 后台应用 CPU 降压 $offset mV..." }
    $null = Start-UiOperation -Action 'UndervoltApply' -Payload @{ OffsetMilliVolts = $offset } -ProgressMessage $progress
})

$script:UI.ClearUndervoltButton.Add_Click({
    $null = Start-UiOperation -Action 'UndervoltClear' -Payload @{} -ProgressMessage '正在通过 Intel XTU 后台清除 CPU 降压...'
})

$script:UI.SelectXtuButton.Add_Click({
    try {
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Title = '选择 Intel XTU 的 XTUCli.exe'
        $dialog.Filter = 'Intel XTU CLI|XTUCli.exe|可执行文件|*.exe'
        $dialog.CheckFileExists = $true
        if ($dialog.ShowDialog() -eq $true) {
            $null = Start-UiOperation -Action 'SelectXtu' -Payload @{ XtuCliPath = $dialog.FileName } -ProgressMessage '正在后台保存 Intel XTU CLI 路径...'
        }
    }
    catch {
        Set-StatusMessage -Message "保存 XTU 路径失败：$($_.Exception.Message)" -Error
    }
})

$script:UI.RestorePowerButton.Add_Click({
    $null = Start-UiOperation -Action 'RestorePower' -Payload @{} -ProgressMessage '正在后台还原电源策略...'
})

$script:UI.Window.Add_Closing({
    param($sender, $eventArgs)
    if ($script:OperationInProgress) {
        $eventArgs.Cancel = $true
        if ($script:OperationIsReadOnly) {
            $script:CloseWhenOperationEnds = $true
            $script:OperationCancelled = $true
            Set-StatusMessage -Message '正在取消只读状态刷新，结束后关闭窗口。'
            $null = Stop-ReadOnlyUiWorker
        }
        else {
            Set-StatusMessage -Message '设置操作仍在执行，完成后再关闭窗口；为避免部分应用，不会中断工作进程。'
        }
    }
})

if ($AsyncLifecycleTest) {
    Invoke-AsyncLifecycleSelfTest
    exit 0
}

$script:UI.ModelText.Text = Get-ModelDescription
Initialize-CpuUndervoltLevels
$null = Start-UiOperation -Action 'Refresh' -Payload @{} -ProgressMessage '正在后台读取状态...'
$null = $script:UI.Window.ShowDialog()
