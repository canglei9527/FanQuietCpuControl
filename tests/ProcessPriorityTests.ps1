[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module -Force -Name (Join-Path $projectRoot 'src\ProcessPriorityControl.psm1')

function Assert-True {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][bool]$Condition)
    if (-not $Condition) { throw "FAIL $Name" }
    Write-Output "PASS $Name"
}

function Quote-PowerShellLiteral {
    param([Parameter(Mandatory)][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Get-EncodedPowerShellArguments {
    param([Parameter(Mandatory)][string]$Command)
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Command))
    return "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
}

function Start-ProcessPriorityTestWorker {
    param(
        [Parameter(Mandatory)][string]$ModulePath,
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][long]$StartTimeUtcTicks,
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string]$ReadyPath,
        [Parameter(Mandatory)][string]$OtherReadyPath
    )

    $command = @"
try {
    Import-Module -Force -Name $(Quote-PowerShellLiteral $ModulePath)
    [System.IO.File]::WriteAllText($(Quote-PowerShellLiteral $ReadyPath), 'ready')
    `$watch = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $(Quote-PowerShellLiteral $OtherReadyPath)) -and `$watch.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 25 }
    if (-not (Test-Path -LiteralPath $(Quote-PowerShellLiteral $OtherReadyPath))) { throw 'The concurrent test peer did not reach the start barrier.' }
    `$result = Set-ManagedProcessPriority -ProcessId `$ProcessId -StartTimeUtcTicks `$StartTimeUtcTicks -ExecutablePath $(Quote-PowerShellLiteral $ExecutablePath) -Priority 'BelowNormal' -BackupPath $(Quote-PowerShellLiteral $BackupPath)
    [Console]::Out.WriteLine((`$result | ConvertTo-Json -Compress))
    exit 0
}
catch {
    [Console]::Error.WriteLine(`$_.Exception.Message)
    exit 1
}
"@
    $command = $command.Replace('$ProcessId', [string]$ProcessId).Replace('$StartTimeUtcTicks', [string]$StartTimeUtcTicks)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $startInfo.Arguments = Get-EncodedPowerShellArguments -Command $command
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $worker = New-Object System.Diagnostics.Process
    $worker.StartInfo = $startInfo
    if (-not $worker.Start()) { throw 'Could not start a concurrent priority test worker.' }
    return [pscustomobject]@{
        Process = $worker
        StdoutTask = $worker.StandardOutput.ReadToEndAsync()
        StderrTask = $worker.StandardError.ReadToEndAsync()
    }
}

$temporaryBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
$testDirectory = Join-Path $temporaryBase ('FanQuietProcessPriorityTest-' + [Guid]::NewGuid().ToString('N'))
$testDirectoryFull = [System.IO.Path]::GetFullPath($testDirectory)
$testPrefix = $temporaryBase + [System.IO.Path]::DirectorySeparatorChar
if ($testDirectoryFull -eq $temporaryBase -or -not $testDirectoryFull.StartsWith($testPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe process priority test directory: $testDirectoryFull"
}

$backupPath = Join-Path $testDirectoryFull 'priority-backups.json'
$parallelBackupPath = Join-Path $testDirectoryFull '并发优先级-恢复记录.json'
$child = $null
$parallelChild = $null
$restoreNeeded = $false
$parallelPrimaryRestoreNeeded = $false
$parallelRestoreNeeded = $false
$blockedDirectoryPath = $null
$childStopPaths = New-Object 'System.Collections.Generic.List[string]'
$parallelWorkers = New-Object 'System.Collections.Generic.List[object]'
$mainProcessId = [System.Diagnostics.Process]::GetCurrentProcess().Id

try {
    New-Item -ItemType Directory -Path $testDirectoryFull | Out-Null
    $childStartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $childStartInfo.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $childStopPath = Join-Path $testDirectoryFull 'first-child.stop'
    $childStopPaths.Add($childStopPath)
    $childScript = "while (-not (Test-Path -LiteralPath $(Quote-PowerShellLiteral $childStopPath))) { Start-Sleep -Milliseconds 50 }"
    $childStartInfo.Arguments = Get-EncodedPowerShellArguments -Command $childScript
    $childStartInfo.UseShellExecute = $false
    $childStartInfo.CreateNoWindow = $true
    $child = [System.Diagnostics.Process]::Start($childStartInfo)
    if ($null -eq $child) { throw 'Could not start the isolated process priority test child.' }

    $child.Refresh()
    $processId = [int]$child.Id
    $startTimeUtcTicks = [long]$child.StartTime.ToUniversalTime().Ticks
    $executablePath = [System.IO.Path]::GetFullPath($child.MainModule.FileName)
    $originalPriority = [string]$child.PriorityClass

    $snapshot = @(Get-ProcessPrioritySnapshot -ProtectedProcessId $mainProcessId -BackupPath $backupPath)
    $candidate = @($snapshot | Where-Object { $_.ProcessId -eq $processId } | Select-Object -First 1)
    Assert-True -Name 'current-session background process is listed' -Condition ($candidate.Count -eq 1 -and $candidate[0].Category -eq '当前会话后台程序')
    Assert-True -Name 'process identity is eligible' -Condition ([bool]$candidate[0].CanAdjust)

    $mismatchRejected = $false
    try {
        Set-ManagedProcessPriority -ProcessId $processId -StartTimeUtcTicks ($startTimeUtcTicks + 1) -ExecutablePath $executablePath -Priority 'BelowNormal' -ProtectedProcessId $mainProcessId -BackupPath $backupPath | Out-Null
    }
    catch { $mismatchRejected = $true }
    Assert-True -Name 'stale start-time identity is rejected' -Condition $mismatchRejected

    $mainProcess = [System.Diagnostics.Process]::GetProcessById($mainProcessId)
    $mainStartTicks = [long]$mainProcess.StartTime.ToUniversalTime().Ticks
    $mainPath = [System.IO.Path]::GetFullPath($mainProcess.MainModule.FileName)
    $toolSelfRejected = $false
    try {
        Set-ManagedProcessPriority -ProcessId $mainProcessId -StartTimeUtcTicks $mainStartTicks -ExecutablePath $mainPath -Priority 'BelowNormal' -ProtectedProcessId $mainProcessId -BackupPath $backupPath | Out-Null
    }
    catch { $toolSelfRejected = $true }
    $mainProcess.Dispose()
    Assert-True -Name 'FanQuiet host process is rejected' -Condition $toolSelfRejected

    $criticalRejected = $false
    try {
        Set-ManagedProcessPriority -ProcessId 4 -StartTimeUtcTicks 0 -ExecutablePath (Join-Path $env:SystemRoot 'System32\ntoskrnl.exe') -Priority 'BelowNormal' -ProtectedProcessId $mainProcessId -BackupPath $backupPath | Out-Null
    }
    catch { $criticalRejected = $true }
    Assert-True -Name 'system critical process is rejected' -Condition $criticalRejected

    $realtimeRejected = $false
    try {
        Set-ManagedProcessPriority -ProcessId $processId -StartTimeUtcTicks $startTimeUtcTicks -ExecutablePath $executablePath -Priority 'Realtime' -ProtectedProcessId $mainProcessId -BackupPath $backupPath | Out-Null
    }
    catch { $realtimeRejected = $true }
    Assert-True -Name 'Realtime priority is rejected' -Condition $realtimeRejected

    $blockedDirectoryPath = Join-Path $testDirectoryFull 'not-a-directory'
    [System.IO.File]::WriteAllText($blockedDirectoryPath, 'fixture')
    $backupSaveRejected = $false
    try {
        Set-ManagedProcessPriority -ProcessId $processId -StartTimeUtcTicks $startTimeUtcTicks -ExecutablePath $executablePath -Priority 'BelowNormal' -ProtectedProcessId $mainProcessId -BackupPath (Join-Path $blockedDirectoryPath 'priority-backups.json') | Out-Null
    }
    catch { $backupSaveRejected = $true }
    $child.Refresh()
    Assert-True -Name 'priority is not changed when original backup cannot be saved' -Condition ($backupSaveRejected -and [string]$child.PriorityClass -eq $originalPriority)

    $changed = Set-ManagedProcessPriority -ProcessId $processId -StartTimeUtcTicks $startTimeUtcTicks -ExecutablePath $executablePath -Priority 'BelowNormal' -ProtectedProcessId $mainProcessId -BackupPath $backupPath
    $restoreNeeded = $true
    $child.Refresh()
    Assert-True -Name 'isolated child priority changed' -Condition ([string]$child.PriorityClass -eq 'BelowNormal' -and [string]$changed.OriginalPriority -eq $originalPriority)

    $snapshot = @(Get-ProcessPrioritySnapshot -ProtectedProcessId $mainProcessId -BackupPath $backupPath)
    $candidate = @($snapshot | Where-Object { $_.ProcessId -eq $processId } | Select-Object -First 1)
    Assert-True -Name 'snapshot retains original-priority recovery record' -Condition ($candidate.Count -eq 1 -and $candidate[0].OriginalPriority -eq $originalPriority -and $candidate[0].CanRestore)

    $backupLock = [System.IO.File]::Open($backupPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $cleanupFailureMessage = $null
    $cleanupFailureRestoredMarker = $false
    try {
        try {
            Restore-ManagedProcessPriority -ProcessId $processId -StartTimeUtcTicks $startTimeUtcTicks -ExecutablePath $executablePath -ProtectedProcessId $mainProcessId -BackupPath $backupPath | Out-Null
        }
        catch {
            $cleanupFailureMessage = $_.Exception.Message
            $cleanupFailureRestoredMarker = [bool]$_.Exception.Data['PriorityRestored']
        }
    }
    finally { $backupLock.Dispose() }
    $child.Refresh()
    Assert-True -Name 'restore reports applied priority when backup cleanup fails' -Condition ($cleanupFailureMessage -match '优先级已恢复为' -and [string]$child.PriorityClass -eq $originalPriority)
    Assert-True -Name 'restore cleanup warning carries applied-state marker' -Condition $cleanupFailureRestoredMarker
    $stateAfterCleanupFailure = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
    Assert-True -Name 'backup record remains retryable after cleanup failure' -Condition (@($stateAfterCleanupFailure.Backups).Count -eq 1)

    $restored = Restore-ManagedProcessPriority -ProcessId $processId -StartTimeUtcTicks $startTimeUtcTicks -ExecutablePath $executablePath -ProtectedProcessId $mainProcessId -BackupPath $backupPath
    $restoreNeeded = $false
    $child.Refresh()
    Assert-True -Name 'isolated child priority restored' -Condition ([string]$child.PriorityClass -eq $originalPriority -and [string]$restored.CurrentPriority -eq $originalPriority)

    $savedState = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
    Assert-True -Name 'restored identity removed from recovery records' -Condition (@($savedState.Backups).Count -eq 0)

    $parallelStopPath = Join-Path $testDirectoryFull 'parallel-child.stop'
    $childStopPaths.Add($parallelStopPath)
    $parallelChildStartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $parallelChildStartInfo.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $parallelChildScript = "while (-not (Test-Path -LiteralPath $(Quote-PowerShellLiteral $parallelStopPath))) { Start-Sleep -Milliseconds 50 }"
    $parallelChildStartInfo.Arguments = Get-EncodedPowerShellArguments -Command $parallelChildScript
    $parallelChildStartInfo.UseShellExecute = $false
    $parallelChildStartInfo.CreateNoWindow = $true
    $parallelChild = [System.Diagnostics.Process]::Start($parallelChildStartInfo)
    if ($null -eq $parallelChild) { throw 'Could not start the second isolated priority test process.' }

    $parallelChild.Refresh()
    $parallelProcessId = [int]$parallelChild.Id
    $parallelStartTimeUtcTicks = [long]$parallelChild.StartTime.ToUniversalTime().Ticks
    $parallelExecutablePath = [System.IO.Path]::GetFullPath($parallelChildStartInfo.FileName)
    $parallelOriginalPriority = [string]$parallelChild.PriorityClass
    $parallelPrimaryRestoreNeeded = $true
    $parallelRestoreNeeded = $true

    $readyOne = Join-Path $testDirectoryFull 'worker-one.ready'
    $readyTwo = Join-Path $testDirectoryFull 'worker-two.ready'
    $firstWorker = Start-ProcessPriorityTestWorker -ModulePath (Join-Path $projectRoot 'src\ProcessPriorityControl.psm1') -BackupPath $parallelBackupPath -ProcessId $processId -StartTimeUtcTicks $startTimeUtcTicks -ExecutablePath $executablePath -ReadyPath $readyOne -OtherReadyPath $readyTwo
    $parallelWorkers.Add($firstWorker)
    $secondWorker = Start-ProcessPriorityTestWorker -ModulePath (Join-Path $projectRoot 'src\ProcessPriorityControl.psm1') -BackupPath $parallelBackupPath -ProcessId $parallelProcessId -StartTimeUtcTicks $parallelStartTimeUtcTicks -ExecutablePath $parallelExecutablePath -ReadyPath $readyTwo -OtherReadyPath $readyOne
    $parallelWorkers.Add($secondWorker)
    foreach ($worker in $parallelWorkers) {
        if (-not $worker.Process.WaitForExit(30000)) { throw 'A concurrent priority worker did not finish within 30 seconds.' }
        $stdout = $worker.StdoutTask.GetAwaiter().GetResult()
        $stderr = $worker.StderrTask.GetAwaiter().GetResult()
        if ($worker.Process.ExitCode -ne 0) { throw "Concurrent priority worker failed: $stderr $stdout" }
    }
    $parallelChild.Refresh()
    $child.Refresh()
    $parallelState = Get-Content -LiteralPath $parallelBackupPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $parallelIds = @($parallelState.Backups | ForEach-Object { [int]$_.ProcessId })
    Assert-True -Name 'concurrent writes preserve both process recovery records' -Condition ($parallelIds.Count -eq 2 -and $parallelIds -contains $processId -and $parallelIds -contains $parallelProcessId)
    Assert-True -Name 'concurrent isolated process priorities were changed' -Condition ([string]$child.PriorityClass -eq 'BelowNormal' -and [string]$parallelChild.PriorityClass -eq 'BelowNormal')

    $null = Restore-ManagedProcessPriority -ProcessId $processId -StartTimeUtcTicks $startTimeUtcTicks -ExecutablePath $executablePath -ProtectedProcessId $mainProcessId -BackupPath $parallelBackupPath
    $parallelPrimaryRestoreNeeded = $false
    $restoreNeeded = $false
    $null = Restore-ManagedProcessPriority -ProcessId $parallelProcessId -StartTimeUtcTicks $parallelStartTimeUtcTicks -ExecutablePath $parallelExecutablePath -ProtectedProcessId $mainProcessId -BackupPath $parallelBackupPath
    $parallelRestoreNeeded = $false
    $child.Refresh()
    $parallelChild.Refresh()
    Assert-True -Name 'both concurrent targets restore their original priority' -Condition ([string]$child.PriorityClass -eq $originalPriority -and [string]$parallelChild.PriorityClass -eq $parallelOriginalPriority)
    $parallelRestoredState = Get-Content -LiteralPath $parallelBackupPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True -Name 'concurrent restore clears both recovery records' -Condition (@($parallelRestoredState.Backups).Count -eq 0)

    $unicodeBackupPath = Join-Path $testDirectoryFull '中文目录\优先级-备份.json'
    $unicodeState = [pscustomobject]@{
        Version = 1
        Backups = @([pscustomobject]@{
            ProcessName = '测试桌面程序'
            ProcessId = 2000000000
            StartTimeUtcTicks = [long]638950000000000000
            ExecutablePath = 'C:\测试目录\图形应用.exe'
            OriginalPriority = 'Normal'
            SavedAtUtc = [DateTime]::UtcNow.ToString('o')
        })
    }
    $priorityModule = Get-Module -Name ProcessPriorityControl
    & $priorityModule { param($State, $Path) Save-ProcessPriorityBackupState -State $State -BackupPath $Path } $unicodeState $unicodeBackupPath
    $unicodeSnapshot = @(Get-ProcessPrioritySnapshot -ProtectedProcessId $mainProcessId -BackupPath $unicodeBackupPath)
    $unicodeRow = @($unicodeSnapshot | Where-Object { $_.Category -eq '原恢复记录' -and $_.ProcessId -eq 2000000000 } | Select-Object -First 1)
    Assert-True -Name 'UTF-8 backup round-trip preserves Chinese process name and executable path' -Condition ($unicodeRow.Count -eq 1 -and $unicodeRow[0].ProcessName -eq '测试桌面程序' -and $unicodeRow[0].ExecutablePath -eq 'C:\测试目录\图形应用.exe')
}
catch {
    [Console]::Error.WriteLine("Process-priority test trace: $($_.Exception.ToString())")
    [Console]::Error.WriteLine([string]$_.ScriptStackTrace)
    throw
}
finally {
    foreach ($worker in $parallelWorkers) {
        if (-not $worker.Process.HasExited -and -not $worker.Process.WaitForExit(20000)) { throw 'A concurrent priority worker remains active; it was not terminated.' }
        try { $worker.Process.Dispose() } catch { }
    }
    if ($restoreNeeded -and $null -ne $child) {
        try {
            $child.Refresh()
            if (-not $child.HasExited) {
                $null = Restore-ManagedProcessPriority -ProcessId $child.Id -StartTimeUtcTicks ([long]$child.StartTime.ToUniversalTime().Ticks) -ExecutablePath $child.MainModule.FileName -ProtectedProcessId $mainProcessId -BackupPath $backupPath
            }
        }
        catch { Write-Warning "Best-effort isolated-process restore failed: $($_.Exception.Message)" }
    }
    if ($parallelPrimaryRestoreNeeded -and $null -ne $child) {
        try {
            $child.Refresh()
            if (-not $child.HasExited) {
                $null = Restore-ManagedProcessPriority -ProcessId $child.Id -StartTimeUtcTicks ([long]$child.StartTime.ToUniversalTime().Ticks) -ExecutablePath $child.MainModule.FileName -ProtectedProcessId $mainProcessId -BackupPath $parallelBackupPath
            }
        }
        catch { Write-Warning "Best-effort concurrent-primary restore failed: $($_.Exception.Message)" }
    }
    if ($parallelRestoreNeeded -and $null -ne $parallelChild) {
        try {
            $parallelChild.Refresh()
            if (-not $parallelChild.HasExited) {
                $null = Restore-ManagedProcessPriority -ProcessId $parallelChild.Id -StartTimeUtcTicks ([long]$parallelChild.StartTime.ToUniversalTime().Ticks) -ExecutablePath $parallelChild.MainModule.FileName -ProtectedProcessId $mainProcessId -BackupPath $parallelBackupPath
            }
        }
        catch { Write-Warning "Best-effort parallel isolated-process restore failed: $($_.Exception.Message)" }
    }
    foreach ($stopPath in $childStopPaths) {
        [System.IO.File]::WriteAllText($stopPath, 'stop')
    }
    foreach ($testChild in @($child, $parallelChild)) {
        if ($null -eq $testChild) { continue }
        if (-not $testChild.WaitForExit(10000)) { throw 'An isolated test process did not exit normally after its stop marker; it was not terminated.' }
        $testChild.Dispose()
    }
    if (Test-Path -LiteralPath $backupPath -PathType Leaf) { Remove-Item -LiteralPath $backupPath -Force }
    if ($null -ne $blockedDirectoryPath -and (Test-Path -LiteralPath $blockedDirectoryPath -PathType Leaf)) { Remove-Item -LiteralPath $blockedDirectoryPath -Force }
    $resolvedTestDirectory = [System.IO.Path]::GetFullPath($testDirectoryFull)
    if ($resolvedTestDirectory -eq $temporaryBase -or -not $resolvedTestDirectory.StartsWith($testPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to recursively remove a test directory outside the system temp child path: $resolvedTestDirectory"
    }
    if (Test-Path -LiteralPath $resolvedTestDirectory -PathType Container) { Remove-Item -LiteralPath $resolvedTestDirectory -Recurse -Force }
}

Write-Output 'PASS process-priority isolated integration tests; test child exited normally.'
