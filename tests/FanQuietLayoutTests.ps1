[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$entryPath = Join-Path $projectRoot 'src\FanQuietCpuControl.ps1'
$source = Get-Content -Raw -LiteralPath $entryPath
$xamlMatch = [regex]::Match($source, '(?s)\$xaml = @''\r?\n(?<Xaml>.*?)\r?\n''@')
if (-not $xamlMatch.Success) {
    throw 'FanQuiet XAML block was not found.'
}

[xml]$xaml = $xamlMatch.Groups['Xaml'].Value
$namespaces = [System.Xml.XmlNamespaceManager]::new($xaml.NameTable)
$namespaces.AddNamespace('p', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
$namespaces.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')

function Get-NamedXamlNode {
    param([Parameter(Mandatory)][string]$Name)

    $node = $xaml.SelectSingleNode("//*[@x:Name='$Name']", $namespaces)
    if ($null -eq $node) {
        throw "Required FanQuiet layout element is missing: $Name"
    }
    return $node
}

$tabs = @($xaml.SelectNodes('//p:TabControl[@x:Name="MainTabs"]/p:TabItem', $namespaces))
if ($tabs.Count -ne 3) {
    throw "Expected three independent FanQuiet tabs; found $($tabs.Count)."
}

$cpuTab = Get-NamedXamlNode -Name 'CpuTab'
$processTab = Get-NamedXamlNode -Name 'ProcessPriorityTab'
$graphicsTab = Get-NamedXamlNode -Name 'GraphicsTab'
$processGrid = Get-NamedXamlNode -Name 'ProcessPriorityGrid'
$processGridContainer = $processGrid.SelectSingleNode('ancestor::p:Grid[1]', $namespaces)
$starRows = @()
if ($null -ne $processGridContainer) {
    $starRows = @($processGridContainer.SelectNodes('./p:Grid.RowDefinitions/p:RowDefinition[@Height="*"]', $namespaces))
}
if ($starRows.Count -eq 0) {
    throw 'The process table is not inside a star-sized row that can use the remaining tab height.'
}

foreach ($name in @('ProcessPriorityRefreshButton', 'ProcessPriorityChoiceCombo', 'ProcessPriorityApplyButton', 'ProcessPriorityRestoreButton', 'ProcessPriorityDetailValue')) {
    $node = Get-NamedXamlNode -Name $name
    if (-not $processTab.SelectSingleNode(".//*[@x:Name='$name']", $namespaces)) {
        throw "Process page control is outside its own tab: $name"
    }
}

foreach ($name in @('DetailedDiagnosisExpander', 'CpuUndervoltExpander', 'GraphicsDetailsExpander')) {
    $node = Get-NamedXamlNode -Name $name
    if ($node.GetAttribute('IsExpanded') -ne 'False') {
        throw "Advanced details should be collapsed at startup: $name"
    }
}

$graphicsScroll = Get-NamedXamlNode -Name 'GraphicsPageScroll'
if (-not $graphicsTab.SelectSingleNode(".//*[@x:Name='GraphicsPageScroll']", $namespaces)) {
    throw 'The graphics page does not have its own scrollable body.'
}
$status = Get-NamedXamlNode -Name 'StatusBorder'
$statusViewer = $status.SelectSingleNode('.//p:ScrollViewer', $namespaces)
if ($status.GetAttribute('MaxHeight') -ne '72' -or $null -eq $statusViewer -or $statusViewer.GetAttribute('MaxHeight') -ne '50') {
    throw 'The global status area is not height-limited with its own scrolling.'
}
$null = Get-NamedXamlNode -Name 'StatusDot'
$cpuScroll = Get-NamedXamlNode -Name 'CpuPageScroll'
if (-not $cpuTab.SelectSingleNode(".//*[@x:Name='CpuPageScroll']", $namespaces)) {
    throw 'The CPU page does not have its own scrollable body.'
}
foreach ($metricName in @('CpuTempValue', 'GpuTempValue', 'Fan1Value', 'Fan2Value')) {
    $null = Get-NamedXamlNode -Name $metricName
    if (-not $cpuTab.SelectSingleNode(".//*[@x:Name='$metricName']", $namespaces)) {
        throw "CPU metric is outside its own tab: $metricName"
    }
}
if ($cpuScroll.GetAttribute('HorizontalScrollBarVisibility') -ne 'Disabled') {
    throw 'The CPU page must disable horizontal scrolling so content is not clipped off-screen.'
}

$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$previewOutput = @(& $windowsPowerShell -NoProfile -STA -ExecutionPolicy Bypass -File $entryPath -LayoutPreview 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "WPF layout preview failed: $($previewOutput -join ' ')"
}
$previewOutput | ForEach-Object { Write-Output $_ }
$previewLine = @($previewOutput | Where-Object { ([string]$_).StartsWith('LAYOUT_PREVIEW=') } | Select-Object -Last 1)
if ($previewLine.Count -eq 0) {
    throw 'WPF layout preview did not report its output directory.'
}
$previewDirectory = ([string]$previewLine[0]).Substring('LAYOUT_PREVIEW='.Length)
$previewFullPath = [IO.Path]::GetFullPath($previewDirectory)
$expectedRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot 'build\layout-preview')) + [IO.Path]::DirectorySeparatorChar
if (-not $previewFullPath.StartsWith($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "WPF layout preview escaped its project build directory: $previewFullPath"
}

foreach ($name in @(
    'cpu-default-980x760.png',
    'cpu-minimum-800x600.png',
    'cpu-minimum-advanced-expanded.png',
    'process-default-980x760.png',
    'process-default-normal-status.png',
    'process-minimum-800x600.png',
    'graphics-default-980x760.png',
    'graphics-minimum-800x600.png',
    'graphics-minimum-scrolled-details-expanded.png',
    'graphics-minimum-scrolled-details-expanded-bounds.txt'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $previewDirectory $name) -PathType Leaf)) {
        throw "WPF layout preview artifact is missing: $name"
    }
}

Write-Output 'PASS FanQuiet three-page layout structure and rendered reachability checks.'
