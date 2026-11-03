[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('FanQuietCpuControl-IExpress-' + [Guid]::NewGuid().ToString('N'))
$temporaryBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
$temporaryRootFull = [System.IO.Path]::GetFullPath($temporaryRoot)
$temporaryRootPrefix = $temporaryBase + [System.IO.Path]::DirectorySeparatorChar
if ($temporaryRootFull -eq $temporaryBase -or -not $temporaryRootFull.StartsWith($temporaryRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Temporary build path is outside the system temp directory: $temporaryRootFull"
}
$stageDirectory = Join-Path $temporaryRoot 'staging'
$temporaryTargetPath = Join-Path $temporaryRoot 'FanQuietCpuControl.exe'
$distDirectory = Join-Path $projectRoot 'dist'
$targetPath = Join-Path $distDirectory 'FanQuietCpuControl.exe'
$iexpressPath = Join-Path $env:SystemRoot 'System32\iexpress.exe'

$payload = @(
    [pscustomobject]@{
        Source = Join-Path $projectRoot 'src\FanQuietCpuControl.ps1'
        FileName = 'FanQuietCpuControl.ps1'
    }
    [pscustomobject]@{
        Source = Join-Path $projectRoot 'src\CpuMaxFrequencyControl.psm1'
        FileName = 'CpuMaxFrequencyControl.psm1'
    }
    [pscustomobject]@{
        Source = Join-Path $projectRoot 'src\CpuUndervolt.psm1'
        FileName = 'CpuUndervolt.psm1'
    }
    [pscustomobject]@{
        Source = Join-Path $projectRoot 'src\ProcessPriorityControl.psm1'
        FileName = 'ProcessPriorityControl.psm1'
    }
    [pscustomobject]@{
        Source = Join-Path $PSScriptRoot 'Launcher.ps1'
        FileName = 'Launcher.ps1'
    }
    [pscustomobject]@{
        Source = Join-Path $PSScriptRoot 'Launch-FanQuiet.cmd'
        FileName = 'Launch-FanQuiet.cmd'
    }
)

if (-not (Test-Path -LiteralPath $iexpressPath -PathType Leaf)) {
    throw "IExpress was not found: $iexpressPath"
}

foreach ($item in $payload) {
    if (-not (Test-Path -LiteralPath $item.Source -PathType Leaf)) {
        throw "Package source file is missing: $($item.Source)"
    }
}

New-Item -ItemType Directory -Force -Path $stageDirectory, $distDirectory | Out-Null
Remove-Item -LiteralPath $temporaryTargetPath -Force -ErrorAction SilentlyContinue

foreach ($item in $payload) {
    Copy-Item -LiteralPath $item.Source -Destination (Join-Path $stageDirectory $item.FileName) -Force
}

$sedPath = Join-Path $stageDirectory 'FanQuietCpuControl.sed'
$sed = @"
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=0
HideExtractAnimation=1
UseLongFileName=1
InsideCompressed=1
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=
DisplayLicense=
FinishMessage=
TargetName=$temporaryTargetPath
FriendlyName=FanQuiet CPU Frequency Control
AppLaunched=cmd.exe /c Launch-FanQuiet.cmd
PostInstallCmd=<None>
AdminQuietInstCmd=
UserQuietInstCmd=
SourceFiles=SourceFiles
[Strings]
FILE0="FanQuietCpuControl.ps1"
FILE1="CpuMaxFrequencyControl.psm1"
FILE2="CpuUndervolt.psm1"
FILE3="ProcessPriorityControl.psm1"
FILE4="Launcher.ps1"
FILE5="Launch-FanQuiet.cmd"
[SourceFiles]
SourceFiles0=$stageDirectory\
[SourceFiles0]
%FILE0%=
%FILE1%=
%FILE2%=
%FILE3%=
%FILE4%=
%FILE5%=
"@

Set-Content -LiteralPath $sedPath -Value $sed -Encoding ascii
$iexpressProcess = Start-Process -FilePath $iexpressPath -ArgumentList @('/N', '/Q', $sedPath) -WindowStyle Hidden -Wait -PassThru

if ($iexpressProcess.ExitCode -ne 0) {
    throw "IExpress failed with exit code $($iexpressProcess.ExitCode)."
}

if (-not (Test-Path -LiteralPath $temporaryTargetPath -PathType Leaf)) {
    throw "IExpress finished without producing the package: $temporaryTargetPath"
}

[byte[]]$header = Get-Content -LiteralPath $temporaryTargetPath -Encoding Byte -TotalCount 2
if ($header.Count -ne 2 -or $header[0] -ne 0x4D -or $header[1] -ne 0x5A) {
    throw "The generated package is not a Windows executable: $temporaryTargetPath"
}

$actualTargetPath = $targetPath
try {
    $null = Move-Item -LiteralPath $temporaryTargetPath -Destination $targetPath -Force
}
catch {
    $suffix = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $actualTargetPath = Join-Path $distDirectory "FanQuietCpuControl-optimized-$suffix.exe"
    $null = Move-Item -LiteralPath $temporaryTargetPath -Destination $actualTargetPath
    Write-Warning "The standard EXE could not be replaced, so the optimized build was saved as $actualTargetPath. The existing EXE was left in place."
}

$resolvedTemporaryRoot = [System.IO.Path]::GetFullPath($temporaryRoot)
if ($resolvedTemporaryRoot -eq $temporaryBase -or -not $resolvedTemporaryRoot.StartsWith($temporaryRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing recursive cleanup outside the system temp directory: $resolvedTemporaryRoot"
}
$null = Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
$artifact = Get-Item -LiteralPath $actualTargetPath
Write-Output "Built EXE: $($artifact.FullName) ($($artifact.Length) bytes)"
